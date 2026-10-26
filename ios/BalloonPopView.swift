import SwiftUI
import UIKit
import AVFoundation

// MARK: - Synthesized balloon pop sound

/// A short balloon pop, synthesized with AVAudioEngine — no audio file needed.
enum PopSound {
    private static var engine: AVAudioEngine?
    private static var player: AVAudioPlayerNode?
    private static let lock = NSLock()

    private static func setupIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard engine == nil else { return }
        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        e.attach(p)
        // Explicit mono format: the scheduled buffer is mono, and the
        // mixer must agree on the channel count or it throws.
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        e.connect(p, to: e.mainMixerNode, format: format)
        try? e.start()
        engine = e
        player = p
    }

    static func play() {
        setupIfNeeded()
        guard let player else { return }
        let sampleRate = 44100.0
        let duration = 0.14
        let frames = Int(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = buffer.floatChannelData![0]
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let p = t / duration
            // pitch drops 700 -> 180 Hz, amplitude decays hard = "pop!"
            let freq = 700.0 * pow(180.0 / 700.0, p)
            let env = exp(-p * 14.0)
            // a little click at the very start
            let click = p < 0.08 ? (Double.random(in: -1...1) * (1 - p / 0.08)) : 0
            data[i] = Float((sin(2 * .pi * freq * t) * env * 0.7) + click * 0.25)
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
        // a physical pop feel to go with the sound
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

// MARK: - Models

struct PopBalloon: Identifiable {
    let id = UUID()
    var word: Word
    var x: Double        // 0-1 across the screen
    var y: Double        // 0-1; 1.15 = below, -0.25 = gone above
    var speed: Double    // y units per second
    var color: Color
    var wobbling = false
}

struct PopParticle: Identifiable {
    let id = UUID()
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var life: Double     // 1 -> 0
    var color: Color
}

// MARK: - Balloon Pop game

/// Hear the Nepali word, pop the balloon showing it. 60-second rounds,
/// +2 XP per pop. The "reward game" after missions and lessons.
struct BalloonPopView: View {
    let words: [Word]

    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.balloon.best") private var bestScore = 0
    @Environment(\.dismiss) private var dismiss

    enum Phase { case ready, playing, done }
    @State private var phase: Phase = .ready
    @State private var balloons: [PopBalloon] = []
    @State private var particles: [PopParticle] = []
    @State private var target: Word?
    @State private var score = 0
    @State private var xpEarned = 0
    /// Wrong-tap penalty (Som's call 2026-10-19, after his cousin gamed
    /// the game by mashing every balloon): a wrong tap costs 3 seconds
    /// and drops the current target's pop from +2 XP to +1.
    @State private var targetMissed = false
    @State private var penaltyFlash = false
    @State private var timeLeft = 60
    @State private var secondsSinceTarget = 0
    @State private var audioPlayer: AVPlayer?
    @State private var tickTimer: Timer?
    @State private var secondTimer: Timer?

    private let roundSeconds = 60
    private let xpPerPop = 2
    private let balloonColors: [Color] = [.red, .blue, .green, .orange, .purple, .pink]

    /// Only words with pictures — the game is hear-it, find-the-picture.
    private var playable: [Word] {
        words.filter { $0.image != nil }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                skyBackground
                if phase == .ready {
                    readyView
                } else if phase == .playing {
                    gameView
                } else {
                    doneView
                }
            }
            .navigationTitle("Balloon Pop 🎈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { stopTimers(); dismiss() }
                }
            }
            .onDisappear { stopTimers() }
        }
    }

    // MARK: - Screens

    private var skyBackground: some View {
        LinearGradient(colors: [.cyan.opacity(0.25), .blue.opacity(0.12)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    private var readyView: some View {
        VStack(spacing: 20) {
            Text("🎈")
                .font(.system(size: 90))
            Text("Hear the word.\nPop its balloon!")
                .font(.title2).bold()
                .multilineTextAlignment(.center)
            Text("Wrong pops cost 3 seconds! ⏱")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if bestScore > 0 {
                Text("Best: \(bestScore) pops")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Button("Start!") { startGame() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .font(.title3)
        }
        .padding()
    }

    private var gameView: some View {
        VStack(spacing: 0) {
            hudRow
            GeometryReader { geo in
                ZStack {
                    ForEach(balloons) { balloon in
                        balloonView(balloon)
                            .position(x: balloon.x * geo.size.width,
                                      y: balloon.y * geo.size.height)
                            .onTapGesture { tapBalloon(balloon) }
                    }
                    ForEach(particles) { p in
                        Circle()
                            .fill(p.color)
                            .frame(width: 10, height: 10)
                            .opacity(p.life)
                            .position(x: p.x * geo.size.width,
                                      y: p.y * geo.size.height)
                    }
                }
                // Flatten the playfield into one layer — much cheaper to
                // re-render every frame than dozens of separate views.
                .drawingGroup()
            }
            replayRow
        }
    }

    private var hudRow: some View {
        HStack {
            Text("🎈 \(score)")
                .font(.title2).bold()
            Spacer()
            if let t = target {
                Text("Pop: \(t.devanagari)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("⏱ \(timeLeft)")
                .font(.title2).bold()
                .foregroundStyle(penaltyFlash || timeLeft <= 10 ? .red : .primary)
            if penaltyFlash {
                Text("-3s")
                    .font(.headline).bold()
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var replayRow: some View {
        Button(action: playTarget) {
            Label("Hear it again", systemImage: "speaker.wave.2.fill")
        }
        .buttonStyle(.bordered)
        .padding(.bottom, 8)
    }

    private var doneView: some View {
        VStack(spacing: 16) {
            Text("⏰ Time's up!")
                .font(.largeTitle).bold()
            Text("🎈 \(score) pops")
                .font(.title)
            if score >= bestScore && score > 0 {
                Text("New best! 🏆")
                    .font(.headline)
                    .foregroundStyle(.orange)
            } else if bestScore > 0 {
                Text("Best: \(bestScore)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("+\(xpEarned) XP")
                .font(.headline)
                .foregroundStyle(.green)
            HStack(spacing: 16) {
                Button("Play again") { startGame() }
                    .buttonStyle(.borderedProminent)
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
    }

    // MARK: - Balloon rendering

    private func balloonView(_ balloon: PopBalloon) -> some View {
        VStack(spacing: 0) {
            ZStack {
                // the balloon body
                Ellipse()
                    .fill(balloon.color)
                    .frame(width: 104, height: 128)
                    .shadow(radius: 3)
                // shine
                Ellipse()
                    .fill(.white.opacity(0.35))
                    .frame(width: 22, height: 34)
                    .offset(x: -24, y: -30)
                    .rotationEffect(.degrees(-20))
                // picture (when it loads) + the word, ALWAYS —
                // the word must never be invisible.
                VStack(spacing: 4) {
                    balloonPicture(balloon.word)
                    Text(balloon.word.devanagari)
                        .font(.headline).bold()
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 90)
                        .shadow(radius: 2)
                }
            }
            // knot + string
            BalloonKnot()
                .fill(balloon.color)
                .frame(width: 14, height: 10)
                .offset(y: -2)
            Rectangle()
                .fill(.gray.opacity(0.6))
                .frame(width: 2, height: 44)
        }
        .rotationEffect(.degrees(balloon.wobbling ? 12 : 0))
        .animation(.easeInOut(duration: 0.12), value: balloon.wobbling)
    }

    @ViewBuilder
    private func balloonPicture(_ word: Word) -> some View {
        if let imagePath = word.image,
           let url = URL(string: GharAPI.baseURLString + imagePath) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    // Still loading or failed — the devanagari below
                    // always identifies the balloon, so this stays empty.
                    Color.clear
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 2))
        }
    }

    // MARK: - Game logic

    private func startGame() {
        score = 0
        xpEarned = 0
        timeLeft = roundSeconds
        particles = []
        balloons = []
        for _ in 0..<4 { spawnBalloon(initial: true) }
        phase = .playing
        newTarget()
        startTimers()
    }

    private func endGame() {
        stopTimers()
        if score > bestScore { bestScore = score }
        phase = .done
        WinFanfare.play()
    }

    private func newTarget() {
        guard !playable.isEmpty else { return }
        var pick = playable.randomElement()!
        if let t = target, playable.count > 1 {
            while pick.id == t.id { pick = playable.randomElement()! }
        }
        target = pick
        targetMissed = false
        secondsSinceTarget = 0
        ensureTargetVisible()
        playTarget()
    }

    /// The target word must ALWAYS be on screen. Balloons float off the
    /// top and get replaced with random words, so re-plant the target
    /// onto a random balloon whenever it's missing.
    private func ensureTargetVisible() {
        guard let t = target, !balloons.isEmpty else { return }
        if !balloons.contains(where: { $0.word.id == t.id }),
           let i = balloons.indices.randomElement() {
            balloons[i].word = t
        }
    }

    private func playTarget() {
        guard let t = target else { return }
        if t.hasAudio == true, let url = URL(string: GharAPI.baseURLString + t.audioUrl) {
            audioPlayer?.pause() // fast pops: don't stack word clips
            audioPlayer = AVPlayer(url: url)
            audioPlayer?.play()
        } else {
            NepaliSpeaker.say(nepali: t.devanagari, romanized: t.romanized)
        }
    }

    private func spawnBalloon(initial: Bool) {
        guard !playable.isEmpty else { return }
        let word = playable.randomElement()!
        balloons.append(PopBalloon(
            word: word,
            x: Double.random(in: 0.12...0.88),
            y: initial ? Double.random(in: 0.15...0.95) : 1.15,
            speed: Double.random(in: 0.10...0.20),
            color: balloonColors.randomElement()!
        ))
    }

    private func tapBalloon(_ balloon: PopBalloon) {
        guard phase == .playing, let t = target else { return }
        guard let i = balloons.firstIndex(where: { $0.id == balloon.id }) else { return }
        if balloon.word.id == t.id {
            // POP!
            popBalloon(at: i)
        } else {
            // Wrong one: -3 seconds, and the current target now pays
            // half XP. Mashing every balloon has to LOSE, not win.
            targetMissed = true
            timeLeft = max(0, timeLeft - 3)
            penaltyFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { penaltyFlash = false }
            if timeLeft <= 0 { endGame(); return }
            // wobble it
            balloons[i].wobbling = true
            let id = balloon.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if let j = balloons.firstIndex(where: { $0.id == id }) {
                    balloons[j].wobbling = false
                }
            }
        }
    }

    private func popBalloon(at i: Int) {
        let balloon = balloons[i]
        PopSound.play()
        // burst particles
        for _ in 0..<10 {
            let angle = Double.random(in: 0...(2 * .pi))
            let speed = Double.random(in: 0.15...0.45)
            particles.append(PopParticle(
                x: balloon.x, y: balloon.y,
                vx: cos(angle) * speed, vy: sin(angle) * speed,
                life: 1.0, color: balloon.color
            ))
        }
        score += 1
        let xp = targetMissed ? 1 : xpPerPop
        xpEarned += xp
        totalXP += xp
        balloons.remove(at: i)
        spawnBalloon(initial: false)
        newTarget()
    }

    // MARK: - Timers

    private func startTimers() {
        stopTimers()
        // 10fps is plenty for slow-floating balloons — 20fps just burned CPU.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in tick() }
        secondTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            timeLeft -= 1
            // Haven't popped it? The word repeats itself every 6 seconds
            // until you get it — no getting stuck.
            secondsSinceTarget += 1
            if secondsSinceTarget >= 6 {
                secondsSinceTarget = 0
                playTarget()
            }
            if timeLeft <= 0 { endGame() }
        }
    }

    private func stopTimers() {
        tickTimer?.invalidate(); tickTimer = nil
        secondTimer?.invalidate(); secondTimer = nil
    }

    private func tick() {
        guard phase == .playing else { return }
        let dt = 0.1
        // float balloons up
        for i in balloons.indices {
            balloons[i].y -= balloons[i].speed * dt
        }
        balloons.removeAll(where: { $0.y < -0.25 })
        while balloons.count < 4 { spawnBalloon(initial: false) }
        ensureTargetVisible()
        // fly particles
        for i in particles.indices {
            particles[i].x += particles[i].vx * dt
            particles[i].y += particles[i].vy * dt
            particles[i].vy += 0.6 * dt   // slight gravity
            particles[i].life -= dt * 2.2
        }
        particles.removeAll(where: { $0.life <= 0 })
    }
}

// MARK: - BalloonKnot (the little triangle under the balloon)

struct BalloonKnot: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
