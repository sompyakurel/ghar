import SwiftUI
import AVFoundation
import UIKit

/// Text Pack: phrases kids can actually text to friends and family.
/// Each card shows the romanized phrase big (that's what gets copied),
/// with Devanagari + English below, a formality badge, a copy button
/// that drops the romanized text on the clipboard, and audio playback.
struct TextPackView: View {
    let deck: Deck
    @State private var player: AVPlayer?
    /// Word ID currently showing "Copied!" feedback.
    @State private var copiedID: String?
    @AppStorage("ghar.shop.owned") private var ownedData = Data()
    @AppStorage("ghar.teenprizes.celebrated") private var celebratedData = Data()
    /// Set the first time this deck's teen prize is seen earned.
    @State private var prizeWon: ShopItem?

    /// Phrases grouped under their `section` header, in file order.
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
        List {
            // How teen lessons pay out (Som's ask, 2026-10-23): say
            // it right on the lesson, before the first phrase.
            Section {
                HStack(spacing: 10) {
                    Text("🎁").font(.title2)
                    Text("Tap the \u{1F50A} sound on every phrase and learn them all — finish the whole deck to earn your reward!")
                        .font(.subheadline)
                }
                .padding(.vertical, 4)
            }
            ForEach(Array(grouped.enumerated()), id: \.offset) { _, group in
                Section(header: Text(group.header ?? "")) {
                    ForEach(group.words) { word in
                        TextPhraseCard(
                            word: word,
                            isCopied: copiedID == word.id,
                            onCopy: { copy(word: word) },
                            onPlay: { play(word: word) }
                        )
                    }
                }
            }
        }
        .navigationTitle("Text Pack 💬")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            DeckProgress.evaluate(deck)
            checkTeenPrize()
        }
        .alert(item: $prizeWon) { prize in
            Alert(
                title: Text("🎁 Prize earned!"),
                message: Text("You finished this deck and earned the \(prize.nameEn) \(prize.icon)! Find it in My Ghar — and on the Teen Rewards shelf."),
                dismissButton: .default(Text("Nice!"))
            )
        }
    }

    /// Teen lesson prize: DeckProgress.evaluate grants this deck's
    /// prize into the owned set the moment the deck completes (hear
    /// every phrase). The first time we see it earned, celebrate —
    /// once per deck, remembered across launches.
    private func checkTeenPrize() {
        guard prizeWon == nil,
              let prize = teenDeckPrizes.first(where: { $0.deck == deck.id })?.item else { return }
        let celebrated = (try? JSONDecoder().decode(Set<String>.self, from: celebratedData)) ?? []
        guard !celebrated.contains(deck.id) else { return }
        let owned = (try? JSONDecoder().decode(Set<String>.self, from: UserDefaults.standard.data(forKey: "ghar.shop.owned") ?? Data())) ?? []
        guard owned.contains(prize.id) else { return }
        var done = celebrated
        done.insert(deck.id)
        celebratedData = (try? JSONEncoder().encode(done)) ?? Data()
        prizeWon = prize
        QuizDing.play()
    }

    private func play(word: Word) {
        guard word.hasAudio == true,
              let url = URL(string: GharAPI.baseURLString + word.audioUrl) else { return }
        player?.pause()
        player = AVPlayer(url: url)
        player?.play()
        // Teen decks complete like the kids' decks: hear every phrase.
        DeckProgress.markHeard(word.id)
        DeckProgress.evaluate(deck)
        checkTeenPrize()
    }

    private func copy(word: Word) {
        UIPasteboard.general.string = word.romanized
        copiedID = word.id
        // Clear the "Copied!" feedback after 1.5s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedID == word.id { copiedID = nil }
        }
    }
}

/// One phrase card: big romanized text, Devanagari + English,
/// formality badge, copy button, play button.
struct TextPhraseCard: View {
    let word: Word
    let isCopied: Bool
    let onCopy: () -> Void
    let onPlay: () -> Void

    /// "timi" → friends & family, "tapai" → elders.
    private var formalityLabel: String? {
        switch word.formality {
        case "timi": return "👥 friends & family"
        case "tapai": return "🙏 elders"
        default: return nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Phrase image, when available.
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
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            VStack(alignment: .leading, spacing: 8) {
            // The star: romanized text, big — this is what gets copied.
            Text(word.romanized)
                .font(.title2)
                .fontWeight(.semibold)

            Text(word.devanagari)
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(word.english)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                if let label = formalityLabel {
                    Text(label)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.12))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }
                Spacer()
                // Copy button with "Copied!" feedback.
                Button(action: onCopy) {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        Text(isCopied ? "Copied!" : "Copy")
                    }
                    .font(.subheadline)
                    .fontWeight(.medium)
                }
                .buttonStyle(.bordered)
                .tint(isCopied ? .green : .blue)
                // Play button.
                Button(action: onPlay) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.title3)
                }
                .buttonStyle(.bordered)
                .disabled(word.hasAudio != true)
                .opacity(word.hasAudio == true ? 1 : 0.4)
            }
            }
        }
        .padding(.vertical, 4)
    }
}
