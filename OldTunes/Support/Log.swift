import Foundation
import os

/// One log for the whole app: ~/Library/Logs/OldTunes/oldtunes.log, plus stdout and os_log.
/// Harness runs capture stdout with `open --stdout`, so agents and humans read the same lines.
enum Log {
    private static let logger = Logger(subsystem: "com.noahtsutsui.oldtunes", category: "app")
    private static let queue = DispatchQueue(label: "com.noahtsutsui.oldtunes.log")
    /// Rotated at launch once it passes this size, keeping one previous file.
    private static let rotateBytes = 5 * 1024 * 1024

    /// Opened with O_APPEND and written one whole line per write(2), so the kernel puts every line
    /// at the current end of file: an app and a harness running at once cannot overwrite each other.
    nonisolated(unsafe) private static var fd: Int32 = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/OldTunes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("oldtunes.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > rotateBytes {
            let previous = dir.appendingPathComponent("oldtunes.1.log")
            try? FileManager.default.removeItem(at: previous)
            // Another process may have rotated first; either way new lines land in a fresh file.
            try? FileManager.default.moveItem(at: url, to: previous)
        }
        return open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
    }()

    static func info(_ message: String, file: String = #fileID) {
        write("INFO", message, file)
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String, file: String = #fileID) {
        write("ERROR", message, file)
        logger.error("\(message, privacy: .public)")
    }

    /// Local time with its offset (e.g. 2026-10-19T17:51:17-07:00), so lines read in Pacific time.
    private static let stamp = Date.ISO8601FormatStyle(timeZone: .current)

    private static func write(_ level: String, _ message: String, _ file: String) {
        let line = Data("\(Date().formatted(stamp)) \(level) [\(file)] \(message)\n".utf8)
        queue.async {
            FileHandle.standardOutput.write(line)
            guard fd >= 0 else { return }
            line.withUnsafeBytes { raw in
                guard var p = raw.baseAddress else { return }
                var left = raw.count
                while left > 0 {
                    let n = Darwin.write(fd, p, left)
                    if n <= 0 { if n < 0 && errno == EINTR { continue }; return }
                    p += n; left -= n
                }
            }
        }
    }

    /// Blocks until queued lines are written. Call before terminating a harness run.
    static func flush() { queue.sync {} }
}
