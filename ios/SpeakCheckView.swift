import SwiftUI
import AVFoundation

/// Record-and-compare pronunciation practice: the kid hears the model
/// (Som's cloned voice), records themself saying the word, then plays
/// both back side by side. No transcription, no grading — just listening
/// and shadowing. 100% on-device: nothing is uploaded anywhere.
///
/// Teaching notes:
/// - `AVAudioRecorder` writes straight to a temp file. The temp file is
///   deleted when the view disappears, so recordings never pile up.
/// - iOS shows the mic permission popup only from a user tap — that's why
///   permission is requested from the record button, not .onAppear.
/// - Mirrors MissionRecorder's session pattern (.playAndRecord +
///   .defaultToSpeaker so playback comes out the loudspeaker, not the
///   earpiece).
@MainActor
final class SpeakCompare: ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var hasRecording = false
    @Published var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var tickTimer: Timer?
    private var modelPlayer: AVPlayer?
    private var mePlayer: AVPlayer?
    // Serial queue for audio-session work (same reason as MissionRecorder:
    // setActive can block the main thread).
    private let sessionQueue = DispatchQueue(label: "ghar.speakCompare", qos: .userInitiated)

    let fileURL: URL

    init(wordID: String) {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakcheck_\(wordID).m4a")
    }

    /// iOS 17+: AVAudioApplication replaces the deprecated
    /// AVAudioSession.requestRecordPermission.
    func requestMic() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    func startRecording() {
        errorMessage = nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
            try? session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try? AVAudioRecorder(url: self.fileURL, settings: settings)
            recorder?.record()
            let started = recorder?.isRecording ?? false
            DispatchQueue.main.async {
                if started {
                    self.recorder = recorder
                    self.isRecording = true
                    self.hasRecording = false
                    self.elapsed = 0
                    self.startTick()
                } else {
                    self.errorMessage = "Couldn't start the microphone. Try again!"
                }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        // AVAudioRecorder is safe to stop on the main thread — keep the
        // recorder (main-actor state) out of the session queue's closure.
        recorder?.stop()
        recorder = nil
        isRecording = false
        tickTimer?.invalidate()
        tickTimer = nil
        hasRecording = FileManager.default.fileExists(atPath: fileURL.path)
        sessionQueue.async {
            // Back to playback so word audio goes through the speaker.
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
        }
    }

    func playModel(url: URL) {
        stopPlayers()
        modelPlayer = AVPlayer(url: url)
        modelPlayer?.play()
    }

    func playMe() {
        guard hasRecording else { return }
        stopPlayers()
        mePlayer = AVPlayer(url: fileURL)
        mePlayer?.play()
    }

    /// "Try again": drop the take so the next recording starts fresh.
    func reset() {
        stopPlayers()
        hasRecording = false
        elapsed = 0
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// View is going away: stop everything and delete the temp file.
    func cleanup() {
        tickTimer?.invalidate()
        tickTimer = nil
        recorder?.stop()
        recorder = nil
        stopPlayers()
        try? FileManager.default.removeItem(at: fileURL)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTick() {
        tickTimer?.invalidate()
        // 10-second safety net: a kid who walks away mid-record doesn't
        // fill the temp folder or drain the battery.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.elapsed += 0.5
                if self.elapsed >= 10 { self.stopRecording() }
            }
        }
    }

    private func stopPlayers() {
        modelPlayer?.pause()
        modelPlayer = nil
        mePlayer?.pause()
        mePlayer = nil
    }
}

/// The record-and-compare screen for one word. Takes a Word so any word
/// row in the app can present it with one line: SpeakCheckView(word: word).
struct SpeakCheckView: View {
    let word: Word
    @Environment(\.dismiss) private var dismiss
    @StateObject private var compare: SpeakCompare
    @State private var permissionDenied = false

    init(word: Word) {
        self.word = word
        _compare = StateObject(wrappedValue: SpeakCompare(wordID: word.id))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // The word to practice.
                VStack(spacing: 6) {
                    Text("Listen, say it, then compare!")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(word.devanagari)
                        .font(.system(size: 64))
                    Text("\(word.romanized) — \(word.english)")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top)

                if permissionDenied {
                    Text("Microphone is off — turn it on in Settings to practice speaking.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Step 1: hear the model.
                Button {
                    playModel()
                } label: {
                    Label("1 · Hear it", systemImage: "speaker.wave.2.fill")
                        .font(.title3)
                        .padding(.horizontal)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                // Same dimming pattern as WordRow's speaker button: no
                // recording yet → dimmed instead of silently doing nothing.
                .disabled(!(word.hasAudio ?? true))
                .opacity((word.hasAudio ?? true) ? 1 : 0.4)

                // Step 2: record yourself.
                if compare.isRecording {
                    VStack(spacing: 10) {
                        Text("● Recording… \(Int(compare.elapsed))s")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Button("Stop") { compare.stopRecording() }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .controlSize(.large)
                    }
                } else if !compare.hasRecording {
                    Button {
                        Task { await beginRecording() }
                    } label: {
                        Label("2 · Say it", systemImage: "mic.fill")
                            .font(.title2)
                            .padding(.horizontal)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                // Step 3: compare the two.
                if compare.hasRecording && !compare.isRecording {
                    VStack(spacing: 12) {
                        Text("3 · Compare — how close were you?")
                            .font(.headline)
                        HStack(spacing: 16) {
                            Button {
                                playModel()
                            } label: {
                                Label("Hear model", systemImage: "speaker.wave.2.fill")
                            }
                            .buttonStyle(.bordered)
                            Button {
                                compare.playMe()
                            } label: {
                                Label("Hear me", systemImage: "play.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                        Button("Try again") { compare.reset() }
                            .font(.subheadline)
                    }
                }

                if let err = compare.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Spacer()
                Text("Your voice stays on this phone — nothing is uploaded.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .navigationTitle("Say it")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onDisappear { compare.cleanup() }
        }
    }

    private func playModel() {
        guard let url = URL(string: GharAPI.baseURLString + word.audioUrl) else { return }
        compare.playModel(url: url)
    }

    private func beginRecording() async {
        permissionDenied = false
        if await compare.requestMic() {
            compare.startRecording()
        } else {
            permissionDenied = true
        }
    }
}
