import SwiftUI
import AVFoundation

/// Trace-the-picture, worksheet style, in two full-screen steps:
///   1. Trace the dotted picture.
///   2. Trace the dotted Nepali word (big box, room to draw).
/// Each step needs ~70% coverage before the next unlocks. Finishing both
/// reveals the full-color picture: confetti, the word plays, +5 XP the
/// first time per word.
struct TraceView: View {
    @State private var word: Word
    /// All word IDs in this trace deck (Animals/Fruits/Body Parts) — when
    /// every one is traced, the kid earns the lucky gift box.
    var deckID: String? = nil
    var deckWords: [Word] = []

    init(word: Word, deckID: String? = nil, deckWords: [Word] = []) {
        _word = State(initialValue: word)
        self.deckID = deckID
        self.deckWords = deckWords
    }

    private var deckWordIDs: [String] { deckWords.map(\.id) }

    /// The next word in the deck, for the "Next →" button after finishing.
    private var nextWord: Word? {
        guard let i = deckWords.firstIndex(where: { $0.id == word.id }),
              i + 1 < deckWords.count else { return nil }
        return deckWords[i + 1]
    }

    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.traced.words") private var tracedData = Data()
    @AppStorage("ghar.giftbox.opened") private var giftBoxData = Data()
    @Environment(\.dismiss) private var dismiss

    /// 0 = trace picture, 1 = trace word, 2 = celebration
    @State private var step = 0
    @State private var picHits: Set<Int> = []
    @State private var wordHits: Set<Int> = []
    @State private var showConfetti = false
    @State private var showNameCard = false
    @State private var showGiftBox = false
    @State private var audioPlayer: AVPlayer?
    /// One-shot latch: the name plays exactly once per word, even though
    /// picProgress keeps changing while the name card is up.
    @State private var namePlayed = false

    private var picTargets: [CGPoint] {
        (word.tracePoints ?? []).map { CGPoint(x: $0[0], y: $0[1]) }
    }
    private var wordTargets: [CGPoint] {
        (word.wordTracePoints ?? []).map { CGPoint(x: $0[0], y: $0[1]) }
    }
    private var picProgress: Double {
        guard !picTargets.isEmpty else { return 0 }
        return Double(picHits.count) / Double(picTargets.count)
    }
    private var wordProgress: Double {
        guard !wordTargets.isEmpty else { return 0 }
        return Double(wordHits.count) / Double(wordTargets.count)
    }
    private var currentProgress: Double {
        step == 0 ? picProgress : wordProgress
    }
    private let picCompleteAt = 0.75
    private let wordCompleteAt = 0.7

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                stepHeader
                progressRow

