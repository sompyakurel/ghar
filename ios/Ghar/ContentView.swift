import SwiftUI
import AVFoundation

/// First screen: tab bar with Lessons and Missions, loaded live from our Python backend.
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
/// the Nepali title, and an XP badge. Tapping a row opens the detail
/// screen (next step).
///
/// Teaching notes:
/// - `List(missions)` works because Mission is Identifiable (it has `id`).
/// - Rows are plain display for now — NavigationLink comes in step 3.
struct MissionsView: View {
    let missions: [Mission]

    var body: some View {
        List(missions) { mission in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
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
