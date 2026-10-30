import AppKit
import CoreMedia
import Foundation
import os
import ScreenCaptureKit
import VisualizerCore

/// The visualizer's ears without any permission: ScreenCaptureKit capturing OldTunes itself.
///
/// macOS lets an app capture its own content without the Screen Recording or System Audio Recording
/// permission, and without asking (`SCShareableContent.currentProcess`, macOS 14.4). The sound of an
/// app capture is the app's own plus that of every process RunningBoard counts as hosted by it, and
/// the RemotePlayerService MusicKit starts for OldTunes is one of those (RunningBoard names it
/// `xpcservice<com.apple.MediaPlayer.RemotePlayerService([app<application.com.noahtsutsui.oldtunes…>:pid])>`).
/// So a capture of OldTunes alone hears its iCloud songs as well as its files: the selfcapture bench
/// heard a real one at −13 dBFS, every sample non-zero, on October 29, 2026. replayd, which runs the
/// capture, makes the audio tap on its own entitlements.
///
/// Measured on October 29, 2026 (macOS 27.0.1, screen locked) with tools/self-capture-probe: an app
/// and an XPC service of its own, sandboxed and never granted either permission. −60 dBFS tones from
/// both came through at exactly −63.0 dBFS RMS, and silence as exact zeros. A service that started
/// after the capture was heard as soon as it played. TCC saw preflights only, and nothing asked. The
/// sound kept coming with the window minimized or the app hidden (capturing the window) and with the
/// only window ordered out after the capture started (capturing the app, as here). It arrives as
/// 48 kHz stereo float, one buffer per channel, 960 frames a buffer, 31–34 ms after it was played on
/// the median and 46–49 ms at worst in a run of about 1,100 buffers (once 66 ms), hence `readDelay`.
///
/// macOS counts this as sharing the screen while it runs, so VisualizerAudio uses it only when
/// OldTunes isn't known to have System Audio Recording, or its tap hears nothing. ScreenCaptureKit won't run without video, so it
/// gets 16 × 16 pixels once a second, and they are thrown away. Exists only while the visualizer is on.
@available(macOS 14.4, *)
@MainActor
final class SelfCapture: NSObject {
    let ring: SampleRing
    private(set) var status = TapStatus()
    /// Called after every build or teardown, with the reason.
    var onStatusChange: ((TapStatus, String) -> Void)?
    /// Called when the person stops the capture with the menu bar's Stop button. It then stays off
    /// until `start()`, that is until the visualizer is turned on again.
    var onStoppedByUser: (() -> Void)?
    private(set) var stoppedByUser = false

    private var stream: SCStream?
    /// One per stream, so sound from a stream already torn down is dropped.
    private var output: SelfCaptureOutput?
    private var wanted = false
    /// Bumped by every start and stop, so a build that finishes late knows it was overtaken.
    private var generation = 0
    private var building: Int?
    private var pendingRebuild: Task<Void, Never>?
    private let queue = DispatchQueue(label: "com.noahtsutsui.oldtunes.visualizer.selfcapture", qos: .userInteractive)

    init(ring: SampleRing) {
        self.ring = ring
        super.init()
    }

    /// Starts the capture if it isn't running. Returns once it is running or has failed.
    func start() async {
        wanted = true
        stoppedByUser = false
        if status.isRunning || building == generation { return }
        await build(reason: "start")
    }

    func stop() {
        wanted = false
        generation += 1
        pendingRebuild?.cancel()
        pendingRebuild = nil
        teardown()
        report("stop")
    }

    /// Tears down and builds again, for the watchdog.
    func rebuild(reason: String) async {
        guard wanted, !stoppedByUser else { return }
        generation += 1
        teardown()
        await build(reason: reason)
    }

    // MARK: - Building

