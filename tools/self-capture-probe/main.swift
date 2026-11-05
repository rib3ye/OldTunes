import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

// Self-capture probe (docs/VISUALIZER.md ▸ Without the permission). Question: can an app with no
// Screen Recording and no System Audio Recording permission capture the sound of its OWN content
// (SCShareableContent.currentProcess, macOS 14.4+, "available to capture by current process without
// user consent via TCC"), and does that sound include a process the app hosts (here ToneService.xpc;
// for oldTunes, RemotePlayerService)? oldTunes's SelfCapture rests on both.
//
// It plays inaudible tones: 19 kHz from the app itself, 18 kHz from its XPC service, at -60 dBFS,
// and prints the level of each as captured, then a summary. build.sh says how to build and run it.
// Options: --mode window|app (what to capture; oldTunes captures the app), --obscure
// minimize|hide|close (done to the window as the service's tone starts), --db -60 (tone level),
// --hold 20 (seconds to keep capturing after the tones, to look at the menu bar).

let started = Date()
func log(_ text: String) {
    print(String(format: "[%6.2f] ", Date().timeIntervalSince(started)) + text)
    fflush(stdout)
}

struct Options {
    var mode = "window"
    var dBFS = -60.0
    var obscure = ""
    var hold = 0.0
    init() {
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--mode": mode = args.next() ?? mode
            case "--db": dBFS = Double(args.next() ?? "") ?? dBFS
            case "--obscure": obscure = args.next() ?? ""
            case "--hold": hold = Double(args.next() ?? "") ?? hold
            default: break
            }
        }
    }
}

/// What the capture heard during one phase of the test.
struct PhaseStats {
    var name: String
    var buffers = 0
    var frames = 0
    var sumSquares = 0.0
    var nonZero = 0
    var mono: [Float] = []
    var lags: [Double] = []

