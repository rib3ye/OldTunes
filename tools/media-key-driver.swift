// Drives OLDTUNES_PLAYBACK_MODE=startup through macOS, never through PlaybackCoordinator.
// Build: swiftc tools/media-key-driver.swift -o /private/tmp/oldtunes-media-key-driver
// Run with a fresh stdout log path before launching the bench. See docs/DEVELOPMENT.md.
// Uses private MediaRemote only in this test executable. Refuses to send to another process.
import Foundation
import Darwin
import ObjectiveC
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: media-key-driver <fresh bench stdout log>\n", stderr)
    exit(2)
}
let log = CommandLine.arguments[1]
// `open --stdout` can create the file before this process finishes loading its frameworks.
// Accept those initial launch lines, but never replay a previous bench's requests.
let existing = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
guard !existing.contains("STARTUP-READY"), !existing.contains("STARTUP-END") else {
    fputs("Use a new log path, so the driver cannot replay old requests.\n", stderr)
    exit(2)
}
guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
      let sendFunction = dlsym(handle, "MRMediaRemoteSendCommand"),
      let request = NSClassFromString("MRNowPlayingRequest") as? NSObject.Type,
      request.responds(to: NSSelectorFromString("localNowPlayingPlayerPath")) else {
    fputs("This macOS version does not provide the driver's MediaRemote API.\n", stderr)
    exit(2)
}
typealias Send = @convention(c) (UInt32, CFDictionary?) -> Bool
let send = unsafeBitCast(sendFunction, to: Send.self)
var seen = Set<String>()
var failures = 0
var sent = 0
let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
    guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return }
    if let end = text.split(separator: "\n").last(where: { $0.contains("STARTUP-END") }) {
        print(end)
        exit(failures == 0 && sent > 0 && end.contains(", 0 FAIL") ? 0 : 1)
    }
    for line in text.split(separator: "\n") where line.contains("STARTUP-READY") {
        let line = String(line)
        guard seen.insert(line).inserted else { continue }
        let fields = Dictionary(line.split(separator: " ").compactMap { value -> (String, String)? in
            let pair = value.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        }, uniquingKeysWith: { _, b in b })
        guard let pid = Int32(fields["pid"] ?? ""), pid > 0,
              let delay = Double(fields["delay"] ?? ""), delay.isFinite, (0...1000).contains(delay),
              let cmd = fields["cmd"], let number = ["next": UInt32(4), "previous": 5, "toggle": 2][cmd] else { continue }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000) {
            let path = request.perform(NSSelectorFromString("localNowPlayingPlayerPath"))?.takeUnretainedValue() as? NSObject
            let client = path?.value(forKey: "client") as? NSObject
            let actual = (client?.value(forKey: "processIdentifier") as? NSNumber)?.int32Value ?? 0
            guard actual == pid else {
                failures += 1
                print("DRIVER FAIL: owner \(actual), expected \(pid), \(cmd) +\(delay)ms")
                fflush(stdout)
                return
            }
            let accepted = send(number, nil)
            if accepted { sent += 1 } else { failures += 1 }
            print("DRIVER SEND \(cmd) +\(delay)ms owner=\(actual) sent=\(accepted)")
            fflush(stdout)
        }
    }
}
RunLoop.main.run(until: Date().addingTimeInterval(300))
fputs("Driver timed out before STARTUP-END\n", stderr)
exit(1)
