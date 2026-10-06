import SwiftUI
import AVFoundation

@main
struct GharApp: App {
    init() {
        // Playback mode: audio plays through the speaker even with the
        // mute switch on. (The recorder switches to .playAndRecord while
        // recording and switches back when done.) Without this, a real
        // iPhone stays silent — the simulator doesn't enforce it.
        // setActive can block — keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
