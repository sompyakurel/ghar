import SwiftUI
import AVFoundation

// MARK: - Bagh-Chal engine (pure logic)
//
// Mirrors ~/workspace/baghchal/baghchal.py, which was battle-tested with
// hundreds of simulated games before this UI existed. The Python version
// is the reference: any rule question gets settled there first.
//
// Rules (kids' edition of the classic Nepali tiger-and-goats game):
// - 5x5 points. Orthogonal neighbors always connected; diagonal
//   neighbors connected where (r + c) is even (the traditional pattern).
// - 4 tigers start on the corners. The kid (goats) places 20 goats one
//   per turn; tigers move between placements.
// - Then both sides move one piece per turn. Tigers jump over an
//   adjacent goat to an empty point to capture it (capturing is optional).
// - Tigers win by capturing 5 goats. Goats win by leaving every tiger
//   with no legal move. 300 half-moves with no result = a draw.

enum BaghPiece: Equatable { case empty, goat, tiger }

struct BaghPoint: Hashable, Equatable {
    let r: Int
    let c: Int
}

struct BaghTigerMove: Equatable {
    let src: BaghPoint
    let dst: BaghPoint
    let captured: BaghPoint?
}

struct BaghGoatMove: Equatable {
    let src: BaghPoint
    let dst: BaghPoint
}

struct BaghChalEngine: Equatable {
    var board: [BaghPoint: BaghPiece] = [:]
    var goatsInHand = 20
    var captured = 0
    var goatTurn = true
    var plies = 0

    static let corners = [BaghPoint(r: 0, c: 0), BaghPoint(r: 0, c: 4),
                          BaghPoint(r: 4, c: 0), BaghPoint(r: 4, c: 4)]

    init() { reset() }

    mutating func reset() {
        board = [:]
        for r in 0..<5 {
            for c in 0..<5 { board[BaghPoint(r: r, c: c)] = .empty }
        }
        for corner in Self.corners { board[corner] = .tiger }
        goatsInHand = 20
        captured = 0
        goatTurn = true
        plies = 0
    }

    static func neighbors(_ p: BaghPoint) -> [BaghPoint] {
        var out: [BaghPoint] = []
        for (dr, dc) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let q = BaghPoint(r: p.r + dr, c: p.c + dc)
            if (0..<5).contains(q.r), (0..<5).contains(q.c) { out.append(q) }
        }
        if (p.r + p.c) % 2 == 0 {
            for (dr, dc) in [(-1, -1), (-1, 1), (1, -1), (1, 1)] {
                let q = BaghPoint(r: p.r + dr, c: p.c + dc)
                if (0..<5).contains(q.r), (0..<5).contains(q.c) { out.append(q) }
            }
        }
        return out
    }

    /// Every board segment exactly once (for drawing).
    static func segments() -> [(BaghPoint, BaghPoint)] {
        var segs: [(BaghPoint, BaghPoint)] = []
        for r in 0..<5 {
            for c in 0..<5 {
                let p = BaghPoint(r: r, c: c)
                for q in neighbors(p) where q.r > p.r || (q.r == p.r && q.c > p.c) {
                    segs.append((p, q))
                }
            }
        }
        return segs
    }

    func tigerMoves() -> [BaghTigerMove] {
        var moves: [BaghTigerMove] = []
        for r in 0..<5 {
            for c in 0..<5 {
                let p = BaghPoint(r: r, c: c)
                guard board[p] == .tiger else { continue }
                for q in Self.neighbors(p) {
                    if board[q] == .empty {
                        moves.append(BaghTigerMove(src: p, dst: q, captured: nil))
                    } else if board[q] == .goat {
                        let land = BaghPoint(r: q.r + (q.r - p.r), c: q.c + (q.c - p.c))
                        if (0..<5).contains(land.r), (0..<5).contains(land.c),
                           board[land] == .empty {
                            moves.append(BaghTigerMove(src: p, dst: land, captured: q))
                        }
                    }
                }
            }
        }
        return moves
    }

    func goatMoves() -> [BaghGoatMove] {
        var moves: [BaghGoatMove] = []
        for r in 0..<5 {
            for c in 0..<5 {
                let p = BaghPoint(r: r, c: c)
                guard board[p] == .goat else { continue }
                for q in Self.neighbors(p) where board[q] == .empty {
                    moves.append(BaghGoatMove(src: p, dst: q))
                }
            }
        }
        return moves
    }

    func placements() -> [BaghPoint] {
        (0..<5).flatMap { r in (0..<5).compactMap { c in
            let p = BaghPoint(r: r, c: c)
            return board[p] == .empty ? p : nil
        } }
    }

    mutating func placeGoat(_ p: BaghPoint) {
        board[p] = .goat
        goatsInHand -= 1
        goatTurn = false
        plies += 1
    }

    mutating func moveGoat(_ m: BaghGoatMove) {
        board[m.src] = .empty
        board[m.dst] = .goat
        goatTurn = false
        plies += 1
    }

    mutating func moveTiger(_ m: BaghTigerMove) {
        board[m.src] = .empty
        board[m.dst] = .tiger
        if let cap = m.captured {
            board[cap] = .empty
            captured += 1
        }
        goatTurn = true
        plies += 1
    }

    /// A side with no legal move loses its turn (goats can be squeezed).
    mutating func passGoats() {
        goatTurn = false
        plies += 1
    }

    enum Outcome { case playing, goatsWin, tigersWin, draw }

    func outcome() -> Outcome {
        if captured >= 5 { return .tigersWin }
        if tigerMoves().isEmpty { return .goatsWin }
        if plies >= 300 { return .draw }
        return .playing
    }
}

