import AppKit
import CoreAudio
import Darwin
import VisualizerCore

/// OLDTUNES_VIS_MODE=cycles — turns the visualizer on and off 50 times, about 2 s each, in a window
/// of its own (no library on screen), then checks that it left nothing behind: no process taps, no
/// aggregate devices, no frame callbacks after off, Metal memory that stops growing, and memory and
/// threads back near where they began.
/// The tap is muted unless OLDTUNES_VIS_AUDIBLE=1; nothing plays.
extension VisualizerHarness {
    static func cycles(_ bench: VisualizerBench) async {
        guard VisualizerController.isSupported else {
            bench.note("cycles skipped: the visualizer needs macOS 14.2")
            return
        }
        let rounds = Int(ProcessInfo.processInfo.environment["OLDTUNES_VIS_CYCLES"] ?? "") ?? 50
        let library = PlaybackHarnessLibrary(tracks: [], songs: [:])
        let player = PlaybackCoordinator(library: library, cloud: library)
        player.cloud.affectsListeningHistory = false

        // A small window in the corner, kept above other apps' windows: the visualizer draws nothing while
        // its window is covered, and a bench run doesn't always get to be the active app.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: NSRect(x: screen.maxX - 500, y: screen.minY + 20, width: 480, height: 300),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Visualizer cycles"
        window.isReleasedWhenClosed = false
        window.level = .floating
        let host = NSView(frame: window.contentLayoutRect)
        host.autoresizingMask = [.width, .height]
        let list = NSView(frame: host.bounds)
        list.autoresizingMask = [.width, .height]
        host.addSubview(list)
        window.contentView = host
        window.orderFrontRegardless()
        window.makeKey()
        NSApp.activate()

        let visualizer = VisualizerController(player: player, inlineHost: host, listView: list)
        visualizer.tapMuted = !audible
        var frames = 0
        visualizer.onFrame = { frames += 1 }

        // Warm up once, so one-time costs (frameworks, the first tap) don't count as a leak.
        visualizer.setOn(true)
        try? await Task.sleep(for: .seconds(2))
        visualizer.setOn(false)
        try? await Task.sleep(for: .seconds(1))
        let before = Footprint.now()
        let gpuBefore = visualizer.renderLoop?.presenter.device.currentAllocatedSize ?? 0
        let tapsBefore = AudioHAL.readIDs(AudioHAL.system, kAudioHardwarePropertyTapList).count
        let devicesBefore = AudioHAL.readIDs(AudioHAL.system, kAudioHardwarePropertyDevices).count
        bench.note("cycles: \(rounds) rounds; before: \(before), \(tapsBefore) taps, \(devicesBefore) devices")

        var framesPerRound: [Int] = []
        var coveredRounds = 0
        var gpuPerRound: [Int] = []
        for _ in 0..<rounds {
            let start = frames
            visualizer.setOn(true)
            try? await Task.sleep(for: .seconds(2))
            framesPerRound.append(frames - start)
            if !window.occlusionState.contains(.visible) { coveredRounds += 1 }
            visualizer.setOn(false)
            try? await Task.sleep(for: .milliseconds(200))
            gpuPerRound.append(visualizer.renderLoop?.presenter.device.currentAllocatedSize ?? 0)
        }
        let afterOff = frames
        try? await Task.sleep(for: .seconds(1))
        let after = Footprint.now()
        let gpuAfter = visualizer.renderLoop?.presenter.device.currentAllocatedSize ?? 0
        let taps = AudioHAL.readIDs(AudioHAL.system, kAudioHardwarePropertyTapList).count
        let devices = AudioHAL.readIDs(AudioHAL.system, kAudioHardwarePropertyDevices).count

        let slowest = framesPerRound.min() ?? 0
        bench.check("frames tick while on", slowest >= 60,
                    "fewest frames in a 2 s round: \(slowest); median \(framesPerRound.sorted()[framesPerRound.count / 2]); "
                    + "window covered at the end of \(coveredRounds) of \(rounds) rounds")
        bench.check("no frames after off", frames == afterOff, "\(frames - afterOff) frames in the second after the last off")
        bench.check("no taps or aggregate devices left", taps == tapsBefore && devices == devicesBefore,
                    "taps \(tapsBefore) → \(taps), devices \(devicesBefore) → \(devices)")
        let grewMB = Double(after.physFootprint - before.physFootprint) / 1_048_576
        bench.check("memory back near where it began", grewMB < 5, String(format: "footprint %+.1f MB", grewMB))
        // The layer keeps drawables for reuse, so one reading can be a drawable above the next (1.1 MB in
        // this window). A leak grows round after round instead: compare the highest reading of the first
        // ten rounds with the highest of the last ten.
        let mb = { (bytes: Int) in Double(bytes) / 1_048_576 }
        let early = gpuPerRound.prefix(10).max() ?? 0, late = gpuPerRound.suffix(10).max() ?? 0
        let gpuSteady = visualizer.renderLoop != nil && mb(late) - mb(early) < 1
        bench.check("Metal memory doesn't grow", gpuSteady,
                    String(format: "highest in the first ten rounds %.1f MB, in the last ten %.1f MB; %.1f MB before, %.1f MB after",
                           mb(early), mb(late), mb(gpuBefore), mb(gpuAfter)))
        if !gpuSteady {
            bench.note("Metal memory after each round, MB: " + gpuPerRound.map { String(format: "%.1f", mb($0)) }.joined(separator: " "))
        }
        // Worker threads stay a few seconds after their work ends, so a high count gets up to 10 s to fall.
        // What was running when it was high goes in the log.
        var threads = after.threads
        var waited = 0.0
        if threads > before.threads + 2 {
            bench.note("threads 1 s after off: " + Footprint.threadNames().map { "\($0.count) × \($0.name)" }.joined(separator: ", "))
            while threads > before.threads + 2, waited < 10 {
                try? await Task.sleep(for: .milliseconds(500))
                waited += 0.5
                threads = Footprint.now().threads
            }
        }
        bench.check("threads back near where they began", threads <= before.threads + 2,
                    "threads \(before.threads) → \(after.threads) a second after off"
                    + (waited > 0 ? String(format: ", %d after %.1f s more", threads, waited) : ""))
        window.orderOut(nil)
    }
}

/// This process's memory footprint (what Activity Monitor shows) and thread count.
private struct Footprint: CustomStringConvertible {
    var physFootprint: Int64
    var threads: Int

    static func now() -> Footprint {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        var threads = 0
        if task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS, let threadList {
            threads = Int(threadCount)
            for i in 0..<Int(threadCount) { mach_port_deallocate(mach_task_self_, threadList[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }
        return Footprint(physFootprint: status == KERN_SUCCESS ? Int64(info.phys_footprint) : 0, threads: threads)
    }

    var description: String {
        String(format: "%.1f MB, %d threads", Double(physFootprint) / 1_048_576, threads)
    }

    /// This process's threads grouped by name, the most common first.
    static func threadNames() -> [(name: String, count: Int)] {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS, let threadList else { return [] }
        var counts: [String: Int] = [:]
        for i in 0..<Int(threadCount) {
            var info = thread_extended_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threadList[i], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
                }
            }
            let name = status == KERN_SUCCESS
                ? withUnsafeBytes(of: info.pth_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : "?"
            counts[name.isEmpty ? "unnamed" : name, default: 0] += 1
            mach_port_deallocate(mach_task_self_, threadList[i])
        }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)),
                      vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        return counts.sorted { $0.value > $1.value }.map { (name: $0.key, count: $0.value) }
    }
}
