import SwiftUI
import AVFoundation
import UIKit
import Combine
import CoreText

/// First screen: tab bar with Lessons, Missions, Quiz, and My Ghar, loaded live from our Python backend.
///
/// Teaching notes:
/// - `@State` = "this view owns this data, redraw when it changes."
///   When `pack` goes from nil -> loaded, SwiftUI rebuilds the list.
/// - `.task { await load() }` runs once when the view appears.
/// - `TabView` + `.tabItem` = the bottom tab bar (like Instagram's).
///   Each tab gets its own NavigationStack so back-buttons stay separate.
/// - `NavigationStack` + `NavigationLink` = free push navigation,
///   the iOS-standard drill-down pattern.
struct ContentView: View {
    @State private var pack: ContentPack?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let pack {
                TabView {
                    // --- Tab 1: Lessons (the deck list you already had) ---
                    NavigationStack {
                        List(pack.decks) { deck in
                            NavigationLink(destination: lessonDestination(for: deck)) {
                                HStack(spacing: 12) {
                                    DeckCover(deck: deck)
                                    VStack(alignment: .leading) {
                                        Text(deck.title).font(.headline)
                                        Text(lessonSubtitle(for: deck))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .navigationTitle("Ghar 🇳🇵")
                    }
                    .tabItem {
                        Label("Lessons", systemImage: "book.fill")
                    }

                    // --- Tab 2: Missions (new!) ---
                    NavigationStack {
                        MissionsView(missions: pack.missions)
                            .navigationTitle("Missions")
                    }
                    .tabItem {
                        Label("Missions", systemImage: "flag.fill")
                    }

                    // --- Tab 3: Quiz (listening game, with sections) ---
                    NavigationStack {
                        QuizMenuView(pack: pack)
                            .navigationTitle("Quiz")
                    }
                    .tabItem {
                        Label("Quiz", systemImage: "questionmark.circle.fill")
                    }

                    // --- Tab 4: My Ghar (the house you build with XP) ---
                    NavigationStack {
                        MyGharView(pack: pack)
                            .navigationTitle("My Ghar")
                    }
                    .tabItem {
                        Label("My Ghar", systemImage: "house.fill")
                    }
                }
            } else if let errorMessage {
                    VStack(spacing: 12) {
                        Text("Couldn't load lessons")
                            .font(.headline)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Is the backend running? (uvicorn app.main:app --reload)")
                            .font(.caption)
                    }
                    .padding()
                } else {
                    ProgressView("Loading Nepali lessons…")
                }
            }
            .task { await load() }
    }

    private func load() async {
        do {
            pack = try await GharAPI.shared.fetchPack()
            // WinFanfare's Nepali cheers come from here: once the pack
            // is in, every win outside the Dashain/Tihar picture quizzes
            // can play Som's recorded praise.
            WinFanfare.praise = pack?.praise ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The Missions tab: a header card (total XP + "X of 5 done" progress bar)
/// plus one tappable card per mission — emoji icon, English title, the
/// prompt, the Nepali title, and an XP pill. Done missions get a green
/// tint + checkmark, grown-up-verified ones a gold tint + star.
/// Tapping a card pushes the detail screen.
///
/// Teaching notes:
/// - `ForEach(missions)` works because Mission is Identifiable (it has `id`).
/// - `NavigationLink(destination:)` turns each card into a tappable link.
///   The card content becomes the label (what you tap); the destination
///   is the screen you land on.
/// - `.buttonStyle(.plain)` stops the link from tinting the whole card blue.
/// - `@AppStorage` here uses the SAME keys as MissionDetailView. Two views
///   declaring the same key share the value live: tap "I did it!" over
///   there, the checkmark appears here with zero extra wiring.
struct MissionsView: View {
    let missions: [Mission]
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.missions.completed") private var completedData = Data()
    @AppStorage("ghar.missions.verified") private var verifiedData = Data()

    /// The IDs of finished missions, decoded from storage.
    /// @AppStorage only holds simple types (Int, String, Data...), so a Set
    /// gets JSON-encoded into Data — our little packing trick.
    private var completedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: completedData)) ?? []
    }

    /// Same trick for grown-up-verified missions: the gold-star set.
    private var verifiedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: verifiedData)) ?? []
    }

    /// Playful icon per mission, so the list reads at a glance.
    /// (Hardcoded here — no backend change needed to pick a new icon.)
    private func icon(for mission: Mission) -> String {
        switch mission.id {
        case "tihar-greeting": return "🪔"
        case "count-to-five": return "🔢"
        case "dinner-words": return "🍽️"
        case "deusi-line": return "🎶"
        case "tihar-smell": return "🌸"
        default: return "⭐"
        }
    }

    /// How many missions are done — drives the header progress bar.
    private var doneCount: Int {
        missions.filter { completedIDs.contains($0.id) }.count
    }

    /// Accent color for the icon circle + card border, by mission state.
    private func tint(isVerified: Bool, isDone: Bool) -> Color {
        if isVerified { return .yellow }
        if isDone { return .green }
        return .orange
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Header card: big XP total + "X of 5 done" progress bar.
                VStack(spacing: 8) {
                    HStack {
                        Text("⭐")
                            .font(.largeTitle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(totalXP) XP")
                                .font(.title2)
                                .bold()
                            Text("\(doneCount) of \(missions.count) missions done")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    ProgressView(value: Double(doneCount),
                                 total: Double(max(missions.count, 1)))
                        .tint(.orange)
                }
                .padding()
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)

                // One card per mission.
                ForEach(missions) { mission in
                    NavigationLink(destination: MissionDetailView(mission: mission)) {
                        missionCard(for: mission)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    /// A single mission card: emoji icon, titles, prompt, XP pill, status.
    private func missionCard(for mission: Mission) -> some View {
        let isVerified = verifiedIDs.contains(mission.id)
        let isDone = completedIDs.contains(mission.id)
        let accent = tint(isVerified: isVerified, isDone: isDone)
        return HStack(spacing: 12) {
            Text(icon(for: mission))
                .font(.largeTitle)
                .frame(width: 58, height: 58)
                .background(accent.opacity(0.15))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(mission.titleEn)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    if isVerified {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                    } else if isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(mission.promptEn)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack {
                    Text(mission.titleNe)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("+\(mission.xp) XP")
                        .font(.caption)
                        .bold()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(accent.opacity((isDone || isVerified) ? 0.5 : 0),
                              lineWidth: 2)
        )
    }
}

/// Owns the microphone for mission "proof" recordings: the kid records
/// themself doing or saying the mission, then a grown-up listens and
/// confirms. The .m4a lands in the app's documents folder — on the phone,
/// never uploaded anywhere (that's the COPPA-safe part).
///
/// Teaching notes:
/// - `ObservableObject` + `@Published`: when `isRecording` flips, every view
///   watching this object redraws. Same reactive idea as @State, but shared
///   between the detail view and the sheet.
/// - `AVAudioRecorder` writes straight to a file URL. No server involved.
/// - iOS shows the mic permission popup only when WE ask, and only from a
///   user tap — that's why `requestPermission` is called from the button,
///   not from `.onAppear`.
/// - The app must declare NSMicrophoneUsageDescription (in the Xcode target's
///   build settings) or iOS kills the app the moment recording starts.
final class MissionRecorder: ObservableObject {
    @Published var isRecording = false
    private var recorder: AVAudioRecorder?
    // Serial queue for audio-session work: setActive can block the main
    // thread (Xcode purple warning), and serial keeps start/stop from
    // racing each other.
    private let sessionQueue = DispatchQueue(label: "ghar.audioSession", qos: .userInitiated)

    func requestPermission(_ done: @escaping (Bool) -> Void) {
        // iOS 17+: AVAudioApplication replaces the deprecated
        // AVAudioSession.requestRecordPermission.
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    func start(to url: URL) {
        // Session setup goes through sessionQueue (off main thread).
        // The recorder itself starts on main once the session is live.
        sessionQueue.async { [weak self] in
            let session = AVAudioSession.sharedInstance()
            // .defaultToSpeaker: without it, .playAndRecord routes to the
            // earpiece and the grown-up can't hear the kid's recording.
            try? session.setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
            try? session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.recorder = try? AVAudioRecorder(url: url, settings: settings)
                self.recorder?.record()
                self.isRecording = self.recorder?.isRecording ?? false
            }
        }
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        // Back to playback mode so word audio goes through the speaker.
        sessionQueue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
        }
    }
}

/// Step 1 of "Prove it": the kid records themself. Big record button,
/// playback to check it sounds right, re-record as many times as they
/// want, then "Hand to a grown-up" moves to step 2.
struct ProveItSheet: View {
    let mission: Mission
    let proofURL: URL
    @ObservedObject var recorder: MissionRecorder
    let onHandOff: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var hasRecording = false
    @State private var showDenied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("🎤 Prove it")
                    .font(.largeTitle)
                    .bold()
                Text(mission.titleEn)
                    .font(.title2)
                Text("Say what you did — or say the Nepali words out loud — then hand the phone to a grown-up.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Button(action: recordTapped) {
                    Label(recorder.isRecording ? "Stop" : "● Record",
                          systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : .blue)

                if hasRecording && !recorder.isRecording {
                    Button(action: playProof) {
                        Label("▶ Play my recording", systemImage: "play.circle.fill")
                            .font(.title3)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: onHandOff) {
                        Label("Hand to a grown-up →", systemImage: "person.fill")
                            .font(.title3)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }

                Text("Your recording stays on this phone. Nobody else hears it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Prove it")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                hasRecording = FileManager.default.fileExists(atPath: proofURL.path)
            }
            .alert("Microphone is off", isPresented: $showDenied) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Turn on the microphone for Ghar in Settings to record your proof.")
            }
        }
    }

    private func recordTapped() {
        if recorder.isRecording {
            recorder.stop()
            hasRecording = true
            return
        }
        recorder.requestPermission { granted in
            if granted {
                recorder.start(to: proofURL)
            } else {
                showDenied = true
            }
        }
    }

    private func playProof() {
        player = AVPlayer(url: proofURL)
        player?.play()
    }
}

/// Step 2 of "Prove it": the grown-up's screen. They listen to the kid's
/// recording and tap confirm — one honest tap is the whole verification.
struct GrownUpSheet: View {
    let mission: Mission
    let proofURL: URL
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("🧑‍🦰 Grown-up check")
                    .font(.largeTitle)
                    .bold()
                Text("Listen to the recording. Did they really do “\(mission.titleEn)”?")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Button(action: {
                    player = AVPlayer(url: proofURL)
                    player?.play()
                }) {
                    Label("▶ Play recording", systemImage: "play.circle.fill")
                        .font(.title2)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: onConfirm) {
                    Label("✅ Confirm — mission done", systemImage: "checkmark.circle.fill")
                        .font(.title3)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button("Not yet") { dismiss() }
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Grown-up check")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Tapping a mission row opens this: the full prompt in English + Nepali,
/// a play button for the recorded instruction, "I did it!" for the quick
/// path, and "Prove it" for the verified path: the kid records themself,
/// hands the phone to a grown-up, and the grown-up confirms.
///
/// Two ways to finish, two rewards:
/// - "I did it!" → +xp. Honor system, same as before.
/// - "Prove it 🎤" → record + grown-up confirm → +verifiedXp (bigger).
///   Proving a mission already done the plain way pays the difference.
///   The recording and both checkmarks live on the phone — nothing uploads.
///
/// Teaching notes:
/// - Done-state and verified-state are two separate @AppStorage sets, so
///   the XP math can tell "done" (+xp) apart from "verified" (+verifiedXp).
/// - The two sheets are separate structs owned by this view. Sheets
///   presenting sheets get glitchy, so "hand to grown-up" dismisses the
///   first sheet and raises the second a half-second later.
/// - `verifiedXp` has a default (25) so an older backend that doesn't send
///   the key yet can't break decoding — the app keeps working either way.
struct MissionDetailView: View {
    let mission: Mission
    @State private var player: AVPlayer?
    @StateObject private var recorder = MissionRecorder()
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.missions.completed") private var completedData = Data()
    @AppStorage("ghar.missions.verified") private var verifiedData = Data()
    @AppStorage("ghar.last.win") private var lastWin = ""
    @State private var showConfetti = false
    @State private var showingRecorder = false
    @State private var showingGrownUp = false

    private var completedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: completedData)) ?? []
    }
    private var verifiedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: verifiedData)) ?? []
    }
    private var isDone: Bool { completedIDs.contains(mission.id) }
    private var isVerified: Bool { verifiedIDs.contains(mission.id) }

    /// The proof recording's home: the app's documents folder, on-device.
    private var proofURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mission_\(mission.id)_proof.m4a")
    }

    /// Plain path: +xp now. Tapping again un-does — and un-verifies too,
    /// refunding whichever amount was actually paid out.
    private func toggleDone() {
        var ids = completedIDs
        var vids = verifiedIDs
        if ids.contains(mission.id) {
            let paid = vids.contains(mission.id) ? mission.verifiedXp : mission.xp
            ids.remove(mission.id)
            vids.remove(mission.id)
            // Never go below zero: XP already spent in the shop stays spent.
            totalXP = max(0, totalXP - paid)
        } else {
            ids.insert(mission.id)
            totalXP += mission.xp
            // The win moment: voice cheer + confetti. (Un-completing stays quiet.)
            WinFanfare.play()
            celebrate()
            lastWin = mission.titleEn
        }
        completedData = (try? JSONEncoder().encode(ids)) ?? Data()
        verifiedData = (try? JSONEncoder().encode(vids)) ?? Data()
    }

    /// Verified path: pays verifiedXp in TOTAL — just the difference if the
    /// plain path already paid xp. Guarded, so it can never double-pay.
    private func markVerified() {
        guard !isVerified else { return }
        var ids = completedIDs
        var vids = verifiedIDs
        if ids.contains(mission.id) {
            totalXP += mission.verifiedXp - mission.xp
        } else {
            ids.insert(mission.id)
            totalXP += mission.verifiedXp
        }
        vids.insert(mission.id)
        completedData = (try? JSONEncoder().encode(ids)) ?? Data()
        verifiedData = (try? JSONEncoder().encode(vids)) ?? Data()
        WinFanfare.play()
        celebrate()
        lastWin = mission.titleEn
    }

    /// Fire the confetti so it can never get "stuck": drop any in-flight
    /// burst first, then raise a fresh one on the next runloop turn.
    /// (The burst dismisses itself with a 1.2s `.task` timer — but `.task`
    /// dies with the view. Tap "I did it!", hit Back before 1.2s, and the
    /// timer is cancelled with the flag still on, swallowing every future
    /// celebration. Reset-first makes that impossible.)
    private func celebrate() {
        showConfetti = false
        DispatchQueue.main.async { showConfetti = true }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(mission.titleNe)
                    .font(.largeTitle)
                Text(mission.titleEn)
                    .font(.title2)
                    .bold()

                VStack(alignment: .leading, spacing: 8) {
                    Text(mission.promptEn)
                        .font(.body)
                    Text(mission.promptNe)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack {
                    Button(action: play) {
                        Label("Play instruction", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()

                    Text("+\(mission.xp) XP")
                        .font(.headline)
                        .foregroundStyle(.orange)
                }

                if isVerified {
                    Label("Verified! A grown-up confirmed this mission.",
                          systemImage: "star.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button(action: toggleDone) {
                    Label(isDone ? "Done!" : "I did it! +\(mission.xp) XP",
                          systemImage: isDone ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(isDone ? .green : .blue)

                if !isVerified {
                    Button(action: { showingRecorder = true }) {
                        // Honest label: if "I did it!" already paid xp,
                        // Prove-it only pays the difference to verifiedXp.
                        let payout = isDone ? mission.verifiedXp - mission.xp : mission.verifiedXp
                        Label("Prove it 🎤 +\(payout) XP",
                              systemImage: "mic.circle.fill")
                            .font(.title3)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)

                    Text("Record yourself doing it, then hand the phone to a grown-up to confirm — worth more XP.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle(mission.titleEn)
        .navigationBarTitleDisplayMode(.inline)
        // Confetti layer: floats on top, ignores taps, and removes itself
        // after ~1.2s — the timer lives exactly as long as the confetti.
        .overlay {
            if showConfetti {
                ConfettiBurst()
                    .allowsHitTesting(false)
                    .task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        showConfetti = false
                    }
            }
        }
        .sheet(isPresented: $showingRecorder) {
            ProveItSheet(mission: mission, proofURL: proofURL, recorder: recorder) {
                // Sheet-to-sheet handoff: dismiss first, raise the grown-up
                // sheet a beat later so iOS doesn't drop the presentation.
                showingRecorder = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showingGrownUp = true
                }
            }
        }
        .sheet(isPresented: $showingGrownUp) {
            GrownUpSheet(mission: mission, proofURL: proofURL) {
                markVerified()
                showingGrownUp = false
            }
        }
    }

    /// Same streaming trick as DeckView: server address + path from JSON.
    /// Until you record the clips, the file isn't there — AVPlayer just
    /// stays quiet instead of crashing.
    /// The "Play instruction" button: your recording if it's in, TTS in the
    /// meantime so the button never silently does nothing. For bundled
    /// content we verify the file actually exists (not just the flag),
    /// so a stale flag can't mute your voice.
    private func play() {
        let urlString = GharAPI.baseURLString + mission.audioUrl
        if let url = URL(string: urlString) {
            let fileExists: Bool
            if url.isFileURL {
                fileExists = FileManager.default.fileExists(atPath: url.path)
            } else {
                fileExists = mission.hasAudio
            }
            if fileExists {
                player = AVPlayer(url: url)
                player?.play()
                return
            }
        }
        // Fallback reads the English instructions in an English voice.
        NepaliSpeaker.say(nepali: mission.promptNe, romanized: mission.promptEn)
    }
}

/// The deck's cover art in the Lessons list: loads from the backend
/// through the same /images route as the animal photos.
/// A deck without cover art just shows a book icon instead.
struct DeckCover: View {
    let deck: Deck

    var body: some View {
        Group {
            if deck.id == "colors" {
                // No photo cover for colors — its own swatches are the cover.
                colorDots
            } else if let cover = deck.coverImage, cover.hasPrefix("/") {
                AsyncImage(url: URL(string: GharAPI.baseURLString + cover)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure, .empty:
                        Color.clear
                    @unknown default:
                        Color.clear
                    }
                }
            } else {
                Image(systemName: "book.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// 3×3 mini grid of the deck's own colors.
    private var colorDots: some View {
        let cols = [GridItem(.flexible(), spacing: 4),
                    GridItem(.flexible(), spacing: 4),
                    GridItem(.flexible(), spacing: 4)]
        return LazyVGrid(columns: cols, spacing: 4) {
            ForEach(deck.words.prefix(9)) { word in
                Circle()
                    .fill(Color(hex: word.colorHex ?? "#CCCCCC"))
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
    }
}

// MARK: - Festival scenes (Dashain + Tihar)
// Animated, tappable festival pages. A festival deck opens FestivalView:
// a living scene at the top (hotspots kids tap to hear the Nepali word)
// and the deck's vocabulary list below, reusing the normal WordRow.

// How a hotspot idles when nobody is touching it.
enum HotspotMotion {
    case sway    // swings side to side (the ping, jamara leaves)
    case bob     // bobs up and down (kites, the feast)
    case pulse   // grows and shrinks (tika, diyos)
}

// One tappable thing in a festival scene.
struct FestivalHotspot: Identifiable {
    let id: String       // unique in this scene, e.g. "tihar_diyo_3"
    let wordId: String   // the Word it teaches, e.g. "tihar_diyo"
    let emoji: String    // its face — except the ping, which is drawn
    let x: Double        // position as a fraction of the scene (0...1)
    let y: Double
    let size: CGFloat    // emoji point size
    let motion: HotspotMotion
    let startsUnlit: Bool // true for Tihar diyos: gray until tapped, then glowing
}

// A twinkling star's spot in the night sky (fractions of the scene).
struct StarSpot {
    let x: Double
    let y: Double
    let delay: Double   // staggers the twinkles so they don't blink together
}

// Everything a festival scene needs to draw itself.
struct FestivalConfig {
    let skyTop: Color
    let skyBottom: Color
    let ground: Color
    let night: Bool
    let goal: String        // the challenge pill at the top, e.g. "Find all 5 Dashain treasures!"
    let doneTitle: String   // the banner once everything is found
    let hotspots: [FestivalHotspot]
    let stars: [StarSpot]

    // Festival decks are looked up by deck id; anything unknown gets Dashain.
    static func forDeck(_ id: String) -> FestivalConfig {
        switch id {
        case "tihar": return .tihar
        case "dashain": return .dashain
        case "daily-conversations": return .conversations
        default: return .dashain
        }
    }

    static let dashain = FestivalConfig(
        skyTop: Color(red: 1.0, green: 0.62, blue: 0.35),
        skyBottom: Color(red: 1.0, green: 0.88, blue: 0.66),
        ground: Color(red: 0.38, green: 0.62, blue: 0.32),
        night: false,
        goal: "Find all 5 Dashain treasures!",
        doneTitle: "शुभ दशैं! Happy Dashain! 🪁",
        hotspots: [
            FestivalHotspot(id: "dash_tika", wordId: "dash_tika",
                            emoji: "🔴", x: 0.14, y: 0.34, size: 42, motion: .pulse, startsUnlit: false),
            FestivalHotspot(id: "dash_jamara", wordId: "dash_jamara",
                            emoji: "🌱", x: 0.87, y: 0.36, size: 48, motion: .sway, startsUnlit: false),
            FestivalHotspot(id: "dash_ping", wordId: "dash_ping",
                            emoji: "", x: 0.5, y: 0.5, size: 0, motion: .sway, startsUnlit: false),
            FestivalHotspot(id: "dash_changa", wordId: "dash_changa",
                            emoji: "🪁", x: 0.74, y: 0.2, size: 52, motion: .bob, startsUnlit: false),
            FestivalHotspot(id: "dash_bhoj", wordId: "dash_bhoj",
                            emoji: "🍛", x: 0.18, y: 0.7, size: 48, motion: .bob, startsUnlit: false),
        ],
        stars: []
    )

    static let tihar = FestivalConfig(
        skyTop: Color(red: 0.07, green: 0.09, blue: 0.25),
        skyBottom: Color(red: 0.22, green: 0.16, blue: 0.42),
        ground: Color(red: 0.14, green: 0.12, blue: 0.2),
        night: true,
        goal: "Light all 5 diyos, then find every treasure!",
        doneTitle: "शुभ तिहार! Happy Tihar! 🪔",
        hotspots: [
            FestivalHotspot(id: "tihar_diyo_1", wordId: "tihar_diyo",
                            emoji: "🪔", x: 0.1, y: 0.74, size: 54, motion: .pulse, startsUnlit: true),
            FestivalHotspot(id: "tihar_diyo_2", wordId: "tihar_diyo",
                            emoji: "🪔", x: 0.3, y: 0.74, size: 54, motion: .pulse, startsUnlit: true),
            FestivalHotspot(id: "tihar_diyo_3", wordId: "tihar_diyo",
                            emoji: "🪔", x: 0.5, y: 0.74, size: 54, motion: .pulse, startsUnlit: true),
            FestivalHotspot(id: "tihar_diyo_4", wordId: "tihar_diyo",
                            emoji: "🪔", x: 0.7, y: 0.74, size: 54, motion: .pulse, startsUnlit: true),
            FestivalHotspot(id: "tihar_diyo_5", wordId: "tihar_diyo",
                            emoji: "🪔", x: 0.9, y: 0.74, size: 54, motion: .pulse, startsUnlit: true),
            FestivalHotspot(id: "tihar_sayapatri", wordId: "tihar_sayapatri",
                            emoji: "🌼", x: 0.16, y: 0.4, size: 46, motion: .sway, startsUnlit: false),
            FestivalHotspot(id: "tihar_kukur", wordId: "tihar_kukur",
                            emoji: "🐕", x: 0.84, y: 0.44, size: 54, motion: .bob, startsUnlit: false),
            FestivalHotspot(id: "tihar_tihar", wordId: "tihar_tihar",
                            emoji: "🎇", x: 0.5, y: 0.12, size: 48, motion: .pulse, startsUnlit: false),
            FestivalHotspot(id: "tihar_kaag", wordId: "tihar_kaag",
                            emoji: "🐦‍⬛", x: 0.3, y: 0.28, size: 46, motion: .bob, startsUnlit: false),
            FestivalHotspot(id: "tihar_mala", wordId: "tihar_mala",
                            emoji: "🏵️", x: 0.7, y: 0.28, size: 46, motion: .sway, startsUnlit: false),
            FestivalHotspot(id: "tihar_laxmi", wordId: "tihar_laxmi",
                            emoji: "🪷", x: 0.5, y: 0.45, size: 54, motion: .pulse, startsUnlit: false),
            FestivalHotspot(id: "tihar_deusi", wordId: "tihar_deusi",
                            emoji: "🎵", x: 0.14, y: 0.6, size: 44, motion: .bob, startsUnlit: false),
            FestivalHotspot(id: "tihar_bhaitika", wordId: "tihar_bhaitika",
                            emoji: "👧", x: 0.86, y: 0.62, size: 48, motion: .sway, startsUnlit: false),
            FestivalHotspot(id: "tihar_selroti", wordId: "tihar_selroti",
                            emoji: "🥯", x: 0.64, y: 0.6, size: 46, motion: .sway, startsUnlit: false),
        ],
        stars: [
            StarSpot(x: 0.08, y: 0.08, delay: 0),
            StarSpot(x: 0.24, y: 0.18, delay: 0.5),
            StarSpot(x: 0.4, y: 0.07, delay: 1.0),
            StarSpot(x: 0.56, y: 0.16, delay: 0.3),
            StarSpot(x: 0.7, y: 0.08, delay: 0.8),
            StarSpot(x: 0.86, y: 0.2, delay: 0.2),
            StarSpot(x: 0.14, y: 0.3, delay: 0.7),
            StarSpot(x: 0.48, y: 0.28, delay: 0.4),
            StarSpot(x: 0.92, y: 0.34, delay: 0.9),
            StarSpot(x: 0.32, y: 0.12, delay: 0.6),
        ]
    )

    // Daily Conversations: a sunny courtyard where two kids chat.
    // The tappable chat bubbles teach the phrases; the Practice button
    // below the scene starts the role-play game.
    static let conversations = FestivalConfig(
        skyTop: Color(red: 0.45, green: 0.75, blue: 1.0),
        skyBottom: Color(red: 0.85, green: 0.95, blue: 1.0),
        ground: Color(red: 0.55, green: 0.75, blue: 0.42),
        night: false,
        goal: "Tap all 10 chat bubbles!",
        doneTitle: "कुराकानी! You can chat! 💬",
        hotspots: [
            FestivalHotspot(id: "convo_namaste", wordId: "convo_namaste",
                            emoji: "🙏", x: 0.5, y: 0.22, size: 52, motion: .pulse, startsUnlit: false),
            FestivalHotspot(id: "convo_mero_naam", wordId: "convo_mero_naam",
                            emoji: "👦", x: 0.16, y: 0.5, size: 48, motion: .bob, startsUnlit: false),
            FestivalHotspot(id: "convo_tapai_naam", wordId: "convo_tapai_naam",
                            emoji: "❓", x: 0.84, y: 0.5, size: 48, motion: .bob, startsUnlit: false),
            FestivalHotspot(id: "convo_kasto", wordId: "convo_kasto",
                            emoji: "😊", x: 0.3, y: 0.32, size: 46, motion: .sway, startsUnlit: false),
            FestivalHotspot(id: "convo_thik", wordId: "convo_thik",
                            emoji: "👍", x: 0.7, y: 0.32, size: 46, motion: .sway, startsUnlit: false),
            FestivalHotspot(id: "convo_dhanyabad", wordId: "convo_dhanyabad",
                            emoji: "🌸", x: 0.12, y: 0.72, size: 44, motion: .pulse, startsUnlit: false),
            FestivalHotspot(id: "convo_khana", wordId: "convo_khana",
                            emoji: "🍛", x: 0.88, y: 0.72, size: 48, motion: .bob, startsUnlit: false),
            FestivalHotspot(id: "convo_kati_barsa", wordId: "convo_kati_barsa",
                            emoji: "🎂", x: 0.5, y: 0.55, size: 48, motion: .pulse, startsUnlit: false),
            FestivalHotspot(id: "convo_pharkera", wordId: "convo_pharkera",
                            emoji: "👋", x: 0.28, y: 0.78, size: 46, motion: .sway, startsUnlit: false),
            FestivalHotspot(id: "convo_ramro", wordId: "convo_ramro",
                            emoji: "⭐", x: 0.72, y: 0.78, size: 44, motion: .sway, startsUnlit: false),
        ],
        stars: []
    )
}

// The idle motion for a hotspot: sway, bob, or pulse, forever.
struct HotspotMotionModifier: ViewModifier {
    let motion: HotspotMotion
    var anchor: UnitPoint = .center
    @State private var moving = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(motion == .sway ? (moving ? 9 : -9) : 0), anchor: anchor)
            .offset(y: motion == .bob ? (moving ? -9 : 9) : 0)
            .scaleEffect(motion == .pulse ? (moving ? 1.12 : 1.0) : 1.0)
            .onAppear { moving = true }
            .animation(
                .easeInOut(duration: motion == .pulse ? 1.1 : 1.8)
                    .repeatForever(autoreverses: true),
                value: moving
            )
    }
}

// A waving kid for the conversations courtyard: head, kurta, and one arm
// that waves forever. `flip` mirrors the figure so the two face each other.
struct WavingPerson: View {
    let shirt: Color
    let flip: Bool
    @State private var wave = false

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Color(red: 0.72, green: 0.5, blue: 0.34))
                .frame(width: 30, height: 30)
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(shirt)
                    .frame(width: 46, height: 58)
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(red: 0.72, green: 0.5, blue: 0.34))
                    .frame(width: 11, height: 32)
                    .rotationEffect(.degrees(wave ? -30 : 30), anchor: .bottom)
                    .offset(x: 6, y: -8)
            }
        }
        .scaleEffect(x: flip ? -1 : 1, y: 1)
        .onAppear { wave = true }
        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: wave)
    }
}

// One twinkling star in the Tihar night sky.
struct TwinkleStar: View {
    let point: CGPoint
    let delay: Double
    @State private var bright = false

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 5, height: 5)
            .opacity(bright ? 1 : 0.2)
            .position(point)
            .onAppear {
                // Stagger the first twinkle so the sky doesn't blink in sync.
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { bright = true }
            }
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: bright)
    }
}

