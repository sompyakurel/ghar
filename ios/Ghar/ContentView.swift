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
    @AppStorage("ghar.last.win") private var lastWin = ""
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
            // Never go below zero: XP already spent in the shop stays spent.
            totalXP = max(0, totalXP - mission.xp)
        } else {
            ids.insert(mission.id)
            totalXP += mission.xp
            // The win moment: voice cheer + confetti. (Un-completing stays quiet.)
            WinFanfare.play()
            celebrate()
            lastWin = mission.titleEn
        }
        completedData = (try? JSONEncoder().encode(ids)) ?? Data()
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
    @AppStorage("ghar.last.win") private var lastWin = ""

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
/// - Tap-to-speak uses NepaliSpeaker (AVSpeechSynthesizer, ne-NP voice):
///   real spoken Nepali with zero audio files to record.
/// - The "poke" pattern from before is still here — now each tap both
///   speaks the Nepali name AND pops the decoration.
struct MyGharView: View {
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.house.name") private var houseName = ""
    @AppStorage("ghar.house.roof") private var roofChoice = 0
    @AppStorage("ghar.house.walls") private var wallChoice = 0
    @AppStorage("ghar.last.win") private var lastWin = ""
    @AppStorage("ghar.shop.owned") private var ownedData = Data()

    // Poke-state: one Bool per decoration. Tap -> true (spring!) -> timer -> false.
    @State private var diyoPop = false
    @State private var buddyPop = false
    @State private var flagsPop = false
    @State private var doorPop = false
    @State private var windowsPop = false

    // The shop: spend XP to add decorations — nothing is auto-added.
    // Prices are tuned so the first quiz win (5 XP) buys the diyo,
    // and the buddy (80 XP) is a real savings goal.
    private let shopItems: [ShopItem] = [
        ShopItem(id: "diyo", nameEn: "Diyo lamp", nameNe: "दियो", icon: "🪔", cost: 5),
        ShopItem(id: "windows", nameEn: "Windows", nameNe: "झ्याल", icon: "🪟", cost: 15),
        ShopItem(id: "door", nameEn: "Door", nameNe: "ढोका", icon: "🚪", cost: 30),
        ShopItem(id: "flags", nameEn: "Prayer flags", nameNe: "प्रार्थना झण्डा", icon: "🚩", cost: 50),
        ShopItem(id: "buddy", nameEn: "Buddy", nameNe: "साथी", icon: "😊", cost: 80),
    ]

