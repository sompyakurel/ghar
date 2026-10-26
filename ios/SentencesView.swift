import SwiftUI
import AVFoundation

// MARK: - Sentences · Lesson 1: "This Is a Thing"
//
// The app's first step from words into real sentences: यो ___ हो।
// ("yo ___ ho" — "this is a ___.") The kid sees a picture, taps the
// word that completes the sentence, then hears the whole thing spoken.
// +5 XP per correct answer, same as quizzes.
//
// Teaching notes:
// - हो goes at the END (like Japanese) — the game teaches this by
//   position, not by lecture. The blank is always in the middle.
// - The । at the end is the purna biram, the Nepali full stop.
// - Sentences are content: add more lessons here as `SentenceLesson`
//   entries and they appear as new cards automatically.
struct SentencesView: View {
    let lesson: SentenceLesson

    @AppStorage("ghar.xp.total") private var totalXP = 0
    @State private var index = 0
    @State private var options: [Word] = []
    @State private var picked: Word? = nil
    @State private var correctCount = 0
    @State private var wrongPicks = Set<String>()
    @State private var finished = false
    @State private var player: AVPlayer?
    @State private var questionOrder: [Int] = []

    private var question: SentenceQuestion {
        // Question order is shuffled once per visit (and again on
        // replay) so the run isn't book-dog-cat-bird every time.
        if questionOrder.indices.contains(index) {
            return lesson.questions[questionOrder[index]]
        }
        return lesson.questions[index]
    }

