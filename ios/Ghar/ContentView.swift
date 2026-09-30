import SwiftUI
import AVFoundation
import UIKit

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
                            NavigationLink(destination: DeckView(deck: deck)) {
                                VStack(alignment: .leading) {
                                    Text(deck.title).font(.headline)
                                    Text("\(deck.words.count) words")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
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

                    // --- Tab 3: Quiz (listening game) ---
                    NavigationStack {
                        QuizView(words: pack.decks.flatMap { $0.words })
                            .navigationTitle("Quiz")
                    }
                    .tabItem {
                        Label("Quiz", systemImage: "questionmark.circle.fill")
                    }

                    // --- Tab 4: My Ghar (the house you build with XP) ---
                    NavigationStack {
                        MyGharView()
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The Missions tab: one row per mission — English title, the prompt,
/// the Nepali title, and an XP badge. Finished missions get a green
/// checkmark; your total XP sits top-right. Tapping a row pushes the
/// detail screen.
///
/// Teaching notes:
/// - `List(missions)` works because Mission is Identifiable (it has `id`).
/// - `NavigationLink(destination:)` turns each row into a tappable link.
///   The row content becomes the label (what you tap); the destination
///   is the screen you land on.
/// - `@AppStorage` here uses the SAME keys as MissionDetailView. Two views
///   declaring the same key share the value live: tap "I did it!" over
///   there, the checkmark appears here with zero extra wiring.
struct MissionsView: View {
    let missions: [Mission]
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.missions.completed") private var completedData = Data()

    /// The IDs of finished missions, decoded from storage.
    /// @AppStorage only holds simple types (Int, String, Data...), so a Set
    /// gets JSON-encoded into Data — our little packing trick.
    private var completedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: completedData)) ?? []
    }

    var body: some View {
        List(missions) { mission in
            NavigationLink(destination: MissionDetailView(mission: mission)) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        if completedIDs.contains(mission.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Text(mission.titleEn)
                            .font(.headline)
                        Spacer()
                        Text("+\(mission.xp) XP")
                            .font(.caption)
                            .bold()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.orange.opacity(0.2))
                            .clipShape(Capsule())
                    }
                    Text(mission.promptEn)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(mission.titleNe)
                        .font(.subheadline)
                }
                .padding(.vertical, 4)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text("⭐ \(totalXP) XP")
                    .font(.headline)
            }
        }
    }
}

/// Tapping a mission row opens this: the full prompt in English + Nepali,
/// a play button for the recorded instruction, and an "I did it!" button.
/// (The audio files come later — the play button stays silent until then,
/// same as the quest scenes the first time. No crash, just quiet.)
///
/// Teaching notes:
/// - Same pattern as DeckView: the parent hands this view a `mission`,
///   and this view just displays it. Data flows down, never up.
/// - Done-state now lives in @AppStorage (the phone's own storage), not
///   @State. @State forgot when you left the screen — @AppStorage remembers
///   forever, with no login and no server (that's the COPPA-safe part).
/// - XP bookkeeping: +xp when you complete, −xp if you un-complete, so
///   tapping twice can't double-count.
/// - The play button reuses the AVPlayer trick from DeckView: the player
///   lives in @State so SwiftUI doesn't throw it away mid-sound.
/// - The win moment (chime + confetti) fires only when COMPLETING, not
///   when un-completing. Small detail, big feel.
struct MissionDetailView: View {
    let mission: Mission
    @State private var player: AVPlayer?
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.missions.completed") private var completedData = Data()
    @State private var showConfetti = false

