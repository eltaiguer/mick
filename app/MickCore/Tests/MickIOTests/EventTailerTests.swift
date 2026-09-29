import Foundation
import Testing
@testable import MickIO
import MickCore

@Suite(.serialized) struct EventTailerTests {
    private func makeTailer(_ temp: TempHome, offset: UInt64 = 0, rotateBytes: UInt64 = EventFilePolicy.rotateBytes,
                            drainDelay: TimeInterval = EventFilePolicy.drainDelay, sink: BatchSink, log: MemoryLog = MemoryLog()) -> EventTailer {
        EventTailer(directory: temp.home.url, startOffset: offset, rotateBytes: rotateBytes, drainDelay: drainDelay, log: log) { sink.add($0) }
    }

    @Test func existingLinesAreBacklogAndNewOnesAreLive() async throws {
        let temp = try TempHome()
        try temp.append(line("prompt", nowT) + line("stop", nowT + 1))
        let sink = BatchSink()
        let tailer = makeTailer(temp, sink: sink)
        defer { tailer.stop() }
        tailer.start()
        tailer.waitUntilIdle()
        #expect(sink.lines(origin: .backlog).count == 2)
        #expect(sink.lastOffset == temp.size())

        try temp.append(line("prompt", nowT + 2))
        #expect(await eventually { sink.lines(origin: .live).count == 1 })
        #expect(sink.lastOffset == temp.size())
    }

    @Test func readsFromTheSavedOffset() throws {
        let temp = try TempHome()
        let first = line("prompt", nowT)
        try temp.append(first + line("stop", nowT + 1))
        let sink = BatchSink()
        let tailer = makeTailer(temp, offset: UInt64(first.utf8.count), sink: sink)
        defer { tailer.stop() }
        tailer.start()
        tailer.waitUntilIdle()
        #expect(sink.lines.count == 1)
        #expect(sink.lines.first?.contains(#""e":"stop""#) == true)
    }

    @Test func resetsTheOffsetWhenTheFileShrankWhileNotRunning() throws {
        let temp = try TempHome()
        try temp.append(line("prompt", nowT))
        let sink = BatchSink()
        let log = MemoryLog()
        let tailer = makeTailer(temp, offset: 10_000, sink: sink, log: log)
        defer { tailer.stop() }
        tailer.start()
        tailer.waitUntilIdle()
        #expect(sink.lines(origin: .backlog).count == 1)
        #expect(sink.lastOffset == temp.size())
        #expect(log.messages.contains { $0.contains("shorter than the saved offset") })
    }

    @Test func resetsTheOffsetWhenTheFileIsMissingAtLaunch() throws {
        let temp = try TempHome()
        let sink = BatchSink()
        let tailer = makeTailer(temp, offset: 500, sink: sink)
        defer { tailer.stop() }
        tailer.start()
        tailer.waitUntilIdle()
        #expect(sink.lastOffset == 0)
    }

    @Test func handlesTruncationInPlace() async throws {
        let temp = try TempHome()
        try temp.append(line("prompt", nowT) + line("stop", nowT + 1))
        let sink = BatchSink()
        let tailer = makeTailer(temp, sink: sink)
        defer { tailer.stop() }
        tailer.start()
        tailer.waitUntilIdle()
        // Truncate the same file (same inode), then write one short line.
        let handle = try FileHandle(forWritingTo: temp.home.events)
        try handle.truncate(atOffset: 0)
        try handle.close()
        try temp.append(line("prompt", nowT + 5, "B"))
        #expect(await eventually { sink.lines(origin: .live).contains { $0.contains(#""s":"B""#) } })
        #expect(await eventually { sink.lastOffset == temp.size() })
    }

    @Test func noticesTheFileBeingCreated() async throws {
        let temp = try TempHome()
        let sink = BatchSink()
        let tailer = makeTailer(temp, sink: sink)
        defer { tailer.stop() }
        tailer.start()
        tailer.waitUntilIdle()
        #expect(sink.lines.isEmpty)
        try temp.append(line("prompt", nowT))
        #expect(await eventually(timeout: .seconds(2)) { sink.lines(origin: .live).count == 1 })
        try temp.append(line("stop", nowT + 1))
        #expect(await eventually(timeout: .seconds(2)) { sink.lines(origin: .live).count == 2 })
    }

    @Test func noticesTheFileBeingDeletedAndRecreated() async throws {
        let temp = try TempHome()
        try temp.append(line("prompt", nowT))
        let sink = BatchSink()
        let tailer = makeTailer(temp, sink: sink)
        defer { tailer.stop() }
        tailer.start()
        tailer.waitUntilIdle()
        try FileManager.default.removeItem(at: temp.home.events)
        #expect(await eventually { sink.lastOffset == 0 })
        try temp.append(line("prompt", nowT + 3, "B"))
        #expect(await eventually(timeout: .seconds(2)) { sink.lines(origin: .live).count == 1 })
        #expect(sink.lastOffset == temp.size())
    }

    @Test func readsWhatWasLeftWhenTheFileIsReplacedExternally() async throws {
        let temp = try TempHome()
        try temp.append(line("prompt", nowT))
        let sink = BatchSink()
        let tailer = makeTailer(temp, sink: sink)
        defer { tailer.stop() }
        tailer.start()
        tailer.waitUntilIdle()
        // Replace via rename, the way an editor or a script might: a new file with new content.
        let replacement = temp.root.appendingPathComponent("replacement")
        try Data(line("prompt", nowT + 7, "C").utf8).write(to: replacement)
        _ = rename(replacement.path, temp.eventsPath)
        #expect(await eventually(timeout: .seconds(2)) { sink.lines(origin: .live).contains { $0.contains(#""s":"C""#) } })
        #expect(sink.lastOffset == temp.size())
    }