// MARK: - AI

/// Tiger brain (the phone). Greedy 1-ply: captures first, then mobility
/// and hunting, with deliberate blunders. Blunder 0.25 measured ~45-50%
/// goat wins vs decent play in the Python sims — beatable but real.
private func tigerAIMove(_ engine: BaghChalEngine) -> BaghTigerMove? {
    let moves = engine.tigerMoves()
    guard !moves.isEmpty else { return nil }
    if Double.random(in: 0..<1) < 0.25 { return moves.randomElement() }

    let goats = (0..<5).flatMap { r in (0..<5).compactMap { c in
        let p = BaghPoint(r: r, c: c)
        return engine.board[p] == .goat ? p : nil
    } }

    func dist(_ a: BaghPoint, _ b: BaghPoint) -> Int {
        abs(a.r - b.r) + abs(a.c - b.c)
    }

    var best: BaghTigerMove?
    var bestScore = -Double.infinity
    for m in moves {
        var s = 0.0
        if m.captured != nil { s += 100 }
        // Mobility after the move (src will be empty, so it counts).
        s += 3 * Double(BaghChalEngine.neighbors(m.dst)
            .filter { engine.board[$0] == .empty || $0 == m.src }.count)
        if let nearest = goats.map({ dist(m.dst, $0) }).min() {
            s += Double(max(0, 8 - nearest)) * 1.5
        }
        s += Double.random(in: 0..<1) // tie-break jitter
        if s > bestScore { bestScore = s; best = m }
    }
    return best
}

enum BaghHint: Equatable {
    case place(BaghPoint)
    case move(BaghPoint, BaghPoint)
}

/// Goat hint brain (the "💡 Hint" button). Same decent-goat evaluator the
/// Python sims used: minimize tiger captures next turn, then tiger
/// mobility, then keep goats clustered.
private func goatHint(_ engine: BaghChalEngine) -> BaghHint? {
    func dist(_ a: BaghPoint, _ b: BaghPoint) -> Int {
        abs(a.r - b.r) + abs(a.c - b.c)
    }
    var best: BaghHint?
    var bestKey: (Int, Int, Int, Double)?
    let consider: (BaghHint, BaghPoint) -> Void = { hint, newPos in
        var sim = engine
        sim.goatTurn = true
        switch hint {
        case .place(let p): sim.placeGoat(p)
        case .move(let s, let d): sim.moveGoat(BaghGoatMove(src: s, dst: d))
        }
        sim.goatTurn = false
        let tm = sim.tigerMoves()
        let caps = tm.filter { $0.captured != nil }.count
        let mob = tm.count
        let goats = (0..<5).flatMap { r in (0..<5).compactMap { c in
            let p = BaghPoint(r: r, c: c)
            return sim.board[p] == .goat && p != newPos ? p : nil
        } }
        let cluster = goats.map { dist(newPos, $0) }.min() ?? 4
        let key = (caps, mob, cluster, Double.random(in: 0..<2))
        if bestKey == nil || keyIsLess(key, bestKey!) {
            bestKey = key; best = hint
        }
    }
    if engine.goatsInHand > 0 {
        for p in engine.placements() { consider(.place(p), p) }
    } else {
        for m in engine.goatMoves() { consider(.move(m.src, m.dst), m.dst) }
    }
    return best
}

private func keyIsLess(_ a: (Int, Int, Int, Double), _ b: (Int, Int, Int, Double)) -> Bool {
    if a.0 != b.0 { return a.0 < b.0 }
    if a.1 != b.1 { return a.1 < b.1 }
    if a.2 != b.2 { return a.2 < b.2 }
    return a.3 < b.3
}

// MARK: - Game view

/// Bagh-Chal: the classic Nepali tiger-and-goats board game. The kid is
/// the goats; the phone is the tigers. Placement, then movement, then a
/// winner. Win pays 10 XP, finishing pays 2, max 3 paid games a day
/// (same anti-farm thinking as the dog's fetch cap).
struct BaghChalView: View {
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.last.win") private var lastWin = ""
    @AppStorage("ghar.baghchal.day") private var paidDay = ""
    @AppStorage("ghar.baghchal.paid") private var paidCount = 0
    @Environment(\.dismiss) private var dismiss

    enum Phase { case ready, playing, done }
    @State private var phase: Phase = .ready
    @State private var engine = BaghChalEngine()
    @State private var selected: BaghPoint?
    @State private var dests: [BaghPoint] = []
    @State private var tigerThinking = false
    @State private var passNotice = false
    @State private var hint: BaghHint?
    @State private var result: BaghChalEngine.Outcome = .playing
    @State private var xpEarned = 0
    // Adaptive music: synthesized in-app (no audio files), intensity
    // follows the danger — see BaghChalMusic below.
    @StateObject private var music = BaghChalMusic()
    @State private var musicMuted = false
    // Mode + fairness: pass-and-play 2-player. Hints: 3 free per
    // game, then 5 XP each — help is there, but thinking is cheaper.
    @State private var twoPlayer = false
    @State private var hintsLeft = 3
    @State private var hintDenied = false
    @StateObject private var narrator = RulesNarrator()

