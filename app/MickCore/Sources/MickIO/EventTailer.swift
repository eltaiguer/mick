import Darwin
import Dispatch
import Foundation
import MickCore

/// Lines read from the events files in one go.
public struct TailBatch: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// `events.jsonl`.
        case main
        /// `events.jsonl.old`, drained after a rotation (or left over from a crash).
        case rotated
    }

    public var lines: [String]
    public var origin: EventOrigin
    public var source: Source
    /// For `.main`: the offset in `events.jsonl` after this batch, to persist as
    /// `events_offset`. Nil for `.rotated`.
    public var offset: UInt64?
}

/// Follows `events.jsonl` (SPEC §6.3):
///
/// - Reads new complete lines from the last offset. On start, the saved offset is used
///   unless the file is shorter (truncated or replaced), in which case it resets to 0.
///   Everything read by the first pass is backlog; everything after is live.
/// - A vnode source on the file catches appends; a vnode source on the directory
///   catches the file being created or recreated. If the file is renamed or deleted,
///   whatever is left in the old descriptor is read, then the new file is opened at 0.
/// - Rotation: once the file passes the size limit and has been read to the end, it's
///   renamed to `events.jsonl.old` and the old descriptor is kept. After the drain
///   delay (2 s) the rest of it (from a hook that opened the file just before the
///   rename) is read and the file deleted.
///
/// All work happens on a private serial queue; batches are delivered on that queue in
/// file order.
public final class EventTailer: @unchecked Sendable {
    public let directory: URL
    private let rotateBytes: UInt64
    private let drainDelay: TimeInterval
    private let log: any MickLogger
    private let onBatch: @Sendable (TailBatch) -> Void
    private let queue = DispatchQueue(label: "mick.event-tailer")

    // Only touched on `queue`.
    private var savedOffset: UInt64
    private var started = false
    private var stopped = false
    private var firstPass = true
    private var readFD: Int32 = -1
    private var identity: FileIdentity?
    private var offset: UInt64 = 0
    private var lastReportedOffset: UInt64?
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private var directorySource: (any DispatchSourceFileSystemObject)?
    private var rotated: (fd: Int32, offset: UInt64, identity: FileIdentity)?
    private var drainWork: DispatchWorkItem?

    private var eventsPath: String { directory.appendingPathComponent(EventFilePolicy.fileName).path }
    private var rotatedPath: String { directory.appendingPathComponent(EventFilePolicy.rotatedFileName).path }

    public init(
        directory: URL,
        startOffset: UInt64,
        rotateBytes: UInt64 = EventFilePolicy.rotateBytes,
        drainDelay: TimeInterval = EventFilePolicy.drainDelay,
        log: any MickLogger,
        onBatch: @escaping @Sendable (TailBatch) -> Void
    ) {
        self.directory = directory
        self.savedOffset = startOffset
        self.rotateBytes = rotateBytes
        self.drainDelay = drainDelay
        self.log = log
        self.onBatch = onBatch
    }

    deinit {
        // Sources hold closures that capture self weakly; close anything still open.
        if readFD >= 0 { close(readFD) }
        if let rotated { close(rotated.fd) }
    }

    /// Reads the backlog, then starts watching. Idempotent.
    public func start() {
        queue.async { [self] in
            guard !started, !stopped else { return }
            started = true
            watchDirectory()
            drainLeftoverRotatedFile()
            sync()
            firstPass = false
        }
    }

    public func stop() {
        queue.sync { [self] in
            stopped = true
            drainWork?.cancel()
            drainWork = nil
            directorySource?.cancel()
            directorySource = nil
            closeCurrentFile()
            if let rotated { close(rotated.fd) }
            rotated = nil
        }
    }

    /// Re-checks the file now (a safety net next to the vnode sources).
    public func poke() {
        queue.async { [self] in
            guard started, !stopped else { return }
            sync()
        }
    }

    /// Blocks until everything queued so far has run (tests).
    public func waitUntilIdle() {
        queue.sync {}
    }

    // MARK: - Watching

