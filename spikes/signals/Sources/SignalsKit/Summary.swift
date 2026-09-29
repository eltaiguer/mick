import Foundation

/// Aggregates a results log into the numbers the verdict reports.
public struct ProbeSummary: Sendable, Equatable {
    public var label: String?
    public var durationSeconds: Double
    public var timerFires: Int
    public var timerMaxLateness: Double
    public var timerMeanLateness: Double
    public var timerLateOver1s: Int
    public var fileWatchCallbacks: Int
    public var fileWatchMaxLatency: Double
    public var fileWatchMeanLatency: Double
    public var fileWatchOver2s: Int
    public var signals: [String]

    public init(records: [ProbeRecord]) {
        label = records.first { $0.kind == .start }?.note
        let times = records.map(\.t)
        durationSeconds = (times.max() ?? 0) - (times.min() ?? 0)
        let timer = records.filter { $0.kind == .timer }.compactMap(\.lateness)
        timerFires = timer.count
        timerMaxLateness = timer.max() ?? 0
        timerMeanLateness = timer.isEmpty ? 0 : timer.reduce(0, +) / Double(timer.count)
        timerLateOver1s = timer.filter { $0 > 1 }.count
        let fw = records.filter { $0.kind == .fileWatch }.compactMap(\.lateness)
        fileWatchCallbacks = fw.count
        fileWatchMaxLatency = fw.max() ?? 0
        fileWatchMeanLatency = fw.isEmpty ? 0 : fw.reduce(0, +) / Double(fw.count)
        fileWatchOver2s = fw.filter { $0 > 2 }.count
        signals = records.filter { $0.kind == .signal }.compactMap(\.note)
    }

    public static func load(_ url: URL) throws -> ProbeSummary {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        let records = text.split(separator: "\n").compactMap {
            try? decoder.decode(ProbeRecord.self, from: Data($0.utf8))
        }
        return ProbeSummary(records: records)
    }

    public var text: String {
        func f(_ d: Double) -> String { String(format: "%.3f", d) }
        return """
        run: \(label ?? "?")
        duration: \(f(durationSeconds / 60)) min
        timer (one-shot, re-armed): fires=\(timerFires) mean_late=\(f(timerMeanLateness))s max_late=\(f(timerMaxLateness))s late>1s=\(timerLateOver1s)
        file watch (vnode, main queue): callbacks=\(fileWatchCallbacks) mean_latency=\(f(fileWatchMeanLatency))s max_latency=\(f(fileWatchMaxLatency))s over2s=\(fileWatchOver2s)
        workspace signals: \(signals.isEmpty ? "none" : signals.joined(separator: ", "))
        """
    }
}

/// A file-watch line is the writer's timestamp: seconds since 1970 as a decimal.
public enum WriterLine {
    public static func make(at date: Date = Date()) -> String {
        String(format: "%.6f", date.timeIntervalSince1970)
    }

    public static func latency(of line: String, receivedAt date: Date = Date()) -> Double? {
        guard let t = Double(line.trimmingCharacters(in: .whitespaces)) else { return nil }
        return date.timeIntervalSince1970 - t
    }
}
