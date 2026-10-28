import Foundation
import os

/// One log for the whole app: oldtunes.log in `directory`, plus stdout and os_log.
/// Harness runs capture stdout with `open --stdout`, so agents and humans read the same lines.
enum Log {
    /// ~/Library/Logs/OldTunes in Debug builds, which run the test benches: their sandbox has an
    /// exception for that folder (tools/debug-entitlements.sh), so benches and people read the log
    /// where they always have. A release build may write only inside its container, which is where
    /// homeDirectoryForCurrentUser points in the sandbox, so its log is in
    /// ~/Library/Containers/com.noahtsutsui.oldtunes/Data/Library/Logs/OldTunes.
    static var directory: URL {
        #if DEBUG
        let home = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir)) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser
        #endif
        return home.appendingPathComponent("Library/Logs/OldTunes", isDirectory: true)
    }

    private static let logger = Logger(subsystem: "com.noahtsutsui.oldtunes", category: "app")
    private static let queue = DispatchQueue(label: "com.noahtsutsui.oldtunes.log")
    /// Rotated at launch once it passes this size, keeping one previous file.
    private static let rotateBytes = 5 * 1024 * 1024

    /// Opened with O_APPEND and written one whole line per write(2), so the kernel puts every line
    /// at the current end of file: an app and a harness running at once cannot overwrite each other.
    nonisolated(unsafe) private static var fd: Int32 = {
        let dir = directory
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
        #if DEBUG
        logger.info("\(message, privacy: .public)")
        #else
        // Notice, not info, so macOS keeps the line on disk: a release build's file is inside its
        // sandbox container, where Terminal can't read it, and
        //     log show --last 1h --predicate 'subsystem == "com.noahtsutsui.oldtunes"'
        // can, any time later. Debug builds, which run the chatty benches, log to a file in
        // ~/Library/Logs and leave macOS's store alone.
        logger.notice("\(message, privacy: .public)")
        #endif
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