                if step == 0 {
                    Text("Trace the picture with your finger! ✏️")
                        .font(.headline)
                    DotTraceArea(points: picTargets, aspect: 1,
                                 hitSet: $picHits, enabled: step == 0)
                    .padding(.horizontal)
                } else if step == 1 {
                    Text("Now trace the word! ✏️")
                        .font(.headline)
                    DotTraceArea(points: wordTargets, aspect: 2,
                                 hitSet: $wordHits, enabled: step == 1)
                    .padding(.horizontal)
                    Spacer()
                } else {
                    colorReveal
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical)
            .navigationTitle(word.english)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onChange(of: picProgress) { _, new in
                if step == 0 && new >= picCompleteAt && !namePlayed {
                    namePlayed = true
                    // Picture done: name the object out loud, show its name,
                    // then move to tracing the written word.
                    playWord()
                    withAnimation { showNameCard = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        withAnimation {
                            showNameCard = false
                            step = 1
                        }
                    }
                }
            }
            .onChange(of: wordProgress) { _, new in
                if step == 1 && new >= wordCompleteAt {
                    completeTrace()
                }
            }
            .overlay {
                if showNameCard {
                    nameCard
                }
                if showConfetti {
                    ConfettiBurst()
                        .allowsHitTesting(false)
                        .task {
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            showConfetti = false
                        }
                }
            }
            .sheet(isPresented: $showGiftBox) {
                GiftBoxView(deckID: deckID)
            }
        }
    }

    private var stepHeader: some View {
        HStack(spacing: 8) {
            stepDot(number: 1, active: step == 0, done: step > 0)
            stepDot(number: 2, active: step == 1, done: step > 1)
        }
        .font(.caption).bold()
    }

    private func stepDot(number: Int, active: Bool, done: Bool) -> some View {
        Text(done ? "✓ \(number)" : "\(number)")
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(done ? Color.green.opacity(0.2)
                        : active ? Color.orange.opacity(0.2)
                        : Color.gray.opacity(0.15))
            .foregroundStyle(done ? .green : active ? .orange : .gray)
            .clipShape(Capsule())
    }

    private var progressRow: some View {
        HStack {
            ProgressView(value: currentProgress)
                .tint(.orange)
            Text("\(Int(currentProgress * 100))%")
                .font(.caption).bold()
                .frame(width: 40)
        }
        .padding(.horizontal)
        .opacity(step == 2 ? 0 : 1)
    }

    /// Brief card naming the object when its picture is traced.
    private var nameCard: some View {
        VStack(spacing: 8) {
            Text(word.devanagari)
                .font(.system(size: 64))
                .bold()
            Text(word.english)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(radius: 10)
    }

    /// The payoff: the real full-color worksheet picture, revealed like magic.
    private var colorReveal: some View {
        VStack(spacing: 12) {
            if let imagePath = word.traceImage ?? word.image {
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
                .frame(width: 240, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(radius: 6)
            }
            Text("Congratulations! 🎉")
                .font(.title2).bold()
            Text(word.devanagari)
                .font(.largeTitle)
            Button(action: playWord) {
                Label("Hear it again", systemImage: "speaker.wave.2.fill")
            }
            .buttonStyle(.bordered)
            HStack(spacing: 12) {
                Button("Done ✓") { dismiss() }
                    .buttonStyle(.bordered)
                // Next object in the deck — no need to go back to the list.
                if nextWord != nil {
                    Button("Next →") { goToNext() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
    }

    /// Advance to the next word in the deck, resetting the tracing state.
    private func goToNext() {
        guard let next = nextWord else { return }
        word = next
        step = 0
        namePlayed = false
        picHits = []
        wordHits = []
        showConfetti = false
        showNameCard = false
        showGiftBox = false
    }

    private func completeTrace() {
        withAnimation { step = 2 }
        // +5 XP the first time this word is traced.
        var traced = (try? JSONDecoder().decode(Set<String>.self, from: tracedData)) ?? Set<String>()
        let isNew = !traced.contains(word.id)
        if isNew {
            traced.insert(word.id)
            tracedData = (try? JSONEncoder().encode(traced)) ?? Data()
            totalXP += 5
        }
        // No word audio here — it already played with the name card after
        // the picture. The finale is just the congrats fanfare.
        WinFanfare.play()
        showConfetti = true
        // Whole deck traced? The lucky gift box appears (once per deck).
        // (The box marks itself opened when the prize is revealed.)
        if let deckID, !deckWordIDs.isEmpty,
           deckWordIDs.allSatisfy({ traced.contains($0) }) {
            let opened = (try? JSONDecoder().decode(Set<String>.self, from: giftBoxData)) ?? Set<String>()
            if !opened.contains(deckID) {
                // Let the celebration land first, then the gift box pops up.
                Task {
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    showGiftBox = true
                }
            }
        }
    }

    /// Hear the word: Som's recording when it exists, TTS otherwise.
    private func playWord() {
        if word.hasAudio == true, let url = URL(string: GharAPI.baseURLString + word.audioUrl) {
            audioPlayer?.pause() // never overlap the previous clip
            audioPlayer = AVPlayer(url: url)
            audioPlayer?.play()
        } else {
            NepaliSpeaker.say(nepali: word.devanagari, romanized: word.romanized)
        }
    }
}

/// One dotted tracing area: gray dots form the shape, dots turn green as
/// the kid covers them, and an orange stroke follows the finger.
struct DotTraceArea: View {
    let points: [CGPoint]       // normalized 0-1
    let aspect: CGFloat         // width / height (1 = square, 2 = word box)
    @Binding var hitSet: Set<Int>
    var enabled: Bool = true

    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    /// Last dot hit in this stroke — hits only count if the finger moves
    /// continuously from dot to dot. Lifting the finger resets it, so a new
    /// line can start anywhere. This kills scribbling: random fast jumps
    /// across the picture never count.
    @State private var lastHit: CGPoint?

    private let hitRadius = 0.035
    private let maxJump = 0.12    // farthest a continuous stroke may jump

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = w / aspect
            ZStack {
                Color.white
                dotLayer(size: CGSize(width: w, height: h))
                strokeLayer(size: CGSize(width: w, height: h))
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(.gray.opacity(0.3), lineWidth: 2))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard enabled else { return }
                        let p = CGPoint(x: v.location.x / w, y: v.location.y / h)
                        guard p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1 else { return }
                        current.append(p)
                        checkHits(p)
                    }
                    .onEnded { _ in
                        if !current.isEmpty {
                            strokes.append(current)
                            current = []
                        }
                        // Finger lifted: the next stroke may start anywhere.
                        lastHit = nil
                    }
            )
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    private func dotLayer(size: CGSize) -> some View {
        Canvas { ctx, _ in
            let r = size.width * 0.011
            for (i, p) in points.enumerated() {
                let c = CGPoint(x: p.x * size.width, y: p.y * size.height)
                let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r,
                                                 width: r * 2, height: r * 2))
                ctx.fill(dot, with: .color(hitSet.contains(i)
                                           ? .green.opacity(0.55) : .gray))
            }
        }
    }

    private func strokeLayer(size: CGSize) -> some View {
        Canvas { ctx, _ in
            for stroke in strokes + [current] {
                guard stroke.count > 1 else { continue }
                var path = Path()
                path.move(to: CGPoint(x: stroke[0].x * size.width,
                                      y: stroke[0].y * size.height))
                for p in stroke.dropFirst() {
                    path.addLine(to: CGPoint(x: p.x * size.width,
                                             y: p.y * size.height))
                }
                ctx.stroke(path, with: .color(.orange),
                           style: StrokeStyle(lineWidth: 10,
                                              lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func checkHits(_ p: CGPoint) {
        for (i, t) in points.enumerated() where !hitSet.contains(i) {
            let dx = p.x - t.x, dy = p.y - t.y
            guard dx * dx + dy * dy < hitRadius * hitRadius else { continue }
            // Anti-scribble: the dot must be near the last hit dot (or be
            // the first hit of this stroke). Teleporting across the picture
            // doesn't count.
            if let last = lastHit {
                let jx = t.x - last.x, jy = t.y - last.y
                guard jx * jx + jy * jy < maxJump * maxJump else { continue }
            }
            hitSet.insert(i)
            lastHit = t
        }
    }
}

// MARK: - Lucky gift box

/// The reward for finishing a whole trace deck: tap the box, it bursts
/// open with a random bonus (+10 to +30 XP). Variable rewards are the
/// most addictive kind — that's the point.
struct GiftBoxView: View {
    /// Which deck this box is for — marked as opened when the prize is revealed.
    var deckID: String? = nil

    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.shop.owned") private var ownedData = Data()
    @AppStorage("ghar.giftbox.opened") private var giftBoxData = Data()
    @Environment(\.dismiss) private var dismiss

    @State private var opened = false
    @State private var prizeItem: ShopItem?
    @State private var prizeXP = 0
    @State private var shaking = false
    @State private var showConfetti = false
    @State private var audioPlayer: AVPlayer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("You finished the whole section!")
                    .font(.title2).bold()
                    .multilineTextAlignment(.center)
                Text("Tap the gift! 🎁")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Button(action: openBox) {
                    Text(opened ? "🎉" : "🎁")
                        .font(.system(size: 130))
                        .rotationEffect(.degrees(shaking ? 8 : 0))
                        .scaleEffect(opened ? 1.15 : 1.0)
                        .animation(.easeInOut(duration: 0.12).repeatCount(5),
                                   value: shaking)
                        .animation(.spring(), value: opened)
                }
                .buttonStyle(.plain)
                .disabled(opened)

                if opened {
                    if let item = prizeItem {
                        // The prize: an exclusive My Ghar item, never for sale.
                        VStack(spacing: 6) {
                            AsyncImage(url: URL(string: GharAPI.baseURLString + "/images/nepal-v1/mystery_\(item.id).jpg")) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFit()
                                } else {
                                    Text(item.icon)
                                        .font(.system(size: 70))
                                }
                            }
                            .frame(width: 140, height: 140)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .shadow(radius: 4)
                            Text(item.nameNe)
                                .font(.title).bold()
                            Text(item.nameEn)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Text("For your My Ghar — can't be bought!")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .transition(.scale.combined(with: .opacity))
                    } else {
                        Text("+\(prizeXP) XP!")
                            .font(.largeTitle).bold()
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                if opened {
                    Button("Awesome!") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Lucky Gift 🎁")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if showConfetti {
                    ConfettiBurst()
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func openBox() {
        // Shake first, then burst open with the prize.
        shaking = true
        WinFanfare.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            shaking = false
            // The prize: one random unowned mystery item for My Ghar.
            // All owned already? Fall back to a bonus XP prize.
            var owned = (try? JSONDecoder().decode(Set<String>.self, from: ownedData)) ?? Set<String>()
            let unowned = mysteryBoxPrizes.filter { !owned.contains($0.id) }
            if let item = unowned.randomElement() {
                owned.insert(item.id)
                ownedData = (try? JSONEncoder().encode(owned)) ?? Data()
                prizeItem = item
                // Prize name in the cloned voice when the clip is bundled, TTS otherwise.
                if let url = URL(string: GharAPI.baseURLString + "/audio/nepal-v1/myghar_\(item.id)_np.m4a") {
                    audioPlayer?.pause()
                    audioPlayer = AVPlayer(url: url)
                    audioPlayer?.play()
                } else {
                    NepaliSpeaker.say(nepali: item.nameNe, romanized: item.romanized)
                }
            } else {
                prizeXP = Int.random(in: 10...30)
                totalXP += prizeXP
            }
            // Mark this deck's box as claimed (once per deck).
            if let deckID {
                var openedIDs = (try? JSONDecoder().decode(Set<String>.self, from: giftBoxData)) ?? Set<String>()
                openedIDs.insert(deckID)
                giftBoxData = (try? JSONEncoder().encode(openedIDs)) ?? Data()
            }
            withAnimation { opened = true }
            showConfetti = true
        }
    }
}
