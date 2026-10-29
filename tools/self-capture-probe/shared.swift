import AVFoundation
import Foundation

/// The XPC service plays a tone on request, so the app can check whether capturing its own content
/// carries the sound of a process it hosts (as OldTunes hosts RemotePlayerService).
@objc protocol ToneProtocol {
    func play(frequency: Double, dBFS: Double, seconds: Double, reply: @escaping (String) -> Void)
}

/// A quiet sine on the default output, both channels.
final class Tone {
    let engine = AVAudioEngine()
    private let node: AVAudioSourceNode

    init(frequency: Double, dBFS: Double) {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let amplitude = Float(pow(10, dBFS / 20))
        let step = 2 * Double.pi * frequency / max(rate, 1)
        var phase = 0.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        node = AVAudioSourceNode(format: format) { _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for frame in 0..<Int(frames) {
                let value = amplitude * Float(sin(phase))
                phase += step
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                for buffer in buffers { buffer.mData!.assumingMemoryBound(to: Float.self)[frame] = value }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
    }

    func start() throws { try engine.start() }
    func stop() { engine.stop() }
}