// The ping: a bamboo swing drawn with shapes, for the Dashain scene.
// (Drawn instead of emoji so it can sway from its top bar like the real thing.)
struct SwingDrawing: View {
    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: 0.55, green: 0.36, blue: 0.2))
                .frame(width: 76, height: 7)
            HStack(spacing: 44) {
                Rectangle()
                    .fill(Color(red: 0.55, green: 0.36, blue: 0.2))
                    .frame(width: 3, height: 38)
                Rectangle()
                    .fill(Color(red: 0.55, green: 0.36, blue: 0.2))
                    .frame(width: 3, height: 38)
            }
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: 0.55, green: 0.36, blue: 0.2))
                .frame(width: 56, height: 9)
        }
    }
}

// Sel Roti hotspot: hand-drawn mini sel roti — lumpy golden ring with
// crispy edges. (No sel roti emoji exists; the bagel one was confusing.)
struct SelRotiDrawing: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(red: 0.42, green: 0.24, blue: 0.1), lineWidth: 15)
                .frame(width: 30, height: 30)
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color(red: 0.88, green: 0.62, blue: 0.3),
                                 Color(red: 0.7, green: 0.45, blue: 0.19)],
                        startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 12)
                .frame(width: 30, height: 30)
            Circle().fill(Color(red: 0.8, green: 0.55, blue: 0.26))
                .frame(width: 13, height: 11).offset(x: -14, y: -7)
            Circle().fill(Color(red: 0.72, green: 0.48, blue: 0.21))
                .frame(width: 11, height: 12).offset(x: 13, y: 8)
            Circle().fill(Color(red: 0.5, green: 0.3, blue: 0.13))
                .frame(width: 4, height: 4).offset(x: 15, y: 0)
            Circle().fill(Color(red: 0.93, green: 0.7, blue: 0.38))
                .frame(width: 4, height: 4).offset(x: -11, y: 11)
            Circle().fill(Color(red: 0.5, green: 0.3, blue: 0.13))
                .frame(width: 3, height: 3).offset(x: 1, y: -15)
        }
        .frame(width: 46, height: 46)
    }
}

// Where a Lessons row leads: festival decks open the animated scene,
// conversation decks open the animated courtyard + practice game,
// plain word decks open the normal word list.
@ViewBuilder
func lessonDestination(for deck: Deck) -> some View {
    if deck.kind == "festival" {
        FestivalView(deck: deck)
    } else if deck.kind == "convo" {
        ConversationsView(deck: deck)
    } else if deck.kind == "colors" {
        ColorsView(deck: deck)
    } else if deck.kind == "numbers" {
        NumbersView(deck: deck)
    } else {
        DeckView(deck: deck)
    }
}

/// The subtitle under each deck title in the Lessons list.
func lessonSubtitle(for deck: Deck) -> String {
    switch deck.kind {
    case "festival": return "Interactive festival"
    case "convo": return "Interactive conversations"
    case "colors": return "10 colors"
    case "numbers": return "Count to 30"
    default: return "\(deck.words.count) words"
    }
}

// MARK: - Teaching moments ("show me" cards)
// Tapping a festival hotspot or vocabulary word opens a TeachingCard:
// a looping animated illustration that *shows* what the word means,
// instead of just saying it out loud.

// One twinkling sparkle, placed by hand inside a teaching illustration.
struct Twinkle: View {
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let delay: Double
    @State private var on = false

    var body: some View {
        Text("✨")
            .font(.system(size: size))
            .opacity(on ? 1 : 0.15)
            .position(x: x, y: y)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { on = true }
            }
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
    }
}

// Dashain, the festival itself: kites dancing in the sky.
struct DashainArt: View {
    @State private var fly = false

    var body: some View {
        ZStack {
            Text("🪁")
                .font(.system(size: 64))
                .offset(x: fly ? 40 : -40, y: fly ? -30 : 10)
                .rotationEffect(.degrees(fly ? 12 : -12))
            Text("🎉")
                .font(.system(size: 54))
                .offset(x: -50, y: 30)
                .scaleEffect(fly ? 1.15 : 0.95)
            Twinkle(x: 200, y: 40, size: 26, delay: 0)
            Twinkle(x: 60, y: 120, size: 22, delay: 0.5)
            Twinkle(x: 230, y: 120, size: 20, delay: 0.9)
        }
        .frame(width: 260, height: 170)
        .onAppear { fly = true }
        .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: fly)
    }
}

// Tika: the red blessing mark stamps onto a forehead, with sparkles.
struct TikaArt: View {
    @State private var stamp = false

    var body: some View {
        ZStack {
            Text("🙂").font(.system(size: 110))
            Circle()
                .fill(.red)
                .frame(width: 22, height: 22)
                .offset(y: stamp ? -32 : -110)
            Twinkle(x: 170, y: 60, size: 24, delay: 0.2)
            Twinkle(x: 90, y: 70, size: 20, delay: 0.7)
        }
        .frame(width: 260, height: 170)
        .onAppear { stamp = true }
        .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: stamp)
    }
}

// Jamara: barley sprouts growing out of the soil, one after another.
struct JamaraArt: View {
    @State private var grow = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0.5, green: 0.35, blue: 0.22))
                .frame(width: 180, height: 18)
                .offset(y: 60)
            ForEach(0..<3) { i in
                Text("🌱")
                    .font(.system(size: 54))
                    .offset(x: CGFloat(i - 1) * 55, y: 10)
                    .scaleEffect(grow ? 1 : 0.25, anchor: .bottom)
                    .animation(
                        .easeInOut(duration: 1.4).delay(Double(i) * 0.35)
                            .repeatForever(autoreverses: true),
                        value: grow
                    )
            }
        }
        .frame(width: 260, height: 170)
        .onAppear { grow = true }
    }
}

// Ping: the bamboo swing, swinging big with a rider.
struct PingArt: View {
    @State private var swing = false

    var body: some View {
        ZStack {
            ZStack {
                SwingDrawing().scaleEffect(1.3)
                Text("🧒").font(.system(size: 40)).offset(y: -8)
            }
            .rotationEffect(.degrees(swing ? 24 : -24), anchor: .top)
            .offset(y: -10)
        }
        .frame(width: 260, height: 170)
        .onAppear { swing = true }
        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: swing)
    }
}

// Changa: the kite soaring high past the clouds.
struct ChangaArt: View {
    @State private var soar = false

    var body: some View {
        ZStack {
            Ellipse().fill(.white.opacity(0.9)).frame(width: 90, height: 30).offset(x: -70, y: -50)
            Ellipse().fill(.white.opacity(0.9)).frame(width: 70, height: 24).offset(x: 60, y: 40)
            Text("🪁")
                .font(.system(size: 84))
                .offset(x: soar ? 30 : -30, y: soar ? -40 : 20)
                .rotationEffect(.degrees(soar ? 14 : -10))
            Twinkle(x: 210, y: 130, size: 22, delay: 0.4)
        }
        .frame(width: 260, height: 170)
        .onAppear { soar = true }
        .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: soar)
    }
}

// Ghatasthapana, day one: the kalash with jamara sprouting as the sun rises.
struct GhatasthapanaArt: View {
    @State private var grow = false

    var body: some View {
        ZStack {
            Circle().fill(.yellow).frame(width: 44, height: 44)
                .offset(x: 80, y: grow ? -50 : -20)
            Text("🏺").font(.system(size: 80)).offset(y: 25)
            Text("🌱").font(.system(size: 44)).offset(y: -8)
                .scaleEffect(grow ? 1 : 0.3, anchor: .bottom)
        }
        .frame(width: 260, height: 170)
        .onAppear { grow = true }
        .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: grow)
    }
}

// Ashirbad: blessings — folded hands, hearts rising with warm wishes.
struct AshirbadArt: View {
    @State private var bless = false

    var body: some View {
        ZStack {
            Circle().fill(.yellow.opacity(0.25)).frame(width: 150, height: 150)
            Text("🙏").font(.system(size: 84))
            ForEach(0..<3) { i in
                Text("💛")
                    .font(.system(size: 26))
                    .offset(x: CGFloat(i - 1) * 40, y: bless ? -70 : -10)
                    .opacity(bless ? 0 : 1)
                    .animation(
                        .easeInOut(duration: 1.8).delay(Double(i) * 0.3)
                            .repeatForever(autoreverses: true),
                        value: bless
                    )
            }
            Text("🙂").font(.system(size: 54)).offset(y: 55)
        }
        .frame(width: 260, height: 170)
        .onAppear { bless = true }
    }
}

// Bhoj: the festival feast, steaming hot.
struct BhojArt: View {
    @State private var steam = false

    var body: some View {
        ZStack {
            Text("🍛").font(.system(size: 100))
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(0.7))
                    .frame(width: 10, height: 34)
                    .blur(radius: 4)
                    .offset(x: CGFloat(i - 1) * 26, y: steam ? -78 : -38)
                    .opacity(steam ? 0 : 0.8)
                    .animation(
                        .easeOut(duration: 1.6).delay(Double(i) * 0.4)
                            .repeatForever(autoreverses: false),
                        value: steam
                    )
            }
        }
        .frame(width: 260, height: 170)
        .onAppear { steam = true }
    }
}

// Tihar, the festival of lights: diyos lighting up one by one.
struct TiharArt: View {
    @State private var lit = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(red: 0.08, green: 0.08, blue: 0.18))
                .frame(width: 240, height: 150)
            HStack(spacing: 8) {
                ForEach(0..<5) { i in
                    Text("🪔")
                        .font(.system(size: 34))
                        .grayscale(lit ? 0 : 1)
                        .opacity(lit ? 1 : 0.45)
                        .shadow(color: lit ? .orange : .clear, radius: lit ? 10 : 0)
                        .animation(
                            .easeIn(duration: 0.5).delay(Double(i) * 0.4)
                                .repeatForever(autoreverses: true),
                            value: lit
                        )
                }
            }
            Twinkle(x: 40, y: 30, size: 20, delay: 0.3)
            Twinkle(x: 220, y: 40, size: 22, delay: 0.8)
        }
        .frame(width: 260, height: 170)
        .onAppear { lit = true }
    }
}

// Diyo: a clay lamp catching its flame.
struct DiyoArt: View {
    @State private var flicker = false

    var body: some View {
        ZStack {
            Circle().fill(.orange.opacity(0.25)).frame(width: 130, height: 130)
            Text("🪔").font(.system(size: 96))
            Text("🔥")
                .font(.system(size: 40))
                .offset(y: -52)
                .scaleEffect(flicker ? 1.15 : 0.9)
                .opacity(flicker ? 1 : 0.75)
        }
        .frame(width: 260, height: 170)
        .onAppear { flicker = true }
        .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: flicker)
    }
}

// Sayapatri: marigolds blooming open.
struct SayapatriArt: View {
    @State private var bloom = false

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Text("🌼")
                    .font(.system(size: 64))
                    .offset(x: CGFloat(i - 1) * 62, y: CGFloat((i % 2) * 14 - 7))
                    .scaleEffect(bloom ? 1 : 0.2)
                    .rotationEffect(.degrees(bloom ? 0 : -40))
                    .animation(
                        .spring(response: 0.7, dampingFraction: 0.55).delay(Double(i) * 0.3)
                            .repeatForever(autoreverses: true),
                        value: bloom
                    )
            }
        }
        .frame(width: 260, height: 170)
        .onAppear { bloom = true }
    }
}

// Mala: loose marigolds dropping onto the string to form a garland.
struct MalaArt: View {
    @State private var string = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(red: 0.4, green: 0.25, blue: 0.15))
                .frame(width: 200, height: 6)
            HStack(spacing: 6) {
                ForEach(0..<5) { _ in
                    Text("🌼").font(.system(size: 40))
                }
            }
            .offset(y: string ? 0 : -70)
            .opacity(string ? 1 : 0)
        }
        .frame(width: 260, height: 170)
        .onAppear { string = true }
        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: string)
    }
}

// Kaag Tihar: the crow hops over to its bowl of rice.
struct KaagArt: View {
    @State private var feed = false

    var body: some View {
        ZStack {
            Text("🐦‍⬛")
                .font(.system(size: 84))
                .offset(x: feed ? 30 : -60, y: -20)
            Text("🍚")
                .font(.system(size: 60))
                .offset(x: 30, y: 45)
                .scaleEffect(feed ? 1 : 0.01)
        }
        .frame(width: 260, height: 170)
        .onAppear { feed = true }
        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: feed)
    }
}

// Kukur Tihar: the dog gets its marigold garland and tika.
struct KukurArt: View {
    @State private var honor = false

    var body: some View {
        ZStack {
            Text("🐕").font(.system(size: 100))
            HStack(spacing: 2) {
                ForEach(0..<4) { _ in
                    Text("🌼").font(.system(size: 26))
                }
            }
            .offset(y: honor ? 28 : -80)
            Circle()
                .fill(.red)
                .frame(width: 14, height: 14)
                .offset(y: honor ? -34 : -90)
                .opacity(honor ? 1 : 0)
        }
        .frame(width: 260, height: 170)
        .onAppear { honor = true }
        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: honor)
    }
}

// Laxmi Puja: the lotus blooms between two diyos, coins rising.
struct LaxmiArt: View {
    @State private var worship = false

    var body: some View {
        ZStack {
            Text("🪷")
                .font(.system(size: 84))
                .scaleEffect(worship ? 1 : 0.4, anchor: .bottom)
            Text("🪔").font(.system(size: 40)).offset(x: -80, y: 30)
                .shadow(color: .orange, radius: 8)
            Text("🪔").font(.system(size: 40)).offset(x: 80, y: 30)
                .shadow(color: .orange, radius: 8)
            ForEach(0..<3) { i in
                Text("🪙")
                    .font(.system(size: 22))
                    .offset(x: CGFloat(i - 1) * 36, y: worship ? -64 : -20)
                    .opacity(worship ? 0 : 1)
                    .animation(
                        .easeIn(duration: 1.6).delay(Double(i) * 0.3)
                            .repeatForever(autoreverses: false),
                        value: worship
                    )
            }
        }
        .frame(width: 260, height: 170)
        .onAppear { worship = true }
    }
}

// Bhai Tika: the tika travels from sister to brother's forehead.
struct BhaiTikaArt: View {
    @State private var tika = false

    var body: some View {
        ZStack {
            Text("👧").font(.system(size: 84)).offset(x: -55)
            Text("👦").font(.system(size: 84)).offset(x: 55)
            Circle()
                .fill(.red)
                .frame(width: 18, height: 18)
                .offset(x: tika ? 55 : -55, y: -28)
            Twinkle(x: 185, y: 55, size: 22, delay: 0.2)
            Twinkle(x: 200, y: 80, size: 18, delay: 0.8)
        }
        .frame(width: 260, height: 170)
        .onAppear { tika = true }
        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: tika)
    }
}

// Deusi Bhailo: singing groups at the doorstep, music in the air.
struct DeusiArt: View {
    @State private var sing = false

    var body: some View {
        ZStack {
            Text("🏠").font(.system(size: 92)).offset(x: 55, y: 20)
            Text("🧑‍🤝‍🧑").font(.system(size: 64)).offset(x: -60, y: 30)
            ForEach(0..<3) { i in
                Text(["🎵", "🎶", "🎵"][i])
                    .font(.system(size: 26))
                    .offset(x: -60 + CGFloat(i - 1) * 30, y: sing ? -60 : 0)
                    .opacity(sing ? 0 : 1)
                    .animation(
                        .easeOut(duration: 1.8).delay(Double(i) * 0.35)
                            .repeatForever(autoreverses: false),
                        value: sing
                    )
            }
        }
        .frame(width: 260, height: 170)
        .onAppear { sing = true }
    }
}

// Sel Roti: the golden, crispy ring frying in the pan, bubbles rising.
// Real sel roti isn't a perfect ring — it's lumpy and hand-piped, deep
// golden-brown with darker crispy edges, like a thick uneven rope of dough.
struct SelRotiArt: View {
    @State private var fry = false

    // Crispy spots scattered around the ring band (hand-placed).
    private let spots: [(x: CGFloat, y: CGFloat, s: CGFloat, dark: Bool)] = [
        (43, 0, 10, true), (-43, 3, 9, true), (3, -43, 11, false), (-5, 43, 9, true),
        (30, 31, 8, false), (-31, 30, 10, true), (31, -30, 9, true), (-30, -31, 8, false),
        (15, -40, 7, true), (-18, 39, 7, false),
    ]

    var body: some View {
        ZStack {
            // The pan.
            Ellipse().fill(Color(white: 0.2)).frame(width: 190, height: 60).offset(y: 40)
            // The sel roti itself.
            ZStack {
                // Dark crispy underside, peeking out around the edges.
                Circle()
                    .stroke(Color(red: 0.42, green: 0.24, blue: 0.1), lineWidth: 46)
                    .frame(width: 84, height: 84)
                // Golden body of the ring.
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [Color(red: 0.88, green: 0.62, blue: 0.3),
                                     Color(red: 0.72, green: 0.47, blue: 0.2),
                                     Color(red: 0.84, green: 0.58, blue: 0.27)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 36)
                    .frame(width: 84, height: 84)
                // Lumps: hand-piped bulges that break the perfect circle.
                Circle().fill(Color(red: 0.8, green: 0.55, blue: 0.26))
                    .frame(width: 36, height: 32).offset(x: -40, y: -20)
                Circle().fill(Color(red: 0.74, green: 0.5, blue: 0.22))
                    .frame(width: 32, height: 34).offset(x: 38, y: 20)
                Circle().fill(Color(red: 0.7, green: 0.46, blue: 0.2))
                    .frame(width: 30, height: 28).offset(x: 4, y: 42)
                Circle().fill(Color(red: 0.82, green: 0.57, blue: 0.28))
                    .frame(width: 28, height: 30).offset(x: -12, y: -40)
                // Crispy + golden spots for the fried texture.
                ForEach(0..<spots.count, id: \.self) { i in
                    let sp = spots[i]
                    Circle()
                        .fill(sp.dark ? Color(red: 0.5, green: 0.3, blue: 0.13)
                                      : Color(red: 0.93, green: 0.7, blue: 0.38))
                        .frame(width: sp.s, height: sp.s)
                        .offset(x: sp.x, y: sp.y)
                        .opacity(0.85)
                }
            }
            .scaleEffect(fry ? 1.06 : 1.0)
            // Bubbles rising through the hot oil.
            ForEach(0..<4) { i in
                Circle()
                    .fill(.white.opacity(0.6))
                    .frame(width: 8, height: 8)
                    .offset(x: CGFloat(i - 2) * 22, y: fry ? -30 : 30)
                    .opacity(fry ? 0 : 0.8)
                    .animation(
                        .easeOut(duration: 1.4).delay(Double(i) * 0.25)
                            .repeatForever(autoreverses: false),
                        value: fry
                    )
            }
        }
        .frame(width: 260, height: 170)
        .onAppear { fry = true }
    }
}

