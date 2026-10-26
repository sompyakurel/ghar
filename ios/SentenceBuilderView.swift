import SwiftUI
import AVFoundation

// MARK: - Sentence Builder · Lesson 2: "Doing Things"
//
// The kid ASSEMBLES real sentences: म ___ ___छु। ("ma ___ ___chhu" —
// "I ___ ___"). Verbs go LAST in Nepali, and the game teaches that by
// doing: tap the word tiles in order to build the sentence.
//
// 16 sentences in 2 rounds of 8. +5 XP per correct sentence.

struct SentenceBuilderView: View {
    let words: [Word]

    @AppStorage("ghar.xp.total") private var totalXP = 0
    @State private var roundIndex = 0
    @State private var phase: Phase = .build
    @State private var sentenceIndex = 0
    @State private var placedIDs: [String] = []
    @State private var poolIDs: [String] = []
    @State private var shakeToken = 0
    @State private var correctCount = 0
    @State private var roundCorrect = 0
    // Anti-mash (Som's call 2026-10-19): wrong word orders don't pay
    // the full +5. attempts > 0 at solve time drops the sentence to +2.
    @State private var attempts = 0
    // Actual XP paid (missed sentences pay 2, not 5) — the summary
    // screens show these, not correctCount * 5.
    @State private var roundEarnedXP = 0
    @State private var totalEarnedXP = 0
    // This run's rounds, sentence order shuffled (set in startRound).
    @State private var sessionRounds: [[BuilderSentence]] = []

    enum Phase { case build, roundDone, allDone }

    private var rounds: [[BuilderSentence]] { sessionRounds.isEmpty ? BuilderSentences.rounds : sessionRounds }
    private var round: [BuilderSentence] { rounds[roundIndex] }
    private var sentence: BuilderSentence { round[sentenceIndex] }