    private func build(reason: String) async {
        let gen = generation
        building = gen
        defer { if building == gen { building = nil } }
        let began = HostClock.now
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.currentProcess
        } catch {
            guard gen == generation, wanted else { return }
            fail("listing OldTunes's own windows failed: \(error.localizedDescription)", reason: reason)
            return
        }
        guard gen == generation, wanted else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        guard let app = content.applications.first(where: { $0.processID == me }) else {
            fail("macOS lists no window of OldTunes's to capture (\(content.windows.count) windows)", reason: reason)
            return
        }
        // Any display will do for the sound; the one OldTunes is on is the natural choice.
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        let screenID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == screenID }) ?? content.displays.first else {
            fail("macOS lists no display to capture OldTunes on", reason: reason)
            return
        }

        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 16
        config.height = 16
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let output = SelfCaptureOutput(ring: ring)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                stream.startCapture { error in
                    if let error { done.resume(throwing: error) } else { done.resume() }
                }
            }
        } catch {
            output.close()
            guard gen == generation, wanted else { return }
            fail("starting the capture failed: \(error.localizedDescription)", reason: reason)
            return
        }
        guard gen == generation, wanted else {
            output.close()
            stream.stopCapture(completionHandler: nil)
            return
        }
        self.stream = stream
        self.output = output
        let device = AudioHAL.defaultOutputDevice()
        status = TapStatus(isRunning: true, tapped: [], outputDevice: device.flatMap(AudioHAL.name) ?? "unknown",
                           outputIsAirPlay: device.map(AudioHAL.isAirPlay) ?? false,
                           format: "48000 Hz 2 ch float from ScreenCaptureKit",
                           buildMilliseconds: HostClock.seconds(HostClock.now - began) * 1000, failure: nil,
                           seen: "OldTunes and the processes it hosts, on display \(display.displayID)")
        report(reason)
    }

    private func teardown() {
        output?.close()
        if let stream, let output {
            try? stream.removeStreamOutput(output, type: .audio)
            try? stream.removeStreamOutput(output, type: .screen)
        }
        stream?.stopCapture(completionHandler: nil)
        stream = nil
        output = nil
        status.isRunning = false
    }

    private func fail(_ message: String, reason: String) {
        status = TapStatus(failure: message)
        report(reason)
    }

    private func report(_ reason: String) {
        if let failure = status.failure {
            Log.error("visualizer: self-capture \(reason): \(failure)")
        } else if status.isRunning {
            Log.info("visualizer: self-capture \(reason): \(status.seen), output \(status.outputDevice)"
                     + "\(status.outputIsAirPlay ? " (AirPlay)" : ""), \(status.format), "
                     + "built in \(String(format: "%.0f", status.buildMilliseconds)) ms")
        } else {
            Log.info("visualizer: self-capture \(reason)")
        }
        onStatusChange?(status, reason)
    }

    /// `which` is the stream that stopped: a notice about one already torn down changes nothing.
    fileprivate func streamStopped(_ which: ObjectIdentifier, _ code: Int, _ description: String) {
        guard wanted, let stream, ObjectIdentifier(stream) == which else { return }
        teardown()
        if code == SCStreamError.Code.userStopped.rawValue {
            // A build under way would bring the capture back; this drops it.
            generation += 1
            pendingRebuild?.cancel()
            pendingRebuild = nil
            stoppedByUser = true
            status = TapStatus(failure: "stopped from the menu bar")
            report("the person stopped it")
            onStoppedByUser?()
            return
        }
        status = TapStatus(failure: "stopped: \(description)")
        report("the capture stopped")
        pendingRebuild?.cancel()
        pendingRebuild = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.rebuild(reason: "the capture stopped (\(code))")
        }
    }
}

@available(macOS 14.4, *)
extension SelfCapture: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let which = ObjectIdentifier(stream)
        let code = (error as NSError).code
        let description = error.localizedDescription
        Task { @MainActor [weak self] in self?.streamStopped(which, code, description) }
    }
}

/// Takes ScreenCaptureKit's sound into the ring, on ScreenCaptureKit's queue, each buffer at the
/// host time it was played. The video it has to take as well goes nowhere. Once closed, it drops
/// what a stream being torn down still delivers.
@available(macOS 14.4, *)
private final class SelfCaptureOutput: NSObject, SCStreamOutput, Sendable {
    let ring: SampleRing
    private let isOpen = OSAllocatedUnfairLock(initialState: true)

    init(ring: SampleRing) {
        self.ring = ring
    }

    func close() {
        isOpen.withLock { $0 = false }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isOpen.withLock({ $0 }), buffer.isValid, buffer.numSamples > 0,
              let format = buffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else { return }
        let host = Self.hostTime(buffer, clock: stream.synchronizationClock)
        let rate = format.mSampleRate
        try? buffer.withAudioBufferList { list, _ in
            if list.count >= 2, list[0].mNumberChannels == 1, let left = list[0].mData, let right = list[1].mData {
                // Non-interleaved: one buffer per channel.
                let frames = Int(min(list[0].mDataByteSize, list[1].mDataByteSize)) / MemoryLayout<Float>.size
                ring.writePlanarStereo(left: left.assumingMemoryBound(to: Float.self), right: right.assumingMemoryBound(to: Float.self),
                                       frames: frames, firstFrameHostTime: host, sampleRate: rate)
            } else if let first = list.first, let data = first.mData {
                let channels = max(1, Int(first.mNumberChannels))
                let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                ring.writeInterleaved(data.assumingMemoryBound(to: Float.self), frames: frames, channels: channels, gain: 1,
                                      firstFrameHostTime: host, sampleRate: rate)
            }
        }
    }

    /// The buffer's first frame on the host clock. Its time stamp is on the stream's own clock; when
    /// that is missing, the frame is taken to have been played one buffer before now.
    private static func hostTime(_ buffer: CMSampleBuffer, clock: CMClock?) -> UInt64 {
        let stamp = buffer.presentationTimeStamp
        guard stamp.isValid, let clock else {
            let length = HostClock.ticks(seconds: CMTimeGetSeconds(buffer.duration))
            let now = HostClock.now
            return now > length ? now - length : now
        }
        return CMClockConvertHostTimeToSystemUnits(CMSyncConvertTime(stamp, from: clock, to: CMClockGetHostTimeClock()))
    }
}