// Picks the right animated illustration for a festival word.
// Conversation teaching art: two chat bubbles bouncing at each other,
// forever. One generic animation covers all 20 phrases — no bespoke
// art needed per phrase.
struct ConvoArt: View {
    @State private var talking = false

    var body: some View {
        HStack(spacing: 20) {
            Text("💬").font(.system(size: 64)).offset(y: talking ? -12 : 12)
            Text("💬").font(.system(size: 64)).offset(y: talking ? 12 : -12)
        }
        .onAppear { talking = true }
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: talking)
    }
}

struct TeachingArt: View {
    let word: Word

    var body: some View {
        ZStack {
            if let imagePath = word.image, imagePath.hasPrefix("/") {
                // Real illustration from the backend when the word has one
                // (Dashain); the hand-drawn art below stays as the fallback.
                AsyncImage(url: URL(string: GharAPI.baseURLString + imagePath)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure, .empty:
                        fallbackArt
                    @unknown default:
                        fallbackArt
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                fallbackArt
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
    }

    /// The original hand-drawn emoji art, kept for words without an illustration.
    @ViewBuilder
    private var fallbackArt: some View {
        ZStack {
            switch word.id {
            case "dash_dashain": DashainArt()
            case "dash_tika": TikaArt()
            case "dash_jamara": JamaraArt()
            case "dash_ping": PingArt()
            case "dash_changa": ChangaArt()
            case "dash_ghatasthapana": GhatasthapanaArt()
            case "dash_ashirbad": AshirbadArt()
            case "dash_bhoj": BhojArt()
            case "tihar_tihar": TiharArt()
            case "tihar_diyo": DiyoArt()
            case "tihar_sayapatri": SayapatriArt()
            case "tihar_mala": MalaArt()
            case "tihar_kaag": KaagArt()
            case "tihar_kukur": KukurArt()
            case "tihar_laxmi": LaxmiArt()
            case "tihar_bhaitika": BhaiTikaArt()
            case "tihar_deusi": DeusiArt()
            case "tihar_selroti": SelRotiArt()
            case let id where id.hasPrefix("convo_"): ConvoArt()
            default: Text("🎉").font(.system(size: 90))
            }
        }
    }
}

// The "show me" card: the animation up top, the word, and a Hear-it button.
// It says the word out loud as it opens.
struct TeachingCard: View {
    let word: Word
    let onClose: () -> Void
    @State private var player: AVPlayer?   // kept alive so Som's recording plays through

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            VStack(spacing: 10) {
                TeachingArt(word: word)
                Text(word.devanagari)
                    .font(.system(size: 46, weight: .bold))
                Text("\(word.romanized) — \(word.english)")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                // Phrases get a word-by-word gloss: the real teaching.
                if let breakdown = word.breakdown {
                    Text(breakdown)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let example = word.exampleSentenceNp {
                    Text("“\(example)”")
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button {
                        speak()
                    } label: {
                        Label("Hear it", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Done", action: onClose)
                        .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
            .padding(24)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 28)
        }
        .transition(.scale(scale: 0.9).combined(with: .opacity))
        .onAppear {
            speak()
        }
    }

    /// Plays Som's recording when one exists; falls back to the phone's
    /// own voice for words still waiting on a recording — the same
    /// pattern the picture quiz uses in its speak(_:).
    private func speak() {
        if word.hasAudio == true,
           let url = URL(string: GharAPI.baseURLString + word.audioUrl) {
            player = AVPlayer(url: url)
            player?.play()
        } else {
            NepaliSpeaker.say(nepali: word.devanagari, romanized: word.romanized)
        }
    }
}

// MARK: - Festival scene engine

// The animated scene at the top of a festival page: a living diorama of
// Dashain or Tihar. Kids tap the hotspots to hear each Nepali word; finding
// them all earns the same voice cheer + confetti as finishing a mission.
struct FestivalScene: View {
    let deck: Deck
    let config: FestivalConfig
    @Binding var teachingWord: Word?   // set to open the "show me" card

    @State private var found: Set<String> = []
    @State private var lastWord: Word?
    @State private var showConfetti = false
    @State private var celebrated = false

    var body: some View {
        ZStack {
            // Sky and ground.
            VStack(spacing: 0) {
                LinearGradient(colors: [config.skyTop, config.skyBottom],
                               startPoint: .top, endPoint: .bottom)
                config.ground.frame(height: 64)
            }

            // Day: sun + clouds. Night: twinkling stars.
            // Hotspots float above, positioned by fractions so any screen works.
            GeometryReader { geo in
                if config.night {
                    ForEach(config.stars.indices, id: \.self) { i in
                        let star = config.stars[i]
                        TwinkleStar(
                            point: CGPoint(x: star.x * geo.size.width,
                                           y: star.y * geo.size.height),
                            delay: star.delay
                        )
                    }
                } else {
                    Circle()
                        .fill(.yellow)
                        .frame(width: 54, height: 54)
                        .position(x: geo.size.width * 0.88, y: geo.size.height * 0.14)
                    cloud(at: CGPoint(x: geo.size.width * 0.25, y: geo.size.height * 0.14), width: 90)
                    cloud(at: CGPoint(x: geo.size.width * 0.55, y: geo.size.height * 0.26), width: 70)
                }
                ForEach(config.hotspots) { spot in
                    hotspotButton(spot, in: geo.size)
                }
            }

            // Goal pill at the top, discovered-word banner at the bottom.
            VStack {
                Text(config.goal)
                    .font(.caption)
                    .bold()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 10)
                Spacer()
                if celebrated {
                    Text(config.doneTitle)
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.bottom, 10)
                        .transition(.scale.combined(with: .opacity))
                } else if let word = lastWord {
                    Text("\(word.devanagari) · \(word.romanized) — \(word.english)")
                        .font(.subheadline)
                        .bold()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .onChange(of: teachingWord == nil) { _, cardClosed in
            // The card just closed: if that was the last treasure,
            // now is the moment for the voice cheer + confetti.
            if cardClosed { celebrateIfDone() }
        }
        .frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay {
            if showConfetti {
                ConfettiBurst()
                    .allowsHitTesting(false)
                    .task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        showConfetti = false
                    }
            }
        }
    }

    // The win moment: voice cheer + confetti, exactly once. Called when the
    // teaching card closes after the last treasure was found.
    private func celebrateIfDone() {
        guard found.count == config.hotspots.count, !celebrated else { return }
        celebrated = true
        WinFanfare.play()
        showConfetti = false
        DispatchQueue.main.async { showConfetti = true }
    }

    // One cloud: three overlapping white ellipses.
    private func cloud(at point: CGPoint, width: CGFloat) -> some View {
        ZStack {
            Ellipse().fill(.white.opacity(0.92))
                .frame(width: width, height: width * 0.45)
            Ellipse().fill(.white.opacity(0.92))
                .frame(width: width * 0.6, height: width * 0.35)
                .offset(x: -width * 0.25, y: 6)
            Ellipse().fill(.white.opacity(0.92))
                .frame(width: width * 0.55, height: width * 0.32)
                .offset(x: width * 0.25, y: 7)
        }
        .position(point)
    }

    // One hotspot button: speaks the word, marks it found, and celebrates the full set.
    private func hotspotButton(_ spot: FestivalHotspot, in size: CGSize) -> some View {
        let word = deck.words.first { $0.id == spot.wordId }
        let isFound = found.contains(spot.id)
        return Button {
            guard let word else { return }
            found.insert(spot.id)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                lastWord = word
            }
            // The teaching card opens: it shows what the word means and
            // says it out loud. The win moment waits until the card closes
            // so the confetti isn't hidden behind it.
            teachingWord = word
        } label: {
            hotspotFace(spot, word: word, isFound: isFound)
                .scaleEffect(isFound ? 1.18 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isFound)
        }
        .position(x: spot.x * size.width, y: spot.y * size.height)
    }

    // What a hotspot looks like: festivals with real illustrations (Dashain)
    // show them as picture badges; the swing is drawn, everything else is emoji.
    // Unlit diyos sit gray until tapped, then glow.
    @ViewBuilder
    private func hotspotFace(_ spot: FestivalHotspot, word: Word?, isFound: Bool) -> some View {
        if let imagePath = word?.image, imagePath.hasPrefix("/") {
            // Unlit diyos sit gray until tapped, then glow — same as the emoji path.
            let lit = !spot.startsUnlit || isFound
            AsyncImage(url: URL(string: GharAPI.baseURLString + imagePath)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure, .empty:
                    Color.gray.opacity(0.25)
                @unknown default:
                    Color.gray.opacity(0.25)
                }
            }
            .frame(width: 68, height: 68)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .grayscale(lit ? 0 : 1)
            .opacity(spot.startsUnlit && !lit ? 0.55 : 1)
            .shadow(color: spot.startsUnlit && lit ? .orange : .black.opacity(0.3),
                    radius: spot.startsUnlit && lit ? 14 : 6)
            .scaleEffect(isFound ? 1.12 : 1.0)
            .modifier(HotspotMotionModifier(motion: spot.motion, anchor: .top))
        } else if spot.id == "dash_ping" {
            SwingDrawing()
                .modifier(HotspotMotionModifier(motion: spot.motion, anchor: .top))
        } else if spot.id == "tihar_selroti" {
            SelRotiDrawing()
                .modifier(HotspotMotionModifier(motion: spot.motion))
        } else {
            let lit = !spot.startsUnlit || isFound
            Text(spot.emoji)
                .font(.system(size: spot.size))
                .grayscale(lit ? 0 : 1)
                .opacity(spot.startsUnlit && !lit ? 0.5 : 1)
                .shadow(color: spot.startsUnlit && lit ? .orange : .clear,
                        radius: spot.startsUnlit && lit ? 14 : 0)
                .modifier(HotspotMotionModifier(motion: spot.motion))
        }
    }
}

// A festival deck's page: the animated scene, then the vocabulary list
// with the same tap-to-play WordRow the other decks use.
struct FestivalView: View {
    let deck: Deck
    @State private var player: AVPlayer?
    @State private var teachingWord: Word?   // open word = show the "show me" card

    var body: some View {
        let config = FestivalConfig.forDeck(deck.id)
        ScrollView {
            VStack(spacing: 16) {
                FestivalScene(deck: deck, config: config, teachingWord: $teachingWord)
                    .padding(.horizontal)
                Text("Tap a treasure in the scene — or tap any word below to see what it means ✨")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                // "Say it this Dashain": its own tappable section, tap a phrase to hear it.
                // Only decks with phrases in the JSON (Dashain) show this section.
                if let phrases = deck.phrases, !phrases.isEmpty {
                    DisclosureGroup {
                        ForEach(phrases.indices, id: \.self) { i in
                            let phrase = phrases[i]
                            Button {
                                play(phrase: phrase)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(phrase.devanagari)
                                            .font(.headline)
                                        Text(phrase.english)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        Text("Say it this \(deck.title) 🗣️")
                            .font(.headline)
                    }
                    .padding(.horizontal)
                }
                ForEach(deck.words) { word in
                    WordRow(word: word, onPlay: play(word:))
                        .onTapGesture { teachingWord = word }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle(deck.title)
        .overlay {
            if let word = teachingWord {
                TeachingCard(word: word) { teachingWord = nil }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: teachingWord?.id)
    }

    /// Same as DeckView's: builds the full audio URL and plays Som's recording.
    private func play(word: Word) {
        guard let url = URL(string: GharAPI.baseURLString + word.audioUrl) else { return }
        player = AVPlayer(url: url)
        player?.play()
    }

    /// "Say it this Dashain/Tihar": Som's recording when he's recorded the
    /// phrase, otherwise the phone's own voice — same pattern as the
    /// teaching card's speak().
    private func play(phrase: FestivalPhrase) {
        if phrase.hasAudio == true,
           let audioUrl = phrase.audioUrl,
           let url = URL(string: GharAPI.baseURLString + audioUrl) {
            player = AVPlayer(url: url)
            player?.play()
        } else {
            NepaliSpeaker.say(nepali: phrase.devanagari, romanized: phrase.romanized)
        }
    }
}

/// Daily Conversations: the animated courtyard scene on top (tappable
/// phrase bubbles, same engine as the festival scenes), the Practice
/// role-play game in the middle, and the full phrase list below —
/// grouped by section like DeckView, each row opening a teaching card.
struct ConversationsView: View {
    let deck: Deck
    @State private var teachingWord: Word?   // open phrase = show the "show me" card
    @StateObject private var speaker = DialogueSpeaker()  // one voice for every dialogue card
    @State private var openSection: Int? = nil   // which conversation is expanded; nil = all closed
    private let sectionTints: [Color] = [.teal, .indigo, .pink]

    /// Same section grouping as DeckView: headers in file order.
    var grouped: [(header: String?, words: [Word])] {
        var groups: [(header: String?, words: [Word])] = []
        for word in deck.words {
            if !groups.isEmpty, groups.last?.header == word.section {
                groups[groups.count - 1].words.append(word)
            } else {
                groups.append((word.section, [word]))
            }
        }
        return groups
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    Text("Two friends talking — tap a conversation to open it, then hit ▶ to watch it play out, or tap a line to hear it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    NavigationLink(destination: ConvoPracticeView(deck: deck)) {
                        Label("Practice a conversation", systemImage: "person.2.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    ForEach(grouped.indices, id: \.self) { i in
                        ConversationSection(
                            title: grouped[i].header ?? "Conversation",
                            words: grouped[i].words,
                            tint: sectionTints[i % sectionTints.count],
                            isOpen: openSection == i,
                            speaker: speaker,
                            onToggle: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    openSection = (openSection == i) ? nil : i
                                }
                                speaker.stop()   // cut any audio from the section being closed
                                if openSection == i {
                                    // Let the card finish expanding, then bring it into view.
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                        withAnimation { proxy.scrollTo("section-\(i)", anchor: .top) }
                                    }
                                }
                            },
                            onInfo: { teachingWord = $0 }
                        )
                        .id("section-\(i)")
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
        }
        .navigationTitle(deck.title)
        .overlay {
            if let word = teachingWord {
                TeachingCard(word: word) { teachingWord = nil }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: teachingWord?.id)
    }
}

/// One text-to-speech voice shared by every dialogue card on this screen.
///
/// Why a delegate instead of a timer: `AVSpeechSynthesizerDelegate.didFinish`
/// fires the instant a line finishes speaking, so auto-play steps to the next
/// line with perfect timing — no guessing how long a sentence takes to say.
///
/// Two subtleties worth knowing:
/// - `stopSpeaking(at: .immediate)` triggers `didCancel`, never `didFinish`,
///   so cutting a line off can't accidentally advance the conversation.
/// - If card B hits play while card A is mid-line, A is "preempted": its
///   `onPreempt` resets its UI so it doesn't sit there looking stuck.
final class DialogueSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    // nonisolated(unsafe): AVSpeechSynthesizer isn't Sendable, but this
    // instance only ever speaks from the main thread via SwiftUI.
    private nonisolated(unsafe) let synth = AVSpeechSynthesizer()
    private var onFinish: (() -> Void)?
    private var onPreempt: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Speak one line. `onFinish` runs on the main thread when the line ends
    /// on its own; `onPreempt` runs if a later `play` cuts it off first.
    /// Always called on the main thread (button taps and delegate callbacks).
    func play(nepali: String, romanized: String, onFinish: @escaping () -> Void, onPreempt: @escaping () -> Void) {
        if self.onFinish != nil {
            self.onPreempt?()   // someone else was mid-line — reset their UI first
        }
        self.onFinish = onFinish
        self.onPreempt = onPreempt
        synth.stopSpeaking(at: .immediate)
        let utterance: AVSpeechUtterance
        if let nepaliVoice = AVSpeechSynthesisVoice(language: "ne-NP") {
            utterance = AVSpeechUtterance(string: nepali)
            utterance.voice = nepaliVoice
        } else {
            // No Nepali voice on this device (simulators never have one):
            // fall back to the romanized spelling so it's still audible.
            utterance = AVSpeechUtterance(string: romanized)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = 0.45   // slow — these are learners listening
        synth.speak(utterance)
    }

    /// Full stop: no finish callback, no preempt callback, silence now.
    func stop() {
        onFinish = nil
        onPreempt = nil
        synth.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let cb = onFinish
        onFinish = nil
        onPreempt = nil
        if let cb = cb {
            DispatchQueue.main.async { cb() }
        }
    }
}

/// The brain of one dialogue card: which line is playing, who is talking.
///
/// A class, not a struct: the speech-finish callbacks need a stable reference
/// to mutate. `generation` guards against stale callbacks — every new line
/// bumps it, and a callback carrying an older generation is ignored.
final class DialoguePlayer: ObservableObject {
    @Published var autoIndex: Int? = nil        // nil = not auto-playing
    @Published var talkingSpeaker: String? = nil   // "A", "B", or nil
    @Published var speakingWord: Word? = nil   // the line on the "now speaking" bubble

    let words: [Word]
    private let speaker: DialogueSpeaker
    private var generation = 0

    init(words: [Word], speaker: DialogueSpeaker) {
        self.words = words
        self.speaker = speaker
    }

    /// Tap a bubble: stop everything else, hear just that line.
    func tapLine(_ index: Int) {
        guard words.indices.contains(index) else { return }
        stop()
        generation += 1
        let g = generation
        let word = words[index]
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
            talkingSpeaker = word.speaker
            speakingWord = word
        }
        speaker.play(nepali: word.devanagari, romanized: word.romanized,
            onFinish: { [weak self] in
                guard let self = self, self.generation == g else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    self.talkingSpeaker = nil
                    self.speakingWord = nil
                }
            },
            onPreempt: { [weak self] in self?.handlePreempt() })
    }

    /// The ▶ / Stop button.
    func toggleAutoPlay() {
        if autoIndex != nil { stop() } else { startAutoPlay() }
    }

    func stop() {
        generation += 1
        autoIndex = nil
        talkingSpeaker = nil
        speakingWord = nil
        speaker.stop()
    }

    private func startAutoPlay() {
        guard !words.isEmpty else { return }
        autoIndex = 0
        playCurrent()
    }

    /// Speak the current auto-play line; when it finishes, `didFinishLine`
    /// steps to the next one — that callback chain IS the conversation loop.
    private func playCurrent() {
        guard let i = autoIndex, words.indices.contains(i) else { return }
        generation += 1
        let g = generation
        let word = words[i]
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
            talkingSpeaker = word.speaker
            speakingWord = word
        }
        speaker.play(nepali: word.devanagari, romanized: word.romanized,
            onFinish: { [weak self] in
                guard let self = self, self.generation == g else { return }
                self.didFinishLine()
            },
            onPreempt: { [weak self] in self?.handlePreempt() })
    }

    private func didFinishLine() {
        guard let i = autoIndex else { return }
        let next = i + 1
        if next < words.count {
            // A beat between lines — a breath before the next person speaks.
            // speakingWord stays put so the bubble lingers on the line just
            // spoken; the characters go quiet for the pause.
            withAnimation(.easeOut(duration: 0.2)) { talkingSpeaker = nil }
            generation += 1
            let g = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self = self, self.generation == g, self.autoIndex == i else { return }
                self.autoIndex = next
                self.playCurrent()
            }
        } else {
            withAnimation(.easeOut(duration: 0.25)) {
                autoIndex = nil
                talkingSpeaker = nil
                speakingWord = nil
            }
        }
    }

    /// Another card took the shared speaker: reset the UI, ignore late callbacks.
    private func handlePreempt() {
        generation += 1
        autoIndex = nil
        talkingSpeaker = nil
        speakingWord = nil
    }
}

enum PersonAge { case older, younger }

/// A and B as real illustrations (PNGs in Assets.xcassets),
/// instead of drawn shapes. Two frames per person — mouth closed and mouth
/// open — flipped on the bob timer while talking, so their mouths actually
/// move. The rest of the life (breathing float, listener nod, scale-up,
/// sound waves) is the same animation kit as before.
///
/// Teaching notes:
/// - The portraits live in the asset catalog as .imageset folders.
///   `Portraits` (below) loads each with `UIImage(named:)` — the standard
///   iOS way to use image assets, no extra code needed.
/// - The mouth flip-flops on `bob`, the same @State Bool that bobs the body:
///   every time the body bobs down, the mouth-open frame shows. Two frames
///   alternating fast reads as talking — classic cartoon trick.
struct IllustratedPerson: View {
    let age: PersonAge
    let facingRight: Bool   // A (left) looks right; B (right) looks left
    let talking: Bool
    let listening: Bool

    @State private var breathe = false
    @State private var bob = false
    @State private var nod = false

    private var neutral: UIImage? {
        age == .older ? Portraits.olderNeutral : Portraits.youngerNeutral
    }
    private var mouthOpen: UIImage? {
        age == .older ? Portraits.olderTalking : Portraits.youngerTalking
    }

    var body: some View {
        ZStack(alignment: facingRight ? .topTrailing : .topLeading) {
            Group {
                if let uiImage = (talking && bob ? mouthOpen : neutral) ?? neutral {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(height: age == .older ? 148 : 126)
                } else {
                    // Portrait failed to decode — a placeholder so the card never breaks.
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 90))
                        .foregroundStyle(.secondary)
                }
            }
            .rotationEffect(.degrees((talking && bob ? 2.5 : 0) * (facingRight ? 1 : -1)))
            .offset(y: (breathe ? 1.5 : 0) + (bob ? -3 : 0) + (nod ? 3 : 0))
            .scaleEffect(talking ? 1.06 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: talking)
            .background(alignment: .bottom) {
                // Soft ground shadow — plants their feet so they don't float.
                Ellipse()
                    .fill(.black.opacity(0.08))
                    .frame(width: 72, height: 12)
                    .offset(y: 4)
            }
            // Sound waves by the head while talking.
            if talking {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(age == .older ? .blue : .orange)
                            .frame(width: 4, height: 8 + CGFloat(i) * 5)
                    }
                }
                .opacity(bob ? 1 : 0.35)
                .padding(facingRight ? .trailing : .leading, 6)
                .padding(.top, 26)
            }
        }
        .onAppear {
            breathe = false
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .onChange(of: talking) { _, isTalking in
            if isTalking {
                withAnimation(.easeInOut(duration: 0.32).repeatForever(autoreverses: true)) { bob = true }
            } else {
                withAnimation(.easeOut(duration: 0.25)) { bob = false }
            }
        }
        .onChange(of: listening) { _, isListening in
            if isListening {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { nod = true }
            } else {
                withAnimation(.easeOut(duration: 0.4)) { nod = false }
            }
        }
    }
}

/// The line being spoken, floating above the speaker comic-style while the
/// conversation plays. The tail points down toward whoever's talking.
struct NowSpeakingBubble: View {
    let word: Word
    let isA: Bool

