import SwiftUI
import AVFoundation

/// First screen: tab bar with Lessons, Missions, and Quiz, loaded live from our Python backend.
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
struct MissionDetailView: View {
    let mission: Mission
    @State private var player: AVPlayer?
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.missions.completed") private var completedData = Data()

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