    func goertzelDBFS(_ frequency: Double, rate: Double) -> Double {
        guard mono.count > 256, rate > 0 else { return -.infinity }
        let k = 2 * cos(2 * Double.pi * frequency / rate)
        var s1 = 0.0, s2 = 0.0
        for x in mono {
            let s0 = Double(x) + k * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - k * s1 * s2
        let amplitude = 2 * sqrt(max(power, 0)) / Double(mono.count)
        return 20 * log10(max(amplitude, 1e-12))
    }

    func line(rate: Double) -> String {
        let rms = frames > 0 ? 10 * log10(max(sumSquares / Double(max(mono.count, 1)), 1e-24)) : -.infinity
        let nz = mono.isEmpty ? 0 : Double(nonZero) / Double(mono.count) * 100
        let sorted = lags.sorted()
        let lagText = sorted.isEmpty ? "lag n/a" : String(format: "lag median %.1f ms max %.1f ms", sorted[sorted.count / 2] * 1000, sorted.last! * 1000)
        return lagText + "  " + String(format: "%-14@ buffers %4d  frames %7d  RMS %7.1f dBFS  nonzero %5.1f%%  18k %7.1f dBFS  19k %7.1f dBFS",
                      name as NSString, buffers, frames, rms, nz,
                      goertzelDBFS(18_000, rate: rate), goertzelDBFS(19_000, rate: rate))
    }
}

final class Probe: NSObject, NSApplicationDelegate, SCStreamOutput, SCStreamDelegate {
    let options = Options()
    var window: NSWindow!
    var stream: SCStream?
    let queue = DispatchQueue(label: "probe.capture")
    let lock = NSLock()
    var phases: [PhaseStats] = []
    var phaseStart = Date()
    var sampleRate = 0.0
    var formatLogged = false
    var videoFrames = 0
    var selfTone: Tone?
    var connection: NSXPCConnection?
    var hostLags: [Double] = []
    var mismatches = 0
    let hostScale: Double = { var i = mach_timebase_info_data_t(); mach_timebase_info(&i); return Double(i.numer) / Double(i.denom) / 1e9 }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 280, height: 90),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Self-capture probe"
        let label = NSTextField(labelWithString: "Testing self-capture. Closes by itself.")
        label.frame = NSRect(x: 16, y: 34, width: 250, height: 20)
        window.contentView?.addSubview(label)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        log("pid \(getpid()), mode \(options.mode), tones at \(options.dBFS) dBFS")
        log("CGPreflightScreenCaptureAccess() = \(CGPreflightScreenCaptureAccess())")
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        log("screen locked: \(locked)")
        Task { @MainActor in await self.run() }
    }

    @MainActor
    func run() async {
        try? await Task.sleep(nanoseconds: 500_000_000)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.currentProcess
        } catch {
            log("SCShareableContent.currentProcess failed: \(error)")
            finish()
            return
        }
        log("currentProcess: \(content.windows.count) windows, \(content.applications.count) apps, \(content.displays.count) displays")
        for w in content.windows {
            log("  window \(w.windowID) '\(w.title ?? "")' app \(w.owningApplication?.bundleIdentifier ?? "?") onScreen \(w.isOnScreen) frame \(w.frame)")
        }
        for a in content.applications { log("  app \(a.bundleIdentifier) pid \(a.processID)") }
        for d in content.displays { log("  display \(d.displayID) \(d.width)x\(d.height)") }

        let filter: SCContentFilter
        if options.mode == "app" {
            guard let display = content.displays.first, let me = content.applications.first(where: { $0.processID == getpid() }) else {
                log("app mode needs a display and our own app in the content; it has neither")
                finish()
                return
            }
            filter = SCContentFilter(display: display, including: [me], exceptingWindows: [])
        } else {
            guard let mine = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) ?? content.windows.first else {
                log("no window of ours in currentProcess content")
                finish()
                return
            }
            filter = SCContentFilter(desktopIndependentWindow: mine)
        }
        let config = SCStreamConfiguration()
        config.width = 64
        config.height = 64
        config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
        config.queueDepth = 3
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch {
            log("startCapture failed: \(error)")
            finish()
            return
        }
        self.stream = stream
        log("startCapture OK")

        await phase("silence", seconds: 3)
        startSelfTone()
        await phase("self 19k", seconds: 4)
        stopSelfTone()
        await phase("gap", seconds: 1.5)
        playServiceTone(seconds: 5)
        obscureWindow()
        await phase("service 18k", seconds: 4)
        await phase("gap", seconds: 2)
        startSelfTone()
        playServiceTone(seconds: 3)
        await phase("both", seconds: 3)
        stopSelfTone()
        await phase("gap", seconds: 1.5)
        await phase("silence end", seconds: 2)
        if options.hold > 0 {
            log("still capturing for \(Int(options.hold)) s: look at the menu bar and Control Center now")
            try? await Task.sleep(nanoseconds: UInt64(options.hold * 1e9))
        }

        do { try await stream.stopCapture() } catch { log("stopCapture: \(error)") }
        let summary = lock.withLock { phases }
        log("video frames: \(videoFrames)")
        let sortedLags = lock.withLock { hostLags }.sorted()
        if !sortedLags.isEmpty {
            log(String(format: "host-clock lag: min %.1f ms, median %.1f ms, max %.1f ms over %d buffers; %d disagree with the stream clock by > 2 ms",
                       sortedLags.first! * 1000, sortedLags[sortedLags.count / 2] * 1000, sortedLags.last! * 1000, sortedLags.count, mismatches))
        }
        log("SUMMARY (sample rate \(sampleRate))")
        for p in summary where p.name != "gap" { log("  " + p.line(rate: sampleRate)) }
        finish()
    }

    @MainActor
    func phase(_ name: String, seconds: Double) async {
        lock.withLock {
            phases.append(PhaseStats(name: name))
            phaseStart = Date()
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        let last = lock.withLock { phases.last! }
        log("phase \(last.line(rate: sampleRate))")
    }

    func obscureWindow() {
        switch options.obscure {
        case "minimize": window.miniaturize(nil); log("window minimized")
        case "hide": NSApp.hide(nil); log("app hidden")
        case "close": window.orderOut(nil); log("window ordered out")
        default: break
        }
    }

    func startSelfTone() {
        let tone = Tone(frequency: 19_000, dBFS: options.dBFS)
        do { try tone.start(); selfTone = tone } catch { log("self tone failed: \(error)") }
    }

    func stopSelfTone() {
        selfTone?.stop()
        selfTone = nil
    }

    func playServiceTone(seconds: Double) {
        if connection == nil {
            let c = NSXPCConnection(serviceName: "com.noahtsutsui.selfcaptureprobe.tone")
            c.remoteObjectInterface = NSXPCInterface(with: ToneProtocol.self)
            c.resume()
            connection = c
        }
        let proxy = connection!.remoteObjectProxyWithErrorHandler { error in log("XPC error: \(error)") } as! ToneProtocol
        proxy.play(frequency: 18_000, dBFS: options.dBFS, seconds: seconds) { reply in log("XPC: \(reply)") }
    }

    func finish() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        if type == .screen {
            videoFrames += 1
            return
        }
        guard type == .audio else { return }
        if !formatLogged, let fd = sampleBuffer.formatDescription,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
            formatLogged = true
            sampleRate = asbd.mSampleRate
            log(String(format: "first audio buffer: %.0f Hz, %u ch, flags 0x%x, %u frames", asbd.mSampleRate,
                       asbd.mChannelsPerFrame, asbd.mFormatFlags, UInt32(sampleBuffer.numSamples)))
        }
        var lag: Double?
        if let clock = stream.synchronizationClock {
            let end = CMTimeAdd(sampleBuffer.presentationTimeStamp, sampleBuffer.duration)
            let now = CMClockGetTime(clock)
            if end.isValid, now.isValid { lag = CMTimeGetSeconds(CMTimeSubtract(now, end)) }
            // The same lag, on the host clock, the way oldTunes's SelfCapture stamps buffers.
            let host = CMClockConvertHostTimeToSystemUnits(CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock()))
            let endHost = Double(host) * hostScale + CMTimeGetSeconds(sampleBuffer.duration)
            let hostLag = Double(mach_absolute_time()) * hostScale - endHost
            if let lag, abs(hostLag - lag) > 0.002 { lock.lock(); mismatches += 1; lock.unlock() }
            lock.lock(); hostLags.append(hostLag); lock.unlock()
        }
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let first = list.first, let data = first.mData else { return }
            let n = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let p = data.assumingMemoryBound(to: Float.self)
            lock.lock()
            defer { lock.unlock() }
            guard !phases.isEmpty else { return }
            // Skip the first 0.4 s of each phase: capture lag smears the boundaries.
            let settled = Date().timeIntervalSince(phaseStart) > 0.4
            phases[phases.count - 1].buffers += 1
            phases[phases.count - 1].frames += sampleBuffer.numSamples
            if let lag { phases[phases.count - 1].lags.append(lag) }
            guard settled else { return }
            for k in 0..<n {
                let v = p[k]
                phases[phases.count - 1].mono.append(v)
                phases[phases.count - 1].sumSquares += Double(v * v)
                if v != 0 { phases[phases.count - 1].nonZero += 1 }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped with error: \(error)")
    }
}

let app = NSApplication.shared
let probe = Probe()
app.delegate = probe
app.setActivationPolicy(.regular)
app.run()
