import AVFoundation
import MediaToolbox
import os

/// Each item keeps its own normalization gain, including items decoded ahead in the queue.
/// Only the enabled setting is shared. AVPlayer's separate volume remains the user's slider.
final class LocalSoundCheck: Sendable {
    private let enabled = OSAllocatedUnfairLock(initialState: false)

    var isEnabled: Bool {
        get { enabled.withLock { $0 } }
        set { enabled.withLock { $0 = newValue } }
    }

    @MainActor
    func attach(to item: AVPlayerItem, gain: Float) async throws {
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        let inputs = try tracks.map { track in
            let input = AVMutableAudioMixInputParameters(track: track)
            input.audioTapProcessor = try makeTap(gain: gain)
            return input
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = inputs
        item.audioMix = mix
    }

    private func makeTap(gain: Float) throws -> MTAudioProcessingTap {
        let context = Unmanaged.passRetained(LocalGainContext(settings: self, gain: gain))
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: context.toOpaque(),
            init: { _, info, storage in storage.pointee = info },
            finalize: { tap in
                Unmanaged<LocalGainContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let context = Unmanaged<LocalGainContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, requested, _, buffers, frames, flags in
                let status = MTAudioProcessingTapGetSourceAudio(tap, requested, buffers, flags, nil, frames)
                guard status == noErr else { frames.pointee = 0; return }
                let context = Unmanaged<LocalGainContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.process(buffers, frames: frames.pointee,
                                reset: flags.pointee & kMTAudioProcessingTapFlag_StartOfStream != 0)
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            context.release()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return tap
    }
}

/// Owned by the tap. Format and ramp state are used only by its serial audio callbacks.
/// Float PCM retains headroom above 1 until AVPlayer applies the slider and sends audio out.
final class LocalGainContext {
    private let settings: LocalSoundCheck
    private let gain: Float
    private var format = AudioStreamBasicDescription()
    private var current: Float = 1

    init(settings: LocalSoundCheck, gain: Float) {
        self.settings = settings
        self.gain = gain.isFinite && gain >= 0 ? gain : 1
    }

    func prepare(_ format: AudioStreamBasicDescription) {
        self.format = format
        current = settings.isEnabled ? gain : 1
    }

    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int, reset: Bool) {
        guard frames > 0, format.mFormatID == kAudioFormatLinearPCM else { return }
        let target = settings.isEnabled ? gain : 1
        if reset { current = target }
        defer { current = target }
        guard current != 1 || target != 1 else { return }
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let signed = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        // Core Audio supplies native-endian, packed PCM to the tap. Leave other formats intact.
        guard format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mFormatFlags & kAudioFormatFlagIsPacked != 0 else { return }
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            guard let data = buffer.mData else { continue }
            let channels = Int(buffer.mNumberChannels)
            let count = min(frames * channels, Int(buffer.mDataByteSize) / max(1, Int(format.mBitsPerChannel / 8)))
            guard channels > 0 else { continue }
            for i in 0..<count {
                let factor = current + (target - current) * Float(i / channels + 1) / Float(frames)
                switch (isFloat, signed, format.mBitsPerChannel) {
                case (true, _, 32): data.assumingMemoryBound(to: Float.self)[i] *= factor
                case (true, _, 64): data.assumingMemoryBound(to: Double.self)[i] *= Double(factor)
                case (false, true, 16):
                    let samples = data.assumingMemoryBound(to: Int16.self)
                    samples[i] = Int16(min(Double(Int16.max), max(Double(Int16.min), Double(samples[i]) * Double(factor))))
                case (false, true, 32):
                    let samples = data.assumingMemoryBound(to: Int32.self)
                    samples[i] = Int32(min(Double(Int32.max), max(Double(Int32.min), Double(samples[i]) * Double(factor))))
                default: break
                }
            }
        }
    }
}