    var body: some View {
        VStack(spacing: 1) {
            Text(word.devanagari)
                .font(.subheadline.bold())
                .lineLimit(2)
            Text(word.romanized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .overlay(alignment: isA ? .bottomLeading : .bottomTrailing) {
            ChatTail()
                .fill(.white)
                .frame(width: 18, height: 11)
                .offset(x: isA ? 22 : -22, y: 10)
        }
    }
}

/// The illustrated characters, loaded from Assets.xcassets.
/// (The four portrait PNGs live in their own .imageset folders there —
/// drag new art into the matching imageset to swap a character's look.)
/// `static let` = loaded lazily once, on first use — not at app launch.
enum Portraits {
    static let olderNeutral = UIImage(named: "older-neutral")
    static let olderTalking = UIImage(named: "older-talking")
    static let youngerNeutral = UIImage(named: "younger-neutral")
    static let youngerTalking = UIImage(named: "younger-talking")
}

/// A downward triangle — the little tail on a chat bubble.
/// (The file already has a `Triangle`, but that one points up for roofs
/// and prayer flags, so this gets its own name.)
struct ChatTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// One line of the conversation as a chat bubble: A's lines hug the left in
/// blue, B's hug the right in orange. Tap the bubble to hear it; ⓘ opens the
/// teaching card with the word-by-word breakdown.
struct DialogueBubble: View {
    let word: Word
    let isA: Bool
    let talking: Bool
    let onTap: () -> Void
    let onInfo: () -> Void

    private var tint: Color { isA ? .blue : .orange }

    var body: some View {
        HStack {
            if !isA { Spacer(minLength: 48) }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: isA ? .leading : .trailing, spacing: 3) {
                    Text(word.devanagari)
                        .font(.headline)
                    Text(word.romanized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(word.english)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(tint.opacity(0.13))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: isA ? .bottomLeading : .bottomTrailing) {
                ChatTail()
                    .fill(tint.opacity(0.13))
                    .frame(width: 16, height: 10)
                    .offset(x: isA ? 18 : -18, y: 5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(talking ? tint : .clear, lineWidth: 2.5)
            }
            .scaleEffect(talking ? 1.03 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: talking)
            .onTapGesture(perform: onTap)
            if isA { Spacer(minLength: 48) }
        }
    }
}

/// One conversation section as a stage: A (blue, left) and B (orange, right)
/// face each other up top; their lines play out as chat bubbles below.
/// ▶ plays the whole exchange line by line — whoever's line it is animates
/// while it's spoken. Tap any line to hear just that one.
/// One conversation in the accordion: a tappable header row that's always
/// visible, with the DialogueCard revealed underneath when open.
/// Only one section opens at a time — tapping another closes the current one
/// (its `onDisappear` stops any playback, so audio never overlaps).
struct ConversationSection: View {
    let title: String
    let words: [Word]
    let tint: Color
    let isOpen: Bool
    let speaker: DialogueSpeaker
    let onToggle: () -> Void
    let onInfo: (Word) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(tint.gradient)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("\(words.count) lines" + (isOpen ? "" : " · tap to open"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)

            if isOpen {
                // header: nil — the section row above already shows the title.
                DialogueCard(header: nil,
                             words: words,
                             speaker: speaker,
                             onInfo: onInfo)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .padding(.top, 10)
            }
        }
    }
}

struct DialogueCard: View {
    let header: String?
    @StateObject private var player: DialoguePlayer
    let onInfo: (Word) -> Void

    init(header: String?, words: [Word], speaker: DialogueSpeaker, onInfo: @escaping (Word) -> Void) {
        self.header = header
        self.onInfo = onInfo
        _player = StateObject(wrappedValue: DialoguePlayer(words: words, speaker: speaker))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                if let header = header {
                    Text(header)
                        .font(.headline)
                }
                Spacer()
                Button(player.autoIndex != nil ? "Stop" : "▶ Play") {
                    player.toggleAutoPlay()
                }
                .buttonStyle(.bordered)
                .tint(player.autoIndex != nil ? .red : .accentColor)
            }
            // The "now speaking" bubble: while the conversation plays (or a
            // line is tapped), the active line floats above whoever's talking,
            // comic-style. The slot only exists during playback, so the card
            // never jumps mid-conversation.
            if player.autoIndex != nil || player.speakingWord != nil {
                ZStack {
                    if let word = player.speakingWord {
                        HStack(spacing: 0) {
                            if word.speaker != "B" {
                                NowSpeakingBubble(word: word, isA: true)
                                Spacer(minLength: 90)
                            } else {
                                Spacer(minLength: 90)
                                NowSpeakingBubble(word: word, isA: false)
                            }
                        }
                        .id(word.id)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .frame(height: 84)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            // The stage: two friends facing each other —
            // A the older, B the younger, as real illustrations.
            HStack(alignment: .bottom, spacing: 0) {
                VStack(spacing: 4) {
                    IllustratedPerson(age: .older, facingRight: true,
                                      talking: player.talkingSpeaker == "A",
                                      listening: player.talkingSpeaker == "B")
                    Text("A")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                }
                Spacer()
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 44)
                Spacer()
                VStack(spacing: 4) {
                    IllustratedPerson(age: .younger, facingRight: false,
                                      talking: player.talkingSpeaker == "B",
                                      listening: player.talkingSpeaker == "A")
                    Text("B")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)
            // The conversation.
            VStack(spacing: 10) {
                ForEach(player.words.indices, id: \.self) { idx in
                    let word = player.words[idx]
                    let isA = word.speaker != "B"   // a missing speaker reads as A
                    DialogueBubble(word: word,
                                   isA: isA,
                                   talking: word.speaker != nil && player.talkingSpeaker == word.speaker,
                                   onTap: { player.tapLine(idx) },
                                   onInfo: { onInfo(word) })
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onDisappear { player.stop() }
    }
}

/// The conversation practice game: a 5-line role-play. Your friend says
/// a line out loud (device voice until Som's recordings land); you pick
/// the right reply. Each correct reply speaks YOUR line back to you,
/// +5 XP, confetti — finish all five for the big cheer.
///
/// Teaching notes:
/// - `script` is data, not UI: (friend's line, your reply, two wrong
///   replies) as word ids. New exchanges = new tuples, zero UI changes.
/// - Options are shuffled ONCE per round into @State. Shuffling inside
///   `body` would re-roll on every redraw and the buttons would jump.
struct ConvoPracticeView: View {
    let deck: Deck
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.last.win") private var lastWin = ""

    @State private var round = 0
    @State private var options: [Word] = []
    @State private var solved = false
    @State private var wrongIDs: Set<String> = []
    @State private var correctCount = 0
    @State private var finished = false
    @State private var showConfetti = false

    private let script: [(prompt: String, answer: String, wrong: [String])] = [
        ("convo_kasto", "convo_thik", ["convo_hoina", "convo_dhanyabad"]),
        ("convo_tapai_naam", "convo_mero_naam", ["convo_thik", "convo_kaha"]),
        ("convo_kati_barsa", "convo_barsa_bhaye", ["convo_class_padhchu", "convo_ramro"]),
        ("convo_khana", "convo_hajur", ["convo_hoina", "convo_maaph"]),
        ("convo_pharkera", "convo_pharkera", ["convo_namaste", "convo_dhanyabad"]),
    ]

    private func word(_ id: String) -> Word? {
        deck.words.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 20) {
            if finished {
                Text("🎉").font(.system(size: 72))
                Text("You held a whole conversation!")
                    .font(.title2).bold()
                    .multilineTextAlignment(.center)
                Text("\(correctCount) out of \(script.count) perfect replies")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("+\(correctCount * 5) XP")
                    .font(.title3).bold()
                    .foregroundStyle(.green)
                Button("Practice again") {
                    round = 0
                    correctCount = 0
                    finished = false
                    startRound()
                }
                .buttonStyle(.borderedProminent)
            } else if let prompt = word(script[round].prompt) {
                let correctID = script[round].answer
                Text("Your friend says:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    Text("🧑").font(.system(size: 44))
                    Text(prompt.devanagari)
                        .font(.title2).bold()
                        .multilineTextAlignment(.center)
                    Text(prompt.romanized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        NepaliSpeaker.say(nepali: prompt.devanagari, romanized: prompt.romanized)
                    } label: {
                        Label("Hear it again", systemImage: "speaker.wave.2.fill")
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 16))

                Text("Your reply:")
                    .font(.headline)
                ForEach(options) { option in
                    Button(action: { answer(option, correctID: correctID) }) {
                        VStack(spacing: 2) {
                            Text(option.english).font(.headline)
                            Text(option.romanized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(background(for: option, correctID: correctID))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(solved)
                }
                if solved {
                    Button("Next line") { nextRound() }
                        .buttonStyle(.borderedProminent)
                }
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Practice")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { startRound() }
        .overlay {
            if showConfetti {
                ConfettiBurst()
                    .allowsHitTesting(false)
                    .task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        showConfetti = false
                    }
            }
        }
    }

    /// Fresh round: shuffle the reply options once, reset state,
    /// and speak the friend's line out loud.
    private func startRound() {
        let exchange = script[round]
        options = ([exchange.answer] + exchange.wrong).compactMap(word).shuffled()
        solved = false
        wrongIDs = []
        if let prompt = word(exchange.prompt) {
            NepaliSpeaker.say(nepali: prompt.devanagari, romanized: prompt.romanized)
        }
    }

    private func answer(_ option: Word, correctID: String) {
        if option.id == correctID {
            solved = true
            correctCount += 1
            totalXP += 5
            // You "say" your line out loud — hearing yourself nail the
            // reply is the reward. (No voice fanfare here: it would talk
            // over your line. The big cheer waits for the finish.)
            NepaliSpeaker.say(nepali: option.devanagari, romanized: option.romanized)
            celebrate()
        } else {
            wrongIDs.insert(option.id)
        }
    }

    private func nextRound() {
        if round + 1 >= script.count {
            finished = true
            lastWin = "Conversation practice: \(correctCount)/\(script.count)"
            WinFanfare.play()
            celebrate()
        } else {
            round += 1
            startRound()
        }
    }

    /// Same stuck-proof re-trigger as the quiz: drop any in-flight burst
    /// first, then raise a fresh one on the next runloop turn.
    private func celebrate() {
        showConfetti = false
        DispatchQueue.main.async { showConfetti = true }
    }

    /// Button colors, derived from state: right reply goes green,
    /// wrong taps go red, everything else stays neutral.
    private func background(for option: Word, correctID: String) -> Color {
        if solved, option.id == correctID { return .green.opacity(0.25) }
        if wrongIDs.contains(option.id) { return .red.opacity(0.25) }
        return .gray.opacity(0.15)
    }
}

/// The Quiz tab menu: one card per quiz section. Words and Animals are
/// listening quizzes (hear the word, tap the meaning); Dashain and Tihar
/// are picture quizzes (see the illustration, tap the meaning). A section
/// with no recorded audio yet (like Animals right now) shows dimmed with
/// a "Coming soon" note — and wakes up on its own the moment Som's
/// recordings land, no code change needed.
struct QuizMenuView: View {
    let pack: ContentPack

    @AppStorage("ghar.xp.total") private var totalXP = 0

    /// (title, icon, accent, words, picture?) per section, in display order.
    /// Animals and Colors get their own cards; everyday words play together
    /// under Words. Dashain and Tihar are PICTURE quizzes: their words have
    /// beautiful illustrations and no recordings yet, so kids play with eyes
    /// instead of ears. Colors is a LISTENING quiz with swatch answers:
    /// hear the Nepali word, tap the matching color.
    private var sections: [(title: String, icon: String, accent: Color, words: [Word], picture: Bool)] {
        let wordsFor = { (id: String) in pack.decks.first { $0.id == id }?.words ?? [] }
        let rest = pack.decks.filter { !["animals", "colors", "dashain", "tihar"].contains($0.id) }.flatMap { $0.words }
        return [
            ("Words", "💬", .blue, rest, false),
            ("Animals", "🐾", .green, wordsFor("animals"), false),
            ("Colors", "🎨", .pink, wordsFor("colors"), false),
            ("Dashain", "🪔", .orange, wordsFor("dashain"), true),
            ("Tihar", "✨", .purple, wordsFor("tihar"), true),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Header: what quizzes are + the XP reward.
                HStack {
                    Text("🎮")
                        .font(.largeTitle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pick a quiz")
                            .font(.title2)
                            .bold()
                        Text("+5 XP per correct answer · ⭐ \(totalXP) XP")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)

                ForEach(sections.indices, id: \.self) { i in
                    let section = sections[i]
                    let audible = section.words.filter { $0.hasAudio ?? true }
                    let pictured = section.words.filter { $0.image != nil || $0.colorHex != nil }
                    if !audible.isEmpty, !section.picture {
                        // Listening quiz: hear the word, tap what it means.
                        NavigationLink {
                            QuizView(words: section.words)
                                .navigationTitle("\(section.title) Quiz")
                        } label: {
                            quizCard(title: section.title, icon: section.icon,
                                     accent: section.accent,
                                     subtitle: "Hear the word, tap what it means",
                                     count: section.words.count)
                        }
                        .buttonStyle(.plain)
                    } else if section.picture, !pictured.isEmpty {
                        // Picture quiz: see the illustration, tap what it means.
                        NavigationLink {
                            PictureQuizView(words: section.words)
                                .navigationTitle("\(section.title) Quiz")
                        } label: {
                            quizCard(title: section.title, icon: section.icon,
                                     accent: section.accent,
                                     subtitle: "See the picture, tap what it means",
                                     count: section.words.count)
                        }
                        .buttonStyle(.plain)
                    } else {
                        // Nothing to play with yet — this card enables itself
                        // once recordings or illustrations exist.
                        quizCard(title: section.title, icon: section.icon,
                                 accent: .gray, subtitle: "Coming soon", count: 0)
                            .opacity(0.45)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    /// A single quiz-section card: emoji icon, title, how it plays, count.
    private func quizCard(title: String, icon: String, accent: Color,
                          subtitle: String, count: Int) -> some View {
        HStack(spacing: 12) {
            Text(icon)
                .font(.largeTitle)
                .frame(width: 58, height: 58)
                .background(accent.opacity(0.15))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(count > 0 ? "\(subtitle) · \(count) words" : subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: count > 0 ? "chevron.right" : "speaker.slash.fill")
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
}

/// The Quiz tab: a listening game. Hear a Nepali word, tap what it means.
/// +5 XP per correct answer — fed into the SAME total as missions.
///
/// Teaching notes:
/// - A "question" is just @State: the `current` word, the shuffled
///   `options`, whether it's `solved`, and which taps were `wrongIDs`.
///   Everything on screen is derived from those four — no hidden state.
/// - `onAppear` and the "Next word" button both call `newQuestion()`.
///   Same call in two places = it deserved its own function.
/// - XP lands in the same "ghar.xp.total" locker as missions. One shared
///   total, because both views watch the same key.
/// - Wrong taps just mark red and let the kid retry — friendlier for
///   learning than one-strike. The +5 lands exactly once, inside the
///   branch where the right answer is tapped.
struct QuizView: View {
    let words: [Word]
    @State private var player: AVPlayer?
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.last.win") private var lastWin = ""

    @State private var current: Word?
    @State private var options: [Word] = []
    @State private var solved = false
    @State private var wrongIDs: Set<String> = []
    @State private var showConfetti = false
    /// Shuffled deck of upcoming questions: every word gets asked once
    /// before anything repeats, so the quiz never feels stuck on one word.
    @State private var queue: [Word] = []

    var body: some View {
        VStack(spacing: 20) {
            Text("What did you hear?")
                .font(.title2)
                .bold()

            Button(action: playWord) {
                Label("Play word", systemImage: "speaker.wave.2.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderedProminent)
            .disabled(current == nil)

            ForEach(options) { option in
                Button(action: { answer(option) }) {
                    if let hex = option.colorHex {
                        // Colors quiz: hear the Nepali word, tap the matching
                        // swatch. No text — the color IS the answer.
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(hex: hex))
                            .frame(height: 76)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(swatchBorder(for: option), lineWidth: 4)
                            )
                            .opacity(wrongIDs.contains(option.id) ? 0.35 : 1.0)
                    } else {
                        HStack(spacing: 12) {
                            // Animals (and any word with a picture) show it
                            // right on the answer — tap what you see.
                            if let imagePath = option.image, imagePath.hasPrefix("/") {
                                AsyncImage(url: URL(string: GharAPI.baseURLString + imagePath)) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().scaledToFill()
                                    case .failure, .empty:
                                        Color.clear
                                    @unknown default:
                                        Color.clear
                                    }
                                }
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            Text(option.english)
                                .font(.headline)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(background(for: option))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .disabled(solved)
            }

            if solved {
                Button("Next word") { newQuestion() }
                    .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding()
        .onAppear { newQuestion() }
        // Confetti layer: floats on top, ignores taps, removes itself after ~1.2s.
        .overlay {
            if showConfetti {
                ConfettiBurst()
                    .allowsHitTesting(false)
                    .task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        showConfetti = false
                    }
            }
        }
    }

    /// Fresh question: dealt from a shuffled queue, so every word is asked
    /// once before anything repeats. Plus up to 3 random distractors, all
    /// shuffled. Auto-plays the word.
    private func newQuestion() {
        // Only words with recorded audio can be quiz questions —
        // a listening game with nothing to hear isn't a game.
        // `?? true`: packs from before `has_audio` existed count as audible.
        let audible = words.filter { $0.hasAudio ?? true }
        if queue.isEmpty {
            queue = audible.filter { $0.id != current?.id }.shuffled()
            if queue.isEmpty { queue = audible.shuffled() } // single-word quiz
        }
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        current = next
        let distractors = audible.filter { $0.id != next.id }.shuffled().prefix(3)
        options = ([next] + distractors).shuffled()
        solved = false
        wrongIDs = []
        playWord()
    }

    /// Same streaming trick as everywhere else: server + path from JSON.
    /// Words still missing audio just stay silent — no crash.
    private func playWord() {
        guard let current,
              let url = URL(string: GharAPI.baseURLString + current.audioUrl) else { return }
        player = AVPlayer(url: url)
        player?.play()
    }

    private func answer(_ option: Word) {
        if option.id == current?.id {
            solved = true
            totalXP += 5
            // The win moment: voice cheer + confetti.
            WinFanfare.play()
            celebrate()
            lastWin = "Quiz: \(option.english)"
        } else {
            wrongIDs.insert(option.id)
        }
    }

    /// Same stuck-proof re-trigger as MissionDetailView: drop any in-flight
    /// burst first, then raise a fresh one on the next runloop turn.
    private func celebrate() {
        showConfetti = false
        DispatchQueue.main.async { showConfetti = true }
    }

    /// Button colors, derived from state: right answer goes green,
    /// wrong taps go red, everything else stays neutral.
    private func background(for option: Word) -> Color {
        if solved, option.id == current?.id { return .green.opacity(0.25) }
        if wrongIDs.contains(option.id) { return .red.opacity(0.25) }
        return .gray.opacity(0.15)
    }

    /// Border for color-swatch answers: green ring on the right answer,
    /// subtle otherwise. Wrong taps fade via opacity instead.
    private func swatchBorder(for option: Word) -> Color {
        if solved, option.id == current?.id { return .green }
        return .primary.opacity(0.12)
    }
}

/// The festival quiz: a PICTURE game. See the illustration, tap what it means.
/// +5 XP per correct answer — fed into the SAME total as everything else.
///
/// Why not listening like the rest? Dashain/Tihar words have gorgeous
/// watercolor art but no recordings yet. Eyes instead of ears — and the
/// day Som records them, they can join the listening quiz too.
///
/// Teaching notes:
/// - Same shape as QuizView on purpose: `current`, `options`, `solved`,
///   `wrongIDs` — once you understand one quiz, you understand both.
/// - The only real differences: the question shows an `AsyncImage`
///   (streamed from the backend, same as WordRow) instead of a Play
///   button, and the pool is words that HAVE illustrations.
struct PictureQuizView: View {
    let words: [Word]
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.last.win") private var lastWin = ""

    @State private var current: Word?
    @State private var options: [Word] = []
    /// Shuffled deck of upcoming questions: every picture gets asked once
    /// before anything repeats, so the quiz never feels stuck on one word.
    @State private var queue: [Word] = []
    /// The recording player: kept alive while the word plays, same trick
    /// as the listening quiz.
    @State private var player: AVPlayer?
    @State private var solved = false
    @State private var wrongIDs: Set<String> = []
    @State private var showConfetti = false

    var body: some View {
        // ScrollView: the picture + hint + 4 answers + Next button is taller
        // than the screen, so without this the Next button gets pushed
        // off the bottom and can never be reached.
        ScrollView {
            VStack(spacing: 20) {
                Text("What is this?")
                    .font(.title2)
                    .bold()

                if let current {
                    if let imagePath = current.image {
                        AsyncImage(url: URL(string: GharAPI.baseURLString + imagePath)) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            case .failure, .empty:
                                ProgressView()
                            @unknown default:
                                ProgressView()
                            }
                        }
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(radius: 4)
                    } else if let hex = current.colorHex {
                        // Colors quiz: the swatch IS the picture.
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(hex: hex))
                            .frame(height: 220)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                            .shadow(radius: 4)
                    }
                }

                // A distinguishing hint for similar-looking pictures (Dashain).
                // Words without one just skip this — no empty space.
                if let hint = current?.quizHint {
                    Text(hint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                ForEach(options) { option in
                    Button(action: { answer(option) }) {
                        VStack(spacing: 2) {
                            Text(option.english)
                                .font(.headline)
                            Text(option.devanagari)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(background(for: option))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(solved)
                }

                if solved {
                    Button("Next picture") { newQuestion() }
                        .buttonStyle(.bordered)
                        .padding(.bottom)
                }
            }
            .padding()
        }
        .onAppear { newQuestion() }
        .overlay {
            if showConfetti {
                ConfettiBurst()
                    .allowsHitTesting(false)
                    .task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        showConfetti = false
                    }
            }
        }
    }

    /// Fresh question: dealt from the shuffled queue, so every picture is
    /// asked once before anything repeats. Refills (minus the just-asked
    /// word, so the boundary never repeats either) when the queue runs out.
    private func newQuestion() {
        let pictured = words.filter { $0.image != nil || $0.colorHex != nil }
        if queue.isEmpty {
            queue = pictured.filter { $0.id != current?.id }.shuffled()
            if queue.isEmpty { queue = pictured.shuffled() } // single-word quiz
        }
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        current = next
        let distractors = pictured.filter { $0.id != next.id }.shuffled().prefix(3)
        options = ([next] + distractors).shuffled()
        solved = false
        wrongIDs = []
    }

    private func answer(_ option: Word) {
        // Say the tapped word out loud — the family recording once it
        // exists, otherwise the phone's own voice.
        speak(option)
        if option.id == current?.id {
            solved = true
            totalXP += 5
            celebrate()
            lastWin = "Picture quiz: \(option.english)"
        } else {
            wrongIDs.insert(option.id)
        }
    }

    /// Says the tapped word out loud: the family recording when it exists,
    /// otherwise the phone's own voice (Nepali if installed, else the
    /// romanized word in English) — so answers talk from day one, even
    /// before anything is recorded.
    private func speak(_ word: Word) {
        if word.hasAudio == true,
           let url = URL(string: GharAPI.baseURLString + word.audioUrl) {
            player = AVPlayer(url: url)
            player?.play()
        } else {
            NepaliSpeaker.say(nepali: word.devanagari, romanized: word.romanized)
        }
    }

    private func celebrate() {
        showConfetti = false
        DispatchQueue.main.async { showConfetti = true }
    }

    private func background(for option: Word) -> Color {
        if solved, option.id == current?.id { return .green.opacity(0.25) }
        if wrongIDs.contains(option.id) { return .red.opacity(0.25) }
        return .gray.opacity(0.15)
    }
}

/// A plain triangle. SwiftUI has no built-in triangle, so we draw one:
/// apex at top-center, base along the bottom, then close the path.
/// Used for the roof and the prayer flags.
///
/// Teaching notes:
/// - `Shape` is SwiftUI's "draw anything" protocol: you get a rectangle
///   (`rect`) and return a `Path`. Fill it, stroke it, size it — it's
///   vector art, crisp at any size, zero image assets.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// One piece of confetti: its color, flight direction, and spin.
/// `Identifiable` so ForEach can tell the pieces apart.
struct ConfettiPiece: Identifiable {
    let id = UUID()
    let color: Color
    let angle: Double     // radians: which way it flies
    let distance: CGFloat // how far it flies
    let size: CGFloat
    let spin: Double      // degrees of rotation at the end
}

/// A confetti burst: ~40 colored pieces explode outward from the center,
/// spin, drift down a little, and fade — pure SwiftUI, no packages,
/// no image assets.
///
/// Teaching notes:
/// - The pieces are pre-rolled with random values ONCE in a `let`.
///   Re-rolling on every redraw would make them jitter.
/// - `exploded` flips false -> true in `onAppear`, and offset + rotation
///   + opacity all animate together in one `withAnimation` — that's what
///   makes it a burst instead of a pop.
struct ConfettiBurst: View {
    @State private var exploded = false

    private let pieces: [ConfettiPiece] = (0..<40).map { _ in
        ConfettiPiece(
            color: [.red, .orange, .yellow, .green, .blue, .purple, .pink].randomElement()!,
            angle: Double.random(in: 0..<(2 * .pi)),
            distance: CGFloat.random(in: 60...160),
            size: CGFloat.random(in: 6...12),
            spin: Double.random(in: -360...360)
        )
    }

    var body: some View {
        ZStack {
            ForEach(pieces) { piece in
                RoundedRectangle(cornerRadius: 2)
                    .fill(piece.color)
                    .frame(width: piece.size, height: piece.size * 0.6)
                    .offset(x: exploded ? cos(piece.angle) * piece.distance : 0,
                            y: exploded ? sin(piece.angle) * piece.distance + 50 : 0)
                    .rotationEffect(.degrees(exploded ? piece.spin : 0))
                    .opacity(exploded ? 0 : 1)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.0)) { exploded = true }
        }
    }
}

/// The win moment: voice cheer + confetti, everywhere EXCEPT the Dashain
/// and Tihar picture quizzes (on those the app says only the tapped word).
///
/// - Som's voice first: a random pick from his recorded Nepali praise
///   words (`praise` in the pack — स्याबास!, राम्रो!, बधाई छ!). The list
///   is set once when the pack loads (see ContentView.load).
/// - No recordings yet: falls back to the old TTS pool so wins still
///   feel like wins until he records.
/// - `stopSpeaking(at: .immediate)` cuts off the previous cheer: if the
///   kid is on a roll answering fast, cheers never pile up and talk over
///   each other.
/// - The synthesizer lives in a `static let` so nothing throws it away
///   mid-sentence — same keep-alive lesson as the AVPlayer in @State.
/// - `UINotificationFeedbackGenerator` = the iPhone success buzz. One
///   line, and it's the Apple-approved way to say "you did it!"
enum WinFanfare {
    /// One synthesizer for the whole app, kept alive forever.
    private static let synth = AVSpeechSynthesizer()
    /// Keeps a praise recording alive while it plays.
    private static var player: AVPlayer?
    /// Som's recorded Nepali praise, set when the pack loads.
    static var praise: [Word] = []

    static func play() {
        // Haptic + voice both run from the button tap on the main thread.
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        // His voice wins: one random recorded praise word.
        let recorded = praise.filter { $0.hasAudio == true }
        if let cheer = recorded.randomElement(),
           let url = URL(string: GharAPI.baseURLString + cheer.audioUrl) {
            synth.stopSpeaking(at: .immediate)
            player = AVPlayer(url: url)
            player?.play()
            return
        }

        // Nothing recorded yet: the TTS pool.
        synth.stopSpeaking(at: .immediate)
        guard let cheer = cheers.randomElement() else { return }
        let utterance = AVSpeechUtterance(string: cheer.text)
        utterance.voice = AVSpeechSynthesisVoice(language: cheer.language)
        utterance.rate = 0.52            // a touch peppier than default
        utterance.pitchMultiplier = 1.15 // a touch more excited
        synth.speak(utterance)
    }

    /// The TTS fallback pool: (words, language code). Nepali lines join
    /// only if a Nepali voice exists — otherwise an English voice would
    /// mangle the pronunciation.
    private static var cheers: [(text: String, language: String)] {
        var lines: [(text: String, language: String)] = [
            ("Yay!", "en-US"),
            ("Amazing!", "en-US"),
            ("You nailed it!", "en-US"),
            ("Brilliant!", "en-US"),
            ("Let's go!", "en-US"),
            ("Too easy for you.", "en-US"),
            ("That's how it's done!", "en-US"),
        ]
        if AVSpeechSynthesisVoice(language: "ne-NP") != nil {
            lines += [("स्याबास!", "ne-NP"),   // "Well done!"
                      ("राम्रो!", "ne-NP")]     // "Nice!"
        }
        return lines
    }
}

/// The My Ghar tab: your house, built from your XP — now with a shop.
/// Nothing is auto-added: kids spend XP in the Ghar Shop to add each
/// decoration. Name it, paint it, poke the decorations — and tap any
/// decoration to hear its Nepali name spoken out loud.
///
/// Teaching notes:
/// - Still zero image assets: sky, sun, clouds, and the whole house are
///   shapes (circles, triangles, rounded rectangles).
/// - The XP total is the wallet: buying deducts from the same
///   "ghar.xp.total" locker that missions and the quiz feed.
/// - Owned decorations live in @AppStorage as a JSON-encoded Set<String>
///   — the same packing trick as completed missions. On-device, no login,
///   COPPA-safe, survives restarts.
/// - "Put away" moves a bought decoration into a second stored set — off
///   the house, free to put back anytime, never earns XP twice.
/// - Tap-to-speak uses NepaliSpeaker (AVSpeechSynthesizer): the real
///   Nepali voice when the device has one, otherwise the romanized word
///   via the English voice — zero audio files to record either way.
/// - The "poke" pattern from before is still here — now each tap both
///   speaks the Nepali name AND pops the decoration.
struct MyGharView: View {
    let pack: ContentPack
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.house.name") private var houseName = ""
    @AppStorage("ghar.house.roof") private var roofChoice = 0
    @AppStorage("ghar.house.walls") private var wallChoice = 0
    @AppStorage("ghar.last.win") private var lastWin = ""
    @AppStorage("ghar.shop.owned") private var ownedData = Data()
    @AppStorage("ghar.missions.verified") private var verifiedData = Data()
    @AppStorage("ghar.sets.awarded") private var awardedSetsData = Data()
    // Suga the parrot: his name, the word ids he's been taught,
    // how many times he's been fed, and big-ticket upgrades owned.
    // All on-device in @AppStorage — COPPA-safe, survives restarts.
    @AppStorage("ghar.buddy.name") private var buddyName = ""
    @AppStorage("ghar.buddy.taught") private var taughtData = Data()
    @AppStorage("ghar.buddy.fed") private var feedCount = 0
    @AppStorage("ghar.upgrades.owned") private var upgradesData = Data()
    // Storage: decorations the kid bought but put away. They're not on
    // the house, cost nothing to put back, and never earn XP twice.
    @AppStorage("ghar.shop.stored") private var storedData = Data()
    // Arrange mode: drag deltas per decoration id, so kids can reposition
    // things. [x, y] pairs added on top of each item's home spot.
    @AppStorage("ghar.layout") private var layoutData = Data()

    // Poke-state: the id of the thing currently popping (nil = nothing).
    // One state for all 18 decorations instead of 18 separate Bools.
    @State private var poppedID: String? = nil
    @State private var sunSpin = false
    @State private var smokeRise = false
    /// Keeps a decoration recording alive while it plays.
    @State private var decoPlayer: AVPlayer?
    // Collapsible sections: the shop/sets/prizes start closed so My Ghar
    // doesn't scroll forever. Counts on the headers say what's inside.
    @State private var shopOpen = false
    @State private var setsOpen = false
    @State private var prizesOpen = false
    @State private var upgradesOpen = false
    // Naming sheet after adopting Suga; teach sheet for new words.
    @State private var namingBuddy = false
    @State private var teachingBuddy = false
    @State private var buddyNameDraft = ""
    // Living-house animation flags: gentle loops that never stop.
    @State private var buddyBob = false
    @State private var flameFlicker = false
    @State private var flagWave = false
    @State private var butterflyFly = false
    // Arrange mode: drag decorations around the house. dragDeltas holds
    // the live in-progress drag per id until the finger lifts.
    @State private var arranging = false
    @State private var dragDeltas: [String: CGSize] = [:]
    // Garden sway + the feeding treat shown at Suga's beak.
    @State private var flowerSway = false
    @State private var feedEmoji: String? = nil
    // Glistening mountain snow.
    @State private var snowTwinkle = false

    // The shop: 15 decorations, priced 5 → 250 XP. Buying EVERYTHING costs
    // 1,200 XP — with verified missions paying 25, that's a real long-term
    // chase, not a day-one sweep. Nothing is auto-added: kids spend XP.
    private let shopItems: [ShopItem] = [
        ShopItem(id: "diyo", nameEn: "Diyo lamp", nameNe: "दियो", romanized: "diyo", icon: "🪔", cost: 5),
        ShopItem(id: "windows", nameEn: "Windows", nameNe: "झ्याल", romanized: "jhyaal", icon: "🪟", cost: 10),
        ShopItem(id: "tulsi", nameEn: "Tulsi plant", nameNe: "तुलसी", romanized: "tulsi", icon: "🪴", cost: 15),
        ShopItem(id: "sayapatri", nameEn: "Marigold", nameNe: "सयपत्री", romanized: "sayapatri", icon: "🌼", cost: 20),
        ShopItem(id: "door", nameEn: "Door", nameNe: "ढोका", romanized: "dhoka", icon: "🚪", cost: 20),
        ShopItem(id: "jamara", nameEn: "Jamara", nameNe: "जमरा", romanized: "jamara", icon: "🌱", cost: 30),
        ShopItem(id: "flags", nameEn: "Prayer flags", nameNe: "प्रार्थना झण्डा", romanized: "prarthana jhanda", icon: "🚩", cost: 35),
        ShopItem(id: "rangoli", nameEn: "Rangoli", nameNe: "रंगोली", romanized: "rangoli", icon: "🎨", cost: 45),
        ShopItem(id: "mala", nameEn: "Garland", nameNe: "माला", romanized: "mala", icon: "🌸", cost: 55),
        ShopItem(id: "buddy", nameEn: "Suga (Parrot)", nameNe: "सुगा", romanized: "suga", icon: "🦜", cost: 140),
        ShopItem(id: "kukur", nameEn: "Dog", nameNe: "कुकुर", romanized: "kukur", icon: "🐕", cost: 70),
        ShopItem(id: "changa", nameEn: "Kite", nameNe: "चङ्गा", romanized: "changa", icon: "🪁", cost: 85),
        ShopItem(id: "himal", nameEn: "Himalayas", nameNe: "हिमाल", romanized: "himal", icon: "🏔️", cost: 105),
        ShopItem(id: "ghanta", nameEn: "Temple bell", nameNe: "घण्टा", romanized: "ghanta", icon: "🔔", cost: 125),
        ShopItem(id: "mandir", nameEn: "Temple", nameNe: "मन्दिर", romanized: "mandir", icon: "🛕", cost: 175),
    ]

    // Prove-it prizes: NOT for sale at any price. Each unlocks when the
    // kid's verified-mission count hits the requirement — the recording
    // flow made tangible. The shop shows them as locked goals.
    private let exclusiveItems: [ShopItem] = [
        ShopItem(id: "goldenDiyo", nameEn: "Golden Diyo", nameNe: "सुनौलो दियो", romanized: "sunaulo diyo", icon: "🪔", cost: 0),
        ShopItem(id: "starBadge", nameEn: "Star Badge", nameNe: "तारा", romanized: "tara", icon: "⭐", cost: 0),
        ShopItem(id: "mukut", nameEn: "Mukut Crown", nameNe: "मुकुट", romanized: "mukut", icon: "👑", cost: 0),
    ]
    private let exclusiveNeed = ["goldenDiyo": 1, "starBadge": 3, "mukut": 5]

    // Big-ticket upgrades: long-term XP goals that change the yard.
    // Garden (phulbari) blooms flowers; chautari grows the classic
    // Nepali rest-stop tree with its stone platform.
    private let upgradeItems: [ShopItem] = [
        ShopItem(id: "garden", nameEn: "Flower Garden", nameNe: "फूलबारी", romanized: "phulbari", icon: "🌷", cost: 210),
        ShopItem(id: "chautari", nameEn: "Chautari Tree", nameNe: "चौतारी", romanized: "chautari", icon: "🌳", cost: 280),
    ]

    // Decoration sets: own every item in a set, pocket a bonus. The long game.
    private let decoSets: [DecoSet] = [
        DecoSet(id: "tihar", nameEn: "Tihar Set", itemIds: ["diyo", "sayapatri", "rangoli", "mala"], bonus: 40),
        DecoSet(id: "garden", nameEn: "Garden Set", itemIds: ["tulsi", "jamara", "kukur"], bonus: 50),
        DecoSet(id: "home", nameEn: "Home Set", itemIds: ["door", "windows", "flags", "buddy"], bonus: 60),
        DecoSet(id: "sky", nameEn: "Sky & Temple Set", itemIds: ["changa", "himal", "ghanta", "mandir"], bonus: 100),
    ]

    /// IDs of owned decorations (bought + prizes), decoded from storage.
    private var ownedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: ownedData)) ?? []
    }

    /// IDs of grown-up-verified missions — drives the Prove-it prizes.
    private var verifiedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: verifiedData)) ?? []
    }

    /// Set ids whose completion bonus was already paid (paid once, ever).
    private var awardedSets: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: awardedSetsData)) ?? []
    }

    /// Word ids Suga has learned — taught by the kid, 10 XP each.
    private var taughtIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: taughtData)) ?? []
    }

    /// Big-ticket upgrade ids owned (garden, chautari…).
    private var upgradeIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: upgradesData)) ?? []
    }

    /// Decoration ids bought but put away in storage — off the house.
    private var storedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: storedData)) ?? []
    }