    /// IDs of purchased decorations, decoded from storage.
    private var ownedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: ownedData)) ?? []
    }

    /// The Nepali name for a decoration id — what gets spoken on tap.
    private func nepaliName(for id: String) -> String {
        shopItems.first { $0.id == id }?.nameNe ?? id
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

                Text("⭐ \(totalXP) XP")
                    .font(.headline)

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

                // The house scene: sky, sun, drifting clouds, then the house.
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(LinearGradient(
                            colors: [.blue.opacity(0.3), .blue.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom))
                        .frame(width: 310, height: 400)

                    Circle()
                        .fill(.yellow.opacity(0.9))
                        .frame(width: 46, height: 46)
                        .offset(x: -110, y: -155)

                    DriftingCloud(startX: 70, y: -145)
                    DriftingCloud(startX: -50, y: -105)

                    VStack(spacing: 0) {
                        // Prayer flags fly above the roof — tap to hear + see them dance.
                        HStack(spacing: 6) {
                            ForEach(0..<7, id: \.self) { i in
                                Triangle()
                                    .fill(ownedIDs.contains("flags") ? flagColors[i % flagColors.count] : .gray.opacity(0.25))
                                    .frame(width: 24, height: 20)
                            }
                        }
                        .rotationEffect(.degrees(flagsPop ? 10 : -10))
                        .onTapGesture {
                            if ownedIDs.contains("flags") {
                                NepaliSpeaker.say(nepaliName(for: "flags"))
                                poke { flagsPop = $0 }
                            }
                        }
                        .padding(.bottom, 4)

                        // Roof — painted whatever color the kid picked.
                        Triangle()
                            .fill(roofColors[roofChoice % roofColors.count].color)
                            .frame(width: 250, height: 110)

                        // Body — painted walls, decorations positioned inside.
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(wallColors[wallChoice % wallColors.count].color)
                                .frame(width: 210, height: 170)
                                .shadow(radius: 3)

                            HStack(spacing: 70) {
                                window
                                window
                            }
                            .offset(y: -40)
                            .scaleEffect(windowsPop ? 1.15 : 1.0)
                            .onTapGesture {
                                if ownedIDs.contains("windows") {
                                    NepaliSpeaker.say(nepaliName(for: "windows"))
                                    poke { windowsPop = $0 }
                                }
                            }

                            // Door — tap to hear its name + knock (swings on its hinge).
                            RoundedRectangle(cornerRadius: 6)
                                .fill(ownedIDs.contains("door") ? .brown : .gray.opacity(0.25))
                                .frame(width: 54, height: 84)
                                .rotationEffect(.degrees(doorPop ? -14 : 0), anchor: .leading)
                                .onTapGesture {
                                    if ownedIDs.contains("door") {
                                        NepaliSpeaker.say(nepaliName(for: "door"))
                                        poke { doorPop = $0 }
                                    }
                                }
                                .offset(y: 38)

                            diyo
                                .offset(x: -72, y: 48)
                                .scaleEffect(diyoPop ? 1.35 : 1.0)
                                .onTapGesture {
                                    if ownedIDs.contains("diyo") {
                                        NepaliSpeaker.say(nepaliName(for: "diyo"))
                                        poke { diyoPop = $0 }
                                    }
                                }

                            buddy
                                .offset(x: 72, y: 42 + (buddyPop ? -16 : 0))
                                .onTapGesture {
                                    if ownedIDs.contains("buddy") {
                                        NepaliSpeaker.say(nepaliName(for: "buddy"))
                                        poke { buddyPop = $0 }
                                    }
                                }
                        }
                    }
                    .offset(y: 40)
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
                VStack(alignment: .leading, spacing: 12) {
                    Text("🏪 Ghar Shop")
                        .font(.headline)
                    ForEach(shopItems) { item in
                        HStack(spacing: 12) {
                            Text(item.icon).font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.nameNe).font(.headline)
                                Text(item.nameEn).font(.caption).foregroundStyle(.secondary)
                            }
                            Button(action: { NepaliSpeaker.say(item.nameNe) }) {
                                Image(systemName: "speaker.wave.2.fill")
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            if ownedIDs.contains(item.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.title3)
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
                .padding()
                .background(.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                Text("Tap a decoration to hear its Nepali name 🗣️")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical)
        }
    }

    /// Buy a decoration: must be affordable and not already owned.
    /// Deducts the XP, marks it owned, then speaks its Nepali name
    /// out loud as a little celebration.
    private func buy(_ item: ShopItem) {
        guard !ownedIDs.contains(item.id), totalXP >= item.cost else { return }
        totalXP -= item.cost
        var ids = ownedIDs
        ids.insert(item.id)
        ownedData = (try? JSONEncoder().encode(ids)) ?? Data()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        NepaliSpeaker.say(item.nameNe)
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
    /// back after a beat. The Bool arrives as a setter closure so one
    /// helper serves all five decorations.
    private func poke(_ set: @escaping (Bool) -> Void) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.35)) { set(true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { set(false) }
        }
    }

    /// A window: blue pane when owned, grey silhouette when not yet bought.
    private var window: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(ownedIDs.contains("windows") ? Color(red: 0.5, green: 0.75, blue: 0.95) : .gray.opacity(0.25))
            .frame(width: 42, height: 42)
    }

    /// A diyo (oil lamp): clay base with a flame, or grey when not yet bought.
    /// Popping it scales the whole lamp up — the flame looks like it flares.
    private var diyo: some View {
        VStack(spacing: 1) {
            Circle()
                .fill(ownedIDs.contains("diyo") ? (diyoPop ? .yellow : .orange) : .gray.opacity(0.25))
                .frame(width: 14, height: 14)
            Ellipse()
                .fill(ownedIDs.contains("diyo") ? .brown : .gray.opacity(0.25))
                .frame(width: 30, height: 12)
        }
    }

    /// The buddy: a little round friend who moves in once you buy him.
    /// Popping it makes it hop.
    private var buddy: some View {
        ZStack {
            Circle()
                .fill(ownedIDs.contains("buddy") ? .yellow : .gray.opacity(0.25))
                .frame(width: 38, height: 38)
            if ownedIDs.contains("buddy") {
                HStack(spacing: 8) {
                    Circle().fill(.black).frame(width: 5, height: 5)
                    Circle().fill(.black).frame(width: 5, height: 5)
                }
                .offset(y: -4)
            }
        }
    }
}

/// A cloud that drifts side to side forever, all by itself.
/// `repeatForever(autoreverses: true)` on a linear animation = endless
/// gentle motion with no timer and nothing to get stuck.
struct DriftingCloud: View {
    let startX: CGFloat
    let y: CGFloat
    @State private var drifted = false

    var body: some View {
        HStack(spacing: -14) {
            Circle().fill(.white).frame(width: 42, height: 42)
            Circle().fill(.white).frame(width: 58, height: 58)
            Circle().fill(.white).frame(width: 42, height: 42)
        }
        .shadow(color: .black.opacity(0.08), radius: 4)
        .offset(x: startX + (drifted ? 36 : -36), y: y)
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
    let icon: String
    let cost: Int
}

/// Says a Nepali word out loud with the phone's own Nepali voice —
/// no recordings needed. Prefers a real Nepali (ne-NP) voice; if none
/// is installed it falls back to the default voice, which does its best.
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

    static func say(_ nepali: String) {
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: nepali)
        utterance.voice = AVSpeechSynthesisVoice(language: "ne-NP") // nil → default voice
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