    var body: some View {
        VStack(spacing: 0) {
            if finished {
                doneView
            } else {
                // Progress
                HStack {
                    Text("📝 \(lesson.title)")
                        .font(.headline)
                    Spacer()
                    Text("\(index + 1) / \(lesson.questions.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding()

                ProgressView(value: Double(index), total: Double(lesson.questions.count))
                    .padding(.horizontal)

                Spacer()

                // The picture clue
                sentencePicture(question.pictureWord)
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .shadow(radius: 6)

                Spacer().frame(height: 28)

                // The sentence with a blank (or the filled answer)
                HStack(spacing: 6) {
                    Text(question.prefix)
                    if let picked {
                        Text(picked.devanagari)
                            .bold()
                            .foregroundStyle(.green)
                            .transition(.scale)
                    } else {
                        Text("___")
                            .foregroundStyle(.secondary)
                    }
                    Text(question.suffix)
                }
                .font(.system(size: 40))

                if picked == nil {
                    Text("Tap the missing word")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                // Visible stakes (Som's ask 2026-10-19): the kid SEES the
                // value drop the moment a miss lands — +5 clean, +2 after.
                Text(wrongPicks.isEmpty ? "⭐ +5 XP" : "😅 +2 XP now")
                    .font(.headline)
                    .foregroundStyle(wrongPicks.isEmpty ? .green : .orange)
                    .padding(.top, 2)

                Spacer().frame(height: 24)

                // Word choices
                VStack(spacing: 12) {
                    ForEach(options, id: \.id) { word in
                        choiceButton(word)
                    }
                }
                .padding(.horizontal)

                Spacer()

                if picked != nil {
                    Button("Next →") { nextQuestion() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.bottom)
                }
            }
        }
        .navigationTitle("Sentences")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            questionOrder = Array(lesson.questions.indices).shuffled()
            dealQuestion()
        }
    }

    // MARK: - Views

    @ViewBuilder
    private func sentencePicture(_ word: Word) -> some View {
        if let imagePath = word.image,
           let url = URL(string: GharAPI.baseURLString + imagePath) {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.15)
                        .overlay(Text(word.devanagari).font(.largeTitle))
                }
            }
        } else {
            Color.gray.opacity(0.15)
                .overlay(Text(word.devanagari).font(.largeTitle))
        }
    }

    private func choiceButton(_ word: Word) -> some View {
        let isWrong = wrongPicks.contains(word.id)
        return Button {
            pick(word)
        } label: {
            VStack(spacing: 2) {
                Text(word.devanagari)
                    .font(.title2).bold()
                Text(word.romanized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isWrong ? .red.opacity(0.6) : .clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(picked != nil || isWrong)
        .opacity(isWrong ? 0.5 : 1)
        .rotationEffect(.degrees(isWrong ? 2 : 0))
    }

    private var doneView: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("🎉").font(.system(size: 72))
            Text("You built sentences!")
                .font(.title).bold()
            Text("+\(correctCount * 5) XP · \(correctCount)/\(lesson.questions.count) correct")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("यो ___ हो। — you know how Nepali says \"this is a ___\".")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Play again") {
                index = 0
                correctCount = 0
                finished = false
                questionOrder = Array(lesson.questions.indices).shuffled()
                dealQuestion()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .padding()
    }

    // MARK: - Game logic

    private func dealQuestion() {
        picked = nil
        wrongPicks = []
        var pool = lesson.questions.map { $0.pictureWord }
        pool.removeAll { $0.id == question.pictureWord.id }
        let distractors = Array(pool.shuffled().prefix(2))
        options = ([question.pictureWord] + distractors).shuffled()
        // Hear the question word? No — the kid reads the picture.
        // The full sentence plays after they answer.
    }

    private func pick(_ word: Word) {
        if word.id == question.pictureWord.id {
            picked = word
            correctCount += 1
            // Anti-mash (Som's call 2026-10-19): clean first-try +5,
            // any wrong pick on this question drops it to +2.
            totalXP += wrongPicks.isEmpty ? 5 : 2
            QuizStats.recordCorrect()
            CorrectDing.play()
            playWordClip(question.pictureWord)
        } else {
            wrongPicks.insert(word.id)
            QuizStats.recordWrong()
            WrongAnswerFeedback.play()
        }
    }

    private func nextQuestion() {
        if index + 1 < lesson.questions.count {
            index += 1
            dealQuestion()
        } else {
            finished = true
        }
    }

    /// Plays the answer word's cloned clip. No TTS — the kid hears the
    /// real voice saying the word they just matched to the picture.
    private func playWordClip(_ word: Word) {
        if word.hasAudio == true, let url = URL(string: GharAPI.baseURLString + word.audioUrl) {
            player?.pause()
            player = AVPlayer(url: url)
            player?.play()
        } else {
            let nepali = "\(question.prefix) \(word.devanagari) \(question.suffix)"
            let romanized = "\(question.prefixRomanized) \(word.romanized) \(question.suffixRomanized)"
            NepaliSpeaker.say(nepali: nepali, romanized: romanized)
        }
    }
}

// MARK: - Content

/// One fill-in-the-blank sentence question.
struct SentenceQuestion {
    /// The word shown as a picture; also the correct answer.
    let pictureWord: Word
    let prefix: String
    let prefixRomanized: String
    let suffix: String
    let suffixRomanized: String
}

/// A sentence lesson: a pattern + its questions.
struct SentenceLesson: Identifiable {
    let id: String
    let title: String
    let icon: String
    let subtitle: String
    let questions: [SentenceQuestion]
}

/// Builds Lesson 1 ("यो ___ हो।") from words already in the pack.
/// New lessons get their own builder here.
enum SentenceLessons {
    static func lesson1(words: [Word]) -> SentenceLesson? {
        let want = ["kitab", "kukur", "biralo", "chara", "syau", "kera"]
        let byID = Dictionary(words.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let picked = want.compactMap { byID[$0] }
        guard picked.count >= 3 else { return nil }
        return SentenceLesson(
            id: "yo-ho",
            title: "This Is a Thing",
            icon: "📝",
            subtitle: "यो ___ हो। — your first Nepali sentences",
            questions: picked.map {
                SentenceQuestion(pictureWord: $0,
                                 prefix: "यो", prefixRomanized: "yo",
                                 suffix: "हो।", suffixRomanized: "ho.")
            }
        )
    }

    static func allLessons(words: [Word]) -> [SentenceLesson] {
        [lesson1(words: words)].compactMap { $0 }
    }
}

// MARK: - Quiz menu entry card
//
// Drop this into QuizMenuView under the Balloon Pop card:
//   if let lesson = SentenceLessons.lesson1(words: pack.decks.flatMap { $0.words }) {
//       NavigationLink { SentencesView(lesson: lesson) } label: {
//           SentencesEntryCard(lesson: lesson)
//       }
//       .buttonStyle(.plain)
//   }
struct SentencesEntryCard: View {
    let lesson: SentenceLesson

    var body: some View {
        HStack(spacing: 12) {
            Text(lesson.icon)
                .font(.largeTitle)
                .frame(width: 58, height: 58)
                .background(Color.purple.opacity(0.15))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text("Sentences")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("\(lesson.subtitle) · \(lesson.questions.count) sentences")
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