    /// Saved drag deltas per decoration id: [dx, dy] added on top of each
    /// item's home spot. Empty = everything sits where it started.
    private var layoutDeltas: [String: [Double]] {
        (try? JSONDecoder().decode([String: [Double]].self, from: layoutData)) ?? [:]
    }

    /// A decoration's final offset: its home spot + saved drag + the live
    /// drag in progress (so it follows the finger).
    private func placedOffset(_ id: String, x: CGFloat, y: CGFloat) -> CGSize {
        let s = layoutDeltas[id] ?? [0, 0]
        let live = dragDeltas[id] ?? .zero
        return CGSize(
            width: x + CGFloat(s[0]) + live.width,
            height: y + CGFloat(s.count > 1 ? s[1] : 0) + live.height
        )
    }

    /// Finger lifted: fold the drag into the saved layout.
    private func commitDrag(_ id: String, translation: CGSize) {
        var deltas = layoutDeltas
        let cur = deltas[id] ?? [0, 0]
        deltas[id] = [cur[0] + Double(translation.width),
                       (cur.count > 1 ? cur[1] : 0) + Double(translation.height)]
        layoutData = (try? JSONEncoder().encode(deltas)) ?? Data()
        dragDeltas[id] = nil
    }

    /// What the kid named the parrot — "Suga" until they pick a name.
    private var buddyDisplayName: String {
        let trimmed = buddyName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Suga" : trimmed
    }

    /// Every word in the pack — the teach-a-word picker list.
    private var allWords: [Word] {
        pack.decks.flatMap { $0.words }
    }

    private func word(_ id: String) -> Word? {
        allWords.first { $0.id == id }
    }

    /// Every decoration, shop or prize — for tap-to-speak lookup.
    private func shopItem(_ id: String) -> ShopItem {
        shopItems.first { $0.id == id }
            ?? exclusiveItems.first { $0.id == id }
            ?? shopItems[0]
    }

    /// Says a decoration or scene name out loud: Som's recording when he's
    /// recorded it (`mygharAudio` in the pack), otherwise the phone's own
    /// voice — the same recording-first pattern as everywhere else.
    private func sayDecoration(id: String, nepali: String, romanized: String) {
        // If this exact word was already recorded for the decks (दियो, चङ्गा,
        // जमरा…), reuse that clip — same voice, same tone, nothing to record.
        if let w = allWords.first(where: { $0.devanagari == nepali && $0.hasAudio == true }),
           let url = URL(string: GharAPI.baseURLString + w.audioUrl) {
            decoPlayer = AVPlayer(url: url)
            decoPlayer?.play()
            return
        }
        if pack.mygharAudio?[id] == true,
           let url = URL(string: GharAPI.baseURLString + "/audio/nepal-v1/myghar_\(id)_np.m4a") {
            decoPlayer = AVPlayer(url: url)
            decoPlayer?.play()
        } else {
            NepaliSpeaker.say(nepali: nepali, romanized: romanized)
        }
    }

    /// ShopItem convenience: the Nepali name comes from the item itself.
    private func sayDecoration(_ item: ShopItem) {
        sayDecoration(id: item.id, nepali: item.nameNe, romanized: item.romanized)
    }

    /// Status title from the XP total — the number means something forever,
    /// even after the shop is bought out.
    private var xpTitle: (en: String, ne: String) {
        switch totalXP {
        case 800...: ("Nayak", "नायक")       // hero
        case 400...: ("Ghar-muli", "घरमूली") // head of the household
        case 150...: ("Saathi", "साथी")       // friend
        default: ("Pahuna", "पाहुना")         // guest
        }
    }

    private let roofColors: [(name: String, color: Color)] = [
        ("Crimson", Color(red: 0.75, green: 0.15, blue: 0.2)),
        ("Teal", Color(red: 0.16, green: 0.5, blue: 0.45)),
        ("Marigold", Color(red: 0.95, green: 0.55, blue: 0.15)),
        ("Himal", Color(red: 0.2, green: 0.3, blue: 0.6)),
    ]
    private let wallColors: [(name: String, color: Color)] = [
        ("Cream", Color(red: 1.0, green: 0.96, blue: 0.88)),
        ("Peach", Color(red: 1.0, green: 0.9, blue: 0.8)),
        ("Mint", Color(red: 0.88, green: 0.95, blue: 0.9)),
        ("Sand", Color(red: 0.93, green: 0.87, blue: 0.76)),
    ]

    private let flagColors: [Color] = [.blue, .orange, .red, .green, .yellow]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // The nameplate: whatever the kid named their ghar.
                Text(houseName.isEmpty ? "My Ghar" : "\(houseName)'s Ghar")
                    .font(.title)
                    .bold()

                Text("Earn XP to decorate your house 🏠")
                    .font(.title3)
                    .bold()

                Text("⭐ \(totalXP) XP · \(xpTitle.en)")
                    .font(.headline)
                // How it all works: one plain line, no guessing.
                Text("🎯 Missions +10 · 🎤 Verified +25 · 🎮 Quiz +5")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Empty ghar: tell the kid exactly what to do. If everything
                // is just in storage, nudge them to put it back instead.
                if ownedIDs.isEmpty {
                    Text(storedIDs.isEmpty
                         ? "👆 Your ghar is empty! Do a mission or play the quiz to earn XP, then come back and decorate."
                         : "📦 Everything is in storage! Open the Ghar Shop below to put decorations back.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal)
                }

                // Latest win banner: ties the house to what the kid just did.
                if !lastWin.isEmpty {
                    Text("🎉 Latest win: \(lastWin)")
                        .font(.subheadline)
                        .bold()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.yellow.opacity(0.25))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // The house scene: a Himalayan morning — sun, clouds, snowy
                // peaks, and your ghar with its tiered roof.
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(LinearGradient(
                            colors: [.blue.opacity(0.45), .orange.opacity(0.12)],
                            startPoint: .top, endPoint: .bottom))
                        .frame(width: 310, height: 400)

                    // Sun with slow-turning rays.
                    ZStack {
                        ForEach(0..<8, id: \.self) { i in
                            Rectangle()
                                .fill(.yellow.opacity(0.55))
                                .frame(width: 5, height: 16)
                                .offset(y: -34)
                                .rotationEffect(.degrees(Double(i) * 45))
                        }
                        Circle()
                            .fill(.yellow.opacity(0.95))
                            .frame(width: 44, height: 44)
                    }
                    .offset(x: -100, y: -140)
                    .scaleEffect(poppedID == "sun" ? 1.25 : 1.0)
                    .rotationEffect(.degrees(sunSpin ? 360 : 0))
                    .onTapGesture {
                        sayDecoration(id: "sun", nepali: "सूर्य", romanized: "surya")
                        poke("sun")
                    }
                    .onAppear {
                        withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) {
                            sunSpin = true
                        }
                    }

                    DriftingCloud(startX: 70, y: -120) {
                        sayDecoration(id: "cloud", nepali: "बादल", romanized: "baadal")
                    }
                    DriftingCloud(startX: -60, y: -85) {
                        sayDecoration(id: "cloud", nepali: "बादल", romanized: "baadal")
                    }

                    // The Himalayas — revealed when you buy them.
                    mountainRange