    private let maxPaidPerDay = 3

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if phase == .ready {
                    readyView
                } else {
                    statusBar
                    if twoPlayer {
                        // Big, unmissable turn banner for pass-and-play:
                        // green for goats, orange for tigers.
                        Text(engine.goatTurn ? "🐐 GOATS' TURN" : "🐯 TIGERS' TURN")
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(engine.goatTurn
                                        ? Color.green.opacity(0.25)
                                        : Color.orange.opacity(0.35))
                    }
                    boardView
                    if !music.statusLine.isEmpty {
                        Text(music.statusLine)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }
                    actionRow
                }
                if phase == .done { doneOverlay }
            }
            .navigationTitle("Bagh-Chal 🐯")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { narrator.stop(); music.stop(); dismiss() }
                }
            }
            .onDisappear { narrator.stop(); music.stop() }
        }
    }

    // MARK: Screens

    /// The bundled Nepali rules narration lands in the bundle via the
    /// build-phase copy of backend/app/static/audio/nepal-v1/ — the
    /// button only appears once the clip is installed.
    private var rulesFileExists: Bool {
        Bundle.main.url(forResource: "baghchal_rules", withExtension: "m4a",
                        subdirectory: "Content/audio/nepal-v1") != nil
    }

    private var readyView: some View {
        VStack(spacing: 18) {
            Text("🐯").font(.system(size: 80))
            Text(twoPlayer ? "Goats vs Tigers!" : "Trap the tigers!")
                .font(.largeTitle).bold()
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                Label(twoPlayer
                      ? "One player is the 🐐 goats, one is the 🐯 tigers — pass the phone each turn!"
                      : "You are the goats 🐐 — place all 20, then move them",
                      systemImage: "1.circle")
                Label("Surround every tiger so it can't move", systemImage: "2.circle")
                Label("Tigers jump over goats to catch them — 5 caught and the goats lose!", systemImage: "3.circle")
            }
            .font(.body)
            .padding()
            .background(.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            if rulesFileExists {
                Button {
                    narrator.toggle()
                } label: {
                    Label(narrator.isPlaying ? "Stop" : "Hear the rules in Nepali 🇳🇵",
                          systemImage: narrator.isPlaying ? "stop.circle.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.bordered)
            }
            HStack(spacing: 12) {
                modeCard(icon: "🧠", title: "vs Phone",
                         subtitle: "You play the goats", selected: !twoPlayer) {
                    twoPlayer = false
                }
                modeCard(icon: "👥", title: "2 Players",
                         subtitle: "Pass & play", selected: twoPlayer) {
                    twoPlayer = true
                }
            }
            .padding(.horizontal, 12)
            Button(twoPlayer ? "Start 2-player game!" : "Start!") { startGame() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .font(.title3)
            if !twoPlayer {
                Text("Win +10 XP · finish +2 (max 3 paid games/day)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    /// Whose turn it is, in words. The turn is checked FIRST: during
    /// placement the tigers still move after every goat placement, so
    /// "goats left to place" must not mask a tiger turn.
    private var statusText: String {
        if tigerThinking { return "🐯 Thinking…" }
        if engine.goatTurn {
            if engine.goatsInHand > 0 {
                return twoPlayer
                    ? "🐐 Goats: place one (\(engine.goatsInHand) left)"
                    : "🐐 Your move: place a goat (\(engine.goatsInHand) left)"
            }
            return twoPlayer ? "🐐 Goats to move" : "🐐 Your move"
        }
        // Tiger's turn — true during placement as well as movement.
        if engine.goatsInHand > 0 {
            return twoPlayer ? "🐯 Tigers: move a tiger" : "🐯 Tigers' move"
        }
        return twoPlayer ? "🐯 Tigers to move" : "🐯 Tigers' move"
    }

    private var statusBar: some View {
        HStack {
            Text(statusText)
            Spacer()
            Text("Caught: \(engine.captured)/5")
                .foregroundStyle(engine.captured >= 3 ? .red : .secondary)
        }
        .font(.headline)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var boardView: some View {
        GeometryReader { geo in
            boardLayer(side: min(geo.size.width, geo.size.height))
        }
    }

    /// Big tappable mode card for the ready screen — a plain function
    /// (like boardLayer) so declarations are legal inside.
    private func modeCard(icon: String, title: String, subtitle: String,
                          selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(icon).font(.system(size: 34))
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(selected ? Color.orange.opacity(0.25)
                                : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(selected ? Color.orange : Color.clear, lineWidth: 3)
            )
        }
        .buttonStyle(.plain)
    }

    /// The drawn board. A plain function (not a view-builder property),
    /// so it can declare locals and helpers — a `func` declared inside a
    /// GeometryReader closure fails to compile ("Closure containing a
    /// declaration cannot be used with result builder 'ViewBuilder'").
    private func boardLayer(side: CGFloat) -> some View {
        let pad: CGFloat = 34
        let step = max(0, side - pad * 2) / 4
        func xy(_ p: BaghPoint) -> CGPoint {
            CGPoint(x: pad + CGFloat(p.c) * step, y: pad + CGFloat(p.r) * step)
        }
        return ZStack {
                // Board lines (each segment once).
                Path { path in
                    for (a, b) in BaghChalEngine.segments() {
                        path.move(to: xy(a))
                        path.addLine(to: xy(b))
                    }
                }
                .stroke(Color.brown.opacity(0.7), lineWidth: 2)

                // Intersection points.
                ForEach(0..<25, id: \.self) { i in
                    let p = BaghPoint(r: i / 5, c: i % 5)
                    Circle()
                        .fill(Color.brown.opacity(0.9))
                        .frame(width: 7, height: 7)
                        .position(xy(p))
                }

                // Placement-phase targets: faint dots on empty points.
                if engine.goatsInHand > 0, phase == .playing {
                    ForEach(engine.placements(), id: \.self) { p in
                        Circle()
                            .fill(Color.green.opacity(0.25))
                            .frame(width: step * 0.5, height: step * 0.5)
                            .position(xy(p))
                    }
                }

                // Legal destinations for the selected goat.
                ForEach(dests, id: \.self) { p in
                    Circle()
                        .fill(Color.green.opacity(0.55))
                        .frame(width: step * 0.42, height: step * 0.42)
                        .position(xy(p))
                }

                // Hint highlight.
                if let hint {
                    switch hint {
                    case .place(let p):
                        Circle().stroke(Color.blue, lineWidth: 4)
                            .frame(width: step * 0.72, height: step * 0.72)
                            .position(xy(p))
                    case .move(let s, let d):
                        Circle().stroke(Color.blue, lineWidth: 4)
                            .frame(width: step * 0.72, height: step * 0.72)
                            .position(xy(s))
                        Circle().fill(Color.blue.opacity(0.6))
                            .frame(width: step * 0.5, height: step * 0.5)
                            .position(xy(d))
                    }
                }

                // Pieces.
                ForEach(0..<25, id: \.self) { i in
                    let p = BaghPoint(r: i / 5, c: i % 5)
                    if let piece = engine.board[p], piece != .empty {
                        pieceView(piece, selected: selected == p)
                            .frame(width: step * 0.66, height: step * 0.66)
                            .position(xy(p))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { loc in
                // Nearest point within half a step.
                var best: BaghPoint?
                var bestDist = step * 0.55
                for r in 0..<5 {
                    for c in 0..<5 {
                        let p = BaghPoint(r: r, c: c)
                        let d = hypot(loc.x - xy(p).x, loc.y - xy(p).y)
                        if d < bestDist { bestDist = d; best = p }
                    }
                }
                if let p = best { tapPoint(p) }
            }
            .animation(.easeInOut(duration: 0.25), value: engine)
            .overlay {
                if passNotice {
                    Text("No goat moves — the tigers push through!")
                        .font(.headline)
                        .padding(10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
    }

    @ViewBuilder
    private func pieceView(_ piece: BaghPiece, selected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(piece == .tiger ? Color.orange : Color.white)
                .overlay(Circle().stroke(piece == .tiger ? Color.orange.opacity(0.6) : Color.gray.opacity(0.5), lineWidth: 2))
                .shadow(radius: 2)
            Text(piece == .tiger ? "🐯" : "🐐")
                .font(.system(size: 30))
        }
        .overlay {
            if selected {
                Circle().stroke(Color.blue, lineWidth: 4)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 16) {
            // Hints: 3 free per game, then 5 XP each — and in 2-player
            // there is no hint button at all: both sides think for themselves.
            if !twoPlayer {
                Button {
                    if hintsLeft > 0 {
                        hint = goatHint(engine)
                        hintsLeft -= 1
                    } else if totalXP >= 5 {
                        totalXP -= 5
                        hint = goatHint(engine)
                    } else {
                        hintDenied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            hintDenied = false
                        }
                    }
                } label: {
                    Label(hintDenied ? "Need 5 XP ⭐"
                          : hintsLeft > 0 ? "Hint (\(hintsLeft))"
                          : "Hint · 5 XP",
                          systemImage: "lightbulb.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!engine.goatTurn || tigerThinking || phase != .playing)
                Text("⭐ \(totalXP) XP")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Button("Restart") { startGame() }
                .buttonStyle(.bordered)
            Button {
                musicMuted.toggle()
                music.isMuted = musicMuted
            } label: {
                Label(musicMuted ? "Unmute" : "Music",
                      systemImage: musicMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var doneOverlay: some View {
        VStack(spacing: 14) {
            switch result {
            case .goatsWin:
                Text("🎉").font(.system(size: 64))
                Text(twoPlayer ? "Goats win!" : "You trapped the tigers!")
                    .font(.title2).bold()
            case .tigersWin:
                Text("🐯").font(.system(size: 64))
                Text(twoPlayer ? "Tigers win!" : "The tigers caught 5 goats!")
                    .font(.title2).bold()
            case .draw:
                Text("🤝").font(.system(size: 64))
                Text("Nobody wins — great game!")
                    .font(.title2).bold()
            case .playing:
                EmptyView()
            }
            if twoPlayer {
                Text("Just for fun — no XP in 2-player 🤝")
                    .font(.caption).foregroundStyle(.secondary)
            } else if xpEarned > 0 {
                Text("+\(xpEarned) XP")
                    .font(.headline).foregroundStyle(.green)
            } else {
                Text("Daily game rewards used up — still counts for glory!")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                Button("Play again") { startGame() }
                    .buttonStyle(.borderedProminent)
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
    }

    // MARK: Game flow

    private func startGame() {
        narrator.stop()
        engine.reset()
        selected = nil
        dests = []
        hint = nil
        result = .playing
        xpEarned = 0
        tigerThinking = false
        passNotice = false
        hintsLeft = 3
        phase = .playing
        music.start(level: 0)
    }

    /// Music intensity follows the danger: calm while placing, drums and
    /// speed as the tigers close in, endgame when the trap is nearly shut.
    private func currentLevel() -> Int {
        if engine.captured >= 3 { return 3 }
        if engine.goatsInHand == 0, engine.tigerMoves().count <= 4 { return 3 }
        if engine.captured >= 2 || engine.plies > 80 { return 2 }
        if engine.goatsInHand == 0 { return 1 }
        return 0
    }

    private func tapPoint(_ p: BaghPoint) {
        guard phase == .playing, !tigerThinking, result == .playing else { return }
        if engine.goatTurn {
            if engine.goatsInHand > 0 {
                // Placement: any empty point.
                guard engine.board[p] == .empty else { return }
                hint = nil
                engine.placeGoat(p)
                afterGoatTurn()
                return
            }
            // Movement.
            if let s = selected {
                if p == s {
                    selected = nil; dests = []
                    return
                }
                if dests.contains(p) {
                    hint = nil
                    engine.moveGoat(BaghGoatMove(src: s, dst: p))
                    selected = nil; dests = []
                    afterGoatTurn()
                    return
                }
            }
            if engine.board[p] == .goat {
                selected = p
                dests = engine.goatMoves().filter { $0.src == p }.map(\.dst)
            } else {
                selected = nil; dests = []
            }
        } else if twoPlayer {
            // 2-player: the human tiger plays by tapping. The move is
            // looked up in the engine's legal list so capture info is
            // always right.
            if let s = selected,
               let m = engine.tigerMoves().first(where: { $0.src == s && $0.dst == p }) {
                hint = nil
                engine.moveTiger(m)
                selected = nil; dests = []
                music.setLevel(currentLevel())
                if checkDone() { return }
                afterTigerTurn()
                return
            }
            if engine.board[p] == .tiger {
                selected = p
                dests = engine.tigerMoves().filter { $0.src == p }.map(\.dst)
                hint = nil
            } else {
                selected = nil; dests = []
            }
        }
    }

    /// 2-player only: after the human tiger moves, goats with no legal
    /// move must pass — so it stays the tigers' turn.
    private func afterTigerTurn() {
        guard twoPlayer else { return }
        if engine.goatsInHand == 0, engine.goatMoves().isEmpty, result == .playing {
            passNotice = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                passNotice = false
                engine.passGoats()
                _ = checkDone()
            }
        }
    }

    /// After the kid's turn: check the result, then let the tiger play.
    /// In 2-player the human tiger moves by tapping — no AI.
    private func afterGoatTurn() {
        music.setLevel(currentLevel())
        if checkDone() { return }
        guard !twoPlayer else { return }
        tigerThinking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard let m = tigerAIMove(engine) else {
                // No tiger moves: the kid wins by trapping.
                tigerThinking = false
                _ = checkDone()
                return
            }
            engine.moveTiger(m)
            tigerThinking = false
            music.setLevel(currentLevel())
            if checkDone() { return }
            // Goats squeezed with no move: they pass, tigers go again.
            if engine.goatsInHand == 0, engine.goatMoves().isEmpty {
                passNotice = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    passNotice = false
                    engine.passGoats()
                    if !checkDone() { afterGoatTurn() }
                }
            }
        }
    }

    /// Returns true when the game is over (pays XP once).
    @discardableResult
    private func checkDone() -> Bool {
        let o = engine.outcome()
        guard o != .playing else { return false }
        result = o
        phase = .done
        music.playStinger(win: o == .goatsWin)
        // XP: win 10, finish 2 — max 3 paid games a day.
        // 2-player is just for fun: no XP, so nobody farms the board
        // with a friend as a punching bag.
        if !twoPlayer {
            let today = Streak.todayString
            if paidDay != today { paidDay = today; paidCount = 0 }
            if paidCount < maxPaidPerDay {
                paidCount += 1
                xpEarned = (o == .goatsWin) ? 10 : 2
                totalXP += xpEarned
            }
        }
        if o == .goatsWin {
            WinFanfare.play()
            lastWin = twoPlayer ? "Bagh-Chal (2-player): goats win! 🐐"
                                : "Bagh-Chal: trapped the tigers! 🐯"
        } else {
            lastWin = twoPlayer ? "Bagh-Chal (2-player): tigers win! 🐯"
                                : "Bagh-Chal finished"
        }
        return true
    }
}

// MARK: - Adaptive game music

/// Tiny deterministic RNG so a composed loop is stable per render.
private struct SeededRNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    mutating func nextDouble() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func nextInt(_ n: Int) -> Int { n > 0 ? Int(nextDouble() * Double(n)) % n : 0 }
}

/// Procedurally synthesized background music — no bundled audio files,
/// in the same spirit as the balloon pop and the rhyme beds. A
/// folk-flavored scale (Sa Re Ga tivra-Ma Pa Dha — the bright color of
/// Nepali folk melodies) over a soft drone, composed as an 8-bar loop.
///
/// Playback is deliberately the simplest path on iOS: the loop is
/// rendered to samples, written to a temp WAV, and played with
/// AVAudioPlayer. (An earlier AVAudioEngine + player-node version never
/// produced sound on the device for reasons the silent `try?` hid, so
/// failures now surface in `statusLine`, shown red in the game.)
/// Four intensity levels swap the loop as the game heats up: tempo,
/// note density, and drums all follow.
final class BaghChalMusic: ObservableObject {
    @Published var statusLine = ""

    private var loopPlayer: AVAudioPlayer?
    private var stingerPlayer: AVAudioPlayer?
    private var tempFiles: [URL] = []
    private var currentLevel = -1
    private var genToken = 0
    private let sr = 44100.0

    var isMuted = false { didSet {
        loopPlayer?.volume = isMuted ? 0 : 0.9
        stingerPlayer?.volume = isMuted ? 0 : 0.9
    } }

    /// Semitone steps for scale degrees 0...6 (Sa, Re, Ga, #Ma, Pa, Dha, Sa').
    private let scale = [0, 2, 4, 6, 7, 9, 12]
    private let rootFreq = 261.63 // C4

    func start(level: Int) {
        currentLevel = -1
        setLevel(level, force: true)
    }

    func stop() {
        genToken += 1
        loopPlayer?.stop(); loopPlayer = nil
        stingerPlayer?.stop(); stingerPlayer = nil
        currentLevel = -1
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
    }

    /// Swaps the loop when the level actually changes — safe to call
    /// after every move.
    func setLevel(_ level: Int) { setLevel(level, force: false) }

    private func setLevel(_ level: Int, force: Bool) {
        guard force || level != currentLevel else { return }
        currentLevel = level
        genToken += 1
        let token = genToken
        let seed = UInt64(0xBA64 + level * 7919 + Int.random(in: 0..<100_000))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let samples = self.composeLoop(level: level, seed: seed)
            guard let url = self.writeWAV(samples) else {
                DispatchQueue.main.async {
                    if self.genToken == token { self.statusLine = "music: couldn't write temp file" }
                }
                return
            }
            // Create and start the player off the main thread:
            // play() activates the audio session synchronously, which
            // Xcode flags if it happens on the main thread.
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.numberOfLoops = -1
                p.volume = self.isMuted ? 0 : 0.9
                p.prepareToPlay()
                guard p.play() else {
                    DispatchQueue.main.async {
                        if self.genToken == token {
                            self.statusLine = "music: play() refused — session \(AVAudioSession.sharedInstance().category.rawValue)"
                        }
                    }
                    return
                }
                DispatchQueue.main.async {
                    self.tempFiles.append(url)
                    guard self.genToken == token else { p.stop(); return }
                    let old = self.loopPlayer
                    self.loopPlayer = p
                    if let old {
                        old.setVolume(0, fadeDuration: 0.25)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { old.stop() }
                    }
                    self.statusLine = ""
                }
            } catch {
                DispatchQueue.main.async {
                    if self.genToken == token { self.statusLine = "music failed: \(error.localizedDescription)" }
                }
            }
        }
    }

    func playStinger(win: Bool) {
        genToken += 1
        if let old = loopPlayer {
            old.setVolume(0, fadeDuration: 0.4)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { old.stop() }
            loopPlayer = nil
        }
        currentLevel = -1
        let notes: [(degree: Int, beat: Double)] =
            win ? [(0, 0), (1, 0.5), (2, 1.0), (4, 1.5), (6, 2.25)]
                : [(4, 0), (2, 0.6), (0, 1.2)]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var samples = [Float](repeating: 0, count: Int(self.sr * 3.2))
            for n in notes {
                self.addPluck(into: &samples, freq: self.freq(degree: n.degree),
                              atBeat: n.beat, bpm: 120, amp: 0.5, decay: 2.2)
            }
            guard let url = self.writeWAV(samples) else { return }
            // Player created and started here on the background queue —
            // play() on the main thread trips Xcode's purple warning.
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.volume = self.isMuted ? 0 : 0.9
                p.play()
                DispatchQueue.main.async {
                    self.tempFiles.append(url)
                    self.stingerPlayer = p
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusLine = "music failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func freq(degree: Int) -> Double {
        let semis = scale[max(0, min(scale.count - 1, degree))]
        return rootFreq * pow(2.0, Double(semis) / 12.0)
    }

    /// Compose one seamless 8-bar loop at the level's tempo and density.
    private func composeLoop(level: Int, seed: UInt64) -> [Float] {
        var rng = SeededRNG(state: seed == 0 ? 1 : seed)
        let bpm: Double = [84, 100, 120, 140][level]
        let bars = 8
        let totalBeats = Double(bars) * 4
        var samples = [Float](repeating: 0,
                              count: Int(sr * totalBeats * 60 / bpm) + Int(sr))

        // Drone: soft root + fifth under everything, breathing slowly.
        // Level 3 adds a low F# pedal against the C drone — a tritone rub
        // that adds genuine menace you can hear on a phone speaker.
        addDrone(into: &samples, amp: 0.08)
        if level >= 3 {
            addPedal(into: &samples, freq: rootFreq / 2 * pow(2, 6.0 / 12), amp: 0.05)
        }

        // Bass. Calm levels pluck beats 1 & 3; hot levels drive eighth
        // notes (root root FIFTH root…) for momentum.
        if level <= 1 {
            for bar in 0..<bars {
                for beatInBar in [0.0, 2.0] {
                    let deg = (bar % 2 == 0) ? 0 : 4
                    addPluck(into: &samples, freq: freq(degree: deg) / 2,
                             atBeat: Double(bar) * 4 + beatInBar, bpm: bpm,
                             amp: 0.34, decay: 3.0, brightness: 0.35)
                }
            }
        } else {
            for bar in 0..<bars {
                for e in 0..<8 {
                    let beat = Double(bar) * 4 + Double(e) * 0.5
                    let deg = (e % 4 == 2) ? 4 : 0
                    addPluck(into: &samples, freq: freq(degree: deg) / 2,
                             atBeat: beat, bpm: bpm,
                             amp: e % 2 == 0 ? 0.30 : 0.20,
                             decay: 5.0, brightness: 0.3)
                }
            }
        }

        // Melody. Calm levels: a gentle walk in a warmer (less music-box)
        // tone. Level 2: sparse half notes. Level 3: the wander stops —
        // a short 3-note cell hammered in repetition, which reads as
        // urgency instead of cheer.
        var degree = 0
        switch level {
        case 0, 1:
            let rhythm: [Double] = level == 0 ? [0, 2] : [0, 1, 2, 3]
            let restChance = level == 0 ? 0.30 : 0.15
            for bar in 0..<bars {
                for (i, beat) in rhythm.enumerated() {
                    if bar == bars - 1, i == rhythm.count - 1 { degree = 0 } // home to Sa
                    if rng.nextDouble() >= restChance {
                        addPluck(into: &samples, freq: freq(degree: degree),
                                 atBeat: Double(bar) * 4 + beat, bpm: bpm,
                                 amp: 0.44, decay: 4.0, brightness: 0.45)
                    }
                    degree += [-2, -1, -1, 0, 1, 1, 2][rng.nextInt(7)]
                    degree = max(0, min(scale.count - 1, degree))
                }
            }
        case 2:
            for bar in 0..<bars {
                for (i, beat) in [0.0, 2.0].enumerated() {
                    if bar == bars - 1, i == 1 { degree = 0 }
                    addPluck(into: &samples, freq: freq(degree: degree),
                             atBeat: Double(bar) * 4 + beat, bpm: bpm,
                             amp: 0.40, decay: 3.5, brightness: 0.3)
                    degree += [-2, -1, 1, 2][rng.nextInt(4)]
                    degree = max(0, min(scale.count - 1, degree))
                }
            }
        default:
            let top = 3 + rng.nextInt(2) // 3 or 4
            let cell = [top, top - 1, top - 2]
            for bar in 0..<bars {
                for (i, beat) in [0.0, 0.5, 1.0, 2.0, 2.5, 3.0].enumerated() {
                    addPluck(into: &samples, freq: freq(degree: cell[i % 3]),
                             atBeat: Double(bar) * 4 + beat, bpm: bpm,
                             amp: 0.42, decay: 6.0, brightness: 0.35)
                }
            }
        }

        // Drums. A phone speaker can't reproduce sub-bass, so the audible
        // drum is a midrange thump with an attack click; the low kick
        // rides under it for body on real speakers. Level 3: thumps on
        // every eighth note — driving, unmistakable.
        if level >= 1 {
            let pattern: [Double] = level >= 3 ? [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5]
                : level == 2 ? [0, 1, 2, 3] : [0, 2]
            for bar in 0..<bars {
                for beatInBar in pattern {
                    let beat = Double(bar) * 4 + beatInBar
                    let accent = beatInBar.truncatingRemainder(dividingBy: 1) == 0
                    addThump(into: &samples, atBeat: beat, bpm: bpm,
                             amp: level >= 3 ? (accent ? 0.55 : 0.38)
                                  : level == 2 ? 0.5 : 0.32)
                    if level >= 2 {
                        addKick(into: &samples, atBeat: beat, bpm: bpm,
                                amp: accent ? 0.4 : 0.25)
                    }
                }
            }
        }
        if level >= 2 {
            let hatStep = level >= 3 ? 0.25 : 0.5
            var b = 0.0
            while b < totalBeats {
                let accent = b.truncatingRemainder(dividingBy: 1) == 0
                addHat(into: &samples, atBeat: b, bpm: bpm,
                       amp: accent ? 0.16 : 0.10)
                b += hatStep
            }
        }

        // Normalize: every level uses the full dynamic range, so the hot
        // loops are as loud as the calm ones — intensity comes from
        // tempo, rhythm, and tone, not just volume.
        var peak: Float = 0.0001
        for s in samples { let a = abs(s); if a > peak { peak = a } }
        let g = 0.89 / peak
        for i in 0..<samples.count { samples[i] *= g }

        // Tiny fades at the seam so the loop restarts without a click.
        let fade = Int(sr * 0.05)
        if samples.count > fade * 2 {
            for i in 0..<fade {
                let w = Float(Double(i) / Double(fade))
                samples[i] *= w
                samples[samples.count - 1 - i] *= w
            }
        }
        return samples
    }

    private func addPluck(into samples: inout [Float], freq: Double,
                          atBeat: Double, bpm: Double, amp: Double, decay: Double,
                          brightness: Double = 0.5) {
        let start = Int(atBeat * 60 / bpm * sr)
        guard start < samples.count else { return }
        let frames = Int(sr * 1.2)
        for i in 0..<frames {
            let idx = start + i
            if idx >= samples.count { break }
            let t = Double(i) / sr
            let env = exp(-t * decay * 2)
            // Brightness scales the upper harmonics: lower = warmer,
            // less music-box; the hot levels run darker on purpose.
            let v = sin(2 * .pi * freq * t)
                  + brightness * 0.5 * sin(4 * .pi * freq * t)
                  + brightness * 0.22 * sin(6 * .pi * freq * t)
            samples[idx] += Float(v * env * amp)
        }
    }

    private func addDrone(into samples: inout [Float], amp: Double) {
        let root = rootFreq / 2
        let fifth = root * pow(2, 7.0 / 12)
        for i in 0..<samples.count {
            let t = Double(i) / sr
            let v = sin(2 * .pi * root * t)
                  + 0.6 * sin(2 * .pi * fifth * t)
                  + 0.3 * sin(2 * .pi * root * 2 * t)
            let swell = 0.85 + 0.15 * sin(2 * .pi * 0.07 * t)
            samples[i] += Float(v * amp * swell)
        }
    }

    /// A sustained tone with a slow tremolo — level 3's tritone pedal.
    private func addPedal(into samples: inout [Float], freq: Double, amp: Double) {
        for i in 0..<samples.count {
            let t = Double(i) / sr
            let trem = 0.7 + 0.3 * sin(2 * .pi * 2.2 * t)
            samples[i] += Float(sin(2 * .pi * freq * t) * amp * trem)
        }
    }

    /// The drum a phone speaker can actually play: a midrange body
    /// (420/211 Hz) plus a sharp attack click. Sub-bass alone is silent
    /// on small speakers — that's why the first version's "drums" were
    /// never heard.
    private func addThump(into samples: inout [Float], atBeat: Double,
                          bpm: Double, amp: Double) {
        let start = Int(atBeat * 60 / bpm * sr)
        let frames = Int(sr * 0.25)
        var s: UInt64 = (UInt64(max(0, start)) &* 40503) &+ 7
        for i in 0..<frames {
            let idx = start + i
            if idx >= samples.count { break }
            let t = Double(i) / sr
            let body = sin(2 * .pi * 420 * t) * exp(-t * 16)
                     + 0.7 * sin(2 * .pi * 211 * t) * exp(-t * 12)
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let click = Double(Int64(bitPattern: s) % 1000) / 1000.0 * exp(-t * 220)
            samples[idx] += Float((body * 0.8 + click * 0.5) * amp)
        }
    }

    private func addKick(into samples: inout [Float], atBeat: Double,
                         bpm: Double, amp: Double) {
        let start = Int(atBeat * 60 / bpm * sr)
        let frames = Int(sr * 0.22)
        var s: UInt64 = (UInt64(max(0, start)) &* 99991) &+ 13
        for i in 0..<frames {
            let idx = start + i
            if idx >= samples.count { break }
            let t = Double(i) / sr
            let f = 55 + 95 * exp(-t * 28)
            let body = sin(2 * .pi * f * t) * exp(-t * 20)
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let click = Double(Int64(bitPattern: s) % 1000) / 1000.0 * exp(-t * 260)
            samples[idx] += Float((body + click * 0.6) * amp)
        }
    }

    private func addHat(into samples: inout [Float], atBeat: Double,
                        bpm: Double, amp: Double) {
        let start = Int(atBeat * 60 / bpm * sr)
        let frames = Int(sr * 0.05)
        var s: UInt64 = (UInt64(max(0, start)) &* 2654435761) &+ 97
        for i in 0..<frames {
            let idx = start + i
            if idx >= samples.count { break }
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(Int64(bitPattern: s) % 1000) / 1000.0
            samples[idx] += Float(noise * exp(-Double(i) / sr * 160) * amp)
        }
    }

    /// Write samples as a 16-bit PCM WAV (hand-rolled header — no
    /// AVFoundation file machinery involved).
    private func writeWAV(_ samples: [Float]) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("baghchal-\(UUID().uuidString).wav")
        var data = Data()
        data.reserveCapacity(44 + samples.count * 2)
        func appendU32(_ v: UInt32) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }
        func appendU16(_ v: UInt16) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        appendU32(UInt32(36 + samples.count * 2))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendU32(16)
        appendU16(1)                       // PCM
        appendU16(1)                       // mono
        appendU32(UInt32(sr))
        appendU32(UInt32(sr) * 2)          // byte rate
        appendU16(2)                       // block align
        appendU16(16)                      // bits per sample
        data.append(contentsOf: "data".utf8)
        appendU32(UInt32(samples.count * 2))
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            appendU16(UInt16(bitPattern: v))
        }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - Rules narration

/// Plays the bundled Nepali rules narration (baghchal_rules.m4a, Som's
/// voice clone) from the game's start card. Toggle-style: tap to play,
/// tap again to stop; flips back on its own when the clip ends.
final class RulesNarrator: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    private var player: AVAudioPlayer?

    func toggle() {
        if isPlaying { stop() } else { play() }
    }

    func play() {
        guard let url = Bundle.main.url(forResource: "baghchal_rules",
                                        withExtension: "m4a",
                                        subdirectory: "Content/audio/nepal-v1")
        else { return }
        // Create and start off the main thread: play() activates the
        // audio session synchronously (Xcode's purple warning).
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                if p.play() {
                    DispatchQueue.main.async {
                        self.player = p
                        self.isPlaying = true
                    }
                }
            } catch { /* stays stopped */ }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        isPlaying = false
    }
}
