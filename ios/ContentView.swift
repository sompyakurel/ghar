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

/// The deck's cover art in the Lessons list: loads from the backend
/// through the same /images route as the animal photos.
/// A deck without cover art just shows a book icon instead.
struct DeckCover: View {
    let deck: Deck

    var body: some View {
        Group {
            if let cover = deck.coverImage, cover.hasPrefix("/") {
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
    let showsPeople: Bool = false  // true for the conversations scene:
                                   // two waving kids in the courtyard

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
        stars: [],
        showsPeople: true
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
    } else {
        DeckView(deck: deck)
    }
}

/// The subtitle under each deck title in the Lessons list.
func lessonSubtitle(for deck: Deck) -> String {
    switch deck.kind {
    case "festival": return "Interactive festival"
    case "convo": return "Interactive conversations"
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
    let wordId: String

    var body: some View {
        ZStack {
            switch wordId {
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
        .frame(maxWidth: .infinity)
        .frame(height: 190)
    }
}

// The "show me" card: the animation up top, the word, and a Hear-it button.
// It says the word out loud as it opens.
struct TeachingCard: View {
    let word: Word
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            VStack(spacing: 10) {
                TeachingArt(wordId: word.id)
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
                        NepaliSpeaker.say(nepali: word.devanagari, romanized: word.romanized)
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
                // The conversations courtyard gets two kids mid-chat.
                if config.showsPeople {
                    WavingPerson(shirt: Color(red: 0.95, green: 0.55, blue: 0.2), flip: false)
                        .position(x: geo.size.width * 0.32, y: geo.size.height * 0.62)
                    WavingPerson(shirt: Color(red: 0.35, green: 0.55, blue: 0.9), flip: true)
                        .position(x: geo.size.width * 0.68, y: geo.size.height * 0.62)
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
            hotspotFace(spot, isFound: isFound)
                .scaleEffect(isFound ? 1.18 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isFound)
        }
        .position(x: spot.x * size.width, y: spot.y * size.height)
    }

    // What a hotspot looks like: the swing is drawn, everything else is emoji.
    // Unlit diyos sit gray until tapped, then glow.
    @ViewBuilder
    private func hotspotFace(_ spot: FestivalHotspot, isFound: Bool) -> some View {
        if spot.id == "dash_ping" {
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

    /// Same as DeckView's: builds the full audio URL and plays it.
    /// Festival words have no recordings yet, so their speaker buttons
    /// sit dimmed and disabled until Som records them — then they just work.
    private func play(word: Word) {
        guard let url = URL(string: GharAPI.baseURLString + word.audioUrl) else { return }
        player = AVPlayer(url: url)
        player?.play()
    }
}

/// Daily Conversations: the animated courtyard scene on top (tappable
/// phrase bubbles, same engine as the festival scenes), the Practice
/// role-play game in the middle, and the full phrase list below —
/// grouped by section like DeckView, each row opening a teaching card.
struct ConversationsView: View {
    let deck: Deck
    @State private var player: AVPlayer?
    @State private var teachingWord: Word?   // open phrase = show the "show me" card

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
        let config = FestivalConfig.forDeck(deck.id)
        ScrollView {
            VStack(spacing: 16) {
                FestivalScene(deck: deck, config: config, teachingWord: $teachingWord)
                    .padding(.horizontal)
                Text("Tap a chat bubble in the courtyard — or practice a real conversation below 👇")
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
                    VStack(alignment: .leading, spacing: 4) {
                        if let header = grouped[i].header {
                            Text(header)
                                .font(.headline)
                        }
                        ForEach(grouped[i].words) { word in
                            WordRow(word: word, onPlay: play(word:))
                                .onTapGesture { teachingWord = word }
                        }
                    }
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

    /// Same as FestivalView's: streams the recorded audio once it exists.
    /// The speaker buttons sit dimmed until Som records the 20 phrases —
    /// the teaching card's "Hear it" button uses the device voice meanwhile.
    private func play(word: Word) {
        guard let url = URL(string: GharAPI.baseURLString + word.audioUrl) else { return }
        player = AVPlayer(url: url)
        player?.play()
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

/// The Quiz tab menu: one row per quiz section. A section with no
/// recorded audio yet (like Animals right now) shows dimmed with a
/// "Recordings coming soon" note — and wakes up on its own the moment
/// Som's recordings land, no code change needed.
struct QuizMenuView: View {
    let pack: ContentPack

    /// (title, words) per section, in display order. Animals gets its own
    /// row; everything else plays together under Words.
    private var sections: [(title: String, words: [Word])] {
        let animals = pack.decks.first { $0.id == "animals" }?.words ?? []
        let rest = pack.decks.filter { $0.id != "animals" }.flatMap { $0.words }
        return [("Words", rest), ("Animals", animals)]
    }

    var body: some View {
        List {
            ForEach(sections.indices, id: \.self) { i in
                let section = sections[i]
                let audible = section.words.filter { $0.hasAudio ?? true }
                if audible.isEmpty {
                    // Silent for now — nothing to hear yet, so no game.
                    // This row enables itself once recordings exist.
                    Label {
                        VStack(alignment: .leading) {
                            Text(section.title).font(.headline)
                            Text("Recordings coming soon")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "speaker.slash.fill")
                    }
                    .opacity(0.45)
                } else {
                    NavigationLink {
                        QuizView(words: section.words)
                            .navigationTitle("\(section.title) Quiz")
                    } label: {
                        Label(section.title, systemImage: "questionmark.circle.fill")
                    }
                }
            }
        }
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
        // Only words with recorded audio can be quiz questions —
        // a listening game with nothing to hear isn't a game.
        // `?? true`: packs from before `has_audio` existed count as audible.
        let audible = words.filter { $0.hasAudio ?? true }
        let pool = audible.filter { $0.id != current?.id }
        guard let next = pool.randomElement() else { return }
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
/// - Tap-to-speak uses NepaliSpeaker (AVSpeechSynthesizer): the real
///   Nepali voice when the device has one, otherwise the romanized word
///   via the English voice — zero audio files to record either way.
/// - The "poke" pattern from before is still here — now each tap both
///   speaks the Nepali name AND pops the decoration.
struct MyGharView: View {
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.house.name") private var houseName = ""
    @AppStorage("ghar.house.roof") private var roofChoice = 0
    @AppStorage("ghar.house.walls") private var wallChoice = 0
    @AppStorage("ghar.last.win") private var lastWin = ""
    @AppStorage("ghar.shop.owned") private var ownedData = Data()

    // Poke-state: one Bool per tappable thing. Tap -> true (spring!) -> timer -> false.
    @State private var diyoPop = false
    @State private var buddyPop = false
    @State private var flagsPop = false
    @State private var doorPop = false
    @State private var windowsPop = false
    @State private var sunPop = false
    @State private var roofPop = false

    // The shop: spend XP to add decorations — nothing is auto-added.
    // Prices are tuned so the first quiz win (5 XP) buys the diyo,
    // and the buddy (80 XP) is a real savings goal.
    private let shopItems: [ShopItem] = [
        ShopItem(id: "diyo", nameEn: "Diyo lamp", nameNe: "दियो", romanized: "diyo", icon: "🪔", cost: 5),
        ShopItem(id: "windows", nameEn: "Windows", nameNe: "झ्याल", romanized: "jhyaal", icon: "🪟", cost: 15),
        ShopItem(id: "door", nameEn: "Door", nameNe: "ढोका", romanized: "dhoka", icon: "🚪", cost: 30),
        ShopItem(id: "flags", nameEn: "Prayer flags", nameNe: "प्रार्थना झण्डा", romanized: "prarthana jhanda", icon: "🚩", cost: 50),
        ShopItem(id: "buddy", nameEn: "Buddy", nameNe: "साथी", romanized: "saathi", icon: "😊", cost: 80),
    ]

    /// IDs of purchased decorations, decoded from storage.
    private var ownedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: ownedData)) ?? []
    }

    /// The shop item for a decoration id — what gets spoken on tap.
    private func shopItem(_ id: String) -> ShopItem {
        shopItems.first { $0.id == id } ?? shopItems[0]
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
                        .scaleEffect(sunPop ? 1.25 : 1.0)
                        .onTapGesture {
                            NepaliSpeaker.say(nepali: "सूर्य", romanized: "surya")
                            poke { sunPop = $0 }
                        }

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
                                NepaliSpeaker.say(shopItem("flags"))
                                poke { flagsPop = $0 }
                            }
                        }
                        .padding(.bottom, 4)

                        // Roof — painted whatever color the kid picked. Tap to hear its name.
                        Triangle()
                            .fill(roofColors[roofChoice % roofColors.count].color)
                            .frame(width: 250, height: 110)
                            .scaleEffect(roofPop ? 1.05 : 1.0)
                            .onTapGesture {
                                NepaliSpeaker.say(nepali: "छाना", romanized: "chhana")
                                poke { roofPop = $0 }
                            }

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
                                    NepaliSpeaker.say(shopItem("windows"))
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
                                        NepaliSpeaker.say(shopItem("door"))
                                        poke { doorPop = $0 }
                                    }
                                }
                                .offset(y: 38)

                            diyo
                                .offset(x: -72, y: 48)
                                .scaleEffect(diyoPop ? 1.35 : 1.0)
                                .onTapGesture {
                                    if ownedIDs.contains("diyo") {
                                        NepaliSpeaker.say(shopItem("diyo"))
                                        poke { diyoPop = $0 }
                                    }
                                }

                            buddy
                                .offset(x: 72, y: 42 + (buddyPop ? -16 : 0))
                                .onTapGesture {
                                    if ownedIDs.contains("buddy") {
                                        NepaliSpeaker.say(shopItem("buddy"))
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
                                Text("\(item.romanized) · \(item.nameEn)").font(.caption).foregroundStyle(.secondary)
                            }
                            Button(action: { NepaliSpeaker.say(item) }) {
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

                Text("Tap the sun, clouds, roof, or a decoration to hear its Nepali name 🗣️")
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
        NepaliSpeaker.say(item)
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
            NepaliSpeaker.say(nepali: "बादल", romanized: "baadal")
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
        } else {
            utterance = AVSpeechUtterance(string: romanized)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
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
            ForEach(grouped.indices, id: \.self) { i in
                Section(header: grouped[i].header.map {
                    Text($0).font(.headline)
                }) {
                    ForEach(grouped[i].words) { word in
                        WordRow(word: word, onPlay: play(word:))
                    }
                }
            }
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

#Preview {
    ContentView()
}