    @Test func leavesAPartialLineForTheNextRead() async throws {
        let temp = try TempHome()
        let sink = BatchSink()
        let tailer = makeTailer(temp, sink: sink)
        defer { tailer.stop() }
        tailer.start()
        let full = line("prompt", nowT)
        let cut = full.utf8.count / 2
        try temp.append(String(full.prefix(cut)))
        tailer.poke()
        tailer.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(200))
        #expect(sink.lines.isEmpty)
        #expect((sink.lastOffset ?? 0) == 0)
        try temp.append(String(full.dropFirst(cut)))
        #expect(await eventually { sink.lines == [full.trimmingCharacters(in: .newlines)] })
        #expect(sink.lastOffset == UInt64(full.utf8.count))
    }

    @Test func rotatesPastTheLimitAndDrainsTheOldFile() async throws {
        let temp = try TempHome()
        let sink = BatchSink()
        let log = MemoryLog()
        // Small limit and a long enough drain delay to write into .old in between.
        let tailer = makeTailer(temp, rotateBytes: 300, drainDelay: 0.6, sink: sink, log: log)
        defer { tailer.stop() }
        tailer.start()
        tailer.waitUntilIdle()

        var written = ""
        var i = 0.0
        while written.utf8.count <= 300 {
            written += line("prompt", nowT + i)
            i += 1
        }
        try temp.append(written)
        #expect(await eventually { FileManager.default.fileExists(atPath: temp.home.rotatedEvents.path) })
        #expect(!FileManager.default.fileExists(atPath: temp.eventsPath))
        #expect(await eventually { sink.lastOffset == 0 })
        let beforeLate = sink.lines.count
        #expect(beforeLate == Int(i))

        // A hook that opened the file just before the rename writes into .old...
        try temp.append(line("stop", nowT + 100, "late"), to: temp.home.rotatedEvents)
        // ...and new hook writes create a fresh events.jsonl.
        try temp.append(line("prompt", nowT + 101, "fresh"))
        #expect(await eventually(timeout: .seconds(2)) { sink.lines.contains { $0.contains(#""s":"fresh""#) } })

        // After the drain delay the late line is read and .old is deleted.
        #expect(await eventually(timeout: .seconds(3)) { sink.lines.contains { $0.contains(#""s":"late""#) } })
        #expect(await eventually { !FileManager.default.fileExists(atPath: temp.home.rotatedEvents.path) })
        let late = sink.batches.first { $0.lines.contains { $0.contains(#""s":"late""#) } }
        #expect(late?.source == .rotated)
        #expect(late?.origin == .live)
        #expect(late?.offset == nil)
        #expect(sink.lastOffset == temp.size())
        #expect(log.messages.contains { $0.contains("rotated events.jsonl") })
    }

    @Test func doesNotRotateAtOrBelowTheLimit() async throws {
        let temp = try TempHome()
        let sink = BatchSink()
        let tailer = makeTailer(temp, rotateBytes: 10_000, drainDelay: 0.1, sink: sink)
        defer { tailer.stop() }
        tailer.start()
        try temp.append(line("prompt", nowT))
        #expect(await eventually { sink.lines.count == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(FileManager.default.fileExists(atPath: temp.eventsPath))
        #expect(!FileManager.default.fileExists(atPath: temp.home.rotatedEvents.path))
    }

    @Test func rotatesTheBacklogAtLaunchToo() async throws {
        let temp = try TempHome()
        var written = ""
        for i in 0..<10 { written += line("stop", nowT + Double(i)) }
        try temp.append(written)
        let sink = BatchSink()
        let tailer = makeTailer(temp, rotateBytes: 100, drainDelay: 0.1, sink: sink)
        defer { tailer.stop() }
        tailer.start()
        tailer.waitUntilIdle()
        #expect(sink.lines(origin: .backlog).count == 10)
        #expect(sink.lastOffset == 0)
        #expect(await eventually { !FileManager.default.fileExists(atPath: temp.home.rotatedEvents.path) })
    }

    @Test func replaysALeftoverOldFileAsBacklog() throws {
        let temp = try TempHome()
        try temp.append(line("prompt", nowT, "old"), to: temp.home.rotatedEvents)
        try temp.append(line("stop", nowT + 1, "new"))
        let sink = BatchSink()
        let tailer = makeTailer(temp, sink: sink)
        defer { tailer.stop() }
        tailer.start()
        tailer.waitUntilIdle()
        #expect(sink.lines(origin: .backlog).count == 2)
        #expect(sink.lines.first?.contains(#""s":"old""#) == true)  // before the main file
        #expect(!FileManager.default.fileExists(atPath: temp.home.rotatedEvents.path))
    }

    @Test func stopClosesEverything() async throws {
        let temp = try TempHome()
        let sink = BatchSink()
        let tailer = makeTailer(temp, sink: sink)
        tailer.start()
        tailer.waitUntilIdle()
        tailer.stop()
        try temp.append(line("prompt", nowT))
        try await Task.sleep(for: .milliseconds(200))
        #expect(sink.lines.isEmpty)
    }
}