    private var byID: [String: Word] {
        Dictionary(words.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .build: buildView
            case .roundDone: roundDoneView
            case .allDone: allDoneView
            }
        }
        .navigationTitle("Sentence Builder")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .onAppear { startRound() }
    }

    // MARK: - Build phase

    private var buildView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("🧱 Round \(roundIndex + 1)")
                    .font(.headline)
                Spacer()
                Text("\(sentenceIndex + 1) / \(round.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()

            ProgressView(value: Double(sentenceIndex), total: Double(round.count))
                .padding(.horizontal)

            Spacer().frame(height: 20)

            // Prompt: what to say
            VStack(spacing: 8) {
                Text(sentence.emoji)
                    .font(.system(size: 64))
                Text(sentence.english)
                    .font(.title3).bold()
                Text("Tap the words in order")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Visible stakes (Som's ask 2026-10-19): the kid SEES the
                // value drop the moment a miss lands — +5 clean, +2 after.
                Text(attempts == 0 ? "⭐ +5 XP" : "😅 +2 XP now")
                    .font(.subheadline)
                    .foregroundStyle(attempts == 0 ? .green : .orange)
            }

            Spacer().frame(height: 24)

            // Answer row: placed tiles
            HStack(spacing: 8) {
                ForEach(placedIDs, id: \.self) { id in
                    if let word = byID[id] {
                        Button { unplace(id) } label: {
                            Text(word.devanagari)
                                .font(.title2).bold()
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.green.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .stroke(.green.opacity(0.5), lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if placedIDs.isEmpty {
                    Text("___ ___ ___।")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                } else if placedIDs.count == sentence.wordIDs.count {
                    Text("।").font(.title2).bold()
                }
            }
            .frame(minHeight: 60)
            .modifier(ShakeEffect(shakes: shakeToken))

            Spacer().frame(height: 20)

            // Tile pool
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 12) {
                ForEach(poolIDs, id: \.self) { id in
                    if let word = byID[id] {
                        Button { place(id) } label: {
                            VStack(spacing: 2) {
                                Text(word.devanagari)
                                    .font(.title3).bold()
                                Text(word.romanized)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.systemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shadow(color: .black.opacity(0.06), radius: 3, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)

            Spacer()
        }
    }

    private var roundDoneView: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("🎉").font(.system(size: 72))
            Text("Round \(roundIndex + 1) done!")
                .font(.title).bold()
            Text("+\(roundEarnedXP) XP · \(roundCorrect)/\(round.count) correct")
                .font(.headline)
                .foregroundStyle(.secondary)
            if roundIndex + 1 < rounds.count {
                Button("Next round →") {
                    roundIndex += 1
                    startRound()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button("Finish") { phase = .allDone }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            Spacer()
        }
        .padding()
    }

    private var allDoneView: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("🏆").font(.system(size: 72))
            Text("Sentence builder!")
                .font(.title).bold()
            Text("+\(totalEarnedXP) XP · \(correctCount)/\(rounds.flatMap { $0 }.count) sentences built")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("म ___ ___छु। — you can say what you DO in Nepali now.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Play again") {
                roundIndex = 0
                correctCount = 0
                totalEarnedXP = 0
                startRound()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .padding()
    }

    // MARK: - Game logic

    private func startRound() {
        // Fresh shuffle of both rounds on every run — the sentences
        // used to arrive in the same order every time (Som,
        // 2026-10-23). The word tiles were already shuffled.
        sessionRounds = BuilderSentences.rounds.map { $0.shuffled() }
        sentenceIndex = 0
        roundCorrect = 0
        roundEarnedXP = 0
        phase = .build
        dealSentence()
    }

    private func dealSentence() {
        placedIDs = []
        attempts = 0
        poolIDs = sentence.wordIDs.shuffled()
    }

    private func place(_ id: String) {
        placedIDs.append(id)
        poolIDs.removeAll { $0 == id }
        if placedIDs.count == sentence.wordIDs.count {
            checkAnswer()
        }
    }

    private func unplace(_ id: String) {
        placedIDs.removeAll { $0 == id }
        poolIDs.append(id)
    }

    private func checkAnswer() {
        if placedIDs == sentence.wordIDs {
            correctCount += 1
            roundCorrect += 1
            let earned = attempts == 0 ? 5 : 2
            totalXP += earned
            roundEarnedXP += earned
            totalEarnedXP += earned
            QuizStats.recordCorrect()
            CorrectDing.play()  // synthesized ding — no spoken praise, ignores silent switch
            playFullSentence()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                nextSentence()
            }
        } else {
            attempts += 1
            QuizStats.recordWrong()
            WrongAnswerFeedback.play()
            shakeToken += 1
            // Return tiles to the pool after the shake.
            let wrong = placedIDs
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                placedIDs = []
                poolIDs = (poolIDs + wrong).shuffled()
            }
        }
    }

    private func nextSentence() {
        if sentenceIndex + 1 < round.count {
            sentenceIndex += 1
            dealSentence()
        } else {
            phase = .roundDone
        }
    }

    @State private var queuePlayer: AVQueuePlayer?

    private func playFullSentence() {
        let words = sentence.wordIDs.compactMap { byID[$0] }
        let items = words.compactMap { word -> AVPlayerItem? in
            guard word.hasAudio == true,
                  let url = URL(string: GharAPI.baseURLString + word.audioUrl) else { return nil }
            return AVPlayerItem(url: url)
        }
        if items.count == words.count, !items.isEmpty {
            // Every word has a cloned clip — play them in order, no TTS.
            let qp = AVQueuePlayer(items: items)
            queuePlayer = qp
            qp.play()
        } else {
            // Fallback: TTS only if a clip is missing.
            let nepali = words.map { $0.devanagari }.joined(separator: " ") + "।"
            let romanized = words.map { $0.romanized }.joined(separator: " ") + "."
            NepaliSpeaker.say(nepali: nepali, romanized: romanized)
        }
    }
}

// MARK: - Content

/// One sentence to build: English prompt + word IDs in correct order.
struct BuilderSentence {
    let english: String
    let emoji: String
    let wordIDs: [String]
}

enum BuilderSentences {
    /// 16 sentences, 2 rounds of 8. Every word ID must exist in the pack.
    static var rounds: [[BuilderSentence]] {
        let round1 = [
            BuilderSentence(english: "I eat momos", emoji: "🥟", wordIDs: ["sent_ma", "momo", "khaanchhu"]),
            BuilderSentence(english: "I drink tea", emoji: "🍵", wordIDs: ["sent_ma", "chiya", "piunchhu"]),
            BuilderSentence(english: "I eat apples", emoji: "🍎", wordIDs: ["sent_ma", "syau", "khaanchhu"]),
            BuilderSentence(english: "I drink water", emoji: "💧", wordIDs: ["sent_ma", "pani", "piunchhu"]),
            BuilderSentence(english: "I eat rice pudding", emoji: "🍚", wordIDs: ["sent_ma", "kheer", "khaanchhu"]),
            BuilderSentence(english: "I eat bananas", emoji: "🍌", wordIDs: ["sent_ma", "kera", "khaanchhu"]),
            BuilderSentence(english: "I eat ladoo", emoji: "🍬", wordIDs: ["sent_ma", "ladoo", "khaanchhu"]),
            BuilderSentence(english: "I eat mangoes", emoji: "🥭", wordIDs: ["sent_ma", "aanp", "khaanchhu"]),
        ]
        let round2 = [
            BuilderSentence(english: "I write a letter", emoji: "✉️", wordIDs: ["sent_ma", "chitthi", "lekhchhu"]),
            BuilderSentence(english: "I go to school", emoji: "🏫", wordIDs: ["sent_ma", "vidyalaya", "jaanchhu"]),
            BuilderSentence(english: "I read books", emoji: "📖", wordIDs: ["sent_ma", "kitab", "padhchhu"]),
            BuilderSentence(english: "I go home", emoji: "🏠", wordIDs: ["sent_ma", "ghar", "jaanchhu"]),
            BuilderSentence(english: "I listen to songs", emoji: "🎵", wordIDs: ["sent_ma", "geet", "sunchhu"]),
            BuilderSentence(english: "I watch the cat", emoji: "🐱", wordIDs: ["sent_ma", "biralo", "herchhu"]),
            BuilderSentence(english: "I write my name", emoji: "✏️", wordIDs: ["sent_ma", "naam", "lekhchhu"]),
            BuilderSentence(english: "I watch the dog", emoji: "🐶", wordIDs: ["sent_ma", "kukur", "herchhu"]),
        ]
        return [round1, round2]
    }
}

/// Synthesized "ding" for correct answers. No audio file needed, and it
/// plays even with the silent switch on (uses the playback audio session).
private enum CorrectDing {
    private static var engine: AVAudioEngine?

    static func play() {
        // Audio session setup off the main thread (setActive on main
        // triggers a purple runtime warning about UI unresponsiveness).
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch { /* still try to play */ }
            Self.playEngineSound()
        }
    }

    private static func playEngineSound() {

        let engine = AVAudioEngine()
        self.engine = engine // retain while playing

        let sampleRate = 44_100.0
        let duration = 0.6
        let freq = 880.0 // A5 — bright, pleasant bell tone

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        let data = buffer.floatChannelData![0]
        for i in 0 ..< Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope = exp(-t * 6.0) // natural bell decay
            let tone = sin(2 * .pi * freq * t) * 0.6
                     + sin(2 * .pi * freq * 2 * t) * 0.2 // soft octave harmonic
            data[i] = Float(tone * envelope * 0.5)
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return }
        player.scheduleBuffer(buffer) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                engine.stop()
                CorrectDing.engine = nil
            }
        }
        player.play()
    }
}

/// Shake animation for wrong answers.
struct ShakeEffect: GeometryEffect {
    var shakes: Int
    var animatableData: Int {
        get { shakes }
        set { shakes = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: shakes == 0 ? 0 : sin(Double(shakes) * .pi * 3) * 8,
            y: 0))
    }
}

// MARK: - Quiz menu entry card
//
// Drop this into QuizMenuView under the Sentences card:
//   NavigationLink {
//       SentenceBuilderView(words: pack.decks.flatMap { $0.words })
//   } label: {
//       SentenceBuilderEntryCard()
//   }
//   .buttonStyle(.plain)
struct SentenceBuilderEntryCard: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("🧱")
                .font(.largeTitle)
                .frame(width: 58, height: 58)
                .background(Color.orange.opacity(0.15))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text("Sentence Builder")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("म ___ ___छु। — tap words in order to build it · 16 sentences")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
}
