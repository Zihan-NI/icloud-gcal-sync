import Foundation

/// Minimal logger: one line per message to stderr and, when configured, to a size-rotated file.
public enum Log {
    public enum Level: Int, Sendable { case debug = 0, info, warning, error }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fileURL: URL?
    nonisolated(unsafe) private static var minLevel: Level = .info
    nonisolated(unsafe) private static var echo = true
    private static let maxBytes: UInt64 = 1_000_000
    private static let backups = 3

    public static func configure(file: URL?, verbose: Bool, echoToStderr: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        fileURL = file
        minLevel = verbose ? .debug : .info
        echo = echoToStderr
    }

    public static func debug(_ m: @autoclosure () -> String) { write(.debug, m()) }
    public static func info(_ m: @autoclosure () -> String) { write(.info, m()) }
    public static func warning(_ m: @autoclosure () -> String) { write(.warning, m()) }
    public static func error(_ m: @autoclosure () -> String) { write(.error, m()) }

    private static func write(_ level: Level, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard level.rawValue >= minLevel.rawValue else { return }
        let name = ["DEBUG", "INFO", "WARNING", "ERROR"][level.rawValue]
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        let line = "\(f.string(from: Date())) \(name) \(message)\n"
        if echo { FileHandle.standardError.write(Data(line.utf8)) }
        guard let url = fileURL else { return }
        rotateIfNeeded(url)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > maxBytes else { return }
        for i in stride(from: backups - 1, through: 1, by: -1) {
            let from = url.path + ".\(i)", to = url.path + ".\(i + 1)"
            try? fm.removeItem(atPath: to)
            try? fm.moveItem(atPath: from, toPath: to)
        }
        try? fm.removeItem(atPath: url.path + ".1")
        try? fm.moveItem(atPath: url.path, toPath: url.path + ".1")
    }
}