    private var completedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: completedData)) ?? []
    }

    private var isDone: Bool { completedIDs.contains(mission.id) }

    /// Toggle completion: update the ID set AND the XP total together,
    /// so the two can never disagree with each other.
    private func toggleDone() {
        var ids = completedIDs
        if ids.contains(mission.id) {
            ids.remove(mission.id)
            totalXP -= mission.xp
        } else {
            ids.insert(mission.id)
            totalXP += mission.xp
            // The win moment: voice cheer + confetti. (Un-completing stays quiet.)
            WinFanfare.play()
            showConfetti = true
        }
        completedData = (try? JSONEncoder().encode(ids)) ?? Data()
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

                Button(action: toggleDone) {
                    Label(isDone ? "Done!" : "I did it!",
                          systemImage: isDone ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(isDone ? .green : .blue)
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
    }

    /// Same streaming trick as DeckView: server address + path from JSON.
    /// Until you record the clips, the file isn't there — AVPlayer just
    /// stays quiet instead of crashing.
    private func play() {
        guard let url = URL(string: GharAPI.baseURLString + mission.audioUrl) else { return }
        player = AVPlayer(url: url)
        player?.play()
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

    @State private var current: Word?
    @State private var options: [Word] = []
    @State private var solved = false
    @State private var wrongIDs: Set<String> = []
    @State private var showConfetti = false

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
                    Text(option.english)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(background(for: option))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
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

    /// Fresh question: a random word (never the same twice in a row),
    /// plus up to 3 random distractors, all shuffled. Auto-plays the word.
    private func newQuestion() {
        let pool = words.filter { $0.id != current?.id }
        guard let next = pool.randomElement() else { return }
        current = next
        let distractors = words.filter { $0.id != next.id }.shuffled().prefix(3)
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
            showConfetti = true
        } else {
            wrongIDs.insert(option.id)
        }
    }

    /// Button colors, derived from state: right answer goes green,
    /// wrong taps go red, everything else stays neutral.
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

/// Cheers out loud on a win — a random celebration line spoken by the
/// phone's own voice, no audio files needed. Also fires the
/// Apple-blessed success haptic.
///
/// Teaching notes:
/// - `AVSpeechSynthesizer` is iOS's built-in text-to-speech: hand it an
///   `AVSpeechUtterance` (the words + voice + speed + pitch) and it talks.
///   Free, offline, zero assets — same "no files needed" win as the old
///   synthesized chime, but way more delightful.
/// - The line is picked at random each win from a pool spanning playful
///   ("Yay!") to cool ("Too easy for you.") so it never gets stale —
///   and it throws in Nepali praise (स्याबास! = "well done!") when the
///   phone has a Nepali voice installed.
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

    /// The celebration pool: (words, language code). Nepali lines join
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

    static func play() {
        // Haptic + voice both run from the button tap on the main thread.
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        synth.stopSpeaking(at: .immediate)
        guard let cheer = cheers.randomElement() else { return }
        let utterance = AVSpeechUtterance(string: cheer.text)
        utterance.voice = AVSpeechSynthesisVoice(language: cheer.language)
        utterance.rate = 0.52            // a touch peppier than default
        utterance.pitchMultiplier = 1.15 // a touch more excited
        synth.speak(utterance)
    }
}

/// The My Ghar tab: your house, built from your XP. The roof and walls
/// are always there; every decoration unlocks at an XP threshold — locked
/// ones show as grey silhouettes so the kid sees what's coming.
///
/// Teaching notes:
/// - Still zero image assets: the whole house is shapes (triangles,
///   rounded rectangles, circles, ellipses).
/// - Everything keys off the same "ghar.xp.total" locker. Earn XP in
///   the quiz or missions, the house builds itself. One source of truth.
/// - Positions inside the house body use `.offset(x:y)` — points from the
///   center. Simple to reason about, easy to nudge.
struct MyGharView: View {
    @AppStorage("ghar.xp.total") private var totalXP = 0

    private let diyoAt = 10
    private let windowsAt = 25
    private let doorAt = 50
    private let flagsAt = 75
    private let buddyAt = 100

    private let flagColors: [Color] = [.blue, .orange, .red, .green, .yellow]

    /// The collection shelf: every decoration, its price in XP, and whether
    /// it's unlocked yet. Single source for the shelf below the house.
    private var decorations: [(name: String, icon: String, threshold: Int)] {
        [
            (name: "Diyo lamp", icon: "🪔", threshold: diyoAt),
            (name: "Windows", icon: "🪟", threshold: windowsAt),
            (name: "Door", icon: "🚪", threshold: doorAt),
            (name: "Prayer flags", icon: "🚩", threshold: flagsAt),
            (name: "Buddy", icon: "😊", threshold: buddyAt),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("⭐ \(totalXP) XP")
                    .font(.title)
                    .bold()

                // The house itself — stacked with zero spacing so the
                // flags sit on the roof and the roof sits on the walls.
                VStack(spacing: 0) {
                    // Prayer flags fly above the roof
                    HStack(spacing: 6) {
                        ForEach(0..<7, id: \.self) { i in
                            Triangle()
                                .fill(totalXP >= flagsAt ? flagColors[i % flagColors.count] : .gray.opacity(0.25))
                                .frame(width: 24, height: 20)
                        }
                    }
                    .padding(.bottom, 4)

                    // Roof — crimson, like the app icon
                    Triangle()
                        .fill(Color(red: 0.75, green: 0.15, blue: 0.2))
                        .frame(width: 250, height: 110)

                    // Body — cream walls, decorations positioned inside
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(red: 1.0, green: 0.96, blue: 0.88))
                            .frame(width: 210, height: 170)
                            .shadow(radius: 3)

                        HStack(spacing: 70) {
                            window
                            window
                        }
                        .offset(y: -40)

                        RoundedRectangle(cornerRadius: 6)
                            .fill(totalXP >= doorAt ? .brown : .gray.opacity(0.25))
                            .frame(width: 54, height: 84)
                            .offset(y: 38)

                        diyo.offset(x: -72, y: 48)
                        buddy.offset(x: 72, y: 42)
                    }
                }

                // Collection shelf
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(decorations, id: \.name) { d in
                        HStack {
                            Text(d.icon).font(.title2)
                            Text(d.name)
                            Spacer()
                            if totalXP >= d.threshold {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Text("🔒 \(d.threshold) XP")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding()
                .background(.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
    }

    /// A window: blue pane when unlocked, grey silhouette when locked.
    private var window: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(totalXP >= windowsAt ? Color(red: 0.5, green: 0.75, blue: 0.95) : .gray.opacity(0.25))
            .frame(width: 42, height: 42)
    }

    /// A diyo (oil lamp): clay base with a flame, or grey when locked.
    private var diyo: some View {
        VStack(spacing: 1) {
            Circle()
                .fill(totalXP >= diyoAt ? .orange : .gray.opacity(0.25))
                .frame(width: 14, height: 14)
            Ellipse()
                .fill(totalXP >= diyoAt ? .brown : .gray.opacity(0.25))
                .frame(width: 30, height: 12)
        }
    }

    /// The buddy: a little round friend who moves in at 100 XP.
    private var buddy: some View {
        ZStack {
            Circle()
                .fill(totalXP >= buddyAt ? .yellow : .gray.opacity(0.25))
                .frame(width: 38, height: 38)
            if totalXP >= buddyAt {
                HStack(spacing: 8) {
                    Circle().fill(.black).frame(width: 5, height: 5)
                    Circle().fill(.black).frame(width: 5, height: 5)
                }
                .offset(y: -4)
            }
        }
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

    var body: some View {
        List(deck.words) { word in
            HStack {
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
                Button(action: { play(word: word) }) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.title2)
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 4)
        }
        .navigationTitle(deck.title)
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

#Preview {
    ContentView()
}