                    // Ground — layered green with a dirt path to the door.
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.green.opacity(0.45))
                        .frame(width: 310, height: 110)
                        .offset(y: 145)
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(red: 0.72, green: 0.6, blue: 0.44).opacity(0.85))
                        .frame(width: 54, height: 64)
                        .offset(y: 168)

                    // Chimney smoke, puffing behind the roof.
                    chimneySmoke

                    VStack(spacing: 0) {
                        // Prayer flags fly above the roof — tap to hear + see them dance.
                        HStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { i in
                                Triangle()
                                    .fill(ownedIDs.contains("flags") ? flagColors[i % flagColors.count] : .gray.opacity(0.25))
                                    .frame(width: 24, height: 20)
                            }
                        }
                        // Prayer flags ripple in the wind forever; tapping
                        // still makes them jump and say their name.
                        .rotationEffect(.degrees((poppedID == "flags" ? 14 : 0) + (flagWave ? 7 : -7)))
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                                flagWave = true
                            }
                        }
                        .onTapGesture {
                            if ownedIDs.contains("flags") {
                                sayDecoration(shopItem("flags"))
                                poke("flags")
                            }
                        }
                        .padding(.bottom, 2)

                        // Tiered roof — terracotta gradient with tile rows,
                        // a nod to Nepali temple architecture. Painted whatever
                        // color the kid picked.
                        ZStack {
                            Triangle()
                                .fill(LinearGradient(
                                    colors: [roofColors[roofChoice % roofColors.count].color,
                                             roofColors[roofChoice % roofColors.count].color.opacity(0.65)],
                                    startPoint: .top, endPoint: .bottom))
                                .frame(width: 130, height: 55)
                            VStack(spacing: 9) {
                                ForEach(0..<3, id: \.self) { _ in
                                    Rectangle()
                                        .fill(.black.opacity(0.14))
                                        .frame(height: 2)
                                }
                            }
                            .frame(width: 130, height: 55)
                            .clipShape(Triangle())
                            .offset(y: 6)
                        }
                        ZStack {
                            Triangle()
                                .fill(LinearGradient(
                                    colors: [roofColors[roofChoice % roofColors.count].color,
                                             roofColors[roofChoice % roofColors.count].color.opacity(0.65)],
                                    startPoint: .top, endPoint: .bottom))
                                .frame(width: 260, height: 105)
                            VStack(spacing: 13) {
                                ForEach(0..<5, id: \.self) { _ in
                                    Rectangle()
                                        .fill(.black.opacity(0.14))
                                        .frame(height: 2.5)
                                }
                            }
                            .frame(width: 260, height: 105)
                            .clipShape(Triangle())
                            .offset(y: 10)
                            // Eave shadow under the roof lip.
                            Triangle()
                                .fill(.black.opacity(0.18))
                                .frame(width: 260, height: 12)
                                .offset(y: 52)
                                .blur(radius: 3)
                        }
                        .scaleEffect(poppedID == "roof" ? 1.05 : 1.0)
                        .onTapGesture {
                            sayDecoration(id: "roof", nepali: "छाना", romanized: "chhana")
                            poke("roof")
                        }

                        // Body — plastered walls with soft shading on a stone foundation.
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(LinearGradient(
                                    colors: [wallColors[wallChoice % wallColors.count].color,
                                             wallColors[wallChoice % wallColors.count].color.opacity(0.82)],
                                    startPoint: .top, endPoint: .bottom))
                                .frame(width: 220, height: 150)
                                .shadow(radius: 3)

                            // Soft shadow under the eaves.
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.black.opacity(0.1))
                                .frame(width: 220, height: 22)
                                .offset(y: -64)
                                .blur(radius: 5)

                            // Stone foundation: individual stones, not a flat bar.
                            HStack(spacing: 4) {
                                ForEach(0..<6, id: \.self) { i in
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color(red: 0.52 + Double(i % 2) * 0.06,
                                                   green: 0.52 + Double(i % 3) * 0.03,
                                                   blue: 0.55))
                                        .frame(width: 32, height: 24)
                                }
                            }
                            .offset(y: 62)

                            HStack(spacing: 80) {
                                window
                                window
                            }
                            .offset(y: -35)
                            .scaleEffect(poppedID == "windows" ? 1.15 : 1.0)
                            .onTapGesture {
                                if ownedIDs.contains("windows") {
                                    sayDecoration(shopItem("windows"))
                                    poke("windows")
                                }
                            }

                            // Paneled wooden door in a dark frame — tap to hear
                            // its name + knock (swings on its hinge).
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(red: 0.3, green: 0.2, blue: 0.1))
                                    .frame(width: 66, height: 100)
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(ownedIDs.contains("door")
                                          ? Color(red: 0.45, green: 0.28, blue: 0.15)
                                          : .gray.opacity(0.25))
                                    .frame(width: 58, height: 92)
                                if ownedIDs.contains("door") {
                                    // Wood plank grooves.
                                    HStack(spacing: 13) {
                                        ForEach(0..<3, id: \.self) { _ in
                                            Rectangle()
                                                .fill(.black.opacity(0.22))
                                                .frame(width: 2, height: 80)
                                        }
                                    }
                                    // Panel insets.
                                    VStack(spacing: 10) {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(.black.opacity(0.15))
                                            .frame(width: 38, height: 28)
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(.black.opacity(0.15))
                                            .frame(width: 38, height: 28)
                                    }
                                    // Iron ring handle.
                                    Circle()
                                        .stroke(.yellow.opacity(0.9), lineWidth: 3)
                                        .frame(width: 13, height: 13)
                                        .offset(x: 18)
                                }
                            }
                            .rotationEffect(.degrees(poppedID == "door" ? -14 : 0), anchor: .leading)
                            .onTapGesture {
                                if ownedIDs.contains("door") {
                                    sayDecoration(shopItem("door"))
                                    poke("door")
                                }
                            }
                            .offset(y: 29)

                            // Doorstep.
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.gray.opacity(0.55))
                                .frame(width: 76, height: 12)
                                .offset(y: 74)

                            diyo
                                .offset(placedOffset("diyo", x: -70, y: 52))
                                .arrange("diyo", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
                                .scaleEffect(poppedID == "diyo" ? 1.35 : 1.0)
                                .onTapGesture {
                                    if ownedIDs.contains("diyo") {
                                        sayDecoration(shopItem("diyo"))
                                        poke("diyo")
                                    }
                                }

                            // On the walls: garland, bell, and Prove-it prizes.
                            bodyDeco
                        }
                    }
                    .offset(y: 20)

                    // Suga perches on the roof — tap him to hear him talk.
                    // (His spot is draggable in Arrange mode, like the rest.)
                    buddy
                        .offset(placedOffset("buddy", x: 42, y: -128 + (poppedID == "buddy" ? -16 : 0)))
                        .arrange("buddy", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
                        .onTapGesture {
                            if ownedIDs.contains("buddy") {
                                buddyTalk()
                                poke("buddy")
                            }
                        }

                    // Feeding moment: the treat pops up at Suga's beak,
                    // then vanishes as he hops and eats it. It follows him
                    // if he's been dragged elsewhere in arrange mode.
                    if let emoji = feedEmoji {
                        Text(emoji)
                            .font(.system(size: 30))
                            .offset(placedOffset("buddy", x: 74, y: -116))
                            .transition(.scale.combined(with: .opacity))
                    }

                    // The yard and sky: bought decorations around the house.
                    sceneDeco
                }

                // Arrange mode: drag anything in the scene to move it.
                // Spots are saved, so the house keeps your layout.
                VStack(spacing: 4) {
                    Button(arranging ? "Done arranging" : "🔀 Arrange house") {
                        arranging.toggle()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    if arranging {
                        Text("Drag decorations to move them — taps still make them talk!")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Suga's corner: feed him, teach him words. Only shows
                // once he's adopted from the shop.
                if ownedIDs.contains("buddy") {
                    VStack(spacing: 10) {
                        HStack {
                            Text("🦜 \(buddyDisplayName) (parrot)")
                                .font(.headline)
                            Spacer()
                            Text("knows \(taughtIDs.count + 2) phrases")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 12) {
                            Button(action: feedBuddy) {
                                Label("Feed · 5 XP", systemImage: "fork.knife")
                            }
                            .buttonStyle(.bordered)
                            .disabled(totalXP < 5)
                            Button(action: { teachingBuddy = true }) {
                                Label("Teach a word · 10 XP", systemImage: "graduationcap")
                            }
                            .buttonStyle(.bordered)
                            .disabled(totalXP < 10)
                        }
                        if feedCount > 0 {
                            Text("Fed \(feedCount) time\(feedCount == 1 ? "" : "s") 🍌")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("Tap Suga in the house to hear him talk!")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.green.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }

                // Name your ghar.
                TextField("Name your ghar…", text: $houseName)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 40)

                // Paint shop: pick roof + wall colors.
                VStack(spacing: 10) {
                    paintRow(label: "Roof", choices: roofColors, selected: $roofChoice)
                    paintRow(label: "Walls", choices: wallColors, selected: $wallChoice)
                }
                .padding(.horizontal)

                // Ghar Shop: spend XP to add decorations to your house.
                // Collapsed by default — tap the header to open.
                DisclosureGroup(isExpanded: $shopOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                    Text("Earn XP from missions and the quiz, then spend it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(shopItems) { item in
                        HStack(spacing: 12) {
                            shopIcon(item)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.nameNe).font(.headline)
                                Text("\(item.romanized) · \(item.nameEn)").font(.caption).foregroundStyle(.secondary)
                            }
                            Button(action: { sayDecoration(item) }) {
                                Image(systemName: "speaker.wave.2.fill")
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            if ownedIDs.contains(item.id) {
                                Button("Put away") { storeItem(item) }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.title3)
                            } else if storedIDs.contains(item.id) {
                                Button("Put back") { placeItem(item) }
                                    .buttonStyle(.bordered)
                            } else if totalXP >= item.cost {
                                Button("Buy · \(item.cost) XP") { buy(item) }
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Text("🔒 \(item.cost) XP")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    }
                } label: {
                    HStack {
                        Text("🏪 Ghar Shop")
                            .font(.headline)
                        Spacer()
                        Text("\(shopItems.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.gray.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                .padding()
                .background(.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                // Prove-it Prizes: earned by verifying missions, never sold.
                // Showing them locked advertises the recording flow.
                // Collapsed by default — tap the header to open.
                DisclosureGroup(isExpanded: $prizesOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                    Text("Verify missions with a grown-up to earn these — they can't be bought.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(exclusiveItems) { item in
                        let need = exclusiveNeed[item.id] ?? 99
                        let have = min(verifiedIDs.count, need)
                        HStack(spacing: 12) {
                            shopIcon(item)
                                .opacity(ownedIDs.contains(item.id) ? 1 : 0.4)
                                .grayscale(ownedIDs.contains(item.id) ? 0 : 1)
                            VStack(alignment: .leading, spacing: 2) {
                                if ownedIDs.contains(item.id) {
                                    Text(item.nameNe).font(.headline)
                                    Text("✅ Earned!").font(.caption).foregroundStyle(.green)
                                } else {
                                    Text("🎤 Verify \(need) mission\(need == 1 ? "" : "s")")
                                        .font(.headline)
                                    Text("\(item.nameNe) · \(item.nameEn)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Button(action: { sayDecoration(item) }) {
                                Image(systemName: "speaker.wave.2.fill")
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            if ownedIDs.contains(item.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.title3)
                            } else {
                                Text("🔒 \(have)/\(need) verified")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    }
                } label: {
                    HStack {
                        Text("🏆 Prove-it Prizes")
                            .font(.headline)
                        Spacer()
                        Text("\(exclusiveItems.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.gray.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                .padding()
                .background(.yellow.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                // Decoration Sets: complete a set, pocket a bonus.
                // Collapsed by default — tap the header to open.
                DisclosureGroup(isExpanded: $setsOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                    Text("Own every item in a set to pocket its bonus — each set pays once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(decoSets) { set in
                        let got = set.itemIds.filter { ownedIDs.contains($0) }.count
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(set.nameEn).font(.headline)
                                Text("\(got)/\(set.itemIds.count) · bonus +\(set.bonus) XP")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if awardedSets.contains(set.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.title3)
                            } else {
                                HStack(spacing: 4) {
                                    ForEach(set.itemIds, id: \.self) { id in
                                        shopIcon(shopItem(id), size: 26)
                                            .opacity(ownedIDs.contains(id) ? 1 : 0.3)
                                            .grayscale(ownedIDs.contains(id) ? 0 : 1)
                                    }
                                }
                            }
                        }
                    }
                    }
                } label: {
                    HStack {
                        Text("🎁 Decoration Sets")
                            .font(.headline)
                        Spacer()
                        Text("\(decoSets.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.gray.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                .padding()
                .background(.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                // House Upgrades: big-ticket XP goals that change the yard.
                // Collapsed by default — tap the header to open.
                DisclosureGroup(isExpanded: $upgradesOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                    Text("Big projects for your ghar — save up!")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(upgradeItems) { item in
                        HStack(spacing: 12) {
                            Text(item.icon).font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.nameNe).font(.headline)
                                Text("\(item.romanized) · \(item.nameEn)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if upgradeIDs.contains(item.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.title3)
                            } else if totalXP >= item.cost {
                                Button("Build · \(item.cost) XP") { buyUpgrade(item) }
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Text("🔒 \(item.cost) XP")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    }
                } label: {
                    HStack {
                        Text("🏗️ House Upgrades")
                            .font(.headline)
                        Spacer()
                        Text("\(upgradeItems.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.gray.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                .padding()
                .background(.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                Text("Tap the sun, clouds, roof, or a decoration to hear its Nepali name 🗣️")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical)
        }
        .onAppear {
            grantExclusives()
            checkSets()
        }
        // Naming sheet: pops right after adopting Suga.
        .sheet(isPresented: $namingBuddy) {
            NavigationStack {
                VStack(spacing: 16) {
                    Text("🦜").font(.system(size: 64))
                    Text("You adopted a parrot!")
                        .font(.title2).bold()
                    Text("What will you name him?")
                        .foregroundStyle(.secondary)
                    TextField("Name...", text: $buddyNameDraft)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 40)
                    Button("Meet \(buddyNameDraft.trimmingCharacters(in: .whitespaces).isEmpty ? "Suga" : buddyNameDraft.trimmingCharacters(in: .whitespaces))!") {
                        buddyName = buddyNameDraft.trimmingCharacters(in: .whitespaces)
                        namingBuddy = false
                        poke("buddy")
                        sayDecoration(id: "sugaGreeting", nepali: "नमस्ते! म सुगा हुँ!", romanized: "namaste! ma suga hun!")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .navigationTitle("New friend")
            }
        }
        // Teach sheet: pick any word from the pack, 10 XP, Suga learns it.
        .sheet(isPresented: $teachingBuddy) {
            NavigationStack {
                List(allWords) { w in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(w.devanagari).font(.headline)
                            Text("\(w.romanized) · \(w.english)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if taughtIDs.contains(w.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button("Teach · 10 XP") { teachBuddy(w) }
                                .buttonStyle(.bordered)
                                .disabled(totalXP < 10)
                        }
                    }
                }
                .navigationTitle("Teach \(buddyDisplayName)")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { teachingBuddy = false }
                    }
                }
            }
        }
    }

    /// Buy a decoration: must be affordable and not already owned.
    /// Deducts the XP, marks it owned, speaks its Nepali name as a little
    /// celebration — then checks whether a set just got completed.
    private func buy(_ item: ShopItem) {
        guard !ownedIDs.contains(item.id), totalXP >= item.cost else { return }
        totalXP -= item.cost
        var ids = ownedIDs
        ids.insert(item.id)
        ownedData = (try? JSONEncoder().encode(ids)) ?? Data()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        sayDecoration(item)
        checkSets()
        if item.id == "buddy" {
            buddyNameDraft = ""
            namingBuddy = true
        }
    }

    /// Tapping Suga: he says a random phrase — greetings plus every word
    /// the kid has taught him. Reuses recordings that already exist
    /// (the राम्रो! praise cheer, the नमस्ते! conversation line, each
    /// taught word's own clip) so nothing is recorded twice — anything
    /// still unrecorded falls back to the phone's voice.
    private func buddyTalk() {
        // (nepali, romanized, audioUrl, hasAudio)
        var options: [(String, String, String, Bool)] = []
        if let ramro = pack.praise?.first(where: { $0.id == "ramro" }) {
            options.append(("राम्रो छ!", "ramro chha!", ramro.audioUrl, ramro.hasAudio == true))
        }
        if let namaste = word("convo_namaste") {
            options.append(("नमस्ते!", "namaste!", namaste.audioUrl, namaste.hasAudio == true))
        }
        for id in taughtIDs {
            if let w = word(id) {
                options.append((w.devanagari, w.romanized, w.audioUrl, w.hasAudio == true))
            }
        }
        guard let pick = options.randomElement() else { return }
        if pick.3, let url = URL(string: GharAPI.baseURLString + pick.2) {
            decoPlayer = AVPlayer(url: url)
            decoPlayer?.play()
        } else {
            NepaliSpeaker.say(nepali: pick.0, romanized: pick.1)
        }
    }

    /// Feed Suga: 5 XP. A treat pops up at his beak and he hops and
    /// eats it, saying it's delicious. The recurring sink — there's
    /// always a reason to earn more XP.
    private func feedBuddy() {
        guard ownedIDs.contains("buddy"), totalXP >= 5 else { return }
        totalXP -= 5
        feedCount += 1
        let foods = ["🍎", "🍌", "🌽", "🍇"]
        let yum = foods.randomElement() ?? "🍎"
        withAnimation { feedEmoji = yum }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation { feedEmoji = nil }
        }
        poke("buddy")
        lastWin = buddyDisplayName + " loved the " + yum + "!"
        sayDecoration(id: "sugaMitho", nepali: "मिठो छ!", romanized: "mitho chha!")
    }

    /// Teach Suga a word: 10 XP. He learns it, says it on the spot, and
    /// it joins his tap-to-talk rotation from then on.
    private func teachBuddy(_ w: Word) {
        guard !taughtIDs.contains(w.id), totalXP >= 10 else { return }
        totalXP -= 10
        var ids = taughtIDs
        ids.insert(w.id)
        taughtData = (try? JSONEncoder().encode(ids)) ?? Data()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        lastWin = buddyDisplayName + " learned " + w.romanized + "!"
        // The word's own recording when it exists — no re-recording.
        if w.hasAudio == true,
           let url = URL(string: GharAPI.baseURLString + w.audioUrl) {
            decoPlayer = AVPlayer(url: url)
            decoPlayer?.play()
        } else {
            NepaliSpeaker.say(nepali: w.devanagari, romanized: w.romanized)
        }
    }

    /// Build a big-ticket upgrade: deduct XP, mark owned, celebrate.
    /// The yard redraws itself on the next render — no restart needed.
    private func buyUpgrade(_ item: ShopItem) {
        guard !upgradeIDs.contains(item.id), totalXP >= item.cost else { return }
        totalXP -= item.cost
        var ids = upgradeIDs
        ids.insert(item.id)
        upgradesData = (try? JSONEncoder().encode(ids)) ?? Data()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        lastWin = item.nameEn + " built!"
        sayDecoration(item)
    }

    /// Put a decoration away into storage: off the house, no XP refund.
    /// Putting it back is free, anytime.
    private func storeItem(_ item: ShopItem) {
        guard ownedIDs.contains(item.id) else { return }
        var ids = ownedIDs
        ids.remove(item.id)
        ownedData = (try? JSONEncoder().encode(ids)) ?? Data()
        var stored = storedIDs
        stored.insert(item.id)
        storedData = (try? JSONEncoder().encode(stored)) ?? Data()
    }

    /// Put a stored decoration back on the house — free.
    private func placeItem(_ item: ShopItem) {
        guard storedIDs.contains(item.id) else { return }
        var stored = storedIDs
        stored.remove(item.id)
        storedData = (try? JSONEncoder().encode(stored)) ?? Data()
        var ids = ownedIDs
        ids.insert(item.id)
        ownedData = (try? JSONEncoder().encode(ids)) ?? Data()
        poke(item.id)
    }

    /// Prove-it prizes: grant every exclusive whose verified-mission
    /// requirement is met. Runs on appear, so prizes land the moment the
    /// grown-up confirms — even if the kid is already on this tab.
    private func grantExclusives() {
        var ids = ownedIDs
        var changed = false
        for item in exclusiveItems {
            let need = exclusiveNeed[item.id] ?? Int.max
            if verifiedIDs.count >= need && !ids.contains(item.id) {
                ids.insert(item.id)
                changed = true
                lastWin = "\(item.nameEn) earned! 🏆"
            }
        }
        if changed {
            ownedData = (try? JSONEncoder().encode(ids)) ?? Data()
            WinFanfare.play()
        }
    }

    /// Set bonuses: own every item in a set, pocket the bonus — once ever.
    /// Also runs on appear, so sets completed before this update pay out
    /// as a welcome-back surprise instead of being missed.
    private func checkSets() {
        var awarded = awardedSets
        var changed = false
        for set in decoSets where !awarded.contains(set.id) {
            if set.itemIds.allSatisfy(ownedIDs.contains) {
                awarded.insert(set.id)
                totalXP += set.bonus
                changed = true
                lastWin = "\(set.nameEn) complete! +\(set.bonus) XP 🎁"
            }
        }
        if changed {
            awardedSetsData = (try? JSONEncoder().encode(awarded)) ?? Data()
            WinFanfare.play()
        }
    }

    /// One paint row: a label plus tappable color swatches. The selected
    /// swatch gets a ring; the choice is stored in @AppStorage.
    private func paintRow(label: String,
                          choices: [(name: String, color: Color)],
                          selected: Binding<Int>) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .frame(width: 44, alignment: .leading)
            ForEach(0..<choices.count, id: \.self) { i in
                Circle()
                    .fill(choices[i].color)
                    .frame(width: 34, height: 34)
                    .overlay {
                        if selected.wrappedValue == i {
                            Circle().stroke(.primary, lineWidth: 2.5)
                        }
                    }
                    .onTapGesture {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selected.wrappedValue = i
                    }
                    .accessibilityLabel(choices[i].name)
            }
            Spacer()
        }
    }

    /// The "poke" pattern: pop a decoration with a spring, then settle it
    /// back after a beat. One id state serves all 18 decorations — the view
    /// checks `poppedID == "diyo"` instead of its own Bool.
    private func poke(_ id: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.35)) { poppedID = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                if poppedID == id { poppedID = nil }
            }
        }
    }

    /// One emoji decoration in the scene: pops + speaks its Nepali name on
    /// tap. Callers wrap it in `if ownedIDs.contains(...)` and position it.
    /// A yard decoration: its watercolor illustration once landed on the
    /// backend, emoji while it loads. Callers wrap it in
    /// `if ownedIDs.contains(...)` and position it.
    private func deco(_ id: String, size: CGFloat) -> some View {
        AsyncImage(url: URL(string: GharAPI.baseURLString + "/images/nepal-v1/deco_\(id).jpg")) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            default:
                Text(shopItem(id).icon)
                    .font(.system(size: size))
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(poppedID == id ? 1.3 : 1.0)
        .onTapGesture {
            sayDecoration(shopItem(id))
            poke(id)
        }
    }

    /// Shop row icon: the watercolor illustration (Suga uses his parrot
    /// portrait), falling back to emoji while it loads.
    private func shopIcon(_ item: ShopItem, size: CGFloat = 44) -> some View {
        let path = item.id == "buddy"
            ? "/images/nepal-v1/suga_parrot.jpg"
            : "/images/nepal-v1/deco_\(item.id).jpg"
        return AsyncImage(url: URL(string: GharAPI.baseURLString + path)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            default:
                Text(item.icon)
                    .font(.title2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// The Himalayas, drawn with snowy peaks — revealed when you buy them.
    /// Tapping says the name out loud like any other decoration.
    private var mountainRange: some View {
        Group {
            if ownedIDs.contains("himal") {
                // The watercolor range — snow glistens on the peaks.
                ZStack {
                    AsyncImage(url: URL(string: GharAPI.baseURLString + "/images/nepal-v1/deco_himalayas.jpg")) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        default:
                            Triangle()
                                .fill(.indigo.opacity(0.3))
                                .frame(width: 80, height: 55)
                        }
                    }
                    .frame(width: 150, height: 75)
                    ForEach(0..<4, id: \.self) { i in
                        Circle()
                            .fill(.white)
                            .frame(width: 4, height: 4)
                            .offset(x: [-35, -12, 12, 32][i], y: [-25, -30, -27, -20][i])
                            .opacity(snowTwinkle ? 0.95 : 0.25)
                            .animation(
                                .easeInOut(duration: 1.2)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.4),
                                value: snowTwinkle
                            )
                    }
                }
                .offset(placedOffset("himal", x: 80, y: -138))
                .arrange("himal", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
                .scaleEffect(poppedID == "himal" ? 1.05 : 1.0)
                .onAppear { snowTwinkle = true }
                .onTapGesture {
                    sayDecoration(shopItem("himal"))
                    poke("himal")
                }
            }
        }
    }

    /// Chimney + smoke: the chimney sits on the roof slope (the roof draws
    /// over its base), and a puff of smoke rises and fades on a loop.
    private var chimneySmoke: some View {
        Group {
            Rectangle()
                .fill(Color(red: 0.55, green: 0.35, blue: 0.25))
                .frame(width: 24, height: 60)
                .offset(x: 75, y: -60)
            Circle()
                .fill(.gray.opacity(0.35))
                .frame(width: 16, height: 16)
                .offset(x: 75, y: smokeRise ? -130 : -95)
                .opacity(smokeRise ? 0 : 0.6)
                .onAppear {
                    withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) {
                        smokeRise = true
                    }
                }
        }
    }

    /// The yard and sky: bought decorations placed around the house.
    private var sceneDeco: some View {
        Group {
            if ownedIDs.contains("changa") {
                deco("changa", size: 34)
                    .offset(placedOffset("changa", x: 105, y: -135))
                    .arrange("changa", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("mandir") {
                deco("mandir", size: 40)
                    .offset(placedOffset("mandir", x: -128, y: 95))
                    .arrange("mandir", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("tulsi") {
                deco("tulsi", size: 32)
                    .offset(placedOffset("tulsi", x: -125, y: 160))
                    .arrange("tulsi", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("jamara") {
                deco("jamara", size: 28)
                    .offset(placedOffset("jamara", x: -88, y: 172))
                    .arrange("jamara", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("sayapatri") {
                deco("sayapatri", size: 28)
                    .offset(placedOffset("sayapatri", x: 88, y: 172))
                    .arrange("sayapatri", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("kukur") {
                deco("kukur", size: 34)
                    .offset(placedOffset("kukur", x: 125, y: 158))
                    .arrange("kukur", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("rangoli") {
                rangoli
                    .offset(placedOffset("rangoli", x: 0, y: 172))
                    .arrange("rangoli", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
                    .scaleEffect(poppedID == "rangoli" ? 1.2 : 1.0)
                    .onTapGesture {
                        sayDecoration(shopItem("rangoli"))
                        poke("rangoli")
                    }
            }
            // Flower garden: the watercolor bed, swaying gently.
            // Tap to hear "phulbari".
            if upgradeIDs.contains("garden") {
                AsyncImage(url: URL(string: GharAPI.baseURLString + "/images/nepal-v1/deco_garden.jpg")) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        Text("🌸").font(.system(size: 40))
                    }
                }
                .frame(width: 76, height: 76)
                .rotationEffect(.degrees(flowerSway ? 2 : -2))
                .onAppear {
                    withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                        flowerSway = true
                    }
                }
                .offset(placedOffset("garden", x: -48, y: 162))
                .arrange("garden", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
                .scaleEffect(poppedID == "garden" ? 1.2 : 1.0)
                .onTapGesture {
                    sayDecoration(id: "garden", nepali: "फूलबारी", romanized: "phulbari")
                    poke("garden")
                }
            }
            // Chautari: the classic Nepali rest-stop tree on its stone
            // platform. Tap to hear "chautari".
            if upgradeIDs.contains("chautari") {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(red: 0.55, green: 0.55, blue: 0.58))
                        .frame(width: 76, height: 20)
                        .offset(y: 34)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(red: 0.4, green: 0.28, blue: 0.15))
                        .frame(width: 14, height: 44)
                        .offset(y: 4)
                    Circle().fill(.green.opacity(0.9)).frame(width: 64, height: 64).offset(y: -30)
                    Circle().fill(Color(red: 0.2, green: 0.55, blue: 0.25)).frame(width: 44, height: 44).offset(x: -20, y: -22)
                    Circle().fill(Color(red: 0.25, green: 0.6, blue: 0.3)).frame(width: 40, height: 40).offset(x: 20, y: -24)
                }
                .offset(placedOffset("chautari", x: 52, y: 122))
                .arrange("chautari", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
                .scaleEffect(poppedID == "chautari" ? 1.15 : 1.0)
                .onTapGesture {
                    sayDecoration(id: "chautari", nepali: "चौतारी", romanized: "chautari")
                    poke("chautari")
                }
            }
            // A butterfly loops over the garden forever — the yard breathes.
            if upgradeIDs.contains("garden") {
                Text("🦋")
                    .font(.system(size: 22))
                    .offset(x: butterflyFly ? 40 : -110, y: butterflyFly ? 128 : 150)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) {
                            butterflyFly = true
                        }
                    }
            }
        }
    }

    /// On the house body: garland on the door, bell hanging by the roof,
    /// and the Prove-it prizes (golden diyo, star badge, crown).
    private var bodyDeco: some View {
        Group {
            if ownedIDs.contains("mala") {
                deco("mala", size: 26)
                    .offset(placedOffset("mala", x: 0, y: -14))
                    .arrange("mala", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("ghanta") {
                VStack(spacing: 0) {
                    Rectangle().fill(.gray).frame(width: 4, height: 22)
                    deco("ghanta", size: 30)
                }
                .offset(placedOffset("ghanta", x: 100, y: -58))
                .arrange("ghanta", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("goldenDiyo") {
                goldenDiyo
                    .offset(placedOffset("goldenDiyo", x: -100, y: 52))
                    .arrange("goldenDiyo", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
                    .scaleEffect(poppedID == "goldenDiyo" ? 1.3 : 1.0)
                    .onTapGesture {
                        sayDecoration(shopItem("goldenDiyo"))
                        poke("goldenDiyo")
                    }
            }
            if ownedIDs.contains("starBadge") {
                deco("starBadge", size: 28)
                    .offset(placedOffset("starBadge", x: 0, y: -60))
                    .arrange("starBadge", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("mukut") {
                deco("mukut", size: 24)
                    .offset(placedOffset("mukut", x: 80, y: 18))
                    .arrange("mukut", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
        }
    }

    /// A window: dark wood frame, four panes with a glass reflection
    /// streak, and a sill — or a grey silhouette when not yet bought.
    private var window: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.35, green: 0.22, blue: 0.12))
                .frame(width: 52, height: 52)
            RoundedRectangle(cornerRadius: 3)
                .fill(ownedIDs.contains("windows")
                      ? Color(red: 0.5, green: 0.75, blue: 0.95)
                      : .gray.opacity(0.25))
                .frame(width: 44, height: 44)
            if ownedIDs.contains("windows") {
                Rectangle().fill(Color(red: 0.35, green: 0.22, blue: 0.12)).frame(width: 44, height: 5)
                Rectangle().fill(Color(red: 0.35, green: 0.22, blue: 0.12)).frame(width: 5, height: 44)
                Rectangle()
                    .fill(.white.opacity(0.35))
                    .frame(width: 8, height: 44)
                    .rotationEffect(.degrees(20))
                    .offset(x: -9)
            }
            RoundedRectangle(cornerRadius: 2)
                .fill(.white.opacity(0.9))
                .frame(width: 58, height: 8)
                .offset(y: 30)
        }
    }

    /// The diyo lamp: the watercolor illustration with a warm glow behind
    /// it. It "breathes" gently forever — alive, not a sticker. Grey
    /// placeholder until bought from the shop.
    private var diyo: some View {
        ZStack {
            if ownedIDs.contains("diyo") {
                Circle()
                    .fill(.orange.opacity(0.3))
                    .frame(width: 64, height: 64)
                    .blur(radius: 12)
                AsyncImage(url: URL(string: GharAPI.baseURLString + "/images/nepal-v1/deco_diyo.jpg")) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        VStack(spacing: 1) {
                            Circle().fill(.orange).frame(width: 14, height: 14)
                            Ellipse().fill(.brown).frame(width: 30, height: 12)
                        }
                    }
                }
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .scaleEffect(flameFlicker ? 1.06 : 0.97)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                        flameFlicker = true
                    }
                }
            } else {
                VStack(spacing: 1) {
                    Circle().fill(.gray.opacity(0.25)).frame(width: 14, height: 14)
                    Ellipse().fill(.gray.opacity(0.25)).frame(width: 30, height: 12)
                }
            }
        }
    }

    /// The golden diyo prize: the watercolor illustration with a golden
    /// glow, breathing gently like the clay diyo.
    private var goldenDiyo: some View {
        ZStack {
            Circle()
                .fill(.yellow.opacity(0.35))
                .frame(width: 56, height: 56)
                .blur(radius: 10)
            AsyncImage(url: URL(string: GharAPI.baseURLString + "/images/nepal-v1/deco_goldenDiyo.jpg")) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                default:
                    Ellipse()
                        .fill(Color(red: 0.85, green: 0.65, blue: 0.13))
                        .frame(width: 32, height: 13)
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .scaleEffect(flameFlicker ? 1.06 : 0.97)
        }
    }

    /// A rangoli: concentric colored circles at the doorstep, drawn not bought
    /// as emoji — there's no good rangoli emoji, and circles are prettier.
    private var rangoli: some View {
        ZStack {
            Circle().fill(.red).frame(width: 46, height: 46)
            Circle().fill(.orange).frame(width: 34, height: 34)
            Circle().fill(.yellow).frame(width: 22, height: 22)
            Circle().fill(.pink).frame(width: 10, height: 10)
        }
    }

    /// Suga by the door: a realistic watercolor parrot portrait from the
    /// backend, with the hand-drawn bird as fallback while it loads.
    /// He bobs gently forever — alive, not a sticker — and hops when
    /// tapped or fed. Grey circle until he's adopted from the shop.
    private var buddy: some View {
        let owned = ownedIDs.contains("buddy")
        return ZStack {
            if owned {
                AsyncImage(url: URL(string: GharAPI.baseURLString + "/images/nepal-v1/suga_parrot.jpg")) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        buddyDrawn
                    }
                }
                .frame(width: 84, height: 84)
                .clipShape(Circle())
                .overlay(Circle().stroke(.green.opacity(0.35), lineWidth: 3))
                .shadow(radius: 3)
                .offset(y: buddyBob ? -4 : 4)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        buddyBob = true
                    }
                }
                Text(buddyDisplayName)
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.white.opacity(0.9))
                    .clipShape(Capsule())
                    .offset(y: 54)
            } else {
                Circle()
                    .fill(.gray.opacity(0.25))
                    .frame(width: 56, height: 56)
            }
        }
    }

    /// Hand-drawn fallback parrot — shows inside the portrait circle if
    /// the watercolor image hasn't loaded yet.
    private var buddyDrawn: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(.blue)
                .frame(width: 13, height: 36)
                .offset(x: -16, y: 2)
                .rotationEffect(.degrees(16))
            Ellipse()
                .fill(.green)
                .frame(width: 36, height: 46)
                .offset(y: -4)
            Ellipse()
                .fill(Color(red: 0.12, green: 0.42, blue: 0.18))
                .frame(width: 16, height: 30)
                .offset(x: -7, y: 0)
            Circle()
                .fill(.green)
                .frame(width: 30, height: 30)
                .offset(x: 4, y: -32)
            Circle().fill(.white).frame(width: 10, height: 10).offset(x: 9, y: -34)
            Circle().fill(.black).frame(width: 5, height: 5).offset(x: 10, y: -34)
            Triangle()
                .fill(.orange)
                .frame(width: 13, height: 11)
                .rotationEffect(.degrees(90))
                .offset(x: 21, y: -30)
        }
        .scaleEffect(1.1)
    }
}

/// Drag-to-move for arrange mode in My Ghar. When enabled, dragging a
/// decoration moves it and the drop point is saved; plain taps still fall
/// through to the view's own onTapGesture (speak + poke).
private struct ArrangeModifier: ViewModifier {
    let id: String
    let enabled: Bool
    @Binding var dragDeltas: [String: CGSize]
    let commit: (String, CGSize) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.gesture(
                DragGesture()
                    .onChanged { dragDeltas[id] = $0.translation }
                    .onEnded { commit(id, $0.translation) }
            )
        } else {
            content
        }
    }
}

extension View {
    /// Attach arrange-mode dragging to a My Ghar decoration.
    func arrange(_ id: String, enabled: Bool, dragDeltas: Binding<[String: CGSize]>, commit: @escaping (String, CGSize) -> Void) -> some View {
        modifier(ArrangeModifier(id: id, enabled: enabled, dragDeltas: dragDeltas, commit: commit))
    }
}

/// A cloud that drifts side to side forever, all by itself.
/// `repeatForever(autoreverses: true)` on a linear animation = endless
/// gentle motion with no timer and nothing to get stuck.
struct DriftingCloud: View {
    let startX: CGFloat
    let y: CGFloat
    /// MyGharView passes its recording-first speaker: the cloud says
    /// "बादल" in Som's voice once he's recorded it.
    let speak: () -> Void
    @State private var drifted = false
    @State private var popped = false

    var body: some View {
        HStack(spacing: -14) {
            Circle().fill(.white).frame(width: 42, height: 42)
            Circle().fill(.white).frame(width: 58, height: 58)
            Circle().fill(.white).frame(width: 42, height: 42)
        }
        .shadow(color: .black.opacity(0.08), radius: 4)
        .offset(x: startX + (drifted ? 36 : -36), y: y)
        .scaleEffect(popped ? 1.15 : 1.0)
        .onTapGesture {
            speak()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.35)) { popped = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { popped = false }
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 8).repeatForever(autoreverses: true)) {
                drifted = true
            }
        }
    }
}

/// One thing the Ghar Shop sells: its English + Nepali names,
/// its icon, and its price in XP.
struct ShopItem: Identifiable {
    let id: String
    let nameEn: String
    let nameNe: String
    let romanized: String
    let icon: String
    let cost: Int
}

/// A decoration set: own every item, pocket the bonus — paid once, ever.
struct DecoSet: Identifiable {
    let id: String
    let nameEn: String
    let itemIds: [String]
    let bonus: Int
}

/// Says a decoration's Nepali name out loud — no recordings needed.
/// If the device has a real Nepali (ne-NP) voice installed, it speaks the
/// Devanagari word properly. Otherwise (like on the simulator, which has no
/// Nepali voice) it says the romanized spelling with the English voice —
/// an accent, but always audible. An English voice handed Devanagari text
/// just goes silent, so the romanized fallback is what keeps it working.
/// (On a real iPhone: Settings → Accessibility → Spoken Content → Voices
///  to download the Nepali voice for perfect pronunciation.)
///
/// Teaching notes:
/// - Same AVSpeechSynthesizer engine as the win cheers, but its OWN
///   synthesizer — so tapping a decoration never cuts off a celebration
///   mid-cheer, and vice versa.
/// - `stopSpeaking(at: .immediate)` before each word: rapid tapping
///   re-speaks instead of queueing up a backlog of words.
/// - Slow rate (0.45): these are vocabulary words for learners, not cheers.
enum NepaliSpeaker {
    private static let synth = AVSpeechSynthesizer()

    static func say(_ item: ShopItem) {
        say(nepali: item.nameNe, romanized: item.romanized)
    }

    /// Scene words (sun, roof, clouds) that aren't shop items.
    static func say(nepali: String, romanized: String) {
        synth.stopSpeaking(at: .immediate)
        let utterance: AVSpeechUtterance
        if let nepaliVoice = AVSpeechSynthesisVoice(language: "ne-NP") {
            utterance = AVSpeechUtterance(string: nepali)
            utterance.voice = nepaliVoice
        } else if !romanized.isEmpty {
            utterance = AVSpeechUtterance(string: romanized)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        } else {
            // No Nepali voice on this device and nothing romanized —
            // speak the Devanagari with the default voice rather than
            // staying silent. Mispronounced beats mute.
            utterance = AVSpeechUtterance(string: nepali)
        }
        utterance.rate = 0.45
        synth.speak(utterance)
    }
}

/// Tapping a deck shows its words: Devanagari + romanized + English,
/// each with a speaker button that streams the recorded audio.
///
/// Teaching notes:
/// - `AVPlayer` is Apple's audio/video player. `AVPlayer(url:)` streams
///   straight from our backend — the file never has to live inside the app.
/// - `@State private var player` keeps the player alive while the sound
///   plays. Without this, SwiftUI would throw it away mid-word and you'd
///   hear nothing (a classic beginner bug — now you know it).
struct DeckView: View {
    let deck: Deck
    @State private var player: AVPlayer?
    /// Which section headers are expanded. Starts empty = all collapsed.
    /// (Som asked: Vowels / Consonants should be tappable to open,
    /// not both listed at once.)
    @State private var openSections: Set<String> = []

    /// Words grouped under their `section` header, in file order.
    /// (`section` is how Vowels and Consonants live inside one Alphabets deck.)
    /// Words with no section share one headerless group.
    var grouped: [(header: String?, words: [Word])] {
        var groups: [(header: String?, words: [Word])] = []
        for word in deck.words {
            // Guard against the empty list: on the very first word of a deck
            // with no sections (Food, Family), `groups.last?.header` is nil
            // and `word.section` is nil, so `nil == nil` looked "equal" and
            // the code below tried to append to a group that doesn't exist yet.
            if !groups.isEmpty, groups.last?.header == word.section {
                groups[groups.count - 1].words.append(word)
            } else {
                groups.append((word.section, [word]))
            }
        }
        return groups
    }

    var body: some View {
        List {
            if deck.id == "alphabet" {
                // Learn to WRITE the letters, not just read them.
                Section {
                    NavigationLink {
                        WritingPracticeView(deck: deck)
                    } label: {
                        HStack(spacing: 14) {
                            Text("✍️").font(.largeTitle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Practice writing").font(.headline)
                                Text("Watch, trace, and write each letter")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            ForEach(grouped.indices, id: \.self) { i in
                if let header = grouped[i].header {
                    // Tappable section (Vowels / Consonants): collapsed until opened.
                    Section {
                        DisclosureGroup(isExpanded: sectionBinding(for: header)) {
                            ForEach(grouped[i].words) { word in
                                WordRow(word: word, onPlay: play(word:))
                            }
                        } label: {
                            Text(header).font(.headline)
                        }
                    }
                } else {
                    // Decks with no sections (Food, Family): plain list, as before.
                    Section {
                        ForEach(grouped[i].words) { word in
                            WordRow(word: word, onPlay: play(word:))
                        }
                    }
                }
            }
        }
        .navigationTitle(deck.title)
    }

    /// Two-way binding between a DisclosureGroup and the openSections set.
    private func sectionBinding(for header: String) -> Binding<Bool> {
        Binding(
            get: { openSections.contains(header) },
            set: { isOpen in
                if isOpen { openSections.insert(header) }
                else { openSections.remove(header) }
            }
        )
    }

    /// Builds the full audio URL and plays it:
    ///   server address + path from the JSON
    ///   http://localhost:8000 + /audio/nepal-v1/food_momo_np.m4a
    private func play(word: Word) {
        guard let url = URL(string: GharAPI.baseURLString + word.audioUrl) else { return }
        player = AVPlayer(url: url)
        player?.play()
    }
}

/// One row in a deck: optional animal photo, the word, and its speaker button.
struct WordRow: View {
    let word: Word
    let onPlay: (Word) -> Void

    var body: some View {
        HStack {
            // Real photo for the animals deck, served by the backend:
            // server address + image path from the JSON
            //   http://localhost:8000 + /images/nepal-v1/anim_kukur.jpg
            if let imagePath = word.image, imagePath.hasPrefix("/") {
                AsyncImage(url: URL(string: GharAPI.baseURLString + imagePath)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure, .empty:
                        Color.clear
                    @unknown default:
                        Color.clear
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(word.devanagari)
                    .font(.largeTitle)
                Text("\(word.romanized) — \(word.english)")
                    .foregroundStyle(.secondary)
                if let example = word.exampleSentenceNp {
                    Text("“\(example)”")
                        .font(.caption)
                        .italic()
                }
            }
            Spacer()
            Button(action: { onPlay(word) }) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.title2)
            }
            .buttonStyle(.bordered)
            // No recording yet → dimmed and disabled, instead of a
            // button that silently does nothing when tapped.
            .disabled(!(word.hasAudio ?? true))
            .opacity((word.hasAudio ?? true) ? 1 : 0.35)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Colors + counting (workbook pages in app form)

// Hex strings from the pack ("#E53935") become real SwiftUI colors.
extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/// Colors: a grid of color swatches, like the workbook's रङहरूको ज्ञान page.
/// Tap a swatch to hear its Nepali name — Som's recording when it exists,
/// the phone's voice until then.
struct ColorsView: View {
    let deck: Deck
    @State private var player: AVPlayer?

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(deck.words) { word in
                    Button(action: { speak(word) }) {
                        VStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(Color(hex: word.colorHex ?? "#CCCCCC"))
                                .frame(height: 92)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                )
                            Text(word.devanagari)
                                .font(.title2).bold()
                            Text(word.english)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(deck.title)
    }

    private func speak(_ word: Word) {
        if word.hasAudio == true,
           let url = URL(string: GharAPI.baseURLString + word.audioUrl) {
            player = AVPlayer(url: url)
            player?.play()
        } else {
            NepaliSpeaker.say(nepali: word.devanagari, romanized: word.romanized)
        }
    }
}

/// Numbers: the word list with a "Counting practice" card on top —
/// bunches of things to count, like the workbook's गन्ती गर्ने अभ्यास page.
struct NumbersView: View {
    let deck: Deck
    @State private var player: AVPlayer?

    var body: some View {
        List {
            Section {
                NavigationLink(destination: CountingView(deck: deck)) {
                    HStack(spacing: 12) {
                        Text("🔢").font(.largeTitle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Counting practice").font(.headline)
                            Text("Tap each one and count along!")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Section {
                ForEach(deck.words) { word in
                    WordRow(word: word, onPlay: play(word:))
                }
            }
        }
        .navigationTitle(deck.title)
    }

    private func play(word: Word) {
        guard let url = URL(string: GharAPI.baseURLString + word.audioUrl) else { return }
        player = AVPlayer(url: url)
        player?.play()
    }
}

/// Counting practice: a bunch of things (🍎🍎🍎…) — the kid taps each one
/// and counts along. Every tap speaks the next number (एक, दुई…);
/// finishing the bunch earns a Nepali cheer.
struct CountingView: View {
    let deck: Deck   // numbers deck: words[0] = 1, words[1] = 2, …
    @State private var player: AVPlayer?
    @State private var target = Int.random(in: 2...10)
    @State private var counted: Set<Int> = []
    @State private var emoji = "🍎"
    @State private var showConfetti = false

    private let bunches = ["🍎", "🌼", "🐦", "⭐", "🐟", "🎈", "🦋", "🍊", "🐘", "🌙"]
    private let columns = [GridItem(.adaptive(minimum: 68), spacing: 10)]

    private var done: Bool { counted.count == target }

    var body: some View {
        VStack(spacing: 18) {
            Text("Tap each one and count!")
                .font(.title2).bold()
            Text("\(counted.count) / \(target)")
                .font(.headline)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(0..<target, id: \.self) { i in
                    Button(action: { tap(i) }) {
                        ZStack {
                            Text(emoji)
                                .font(.system(size: 46))
                                .opacity(counted.contains(i) ? 0.25 : 1)
                            if counted.contains(i) {
                                Text("✓")
                                    .font(.title).bold()
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(counted.contains(i))
                }
            }
            .padding()

            if done {
                Text("🎉").font(.system(size: 56))
                Button("New bunch") { reset() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Counting")
        .overlay {
            if showConfetti {
                ConfettiBurst().allowsHitTesting(false)
            }
        }
    }

    private func tap(_ i: Int) {
        counted.insert(i)
        let n = counted.count
        if n <= deck.words.count { speakNumber(deck.words[n - 1]) }
        if n == target {
            // The last number gets its moment first — the cheer waits a beat
            // so the two don't talk over each other.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                WinFanfare.play()
            }
            showConfetti = false
            DispatchQueue.main.async { showConfetti = true }
        }
    }

    private func reset() {
        target = Int.random(in: 2...10)
        counted = []
        emoji = bunches.randomElement() ?? "🍎"
        showConfetti = false
    }

    private func speakNumber(_ word: Word) {
        if word.hasAudio == true,
           let url = URL(string: GharAPI.baseURLString + word.audioUrl) {
            player = AVPlayer(url: url)
            player?.play()
        } else {
            NepaliSpeaker.say(nepali: word.devanagari, romanized: word.romanized)
        }
    }
}

// Character portraits live in Assets.xcassets (see the Portraits enum).

// MARK: - Writing practice (alphabet deck)
//
// "Practice writing ✍️" inside the Alphabets deck. For each letter:
//   1. GUIDE — "Watch 👀" plays the letter drawing itself, pen tip and all;
//      a faint template sits underneath to trace.
//   2. VERIFY — the kid traces with a finger (Trace mode) or writes freehand
//      (Try-it mode). Strokes must cover the letter's shape to count.
//   3. CONGRATULATE — Som's recorded praise, a star burst, +5 XP the first
//      time per letter, and a star on the letter in the picker.
//
// Verification in one paragraph: the letter is rasterized once to a 36×36
// grid; every touch marks the cells under the fingertip (3×3 neighborhood).
// Covering ≥60% of the letter's cells passes. Deliberately generous — the
// goal is time spent shaping the letter, not penmanship judging.

/// English → Devanagari transliteration for names. Rule-based v1: handles
/// common Nepali name spellings; the parent confirms the result before
/// it becomes the practice word, so imperfections are caught by human eyes.
///
/// How it works: scan left-to-right, longest match first. Consonants carry
/// the inherent 'a' — a following 'a' is absorbed, other vowels become
/// matras, and a consonant before another consonant gets a halant.
fileprivate enum DevanagariTransliterator {
    /// (english, devanagari consonant) — longest first for greedy matching.
    private static let consonants: [(String, String)] = [
        ("ksh", "क्ष"), ("tra", "त्र"), ("gya", "ज्ञ"),
        ("kh", "ख"), ("gh", "घ"), ("chh", "छ"), ("jh", "झ"),
        ("th", "थ"), ("dh", "ध"), ("ph", "फ"), ("bh", "भ"),
        ("sh", "श"), ("k", "क"), ("g", "ग"), ("ng", "ङ"),
        ("ch", "च"), ("j", "ज"), ("ny", "ञ"),
        ("T", "ट"), ("Th", "ठ"), ("D", "ड"), ("Dh", "ढ"), ("N", "ण"),
        ("t", "त"), ("d", "द"), ("n", "न"),
        ("p", "प"), ("b", "ब"), ("m", "म"),
        ("y", "य"), ("r", "र"), ("l", "ल"), ("v", "व"), ("w", "व"),
        ("s", "स"), ("h", "ह"),
    ]

    /// Independent vowels (word-start or after a vowel).
    private static let vowels: [(String, String)] = [
        ("ai", "ऐ"), ("au", "औ"),
        ("aa", "आ"), ("ee", "ई"), ("ii", "ई"),
        ("oo", "ऊ"), ("uu", "ऊ"),
        ("a", "अ"), ("i", "इ"), ("u", "उ"),
        ("e", "ए"), ("o", "ओ"),
    ]

    /// Matras (dependent vowels, after a consonant). "a" is inherent — no sign.
    private static let matras: [(String, String)] = [
        ("ai", "ै"), ("au", "ौ"),
        ("aa", "ा"), ("ee", "ी"), ("ii", "ी"),
        ("oo", "ू"), ("uu", "ू"),
        ("i", "ि"), ("u", "ु"),
        ("e", "े"), ("o", "ो"),
    ]

    static func transliterate(_ english: String) -> String {
        let s = english.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "" }
        let lower = s.lowercased()
        var result = ""
        var i = lower.startIndex
        var prevWasConsonant = false

        while i < lower.endIndex {
            // Try consonants (longest first).
            var matched = false
            for (en, de) in consonants {
                if lower[i...].hasPrefix(en) {
                    // Check if next char starts another consonant (needs halant).
                    let after = lower.index(i, offsetBy: en.count, limitedBy: lower.endIndex) ?? lower.endIndex
                    var needsHalant = false
                    if after < lower.endIndex {
                        let nextStr = String(lower[after...])
                        // Next is a consonant (not a vowel) → halant.
                        let nextIsVowel = vowels.contains { nextStr.hasPrefix($0.0) }
                        let nextIsConsonant = consonants.contains { nextStr.hasPrefix($0.0) }
                        if nextIsConsonant && !nextIsVowel {
                            needsHalant = true
                        }
                    }
                    result += de
                    if needsHalant { result += "्" }
                    i = after
                    prevWasConsonant = !needsHalant
                    matched = true
                    break
                }
            }
            if matched { continue }

            // Try vowels/matras.
            let table = prevWasConsonant ? matras : vowels
            var vowelMatched = false
            for (en, de) in table {
                if lower[i...].hasPrefix(en) {
                    // "a" after consonant is inherent — skip it.
                    if !(prevWasConsonant && en == "a") {
                        result += de
                    }
                    i = lower.index(i, offsetBy: en.count, limitedBy: lower.endIndex) ?? lower.endIndex
                    prevWasConsonant = false
                    vowelMatched = true
                    break
                }
            }
            if vowelMatched { continue }

            // Unknown character — skip it.
            i = lower.index(after: i)
            prevWasConsonant = false
        }
        return result
    }
}

/// Shared constants for the writing canvas.
fileprivate enum WritingMetrics {
    /// Working size in points. Template image, outline path and coverage grid
    /// are all derived from the same layout, so they can never disagree.
    static let canvas: CGFloat = 300
    static let grid = 36
    static let passThreshold = 0.6
    static let tryItThreshold = 0.8
    static let xpReward = 5
}

/// Everything the canvas needs for one letter, baked once per letter.
///
/// Single source of truth: the outline path. The visible template, the
/// coverage grid, and the Watch animation are ALL derived from it, so they
/// can never disagree. (No rasterized images — CoreGraphics text drawing
/// proved unreliable in this context.)
fileprivate struct LetterGuide {
    let outline: CGPath     // the letter as a path, 300×300 UIKit coords
    let targets: Set<Int>   // grid cells the letter fills (row * 36 + col)
    let sampler: PathSampler
    let bbox: CGRect        // outline's bounding box, 300-box coords

    static func make(for text: String) -> LetterGuide {
        let S = WritingMetrics.canvas
        let attr = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 220), .foregroundColor: UIColor.black
        ])
        let line = CTLineCreateWithAttributedString(attr)

        // One combined outline in font space (y-up, baseline origin).
        // The run's own font is the only safe source for paths: glyph IDs
        // are font-specific, and CoreText may have substituted a fallback.
        let combined = CGMutablePath()
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let rf = attrs.object(forKey: kCTFontAttributeName) as! CTFont
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRangeMake(0, n), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, n), &positions)
            for i in 0..<n {
                if let gp = CTFontCreatePathForGlyph(rf, glyphs[i], nil) {
                    let t = CGAffineTransform(translationX: positions[i].x,
                                             y: positions[i].y)
                    combined.addPath(gp, transform: t)
                }
            }
        }
        var box = combined.boundingBox
        if box.isNull || box.width < 1 || box.height < 1 {
            box = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        // Font space (y-up) → 300×300 UIKit (y-down), centered, small margin.
        // Manual math (not CGAffineTransform): x' = (x-minX)*s + tx,
        // y' = (maxY-y)*s + ty. Direct arithmetic cannot silently fail.
        let s = min(S / box.width, S / box.height) * 0.9
        let tx = (S - box.width * s) / 2, ty = (S - box.height * s) / 2
        let minX = box.minX, maxY = box.maxY
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - minX) * s + tx,
                    y: (maxY - p.y) * s + ty)
        }

        // Build the outline point-by-point with the manual map.
        // Subpaths are closed explicitly as we go, so contains() works.
        let outline = CGMutablePath()
        var open = false
        combined.applyWithBlock { el in
            let t = el.pointee.type
            if t == .moveToPoint {
                if open { outline.closeSubpath() }
                outline.move(to: map(el.pointee.points[0]))
                open = true
            } else if t == .addLineToPoint {
                outline.addLine(to: map(el.pointee.points[0]))
            } else if t == .addQuadCurveToPoint {
                outline.addQuadCurve(to: map(el.pointee.points[1]),
                                     control: map(el.pointee.points[0]))
            } else if t == .addCurveToPoint {
                outline.addCurve(to: map(el.pointee.points[2]),
                                 control1: map(el.pointee.points[0]),
                                 control2: map(el.pointee.points[1]))
            } else if t == .closeSubpath {
                outline.closeSubpath()
                open = false
            }
        }
        if open { outline.closeSubpath() }

        // Coverage grid: a cell is a target if its center falls inside the
        // outline. The outline is transformed, closed, and in 300-box
        // UIKit coords — point-in-path just works. Row 0 = top.
        let g = WritingMetrics.grid
        let cell = S / CGFloat(g)
        var targets = Set<Int>()
        for row in 0..<g {
            for col in 0..<g {
                let pt = CGPoint(x: (CGFloat(col) + 0.5) * cell,
                                y: (CGFloat(row) + 0.5) * cell)
                if outline.contains(pt, using: .evenOdd) {
                    targets.insert(row * g + col)
                }
            }
        }
        return LetterGuide(outline: outline,
                           targets: targets, sampler: PathSampler(outline),
                           bbox: outline.boundingBox)
    }
}

/// Flattens a CGPath into a point list. Curves are subdivided; the result is
/// in the path's own coordinates.
fileprivate final class PathWalker {
    private(set) var pts: [CGPoint] = []
    private var cur = CGPoint.zero
    private var subStart = CGPoint.zero

    private func add(_ p: CGPoint) {
        if pts.last != p { pts.append(p) }
    }
    private func quad(_ c: CGPoint, _ p: CGPoint) {
        let p0 = cur
        for i in 1...12 {
            let t = CGFloat(i) / 12, mt = 1 - t
            add(CGPoint(x: mt * mt * p0.x + 2 * mt * t * c.x + t * t * p.x,
                        y: mt * mt * p0.y + 2 * mt * t * c.y + t * t * p.y))
        }
        cur = p
    }
    private func cubic(_ c1: CGPoint, _ c2: CGPoint, _ p: CGPoint) {
        let p0 = cur
        for i in 1...16 {
            let t = CGFloat(i) / 16, mt = 1 - t
            add(CGPoint(x: mt*mt*mt*p0.x + 3*mt*mt*t*c1.x + 3*mt*t*t*c2.x + t*t*t*p.x,
                        y: mt*mt*mt*p0.y + 3*mt*mt*t*c1.y + 3*mt*t*t*c2.y + t*t*t*p.y))
        }
        cur = p
    }

    func run(_ path: CGPath) {
        path.apply(info: Unmanaged.passUnretained(self).toOpaque()) { info, elPtr in
            let w = Unmanaged<PathWalker>.fromOpaque(info!).takeUnretainedValue()
            let el = elPtr.pointee
            switch el.type {
            case .moveToPoint:
                w.cur = el.points[0]; w.subStart = el.points[0]; w.add(el.points[0])
            case .addLineToPoint:
                w.add(el.points[0]); w.cur = el.points[0]
            case .addQuadCurveToPoint:
                w.quad(el.points[0], el.points[1])
            case .addCurveToPoint:
                w.cubic(el.points[0], el.points[1], el.points[2])
            case .closeSubpath:
                w.add(w.subStart); w.cur = w.subStart
            @unknown default:
                break
            }
        }
    }
}

/// Point-at-distance along a flattened path — drives the pen tip in Watch mode.
fileprivate struct PathSampler {
    let points: [CGPoint]
    let lengths: [CGFloat]  // cumulative; lengths[i] = distance to points[i]
    let total: CGFloat

    init(_ path: CGPath) {
        let w = PathWalker()
        w.run(path)
        points = w.pts
        var ls: [CGFloat] = [0]
        for i in 1..<w.pts.count {
            let d = hypot(w.pts[i].x - w.pts[i - 1].x, w.pts[i].y - w.pts[i - 1].y)
            ls.append(ls.last! + d)
        }
        lengths = ls
        total = ls.last ?? 0
    }

    func point(at distance: CGFloat) -> CGPoint {
        guard total > 0, points.count > 1 else { return points.first ?? .zero }
        let d = min(max(distance, 0), total)
        var lo = 0, hi = lengths.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if lengths[mid] < d { lo = mid + 1 } else { hi = mid }
        }
        let i = max(lo, 1)
        let seg = lengths[i] - lengths[i - 1]
        guard seg > 0 else { return points[i] }
        let t = (d - lengths[i - 1]) / seg
        return CGPoint(x: points[i - 1].x + (points[i].x - points[i - 1].x) * t,
                       y: points[i - 1].y + (points[i].y - points[i - 1].y) * t)
    }
}

/// Watch 👀 — the letter draws itself as a pure SwiftUI view. `t` goes
/// 0→1; the blue stroke grows along the outline and a pen-tip dot rides
/// the end. Plain View inputs, so every `t` tick redraws. (The Canvas
/// version silently swallowed its redraws, which is why Watch did nothing.)
fileprivate struct WatchOverlayView: View {
    let t: Double
    let guide: LetterGuide
    let size: CGSize

    var body: some View {
        let s = min(size.width, size.height) / WritingMetrics.canvas
        let ox = (size.width - WritingMetrics.canvas * s) / 2
        let oy = (size.height - WritingMetrics.canvas * s) / 2
        let toCanvas = CGAffineTransform(scaleX: s, y: s)
            .translatedBy(x: ox, y: oy)
        let tp = Path(guide.outline).applying(toCanvas)
        let tip = guide.sampler.point(at: CGFloat(t) * guide.sampler.total)
        let c = CGPoint(x: tip.x * s + ox, y: tip.y * s + oy)
        ZStack {
            tp.trimmedPath(from: 0, to: CGFloat(t))
                .stroke(.blue,
                        style: StrokeStyle(lineWidth: 10 * s, lineCap: .round))
            Circle()
                .fill(.blue)
                .frame(width: 18 * s, height: 18 * s)
                .position(c)
        }
    }
}

/// One letter's practice screen: watch it, trace it, get cheered for it.
struct LetterPracticeView: View {
    let words: [Word]
    @State private var idx: Int
    @State private var guide: LetterGuide?
    @State private var strokes: [[CGPoint]] = []
    @State private var currentStroke: [CGPoint] = []
    @State private var covered = Set<Int>()
    @State private var watching = false
    @State private var watchStart = Date()
    @State private var tryIt = false
    @State private var canvasSize: CGSize = .zero
    @State private var celebrated = false
    @State private var justEarned = false
    @State private var player: AVPlayer?
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.writing.done") private var doneIDs = ""

    init(words: [Word], index: Int) {
        self.words = words
        _idx = State(initialValue: index)
    }

    private var word: Word { words[idx] }
    private var progress: Double {
        guard let g = guide, !g.targets.isEmpty else { return 0 }
        return min(1, Double(covered.count) / Double(g.targets.count))
    }

    /// Watch animation duration: scales with the word length so a full
    /// name gets time to draw. ~3.5s per character, minimum 5s — slow
    /// enough for little eyes to follow each stroke.
    private var watchDuration: Double {
        max(5.0, 3.5 * Double(word.devanagari.count))
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            canvasCard
            ProgressView(value: progress)
                .tint(.orange)
                .padding(.horizontal)
            Text(tryIt ? "Write it yourself — no tracing! Earn XP ⭐" : "Trace with your finger — practice, no XP yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            controls
            Spacer()
        }
        .padding()
        .navigationTitle(word.devanagari)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { celebration }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: celebrated)
        .onAppear { setupLetter() }
        .onChange(of: idx) { _, _ in setupLetter() }
        // Switching Trace ↔ Try-it is a fresh attempt: clear the ink.
        .onChange(of: tryIt) { _, _ in
            strokes = []
            currentStroke = []
            covered = []
            celebrated = false
            justEarned = false
        }
    }

    /// (Re)builds the guide and plays the letter's sound — on open and on
    /// every Next-tap. One explicit call each, no task lifecycle surprises.
    private func setupLetter() {
        guide = LetterGuide.make(for: word.devanagari)
        reset()
        hearLetter()
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 16) {
            Text(word.devanagari)
                .font(.system(size: 64))
                .frame(width: 90)
            VStack(alignment: .leading, spacing: 2) {
                Text(word.romanized).font(.title2).bold()
                Text(word.english).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { hearLetter() } label: {
                Image(systemName: "speaker.wave.2.fill").font(.title2)
            }
            .buttonStyle(.bordered)
        }
    }

    private var canvasCard: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Canvas { ctx, _ in drawCanvas(&ctx, size: size) }
                    .onAppear { canvasSize = size }
                    .onChange(of: size) { _, new in canvasSize = new }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { v in
                                guard !celebrated else { return }
                                currentStroke.append(v.location)
                            }
                            .onEnded { _ in
                                if !currentStroke.isEmpty {
                                    strokes.append(currentStroke)
                                    currentStroke = []
                                }
                                recomputeCoverage()
                                checkDone()
                            }
                    )
                // Watch 👀 via TimelineView: it ticks 60×/s on its own and
                // hands us the elapsed time — no Timer, no state-thrashing,
                // no missed redraws.
                if watching, let g = guide {
                    TimelineView(.animation(minimumInterval: 1/60)) { timeline in
                        let t = min(timeline.date.timeIntervalSince(watchStart) / watchDuration, 1.0)
                        WatchOverlayView(t: t, guide: g, size: size)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(RoundedRectangle(cornerRadius: 20)
            .fill(Color(.secondarySystemBackground)))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { watch() } label: {
                Label("Watch", systemImage: "eye.fill")
            }
            .buttonStyle(.bordered)
            .disabled(watching)
            Picker("Mode", selection: $tryIt) {
                Text("Trace").tag(false)
                Text("Try it").tag(true)
            }
            .pickerStyle(.segmented)
            Button { reset() } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var celebration: some View {
        if celebrated {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in
                        Image(systemName: "sparkles")
                            .foregroundStyle(.yellow)
                            .font(.title)
                    }
                }
                Text("स्याबास!").font(.system(size: 52)).bold()
                Text(word.devanagari).font(.system(size: 84))
                Text("You wrote \(word.romanized)!").font(.headline)
                if justEarned {
                    Text("+\(WritingMetrics.xpReward) XP")
                        .font(.headline)
                        .foregroundStyle(.orange)
                } else if !tryIt {
                    Text("Nice tracing! Try Try-it mode to earn XP ⭐")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    Button("Again") { reset() }.buttonStyle(.bordered)
                    if idx + 1 < words.count {
                        Button("Next →") { idx += 1 }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(36)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(radius: 12)
            .padding(32)
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - Drawing

    private func drawCanvas(_ ctx: inout GraphicsContext, size: CGSize) {
        guard let g = guide else { return }
        let s = min(size.width, size.height) / WritingMetrics.canvas
        let ox = (size.width - WritingMetrics.canvas * s) / 2
        let oy = (size.height - WritingMetrics.canvas * s) / 2

        // The template: the outline filled, solid enough to trace in Trace
        // mode. In Try-it mode the canvas is blank — from memory.
        if !tryIt {
            let toCanvas = CGAffineTransform(scaleX: s, y: s)
                .translatedBy(x: ox, y: oy)
            var templatePath = Path(g.outline)
            templatePath = templatePath.applying(toCanvas)
            ctx.fill(templatePath, with: .color(.black.opacity(0.32)))
        }

        // The kid's ink.
        for stroke in strokes { paint(stroke, in: &ctx, scale: s) }
        paint(currentStroke, in: &ctx, scale: s)
        // (Watch animation lives in WatchOverlayView, a real SwiftUI view
        // layered above — Canvas was silently swallowing its redraws.)
    }

    private func paint(_ stroke: [CGPoint], in ctx: inout GraphicsContext, scale s: CGFloat) {
        guard !stroke.isEmpty else { return }
        if stroke.count == 1 {
            let p = stroke[0]
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 7 * s, y: p.y - 7 * s,
                                            width: 14 * s, height: 14 * s)),
                     with: .color(.orange))
            return
        }
        var p = Path()
        p.addLines(stroke)
        ctx.stroke(p, with: .color(.orange),
                   style: StrokeStyle(lineWidth: 14 * s, lineCap: .round, lineJoin: .round))
    }

    /// Size-independent coverage: the kid's drawing is normalized to the
    /// template's bounding box (uniform scale, centered) before checking
    /// grid overlap. A small-but-correct letter passes; a scribble doesn't.
    /// Called when each stroke ends; `progress` reads the cached `covered`.
    private func recomputeCoverage() {
        guard let g = guide, canvasSize.width > 0 else { return }
        let s = min(canvasSize.width, canvasSize.height) / WritingMetrics.canvas
        let ox = (canvasSize.width - WritingMetrics.canvas * s) / 2
        let oy = (canvasSize.height - WritingMetrics.canvas * s) / 2

        // All ink in 300-box coords.
        var pts: [CGPoint] = []
        for stroke in strokes {
            for p in stroke {
                pts.append(CGPoint(x: (p.x - ox) / s, y: (p.y - oy) / s))
            }
        }
        guard !pts.isEmpty else { covered = []; return }
        let ux0 = pts.map(\.x).min()!, ux1 = pts.map(\.x).max()!
        let uy0 = pts.map(\.y).min()!, uy1 = pts.map(\.y).max()!
        let uw = ux1 - ux0, uh = uy1 - uy0
        guard uw > 4 && uh > 4 else { covered = []; return } // a dot, not a letter

        // Map the kid's bbox onto the template's bbox, uniform scale.
        let tb = g.bbox

        // Multi-character words (like names): guard against the "one big
        // letter" cheat. The normalizer below would stretch a single
        // well-drawn letter to fill the whole name's box and hit 80% of
        // the cells. Require the ink to actually span most of the
        // template's width before we'll call it complete.
        if word.devanagari.count > 1, uw < tb.width * 0.6 {
            covered = []
            return
        }

        let sc = min(tb.width / uw, tb.height / uh)
        let cell = WritingMetrics.canvas / CGFloat(WritingMetrics.grid)
        var hit = Set<Int>()
        for p in pts {
            let mx = tb.minX + (tb.width - uw * sc) / 2 + (p.x - ux0) * sc
            let my = tb.minY + (tb.height - uh * sc) / 2 + (p.y - uy0) * sc
            let cc = Int(mx / cell), cr = Int(my / cell)
            for dr in -1...1 {
                for dc in -1...1 {
                    let r = cr + dr, c = cc + dc
                    if r >= 0, r < WritingMetrics.grid,
                       c >= 0, c < WritingMetrics.grid {
                        hit.insert(r * WritingMetrics.grid + c)
                    }
                }
            }
        }
        covered = hit
    }

    // MARK: - Flow

    private func checkDone() {
        // Both modes celebrate at 80% — the kid did the work. But only
        // Try-it (writing from memory, no tracing) earns XP. Trace is
        // practice: the cheer without the payout.
        //
        // Multi-character words (names): don't celebrate until the WHOLE
        // name is written. The 60% width gate in updateCovered keeps
        // partial ink from counting, but 2-of-3 characters can still
        // pass it. Require the ink to span nearly the full template
        // width so "halfway through" never triggers the cheer.
        guard !celebrated,
              progress >= WritingMetrics.tryItThreshold else { return }
        if word.devanagari.count > 1 {
            let pts = strokes.flatMap { $0 } + currentStroke
            guard !pts.isEmpty else { return }
            let ux0 = pts.map(\.x).min()!, ux1 = pts.map(\.x).max()!
            let uw = ux1 - ux0
            guard let g = guide, uw >= g.bbox.width * 0.85 else { return }
        }
        celebrated = true
        if tryIt {
            var done = Set(doneIDs.split(separator: ",").map(String.init))
            if done.insert(word.id).inserted {
                doneIDs = done.sorted().joined(separator: ",")
                totalXP += WritingMetrics.xpReward
                justEarned = true
            }
        }
        // His voice does the congratulating — स्याबास! / राम्रो! / बधाई छ!
        WinFanfare.play()
    }

    private func reset() {
        strokes = []
        currentStroke = []
        covered = []
        celebrated = false
        justEarned = false
        watching = false
    }

    private func watch() {
        guard !watching, guide != nil else { return }
        strokes = []
        currentStroke = []
        covered = []
        // TimelineView drives the animation from watchStart; we just flip
        // `watching` on and off. Nothing to invalidate, nothing to leak.
        watchStart = Date()
        watching = true
        DispatchQueue.main.asyncAfter(deadline: .now() + watchDuration + 0.6) {
            watching = false
        }
    }

    /// The letter's sound: his recording first, the phone's voice as backup.
    private func hearLetter() {
        if word.hasAudio == true,
           let url = URL(string: GharAPI.baseURLString + word.audioUrl) {
            player = AVPlayer(url: url)
            player?.play()
        } else {
            NepaliSpeaker.say(nepali: word.devanagari, romanized: word.romanized)
        }
    }
}

/// "Practice writing ✍️" — the letter picker. Vowels and consonants get
/// their own sections; practiced letters earn a star.
///
/// The practice screen is a full-screen cover (one instance at a time —
/// a NavigationLink stack was spawning a practice view per letter, so
/// tapping one letter played every letter's audio). The cover carries its
/// own chevron back button, so it feels like a push and always lands back
/// on the picker.
struct WritingPracticeView: View {
    let deck: Deck
    @AppStorage("ghar.writing.done") private var doneIDs = ""
    @AppStorage("ghar.myname.devanagari") private var myName = ""
    @AppStorage("ghar.myname.english") private var myNameEnglish = ""
    @State private var selection: LetterSelection?
    @State private var showingNameSetup = false
    @State private var namePractice: LetterSelection?

    private var done: Set<String> {
        Set(doneIDs.split(separator: ",").map(String.init))
    }
    private var vowels: [Word] {
        deck.words.filter { $0.section?.hasPrefix("Vowels") == true }
    }
    private var consonants: [Word] {
        deck.words.filter { $0.section?.hasPrefix("Consonants") == true }
    }

    /// A synthetic Word for the kid's name, so the existing practice view
    /// (Watch/Trace/Try-it + grading) works on it unchanged. The English
    /// spelling rides in `romanized` so the TTS fallback has something to
    /// say when there's no Nepali voice on the device.
    private var nameWord: Word {
        Word(id: "myname", devanagari: myName, romanized: myNameEnglish,
             english: "My name", audioUrl: "", hasAudio: false,
             section: nil, image: nil, exampleSentenceNp: nil,
             exampleSentenceEn: nil, breakdown: nil, speaker: nil,
             colorHex: nil, quizHint: nil)
    }

    var body: some View {
        List {
            Section("My Name") {
                Button {
                    if myName.isEmpty {
                        showingNameSetup = true
                    } else {
                        namePractice = LetterSelection(words: [nameWord], index: 0)
                    }
                } label: {
                    HStack {
                        Text("✏️")
                            .font(.largeTitle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(myName.isEmpty ? "Write my name" : myName)
                                .font(.title2).bold()
                                .foregroundStyle(.primary)
                            Text(myName.isEmpty
                                 ? "Set it up, then practice writing it"
                                 : "Tap to practice")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !myName.isEmpty {
                            Button("Edit") { showingNameSetup = true }
                                .font(.caption)
                        }
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            if !vowels.isEmpty {
                Section("Vowels (स्वर)") { letterGrid(vowels) }
            }
            if !consonants.isEmpty {
                Section("Consonants (व्यञ्जन)") { letterGrid(consonants) }
            }
        }
        .navigationTitle("Practice writing ✍️")
        .sheet(isPresented: $showingNameSetup) {
            NameSetupView(savedName: $myName, savedEnglish: $myNameEnglish)
        }
        .fullScreenCover(item: $selection) { sel in
            NavigationStack {
                LetterPracticeView(words: sel.words, index: sel.index)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                selection = nil
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                        .font(.headline)
                                    Text("Letters")
                                }
                            }
                        }
                    }
            }
        }
        .fullScreenCover(item: $namePractice) { sel in
            NavigationStack {
                LetterPracticeView(words: sel.words, index: sel.index)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                namePractice = nil
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                        .font(.headline)
                                    Text("Writing")
                                }
                            }
                        }
                    }
            }
        }
    }

    private func letterGrid(_ letters: [Word]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76))], spacing: 12) {
            ForEach(letters.indices, id: \.self) { i in
                let w = letters[i]
                Button {
                    selection = LetterSelection(words: letters, index: i)
                } label: {
                    VStack(spacing: 2) {
                        ZStack(alignment: .topTrailing) {
                            Text(w.devanagari)
                                .font(.system(size: 40))
                                .frame(maxWidth: .infinity)
                            if done.contains(w.id) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption)
                            }
                        }
                        Text(w.romanized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Which letter the full-screen practice cover shows.
fileprivate struct LetterSelection: Identifiable {
    let id = UUID()
    let words: [Word]
    let index: Int
}

/// Set up the kid's name for writing practice. Parent types the name in
/// English, the app transliterates to Devanagari, parent confirms or
/// corrects it, then it becomes a practice word (Watch/Trace/Try-it).
/// TTS speaks the name after typing (and on tap of the speaker button)
/// so the parent hears what the kid will hear.
struct NameSetupView: View {
    @Binding var savedName: String
    @Binding var savedEnglish: String
    @Environment(\.dismiss) private var dismiss
    @State private var englishName = ""
    @State private var devanagariName = ""
    @State private var didEditDevanagari = false
    @State private var speakWorkItem: DispatchWorkItem?

    /// Auto-transliteration, unless the parent has hand-corrected it.
    private var preview: String {
        didEditDevanagari ? devanagariName
            : DevanagariTransliterator.transliterate(englishName)
    }

    /// Speak the current Nepali name via TTS.
    private func speakName() {
        let text = preview
        guard !text.isEmpty else { return }
        NepaliSpeaker.say(nepali: text, romanized: englishName)
    }

    /// Debounced auto-speak: waits 1s after the last keystroke so it
    /// doesn't talk over the parent while they're still typing.
    private func scheduleSpeak() {
        speakWorkItem?.cancel()
        let work = DispatchWorkItem { speakName() }
        speakWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name in English") {
                    TextField("e.g. Aarav", text: $englishName)
                        .textInputAutocapitalization(.words)
                        .onChange(of: englishName) {
                            didEditDevanagari = false
                            scheduleSpeak()
                        }
                        .onSubmit { speakName() }
                }
                Section("Name in Nepali") {
                    HStack {
                        TextField("नेपालीमा नाम", text: $devanagariName)
                            .font(.title)
                            .onChange(of: devanagariName) { didEditDevanagari = true }
                        Button(action: speakName) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.title3)
                        }
                        .disabled(preview.isEmpty)
                    }
                    if !englishName.isEmpty, !didEditDevanagari {
                        Text(preview)
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                    Text("Check the spelling — tap the Nepali name to fix it if needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Save my name") {
                        let final = didEditDevanagari ? devanagariName : preview
                        if !final.isEmpty {
                            savedName = final
                            savedEnglish = englishName
                            dismiss()
                        }
                    }
                    .disabled((didEditDevanagari ? devanagariName : preview).isEmpty)
                    if !savedName.isEmpty {
                        Button("Remove saved name", role: .destructive) {
                            savedName = ""
                            savedEnglish = ""
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("My Name")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                // If editing an existing name, preload it.
                if !savedName.isEmpty {
                    devanagariName = savedName
                    englishName = savedEnglish
                    didEditDevanagari = true
                }
            }
            .onDisappear { speakWorkItem?.cancel() }
        }
    }
}

#Preview {
    ContentView()
}
