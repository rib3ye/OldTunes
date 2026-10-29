import Foundation

/// ToneService.xpc: plays a tone when asked. Its own process, hosted by the probe app, like
/// RemotePlayerService is hosted by OldTunes.
final class Service: NSObject, ToneProtocol, NSXPCListenerDelegate {
    private var tones: [Tone] = []

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ToneProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func play(frequency: Double, dBFS: Double, seconds: Double, reply: @escaping (String) -> Void) {
        DispatchQueue.main.async {
            let tone = Tone(frequency: frequency, dBFS: dBFS)
            do {
                try tone.start()
                self.tones.append(tone)
                reply("service pid \(getpid()) playing \(Int(frequency)) Hz at \(Int(dBFS)) dBFS for \(seconds) s")
            } catch {
                reply("service pid \(getpid()) could not start its tone: \(error)")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                tone.stop()
                self.tones.removeAll { $0 === tone }
            }
        }
    }
}

let service = Service()
let listener = NSXPCListener.service()
listener.delegate = service
listener.resume()