    private func watchDirectory() {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            log.log("can't watch \(directory.path): \(String(cString: strerror(errno)))")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self] in self?.sync() }
        source.setCancelHandler { close(fd) }
        source.resume()
        directorySource = source
    }

    private func watchFile() {
        fileSource?.cancel()
        let fd = open(eventsPath, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: queue)
        source.setEventHandler { [weak self] in self?.sync() }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    private func closeCurrentFile() {
        fileSource?.cancel()
        fileSource = nil
        if readFD >= 0 { close(readFD) }
        readFD = -1
        identity = nil
    }

    // MARK: - Reading

    private func sync() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !stopped else { return }
        let onDisk = FileIdentity(path: eventsPath)

        // The file we hold was renamed, deleted or replaced: finish it, then let go.
        if readFD >= 0, onDisk != identity {
            readToEnd(fd: readFD, from: offset, origin: origin, source: .main, final: false)
            log.log("events.jsonl was replaced or removed; reopening")
            closeCurrentFile()
            offset = 0
            report(lines: [], source: .main)
        }

        if readFD < 0, let onDisk {
            let fd = open(eventsPath, O_RDONLY)
            guard fd >= 0 else {
                log.log("can't open events.jsonl: \(String(cString: strerror(errno)))")
                return
            }
            readFD = fd
            identity = FileIdentity(fd: fd) ?? onDisk
            if firstPass {
                offset = EventFilePolicy.startOffset(saved: savedOffset, fileSize: onDisk.size)
                if offset != savedOffset {
                    log.log("events.jsonl is shorter than the saved offset (\(onDisk.size) < \(savedOffset)); reading from 0")
                }
            } else {
                offset = 0
            }
            watchFile()
        } else if readFD < 0, firstPass, savedOffset != 0 {
            log.log("events.jsonl missing; resetting the saved offset")
            offset = 0
            report(lines: [], source: .main)
        }

        guard readFD >= 0 else { return }
        if let size = FileIdentity(fd: readFD)?.size, size < offset {
            log.log("events.jsonl shrank (\(size) < \(offset)); reading from 0")
            offset = 0
        }
        readToEnd(fd: readFD, from: offset, origin: origin, source: .main, final: false)
        report(lines: [], source: .main)  // the offset may have changed with no lines
        rotateIfNeeded()
    }

    private var origin: EventOrigin { firstPass ? .backlog : .live }

    /// Reads `fd` from `start` to its current end and delivers the complete lines.
    /// With `final`, a trailing line without a newline is delivered too. For `.main`,
    /// `self.offset` follows along before each delivery. Returns the end offset.
    @discardableResult
    private func readToEnd(fd: Int32, from start: UInt64, origin: EventOrigin, source: TailBatch.Source, final: Bool) -> UInt64 {
        let chunkSize = 1 << 20
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var pending = Data()
        var pendingStart = start
        while true {
            let position = off_t(pendingStart) + off_t(pending.count)
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, chunkSize, position) }
            if n < 0 {
                log.log("read error on \(source == .main ? EventFilePolicy.fileName : EventFilePolicy.rotatedFileName): \(String(cString: strerror(errno)))")
                break
            }
            if n == 0 { break }
            pending.append(contentsOf: buffer[0..<n])
            let split = EventLines.split(pending)
            if split.consumed > 0 {
                pendingStart += UInt64(split.consumed)
                pending = Data(pending.dropFirst(split.consumed))
                if source == .main { offset = pendingStart }
                deliver(split.lines, origin: origin, source: source)
            }
        }
        if final, !pending.isEmpty {
            let split = EventLines.split(pending, includeTrailingPartial: true)
            pendingStart += UInt64(split.consumed)
            if source == .main { offset = pendingStart }
            deliver(split.lines, origin: origin, source: source)
        }
        return pendingStart
    }

    private func deliver(_ lines: [String], origin: EventOrigin, source: TailBatch.Source) {
        switch source {
        case .main: report(lines: lines, source: .main, origin: origin)
        case .rotated: if !lines.isEmpty { onBatch(TailBatch(lines: lines, origin: origin, source: .rotated, offset: nil)) }
        }
    }

    /// Delivers a `.main` batch when there are lines or the offset moved.
    private func report(lines: [String], source: TailBatch.Source, origin: EventOrigin? = nil) {
        guard !lines.isEmpty || lastReportedOffset != offset else { return }
        lastReportedOffset = offset
        onBatch(TailBatch(lines: lines, origin: origin ?? self.origin, source: .main, offset: offset))
    }

    // MARK: - Rotation

    private func rotateIfNeeded() {
        guard readFD >= 0, let size = FileIdentity(fd: readFD)?.size,
              EventFilePolicy.shouldRotate(fileSize: size, offset: offset, limit: rotateBytes) else { return }
        if rotated != nil { drainRotated() }  // a previous rotation is still pending; finish it first
        guard rename(eventsPath, rotatedPath) == 0 else {
            log.log("couldn't rotate events.jsonl: \(String(cString: strerror(errno)))")
            return
        }
        log.log("rotated events.jsonl at \(size) bytes")
        let fd = readFD
        let id = identity ?? FileIdentity(fd: fd)!
        fileSource?.cancel()
        fileSource = nil
        readFD = -1
        identity = nil
        rotated = (fd: fd, offset: offset, identity: id)
        offset = 0
        report(lines: [], source: .main)

        let work = DispatchWorkItem { [weak self] in self?.drainRotated() }
        drainWork = work
        queue.asyncAfter(deadline: .now() + drainDelay, execute: work)
    }

    private func drainRotated() {
        dispatchPrecondition(condition: .onQueue(queue))
        drainWork?.cancel()
        drainWork = nil
        guard let r = rotated else { return }
        rotated = nil
        let start = readToEnd(fd: r.fd, from: r.offset, origin: .live, source: .rotated, final: true)
        if start > r.offset { log.log("drained \(start - r.offset) bytes from events.jsonl.old") }
        close(r.fd)
        if FileIdentity(path: rotatedPath) == r.identity {
            unlink(rotatedPath)
        }
    }

    /// A `.old` file left by a crash between a rotation and its drain. The saved offset
    /// was already reset for the new file, so its lines are replayed as backlog;
    /// ordering drops the ones already applied (same `t`).
    private func drainLeftoverRotatedFile() {
        guard FileIdentity(path: rotatedPath) != nil else { return }
        let fd = open(rotatedPath, O_RDONLY)
        guard fd >= 0 else { return }
        log.log("found a leftover events.jsonl.old; replaying it as backlog")
        readToEnd(fd: fd, from: 0, origin: .backlog, source: .rotated, final: true)
        close(fd)
        unlink(rotatedPath)
    }
}

/// Device + inode (to tell a replaced file from an appended one) and size.
struct FileIdentity: Equatable {
    var device: dev_t
    var inode: ino_t
    var size: UInt64

    init?(path: String) {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        self.init(st)
    }

    init?(fd: Int32) {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        self.init(st)
    }

    private init(_ st: stat) {
        device = st.st_dev
        inode = st.st_ino
        size = UInt64(max(st.st_size, 0))
    }

    /// Same file, whatever the size.
    static func == (a: FileIdentity, b: FileIdentity) -> Bool {
        a.device == b.device && a.inode == b.inode
    }
}
