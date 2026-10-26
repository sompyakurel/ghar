import SwiftUI
import AVFoundation
import UIKit
import Combine
import CoreText
import StoreKit

/// Deck intros — a warm "let's learn!" in Som's voice when a beginner
/// deck is opened. Plays once per deck per app launch (in-memory set,
/// resets on relaunch) — Som's call 2026-10-19: every reload should greet.
enum DeckIntro {
    private static var player: AVPlayer?
    private static let intros: [String: String] = [
        "alphabet": "intro_alphabet_np.m4a",
        "numbers": "intro_numbers_np.m4a",
        "colors": "intro_colors_np.m4a",
        "food": "intro_food_np.m4a",
        "family": "intro_family_np.m4a",
        "animals": "intro_animals_np.m4a",
        "fruits": "intro_fruits_np.m4a",
        "writing": "intro_writing_np.m4a",
    ]
    /// In-memory only — resets when the app relaunches, so each new
    /// session greets again. (Was UserDefaults once-ever; Som wants it
    /// on every app reload, 2026-10-19.)
    private static var playedThisLaunch: Set<String> = []

    static func play(for deckID: String) {
        guard let file = intros[deckID], !playedThisLaunch.contains(deckID) else { return }
        guard let url = URL(string: GharAPI.baseURLString + "/audio/nepal-v1/" + file) else { return }
        playedThisLaunch.insert(deckID)
        player?.pause()
        player = AVPlayer(url: url)
        // Small delay so it doesn't clash with the navigation animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            player?.play()
        }
    }
}

/// "Vayena!" — warm wrong-answer feedback in Som's voice for all quizzes.
/// Picks randomly from the bundled clips so it doesn't get robotic.
/// Falls back to the phone's voice if a clip file is missing.
/// Teen quizzes use Prakash's voice instead (teen: true).
enum WrongAnswerFeedback {
    private static var player: AVPlayer?
    private static let clips = [
        "feedback_vayena_1_np.m4a",  // "भएन!"
        "feedback_vayena_2_np.m4a",  // "भएन, फेरि प्रयास गर।"
    ]
    private static let teenClips = [
        "feedback_teen_wrong_1_np.m4a",  // "भएन!" (Prakash — kept per Som)
        "feedback_teen_wrong_2_np.m4a",  // Som's own recording
        "feedback_teen_wrong_3_np.m4a",  // Som's own recording (added 2026-10-21)
    ]

    static func play(teen: Bool = false) {
        let all = teen ? teenClips : clips
        // Pick only from clips that actually exist in the bundle: a
        // not-yet-recorded custom clip used to fall through to the
        // phone's robot voice whenever the random pick landed on it.
        let base = GharAPI.baseURLString + "/audio/nepal-v1/"
        let available = all.filter { file in
            guard let url = URL(string: base + file), url.isFileURL else { return true }
            return FileManager.default.fileExists(atPath: url.path)
        }
        if let file = available.randomElement(),
           let url = URL(string: base + file) {
            player?.pause()
            player = AVPlayer(url: url)
            player?.play()
            return
        }
        NepaliSpeaker.say(nepali: "भएन, फेरि प्रयास गर", romanized: "bhayena, pheri prayas gara")
    }
}

/// The $7.99 one-time unlock, via StoreKit 2. No account, no login — the
/// purchase lives on the family's Apple ID. Apple handles payment, receipts,
/// and Restore Purchases. We collect nothing: COPPA-safe by construction.
///
/// - StoreKit 2 (iOS 15+) is async/await, no delegates.
/// - Non-consumable = buy once, keep forever.
/// - `Transaction.currentEntitlements` is checked at launch, so a reinstall
///   or a new device on the same Apple ID restores silently.
/// - Views gate on `@AppStorage("ghar.premium.unlocked")` (same key, same
///   pattern as `ghar.xp.total`) — when this manager flips it, every view
///   re-renders.
@MainActor
final class PremiumManager: ObservableObject {
    static let shared = PremiumManager()
    static let productID = "com.sompyakurel.Ghar.unlock_all"
    static let unlockedKey = "ghar.premium.unlocked"

    @AppStorage(unlockedKey) var isUnlocked = false
    @Published var product: Product?
    @Published var isPurchasing = false
    @Published var errorMessage: String?

    /// Keeps the Transaction.updates listener alive for the app's
    /// whole life (this manager is a singleton, so it never cancels).
    private var transactionListener: Task<Void, Never>?

    private init() {
        // TestFlight = testing: everything unlocked automatically so
        // testers never hit a lock. App Store builds use the real paywall.
        if Self.isTestFlight {
            isUnlocked = true
        }
        // Unlock the moment a transaction lands OUTSIDE the purchase
        // sheet — a parent approving Ask to Buy, a buy finished on
        // another device. Without this listener the app only learns
        // about those at the next cold launch (checkEntitlements),
        // and the compiler warns about exactly that gap.
        transactionListener = Task { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let t) = result,
                      t.productID == Self.productID else { continue }
                if t.revocationDate != nil {
                    self?.isUnlocked = false // refunded / revoked
                } else {
                    self?.isUnlocked = true
                }
                await t.finish()
            }
        }
        Task { await loadProduct(); await checkEntitlements() }
    }

    /// True when running as a TestFlight build (sandbox receipt).
    static var isTestFlight: Bool {
        Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    func loadProduct() async {
        do {
            let products = try await Product.products(for: [Self.productID])
            product = products.first
        } catch {
            // Not in App Store Connect yet, or offline — paywall still
            // shows; purchase just waits for the product to load.
        }
    }

    /// If this Apple ID already owns the unlock, flip the flag silently.
    func checkEntitlements() async {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result else { continue }
            if t.productID == Self.productID {
                isUnlocked = true
                return
            }
        }
    }

    func purchase() async {
        guard let product else {
            errorMessage = "Couldn't reach the App Store. Check your connection and try again."
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    isUnlocked = true
                    await transaction.finish()
                case .unverified:
                    errorMessage = "Purchase couldn't be verified. Try Restore Purchases."
                }
            case .userCancelled:
                break // Tapped away — no error, no nag.
            case .pending:
                errorMessage = "Waiting on a parent's approval (Ask to Buy)."
            @unknown default:
                break
            }
        } catch {
            errorMessage = "Purchase failed. Please try again."
        }
    }

    func restore() async {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            try await AppStore.sync()
            await checkEntitlements()
            if !isUnlocked {
                errorMessage = "No purchase found on this Apple ID."
            }
        } catch {
            errorMessage = "Restore failed. Check your connection."
        }
    }
}

/// The $7.99 one-time unlock sheet. Opens from any locked content, and once
/// (celebratory) when the kid finishes everything free.
struct PaywallView: View {
    @ObservedObject var premium = PremiumManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingGiftSheet = false
    @State private var showingGate = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("\u{1F513}")
                        .font(.system(size: 64))
                    Text("Unlock Everything!")
                        .font(.largeTitle).bold()
                    Text("One payment of $7.99. Yours forever. No subscription.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 12) {
                        unlockRow("\u{270D}\u{FE0F}", "Writing practice", "Trace & write every letter + your name")
                        unlockRow("\u{1F3AE}", "Unlimited quizzes", "As many questions as you want")
                        unlockRow("\u{1F6A9}", "All missions", "Real-world missions with the family")
                        unlockRow("\u{1F3A8}", "Every decoration", "Fill your Ghar — festivals, animals & more")
                        unlockRow("\u{1F3D4}\u{FE0F}", "Festivals & conversations", "Tihar, colors, chats & beyond")
                    }
                    .padding()
                    .background(Color(.systemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    if let product = premium.product {
                        Button {
                            showingGate = true
                        } label: {
                            if premium.isPurchasing {
                                ProgressView().tint(.white)
                            } else {
                                Text("Unlock for \(product.displayPrice)").bold()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(premium.isPurchasing)
                    } else {
                        Text("Connect to the internet to unlock.")
                            .foregroundStyle(.secondary)
                    }

                    if let err = premium.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    Button("Restore Purchases") {
                        Task { await premium.restore() }
                    }
                    .font(.subheadline)

                    // Gift Ghar: the kid asks a grown-up to gift Premium.
                    // Share sheet with a pre-written message — the grown-up
                    // buys the $7.99 unlock (or it's shared via Family Sharing).
                    Button {
                        showingGiftSheet = true
                    } label: {
                        Label("Gift Ghar", systemImage: "gift.fill")
                    }
                    .font(.subheadline)
                    .sheet(isPresented: $showingGiftSheet) {
                        GiftGharSheet()
                    }

                    Text("Payment is handled securely by Apple. No account needed.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("Ghar Premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showingGate) {
                ParentalGateView {
                    Task { await premium.purchase() }
                }
            }
            .onChange(of: premium.isUnlocked) { _, unlocked in
                if unlocked { dismiss() }
            }
        }
    }

    private func unlockRow(_ emoji: String, _ title: String, _ sub: String) -> some View {
        HStack(spacing: 12) {
            Text(emoji).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(sub).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// Parental gate (App Store Guideline 1.3): an adult-level task that must be
/// completed before the StoreKit purchase can start. A small child tapping
/// around can't pass it.
struct ParentalGateView: View {
    /// Called once the grown-up completes the hold.
    var onPassed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var progress = 0.0
    @State private var timer: Timer?

    private let holdSeconds = 2.5

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Text("🧑‍🧒").font(.system(size: 72))
            Text("Grown-ups only")
                .font(.largeTitle).bold()
            Text("Only a grown-up can unlock Ghar Premium. Press and hold the button below until it fills up.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(.systemGroupedBackground))
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * max(0, min(1, progress)))
                }
                Text(progress >= 1 ? "✓" : "Hold to continue")
                    .bold()
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 68)
            .padding(.horizontal, 32)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in startHold() }
                    .onEnded { _ in cancelHold() }
            )
            .accessibilityLabel("Press and hold to confirm you are a grown-up")
            Spacer()
            Text("A purchase never starts without a grown-up's hold.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .onDisappear { timer?.invalidate() }
    }

    private func startHold() {
        guard timer == nil, progress < 1 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            DispatchQueue.main.async {
                progress += 0.05 / holdSeconds
                if progress >= 1 {
                    t.invalidate()
                    timer = nil
                    dismiss()
                    onPassed()
                }
            }
        }
    }

    private func cancelHold() {
        timer?.invalidate()
        timer = nil
        if progress < 1 { progress = 0 }
    }
}

/// Gift Ghar: the sheet behind the paywall's "Gift Ghar" button.
/// Pre-written message for a parent/grandparent + system share sheet.
/// The grown-up buys the $7.99 unlock (or it's already shared with them
/// via Family Sharing) — no account, no codes, nothing to redeem.
struct GiftGharSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The App Store link, once Ghar is published.
    /// The live App Store link (set at submission, 2026-10-23).
    static let appStoreURL = "https://apps.apple.com/app/id6819509554"

    static var giftMessage: String {
        var msg = "Please gift me Ghar Premium! I want to learn Nepali \u{2014} it's $7.99 one time (no subscription) and unlocks writing practice, quizzes, missions, festivals, and my whole Ghar house. \u{2764}\u{FE0F}"
        if !appStoreURL.isEmpty {
            msg += "\n\n" + appStoreURL
        }
        return msg
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("\u{1F381}").font(.system(size: 64))
                Text("Gift Ghar")
                    .font(.title2).bold()
                Text("Send this to a parent or grandparent \u{2014} they'll know what to do!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(Self.giftMessage)
                    .font(.body)
                    .padding()
                    .background(Color(.systemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                ShareLink(item: Self.giftMessage) {
                    Label("Send gift message", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Spacer()
            }
            .padding()
            .navigationTitle("Gift Ghar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

/// Lesson completion, made visible (Som's call, 2026-10-22 — his
/// cousin asked for decks to LOCK until finished; instead, finished
/// decks get a checkmark so kids can SEE what they've completed.
/// Nothing locks.) A deck completes when every word in it has been
/// heard at least once — tapped in the deck, played in a dialogue,
/// or finished in writing practice.
enum DeckProgress {
    private static let key = "ghar.heard.words"

    static var heard: Set<String> {
        get {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let set = try? JSONDecoder().decode(Set<String>.self, from: data)
            else { return [] }
            return set
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    static func markHeard(_ id: String) {
        var set = heard
        if set.insert(id).inserted { heard = set }
    }

    static func heardCount(in deck: Deck) -> Int {
        let set = heard
        return deck.words.filter { set.contains($0.id) }.count
    }

    static func isComplete(_ deck: Deck) -> Bool {
        !deck.words.isEmpty && heardCount(in: deck) == deck.words.count
    }

    // MARK: Completion reward (+25 XP, once per deck — Som's call,
    // 2026-10-22; the all-decks prize stays the v1.1 certificate.)

    private static let rewardedKey = "ghar.decks.rewarded"
    static let completionBonus = 25

    static var rewarded: Set<String> {
        get {
            guard let data = UserDefaults.standard.data(forKey: rewardedKey),
                  let set = try? JSONDecoder().decode(Set<String>.self, from: data)
            else { return [] }
            return set
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: rewardedKey)
            }
        }
    }

    /// If the deck is complete and hasn't been rewarded yet: bank the
    /// bonus XP and announce it — ContentView's root listens and throws
    /// the celebration. Safe to call often (row appear, deck appear /
    /// disappear, after a word plays): only the first call after
    /// completion does anything.
    static func evaluate(_ deck: Deck) {
        guard isComplete(deck), !rewarded.contains(deck.id) else { return }
        var done = rewarded
        done.insert(deck.id)
        rewarded = done
        let xpKey = "ghar.xp.total"
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: xpKey) + completionBonus,
                                  forKey: xpKey)
        // Teen lesson prize: a finished teen deck grants its prize
        // into the shared My Ghar owned set (the same UserDefaults
        // key the views' @AppStorage wraps).
        if let prize = teenDeckPrizes.first(where: { $0.deck == deck.id })?.item {
            let ownedKey = "ghar.shop.owned"
            let ownedData = UserDefaults.standard.data(forKey: ownedKey)
            var owned = (try? JSONDecoder().decode(Set<String>.self, from: ownedData ?? Data())) ?? []
            if owned.insert(prize.id).inserted,
               let data = try? JSONEncoder().encode(owned) {
                UserDefaults.standard.set(data, forKey: ownedKey)
            }
        }
        NotificationCenter.default.post(name: .deckCompleted, object: nil,
                                        userInfo: ["title": deck.title])
    }
}

extension Notification.Name {
    static let deckCompleted = Notification.Name("ghar.deckCompleted")
}

/// One deck row in the Lessons list. Alphabet + numbers are free;
/// everything else shows a lock and opens the paywall until premium.
struct DeckRow: View {
    let deck: Deck
    @AppStorage("ghar.premium.unlocked") private var isUnlocked = false
    @State private var showingPaywall = false
    @State private var showingDeck = false

    private var isFree: Bool {
        deck.id == "alphabet" || deck.id == "numbers"
    }

    var body: some View {
        Button {
            if isFree || isUnlocked { showingDeck = true }
            else { showingPaywall = true }
        } label: {
            HStack(spacing: 12) {
                DeckCover(deck: deck)
                VStack(alignment: .leading) {
                    Text(deck.title).font(.headline)
                    Text(lessonSubtitle(for: deck))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if DeckProgress.isComplete(deck) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                } else if DeckProgress.heardCount(in: deck) > 0 {
                    Text("\(DeckProgress.heardCount(in: deck))/\(deck.words.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !isFree && !isUnlocked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .navigationDestination(isPresented: $showingDeck) {
            lessonDestination(for: deck)
                .onAppear {
                    DeckIntro.play(for: deck.id)
                }
        }
        .onAppear { DeckProgress.evaluate(deck) }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
        }
    }
}

/// Streak tracking: consecutive days with at least one mission done.
/// All on-device (UserDefaults) — COPPA-safe. Milestones auto-grant
/// exclusive decorations at 7 and 30 days.
enum Streak {
    static let countKey = "ghar.streak.count"
    static let lastDayKey = "ghar.streak.lastDay"
    static let dailyDoneKey = "ghar.daily.done"

    static var count: Int {
        UserDefaults.standard.integer(forKey: countKey)
    }

    static var todayString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: Date())
    }

    /// Call when a mission is completed. Grows the streak if yesterday
    /// was the last active day, resets to 1 if the chain broke, no-ops
    /// if already counted today.
    static func recordMissionDone() {
        let today = todayString
        let lastDay = UserDefaults.standard.string(forKey: lastDayKey) ?? ""
        guard lastDay != today else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let yesterday = fmt.string(from: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
        let newCount = (lastDay == yesterday) ? count + 1 : 1
        UserDefaults.standard.set(newCount, forKey: countKey)
        UserDefaults.standard.set(today, forKey: lastDayKey)
        checkMilestones(newCount)
    }

    /// 7-day streak → Flame Diyo. 15-day → Streak Crown. Granted once.
    static func checkMilestones(_ newCount: Int) {
        var ids = (try? JSONDecoder().decode(Set<String>.self, from: UserDefaults.standard.data(forKey: "ghar.shop.owned") ?? Data())) ?? Set<String>()
        var changed = false
        if newCount >= 7 && !ids.contains("flameDiyo") {
            ids.insert("flameDiyo"); changed = true
        }
        if newCount >= 15 && !ids.contains("streakCrown") {
            ids.insert("streakCrown"); changed = true
        }
        if changed {
            UserDefaults.standard.set((try? JSONEncoder().encode(ids)) ?? Data(), forKey: "ghar.shop.owned")
        }
    }

    /// True if today's daily challenge is already done.
    static var dailyDoneToday: Bool {
        UserDefaults.standard.string(forKey: dailyDoneKey) == todayString
    }

    static func markDailyDone() {
        UserDefaults.standard.set(todayString, forKey: dailyDoneKey)
    }
}

/// Daily quiz progress: how many questions solved today. Backs the
/// Quiz Blitz daily challenge (5 solves = done). Resets each day.
enum DailyQuiz {
    static let dateKey = "ghar.daily.quizDate"
    static let countKey = "ghar.daily.quizCount"

    /// Call when a quiz question is solved correctly.
    static func recordSolve() {
        let today = Streak.todayString
        if UserDefaults.standard.string(forKey: dateKey) != today {
            UserDefaults.standard.set(today, forKey: dateKey)
            UserDefaults.standard.set(0, forKey: countKey)
        }
        UserDefaults.standard.set(todayCount + 1, forKey: countKey)
    }

    static var todayCount: Int {
        guard UserDefaults.standard.string(forKey: dateKey) == Streak.todayString else { return 0 }
        return UserDefaults.standard.integer(forKey: countKey)
    }

    /// True if this solve just finished today's Quiz Blitz.
    /// Marks it done (the caller adds the bonus XP + fanfare).
    static func checkBlitzComplete() -> Bool {
        guard DailyChallenge.today().format == .quizBlitz,
              !Streak.dailyDoneToday,
              todayCount >= 5 else { return false }
        Streak.markDailyDone()
        Streak.recordMissionDone()
        return true
    }
}

/// One featured challenge per day, rotating formats so each day feels
/// different. Deterministic from the date — no backend, works offline.
/// Completing it pays 15 XP (vs 10 for regular missions).
struct DailyChallenge {
    enum Format { case mission, teachBack, quizBlitz }
    let format: Format
    let title: String
    let prompt: String
    /// For .mission: which seed mission to deep-link. For .teachBack:
    /// the word IDs to teach, in order. Empty for .quizBlitz.
    let refIDs: [String]
    let xp = 15

    /// 9 rotating challenges (3 per format), picked by day-of-year.
    /// Mission challenges use the two free missions so everyone can play.
    static func today() -> DailyChallenge {
        let dayNum = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        let i = dayNum % 9
        switch i {
        case 0: return DailyChallenge(format: .mission, title: "Mission of the Day",
            prompt: "Do the Tihar Greeting mission today — say it to someone you love.", refIDs: ["tihar-greeting"])
        case 1: return DailyChallenge(format: .teachBack, title: "Teach-Back",
            prompt: "Teach someone the word 'momo' today. Say it, they repeat!", refIDs: ["momo"])
        case 2: return DailyChallenge(format: .quizBlitz, title: "Quiz Blitz",
            prompt: "Answer 5 quiz questions as fast as you can. Beat your best!", refIDs: [])
        case 3: return DailyChallenge(format: .mission, title: "Mission of the Day",
            prompt: "Count to 5 in Nepali for a family member today.", refIDs: ["count-to-five"])
        case 4: return DailyChallenge(format: .teachBack, title: "Teach-Back",
            prompt: "Teach someone 3 Nepali greetings today: namaste, dhanyabad, pheri bhetaula!", refIDs: ["convo_namaste", "convo_dhanyabad", "convo_pharkera"])
        case 5: return DailyChallenge(format: .quizBlitz, title: "Quiz Blitz",
            prompt: "5 questions, no wrong answers. Can you go perfect?", refIDs: [])
        case 6: return DailyChallenge(format: .mission, title: "Mission of the Day",
            prompt: "Say the Tihar greeting to someone at dinner tonight.", refIDs: ["tihar-greeting"])
        case 7: return DailyChallenge(format: .teachBack, title: "Teach-Back",
            prompt: "Teach someone to count to 3 in Nepali: ek, dui, tin!", refIDs: ["num_ek", "num_dui", "num_tin"])
        default: return DailyChallenge(format: .quizBlitz, title: "Quiz Blitz",
            prompt: "Quiz time! 5 questions — how fast can you finish?", refIDs: [])
        }
    }

    var icon: String {
        switch format {
        case .mission: return "\u{1F6A9}"
        case .teachBack: return "\u{1F3A4}"
        case .quizBlitz: return "\u{26A1}"
        }
    }
}

/// Dog celebration popup: confetti + congratulations when ALL missions
/// are complete. The button deep-links to My Ghar to meet the dog.
/// The golden soccer ball moment: full-screen, once, when every
/// teen mission is done. The teen parallel to DogCelebrationView.
struct TeenBallCelebrationView: View {
    let onDone: () -> Void
    @State private var bounce = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.98, green: 0.75, blue: 0.14),
                                    Color(red: 0.85, green: 0.45, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Text("🏆").font(.system(size: 44))
                Group {
                    if let img = myGharSprite("goldsoccerball") {
                        img.resizable().scaledToFit()
                    } else {
                        Text("⚽").font(.system(size: 120))
                    }
                }
                .frame(width: 190, height: 190)
                .offset(y: bounce ? -14 : 0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: bounce)
                Text("GOLDEN SOCCER BALL!")
                    .font(.largeTitle).bold()
                    .foregroundStyle(.white)
                Text("सुनको फुटबल")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.9))
                Text("You finished ALL the teen missions. The golden ball is yours — find it in My Ghar, on the Teen Rewards shelf.")
                    .font(.body)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Show me! 🎉") { onDone() }
                    .font(.headline)
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.orange)
                    .controlSize(.large)
                    .padding(.top, 6)
            }
            .padding()
        }
        .onAppear { bounce = true }
    }
}

struct DogCelebrationView: View {
    let dogName: String
    let onMeetDog: () -> Void
    @State private var showConfetti = false

    var body: some View {
        ZStack {
            VStack(spacing: 20) {
                Text("🎉")
                    .font(.system(size: 80))
                Text("Congratulations!")
                    .font(.largeTitle)
                    .bold()
                SpriteDogView(pose: .idle, wagPhase: 1.2)
                    .frame(width: 118, height: 168)
                Text("You unlocked \(dogName)!")
                    .font(.title2)
                    .bold()
                Text("You completed every single mission. \(dogName) is waiting in My Ghar!")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                Button("Meet my dog! 🐕") {
                    onMeetDog()
                }
                .buttonStyle(.borderedProminent)
                .font(.title3)
            }
            .padding()

            if showConfetti {
                ConfettiBurst()
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            showConfetti = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                showConfetti = false
            }
        }
    }
}

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
/// The load-in (Som's ask, 2026-10-22): prayer flags swaying over a
/// flickering diyo and the name of the house, while a short plucked
/// jingle plays. Pure decoration — it dismisses itself, and a tap
/// skips it.
struct LaunchSplashView: View {
    @State private var flagWave = false
    @State private var flameFlicker = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 1.0, green: 0.97, blue: 0.89),
                         Color(red: 0.99, green: 0.89, blue: 0.71)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                // Prayer flags across the top, swaying gently —
                // hung lower into the screen, not on the top edge.
                Spacer().frame(height: 104)
                Group {
                    if let img = myGharSprite("splashflags") ?? myGharSprite("flags") {
                        img.resizable().scaledToFit()
                    } else {
                        Text("🚩").font(.system(size: 44))
                    }
                }
                .frame(height: 110)
                .rotationEffect(.degrees(flagWave ? 1.1 : -1.1), anchor: .top)
                .offset(y: flagWave ? 3 : 0)
                .onAppear {
                    withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) {
                        flagWave = true
                    }
                }

                Spacer()

                // The golden diyo, glowing bright — the prize lamp
                // from My Ghar, centre stage for the load-in.
                ZStack {
                    Circle()
                        .fill(Color.yellow.opacity(0.5))
                        .frame(width: 120, height: 120)
                        .blur(radius: 16)
                    Group {
                        if let img = myGharSprite("goldenDiyo") {
                            img.resizable().scaledToFit()
                        } else {
                            Text("🪔").font(.system(size: 64))
                        }
                    }
                    .frame(width: 88, height: 88)
                }
                .scaleEffect(flameFlicker ? 1.07 : 0.97)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        flameFlicker = true
                    }
                }
                Text("घर")
                    .font(.system(size: 92, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.62, green: 0.16, blue: 0.12))
                Text("Ghar")
                    .font(.largeTitle).bold()
                Text("Learn Nepali 🇳🇵")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()

                ProgressView()
                    .tint(.orange)
                    .padding(.bottom, 28)
            }
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ContentView: View {
    @State private var pack: ContentPack?
    @State private var errorMessage: String?
    @AppStorage("ghar.premium.unlocked") private var isUnlocked = false
    @AppStorage("ghar.missions.completed") private var completedData = Data()
    @AppStorage("ghar.quiz.freeUsed") private var quizFreeUsed = 0
    @AppStorage("ghar.shop.owned") private var ownedData = Data()
    @AppStorage("ghar.paywall.celebrated") private var paywallCelebrated = false
    @State private var showingCelebratoryPaywall = false
    @State private var showingParents = false
    // Lesson order: kid drags decks into their preferred order, persisted.
    @AppStorage("ghar.lessons.order") private var deckOrderData = Data()
    // Next-up guide (Som's pick 2026-10-19, Gurukul-inspired): the card
    // atop the Lessons tab needs deck-level tracing progress.
    @AppStorage("ghar.traced.words") private var nextUpTracedData = Data()
    @State private var nextUpDeck: Deck?
    @State private var nextUpDeckShown = false
    @State private var nextUpPaywall = false
    // Tab selection: lets the dog celebration deep-link to My Ghar.
    @State private var selectedTab = 0
    // Welcome greeting: plays the very first time a kid ever opens
    // the app, then never again (Som's call, 2026-10-20 — it used to
    // repeat on every launch, which got old fast).
    @AppStorage("ghar.welcome.played") private var welcomePlayed = false
    @State private var welcomePlayer: AVPlayer?
    @State private var welcomeObservation: NSKeyValueObservation?
    // Fun load-in (Som's ask, 2026-10-22): a Nepali-themed splash with
    // a short plucked jingle on every cold launch. Tap to skip.
    @State private var showSplash = true
    @State private var splashPlayer: AVPlayer?
    // Deck-completion celebration (2026-10-22): DeckProgress posts
    // .deckCompleted the first time a deck hits 100%; this card +
    // confetti is the +25 XP moment, wherever the kid happens to be.
    @State private var deckCelebration: String? = nil

    /// Welcome greeting: "welcome to Ghar, let's learn Nepali" — once, ever.
    private func playWelcome() {
        guard !welcomePlayed else { return }
        guard let url = URL(string: GharAPI.baseURLString + "/audio/nepal-v1/welcome_ghar_np.m4a") else { return }
        splashPlayer?.pause()
        welcomePlayer?.pause()
        welcomeObservation?.invalidate()
        let player = AVPlayer(url: url)
        welcomePlayer = player
        var observation: NSKeyValueObservation?
        observation = player.observe(\.timeControlStatus, options: [.new]) { _, change in
            guard change.newValue == .playing else { return }
            welcomePlayed = true
            observation?.invalidate()
        }
        welcomeObservation = observation
        player.play()
    }

    /// Load-in: play the jingle, hold the splash ~2.2s, fade out.
    /// The pack loads from the bundle in well under that, so the
    /// splash IS the loading screen — not a delay on top of one.
    private func startSplash() {
        if let url = URL(string: GharAPI.baseURLString + "/audio/nepal-v1/launch_jingle_np.m4a") {
            splashPlayer?.pause()
            splashPlayer = AVPlayer(url: url)
            splashPlayer?.play()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { dismissSplash() }
    }

    private func dismissSplash() {
        guard showSplash else { return }
        withAnimation(.easeOut(duration: 0.4)) { showSplash = false }
        playWelcome()
    }
    // Dog celebration: confetti + popup when ALL missions are done.
    @State private var showingDogCelebration = false
    @AppStorage("ghar.dog.celebrated") private var dogCelebrated = false
    @State private var showingBallCelebration = false
    @AppStorage("ghar.ball.celebrated") private var ballCelebrated = false
    @AppStorage("ghar.dog.name") private var dogName = "Bhunte"

    /// Decks in the kid's custom order. New decks not yet ordered go last.
    /// Default: alphabet, numbers, colors lead the beginner tier.
    private var orderedDecks: [Deck] {
        guard let pack else { return [] }
        let order = (try? JSONDecoder().decode([String].self, from: deckOrderData)) ?? []
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let defaultRank: [String: Int] = ["alphabet": 0, "numbers": 1, "colors": 2]
        return pack.decks.sorted {
            let r0 = rank[$0.id] ?? defaultRank[$0.id] ?? Int.max
            let r1 = rank[$1.id] ?? defaultRank[$1.id] ?? Int.max
            return (r0, $0.id) < (r1, $1.id)
        }
    }

    /// Difficulty tiers in display order.
    private let tiers = ["beginner", "intermediate", "hard", "teen"]
    private let tierTitles = ["beginner": "🌱 Beginner", "intermediate": "🌿 Intermediate", "hard": "🌳 Hard", "teen": "🔥 Teen"]

    /// Decks grouped by difficulty tier, each in the kid's custom order.
    private var decksByTier: [(tier: String, title: String, decks: [Deck])] {
        tiers.map { tier in
            (tier, tierTitles[tier]!, orderedDecks.filter { ($0.difficulty ?? "beginner") == tier })
        }
    }

    // MARK: - Next up guide

    /// Word-level tracing progress, shared with the deck screens.
    private var nextUpTracedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: nextUpTracedData)) ?? []
    }

    /// The first deck (tier order, then the kid's order) with untraced
    /// words left — and how many. Decks with no traceable words are
    /// skipped. This is the guide's idea of "what's next".
    private var nextUpDeckProgress: (deck: Deck, remaining: Int)? {
        for section in decksByTier {
            for deck in section.decks {
                let traceWords = deck.words.filter { $0.tracePoints != nil }
                guard !traceWords.isEmpty else { continue }
                let remaining = traceWords.filter { !nextUpTracedIDs.contains($0.id) }.count
                if remaining > 0 { return (deck, remaining) }
            }
        }
        return nil
    }

    private var nextUpIcon: String {
        if !Streak.dailyDoneToday { return "⭐" }
        return nextUpDeckProgress == nil ? "🎉" : "✏️"
    }

    private var nextUpTitle: String {
        if !Streak.dailyDoneToday { return "Today's challenge" }
        if let (deck, _) = nextUpDeckProgress { return "Next up: \(deck.title)" }
        return "All caught up!"
    }

    private var nextUpSubtitle: String {
        if !Streak.dailyDoneToday {
            return "\(DailyChallenge.today().title) — finish for +15 XP"
        }
        if let (_, remaining) = nextUpDeckProgress {
            return "\(remaining) more to trace"
        }
        return "Every deck is traced — try a quiz or Balloon Pop"
    }

    private func nextUpTapped() {
        // Challenge first: it lives on the Missions tab.
        if !Streak.dailyDoneToday { selectedTab = 1; return }
        // All traced: send them to the Quiz tab.
        guard let (deck, _) = nextUpDeckProgress else { selectedTab = 2; return }
        // Same free/premium gate as DeckRow.
        if deck.id == "alphabet" || deck.id == "numbers" || isUnlocked {
            nextUpDeck = deck
            nextUpDeckShown = true
        } else {
            nextUpPaywall = true
        }
    }

    @ViewBuilder
    private var nextUpCard: some View {
        Button(action: nextUpTapped) {
            HStack(spacing: 12) {
                Text(nextUpIcon).font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(nextUpTitle).font(.headline)
                    Text(nextUpSubtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: [.orange.opacity(0.18), .yellow.opacity(0.10)],
                                         startPoint: .leading, endPoint: .trailing))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .navigationDestination(isPresented: $nextUpDeckShown) {
            if let deck = nextUpDeck {
                lessonDestination(for: deck)
                    .onAppear { DeckIntro.play(for: deck.id) }
            }
        }
        .sheet(isPresented: $nextUpPaywall) { PaywallView() }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    /// Which tiers are expanded. Collapsed by default.
    @State private var expandedTiers: Set<String> = []

    private func tierBinding(for tier: String) -> Binding<Bool> {
        Binding(
            get: { expandedTiers.contains(tier) },
            set: { if $0 { expandedTiers.insert(tier) } else { expandedTiers.remove(tier) } }
        )
    }

    /// Tier header picture: kids for beginner, family for intermediate, hard-tier art for hard.
    @ViewBuilder
    private func tierImage(for tier: String) -> some View {
        Group {
            if tier == "beginner" {
                // Single portrait, same 64×64 rounded style as the other tiers.
                Image("boy-neutral")
                    .resizable().scaledToFill()
                    .frame(width: 64, height: 64, alignment: .top)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if tier == "teen" {
                // Teen tier: flame symbol.
                Image(systemName: "flame.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                    .frame(width: 64, height: 64)
            } else if tier == "intermediate" {
                AsyncImage(url: URL(string: GharAPI.baseURLString + "/images/nepal-v1/cover_family.jpg")) { phase in
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
            } else {
                // Som's uploaded art, bundled via images_b64.
                AsyncImage(url: URL(string: GharAPI.baseURLString + "/images/nepal-v1/hard-tier.jpg")) { phase in
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
        }
    }

    /// Big tier header: picture + large title.
    @ViewBuilder
    private func tierHeader(tier: String, title: String) -> some View {
        HStack(spacing: 12) {
            tierImage(for: tier)
            Text(title)
                .font(.title2)
                .bold()
        }
        .padding(.vertical, 4)
    }

    /// Drag-and-drop within one tier section: rebuild the persisted order.
    private func moveDeck(in tier: String, from source: IndexSet, to destination: Int) {
        var sectionIds = decksByTier.first { $0.tier == tier }!.decks.map(\.id)
        sectionIds.move(fromOffsets: source, toOffset: destination)
        var newOrder: [String] = []
        for t in tiers {
            if t == tier {
                newOrder += sectionIds
            } else {
                newOrder += orderedDecks.filter { ($0.difficulty ?? "beginner") == t }.map(\.id)
            }
        }
        deckOrderData = (try? JSONEncoder().encode(newOrder)) ?? Data()
    }

    /// True when the kid has exhausted the free tier: 2 missions done,
    /// 5 quiz questions used, 3 decorations owned. Triggers the one-time
    /// celebratory paywall.
    private var hasFinishedFreeTier: Bool {
        let missions = (try? JSONDecoder().decode(Set<String>.self, from: completedData)) ?? []
        let owned = (try? JSONDecoder().decode(Set<String>.self, from: ownedData)) ?? []
        let purchasable = owned.subtracting(["goldenDiyo", "starBadge", "mukut", "flameDiyo", "streakCrown", "quiz50", "quiz100", "quiz250", "quiz500"])
        return missions.count >= 2 && quizFreeUsed >= 5 && purchasable.count >= 3
    }

    var body: some View {
        Group {
            if let pack {
                TabView(selection: $selectedTab) {
                    // --- Tab 1: Lessons (collapsible difficulty tiers) ---
                    NavigationStack {
                        List {
                            // The next-up guide: one clear "do this next"
                            // card above the tiers (challenge, then the
                            // first unfinished tracing deck, then quizzes).
                            nextUpCard
                            ForEach(decksByTier, id: \.tier) { section in
                                DisclosureGroup(isExpanded: tierBinding(for: section.tier)) {
                                    ForEach(section.decks) { deck in
                                        DeckRow(deck: deck)
                                    }
                                    .onMove { source, dest in
                                        moveDeck(in: section.tier, from: source, to: dest)
                                    }
                                    // Rhymes live in the Beginner tier.
                                    if section.tier == "beginner" {
                                        NavigationLink {
                                            // Premium gate (audit, 2026-10-23): songs and
                                            // rhymes are paid content like every non-free
                                            // deck — a locked tap lands on the paywall,
                                            // never the content.
                                            if isUnlocked { RhymesView() } else { PaywallView() }
                                        } label: {
                                            HStack(spacing: 12) {
                                                Text("🎶").font(.title2)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text("Rhymes").font(.headline)
                                                    Text("Sing along in Nepali").font(.caption).foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                    }
                                    // Songs live in the Hard tier.
                                    if section.tier == "hard" {
                                        NavigationLink {
                                            if isUnlocked { SongsView() } else { PaywallView() }
                                        } label: {
                                            HStack(spacing: 12) {
                                                Text("🎵").font(.title2)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text("Songs").font(.headline)
                                                    Text("Sing along in Nepali").font(.caption).foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    tierHeader(tier: section.tier, title: section.title)
                                }
                            }
                        }
                        .navigationTitle("Ghar 🇳🇵")
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button { showingParents = true } label: {
                                    Image(systemName: "person.crop.circle")
                                }
                                .accessibilityLabel("For grown-ups")
                            }
                            ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
                        }
                        .sheet(isPresented: $showingParents) {
                            ParentsView()
                        }
                    }
                    .tabItem {
                        Label("Lessons", systemImage: "book.fill")
                    }
                    .tag(0)

                    // --- Tab 2: Missions (new!) ---
                    NavigationStack {
                        MissionsView(missions: pack.missions, words: pack.decks.flatMap { $0.words })
                            .navigationTitle("Missions")
                    }
                    .tabItem {
                        Label("Missions", systemImage: "flag.fill")
                    }
                    .tag(1)

                    // --- Tab 3: Quiz (listening game, with sections) ---
                    NavigationStack {
                        QuizMenuView(pack: pack)
                            .navigationTitle("Quiz")
                    }
                    .tabItem {
                        Label("Quiz", systemImage: "questionmark.circle.fill")
                    }
                    .tag(2)

                    // --- Tab 4: My Ghar (the house you build with XP) ---
                    NavigationStack {
                        MyGharView(pack: pack)
                            .navigationTitle("My Ghar")
                    }
                    .tabItem {
                        Label("My Ghar", systemImage: "house.fill")
                    }
                    .tag(3)

                    // --- Tab 5: Leaderboard (family XP/streak/quiz/missions) ---
                    NavigationStack {
                        LeaderboardView()
                            .navigationTitle("Leaderboard")
                    }
                    .tabItem {
                        Label("Leaderboard", systemImage: "trophy.fill")
                    }
                    .tag(4)
                }
                // Celebratory paywall: once, when the free tier is exhausted.
                .onChange(of: hasFinishedFreeTier) { _, finished in
                    if finished && !isUnlocked && !paywallCelebrated {
                        paywallCelebrated = true
                        showingCelebratoryPaywall = true
                    }
                }
                .sheet(isPresented: $showingCelebratoryPaywall) {
                    PaywallView()
                }
                // Dog celebration: once, when ALL missions are complete.
                // Confetti + popup with a deep link to My Ghar.
                .onChange(of: completedData) { _, _ in
                    let done = (try? JSONDecoder().decode(Set<String>.self, from: completedData)) ?? []
                    let total = pack.missions.count
                    if total > 0 && done.count >= total && !dogCelebrated {
                        dogCelebrated = true
                        showingDogCelebration = true
                        WinFanfare.play()
                        // The reward moment gets the REAL bark, not the words.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                            DogBark.play()
                        }
                    }
                }
                .sheet(isPresented: $showingDogCelebration) {
                    DogCelebrationView(dogName: dogName) {
                        showingDogCelebration = false
                        selectedTab = 3 // Jump to My Ghar.
                    }
                }
                // Golden ball celebration: once, when ALL teen
                // missions are complete — the teen parallel to the
                // dog moment, with its own big screen.
                .onChange(of: completedData) { _, _ in
                    let done = (try? JSONDecoder().decode(Set<String>.self, from: completedData)) ?? []
                    if !TeenMissions.all.isEmpty,
                       TeenMissions.all.allSatisfy({ done.contains($0.id) }),
                       !ballCelebrated {
                        ballCelebrated = true
                        // Grant the ball right here too (My Ghar's
                        // grantBall stays as the backstop).
                        let ownedKey = "ghar.shop.owned"
                        var owned = (try? JSONDecoder().decode(Set<String>.self, from: UserDefaults.standard.data(forKey: ownedKey) ?? Data())) ?? []
                        if owned.insert("goldsoccerball").inserted,
                           let data = try? JSONEncoder().encode(owned) {
                            UserDefaults.standard.set(data, forKey: ownedKey)
                        }
                        showingBallCelebration = true
                        QuizDing.play()
                    }
                }
                .fullScreenCover(isPresented: $showingBallCelebration) {
                    TeenBallCelebrationView {
                        showingBallCelebration = false
                        selectedTab = 3 // Jump to My Ghar.
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { await load() }
            .overlay {
                if showSplash {
                    LaunchSplashView()
                        .transition(.opacity)
                        .onTapGesture { dismissSplash() }
                }
            }
            .onAppear { startSplash() }
            .overlay {
                if let title = deckCelebration {
                    ZStack {
                        ConfettiBurst()
                        VStack(spacing: 8) {
                            Text("🎉").font(.system(size: 52))
                            Text("Deck complete!")
                                .font(.title2).bold()
                            Text("\(title) · +\(DeckProgress.completionBonus) XP")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(24)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .shadow(radius: 12, y: 6)
                    }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                    .onTapGesture { deckCelebration = nil }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deckCompleted)) { note in
                guard let title = note.userInfo?["title"] as? String else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    deckCelebration = title
                }
                // Lessons complete with the plain ding — no voice
                // congratulations (Som's call, 2026-10-23).
                QuizDing.play()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    withAnimation { deckCelebration = nil }
                }
            }
    }

    private func load() async {
        do {
            pack = try await GharAPI.shared.fetchPack()
            // WinFanfare's Nepali cheers come from here: once the pack
            // is in, every win outside the Dashain/Tihar picture quizzes
            // can play Som's recorded praise.
            WinFanfare.praise = pack?.praise ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The Missions tab: a header card (total XP + "X of 5 done" progress bar)
/// plus one tappable card per mission — emoji icon, English title, the
/// prompt, the Nepali title, and an XP pill. Done missions get a green
/// tint + checkmark, grown-up-verified ones a gold tint + star.
/// Tapping a card pushes the detail screen.
///
/// Teaching notes:
/// - `ForEach(missions)` works because Mission is Identifiable (it has `id`).
/// - `NavigationLink(destination:)` turns each card into a tappable link.
///   The card content becomes the label (what you tap); the destination
///   is the screen you land on.
/// - `.buttonStyle(.plain)` stops the link from tinting the whole card blue.
/// - `@AppStorage` here uses the SAME keys as MissionDetailView. Two views
///   declaring the same key share the value live: tap "I did it!" over
///   there, the checkmark appears here with zero extra wiring.
struct MissionsView: View {
    let missions: [Mission]
    let words: [Word]
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.missions.completed") private var completedData = Data()
    @AppStorage("ghar.missions.verified") private var verifiedData = Data()
    @AppStorage("ghar.premium.unlocked") private var isUnlocked = false
    // @AppStorage (not @State): when the quiz or a mission marks the
    // daily done, this view refreshes on its own — same UserDefaults key.
    @AppStorage("ghar.daily.done") private var dailyDoneDate = ""
    @AppStorage("ghar.streak.count") private var streakCount = 0
    @AppStorage("ghar.shop.owned") private var ownedData = Data()
    @State private var showingPaywall = false
    @State private var selectedMissionID: String?
    @State private var showingQuizBlitz = false
    @State private var teachBackSession: TeachBackSession?

    private var dailyDoneToday: Bool { dailyDoneDate == Streak.todayString }

    /// True when every mission is finished. Missions lock once done, so
    /// on a Mission day there is nothing left to "complete for real" —
    /// without a claim path, finishing all missions would make every
    /// Mission day an automatic streak-breaker. (Glitch caught by Som,
    /// 2026-10-21 — he had completed and verified all 10 himself.)
    private var allMissionsComplete: Bool {
        !missions.isEmpty && missions.allSatisfy { completedIDs.contains($0.id) }
    }

    /// Free tier: 2 missions. Everything else needs premium.
    private func isFree(_ mission: Mission) -> Bool {
        mission.id == "tihar-greeting" || mission.id == "count-to-five"
    }

    /// The IDs of finished missions, decoded from storage.
    /// @AppStorage only holds simple types (Int, String, Data...), so a Set
    /// gets JSON-encoded into Data — our little packing trick.
    private var completedIDs: Set<String> {        (try? JSONDecoder().decode(Set<String>.self, from: completedData)) ?? []
    }

    /// Same trick for grown-up-verified missions: the gold-star set.
    private var verifiedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: verifiedData)) ?? []
    }

    /// Playful icon per mission, so the list reads at a glance.
    /// (Hardcoded here — no backend change needed to pick a new icon.)
    private func icon(for mission: Mission) -> String {
        switch mission.id {
        case "tihar-greeting": return "🪔"
        case "count-to-five": return "🔢"
        case "dinner-words": return "🍽️"
        case "deusi-line": return "🎶"
        case "tihar-smell": return "🌸"
        case "teen-text-it": return "💬"
        case "teen-teach-slang": return "🔥"
        case "teen-caption": return "📸"
        case "teen-comeback": return "💥"
        case "teen-lyrics": return "🎵"
        case "teen-order": return "🍔"
        case "teen-call-home": return "📞"
        case "teen-teach-back": return "🗣️"
        default: return "⭐"
        }
    }

    /// How many missions are done — drives the header progress bar.
    private var doneCount: Int {
        missions.filter { completedIDs.contains($0.id) }.count
    }

    private var ownedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: ownedData)) ?? []
    }

    /// Teaser banner: complete ALL missions to unlock the dog for My Ghar.
    /// Shows progress; once unlocked, celebrates instead.
    @ViewBuilder
    private func dogTeaserCard() -> some View {
        if ownedIDs.contains("dog") {
            HStack(spacing: 12) {
                Text("🐕").font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dog unlocked!").font(.headline)
                    Text("Check My Ghar to meet your new buddy.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
            }
            .padding()
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        } else {
            HStack(spacing: 12) {
                Text("🐕").font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mystery reward!").font(.headline)
                    Text("Complete all \(missions.count) missions to earn an amazing reward for My Ghar…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(doneCount)/\(missions.count)")
                    .font(.headline)
                    .foregroundStyle(.orange)
            }
            .padding()
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        }
    }

    @AppStorage("ghar.teenmystery.claimed") private var teenMysteryClaimed = ""

    /// How many teen missions are done — drives the rewards card.
    private var teenDoneCount: Int {
        TeenMissions.all.filter { completedIDs.contains($0.id) }.count
    }

    /// One-time random teen prize at 4 teen missions: grants the
    /// item straight into the shared owned set (My Ghar reads the
    /// same storage), then remembers the claim so it never re-rolls.
    private func claimTeenMystery() {
        let pool = teenPrizeItems.filter { !ownedIDs.contains($0.id) }
        guard let prize = pool.randomElement() ?? teenPrizeItems.first else { return }
        var ids = ownedIDs
        ids.insert(prize.id)
        ownedData = (try? JSONEncoder().encode(ids)) ?? Data()
        teenMysteryClaimed = prize.id
        QuizDing.play()
    }

    /// Teen rewards card: soccer-ball progress + the mystery prize.
    @ViewBuilder
    private func teenRewardsCard() -> some View {
        let ballOwned = ownedIDs.contains("goldsoccerball")
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("⚽").font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ballOwned ? "Golden soccer ball unlocked!" : "Teen rewards")
                        .font(.headline)
                    Text(ballOwned
                         ? "Your golden soccer ball is waiting in My Ghar."
                         : "Finish all \(TeenMissions.all.count) teen missions to win a golden soccer ball for My Ghar.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if ballOwned {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                } else {
                    Text("\(teenDoneCount)/\(TeenMissions.all.count)")
                        .font(.headline)
                        .foregroundStyle(.orange)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text("🎁").font(.title2)
                if !teenMysteryClaimed.isEmpty {
                    let prize = teenPrizeItems.first { $0.id == teenMysteryClaimed }
                    Text("Mystery prize won: \(prize?.icon ?? "🎁") \(prize?.nameEn ?? "") — it's in My Ghar!")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if teenDoneCount >= 4 {
                    Button("Open your mystery prize →") { claimTeenMystery() }
                        .font(.subheadline).bold()
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                } else {
                    Text("A mystery prize waits at 4 teen missions (\(teenDoneCount)/4).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }

    /// Accent color for the icon circle + card border, by mission state.
    private func tint(isVerified: Bool, isDone: Bool) -> Color {
        if isVerified { return .yellow }
        if isDone { return .green }
        return .orange
    }

    /// Difficulty tiers for grouping missions.
    private let tiers = ["beginner", "intermediate", "hard", "teen"]
    private let tierTitles = ["beginner": "🌱 Beginner", "intermediate": "🌿 Intermediate", "hard": "🌳 Hard", "teen": "🔥 Teen"]

    /// Pack missions + the code-built teen set. Everything that
    /// counts PACK missions (the dog, streaks, the header progress)
    /// keeps using `missions`; only display + navigation combine.
    private var allMissions: [Mission] { missions + TeenMissions.all }

    private var missionsByTier: [(tier: String, title: String, missions: [Mission])] {
        tiers.map { tier in
            (tier, tierTitles[tier]!, allMissions.filter { ($0.difficulty ?? "beginner") == tier })
        }
    }

    /// Which tiers are expanded. Collapsed by default.
    @State private var expandedTiers: Set<String> = []

    private func tierBinding(for tier: String) -> Binding<Bool> {
        Binding(
            get: { expandedTiers.contains(tier) },
            set: { if $0 { expandedTiers.insert(tier) } else { expandedTiers.remove(tier) } }
        )
    }

    /// Tier header picture: kids for beginner, family for intermediate, hard-tier art for hard.
    @ViewBuilder
    private func tierImage(for tier: String) -> some View {
        Group {
            if tier == "beginner" {
                // Single portrait, same 64×64 rounded style as the other tiers.
                Image("boy-neutral")
                    .resizable().scaledToFill()
                    .frame(width: 64, height: 64, alignment: .top)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if tier == "teen" {
                // Teen tier: flame symbol.
                Image(systemName: "flame.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                    .frame(width: 64, height: 64)
            } else if tier == "intermediate" {
                AsyncImage(url: URL(string: GharAPI.baseURLString + "/images/nepal-v1/cover_family.jpg")) { phase in
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
            } else {
                // Som's uploaded art, bundled via images_b64.
                AsyncImage(url: URL(string: GharAPI.baseURLString + "/images/nepal-v1/hard-tier.jpg")) { phase in
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
        }
    }

    /// Big tier header: picture + large title.
    @ViewBuilder
    private func tierHeader(tier: String, title: String) -> some View {
        HStack(spacing: 12) {
            tierImage(for: tier)
            Text(title)
                .font(.title2)
                .bold()
        }
        .padding(.vertical, 4)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Header card: big XP total + "X of 5 done" progress bar.
                VStack(spacing: 8) {
                    HStack {
                        Text("⭐")
                            .font(.largeTitle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(totalXP) XP")
                                .font(.title2)
                                .bold()
                            Text("\(doneCount) of \(missions.count) missions done")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    ProgressView(value: Double(doneCount),
                                 total: Double(max(missions.count, 1)))
                        .tint(.orange)
                }
                .padding()
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)

                // Daily Streak Challenge: one featured challenge per day,
                // rotating formats. +15 XP, and doing it keeps the streak alive.
                dailyChallengeCard()

                // Dog teaser: finish ALL missions to unlock a dog for My Ghar.
                dogTeaserCard()

                // Teen rewards: mystery prize at 4 teen missions,
                // soccer ball at all 8.
                teenRewardsCard()

                // One card per mission, in collapsible difficulty tiers. Locked ones show the paywall.
                ForEach(missionsByTier, id: \.tier) { section in
                    if !section.missions.isEmpty {
                        DisclosureGroup(isExpanded: tierBinding(for: section.tier)) {
                            VStack(spacing: 10) {
                                ForEach(section.missions) { mission in
                                    Button {
                                        if isFree(mission) || isUnlocked {
                                            selectedMissionID = mission.id
                                        } else {
                                            showingPaywall = true
                                        }
                                    } label: {
                                        missionCard(for: mission)
                                            .overlay(alignment: .topTrailing) {
                                                if !isFree(mission) && !isUnlocked {
                                                    Image(systemName: "lock.fill")
                                                        .foregroundStyle(.secondary)
                                                        .padding(8)
                                                }
                                            }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            tierHeader(tier: section.tier, title: section.title)
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationDestination(item: $selectedMissionID) { id in
            if let mission = allMissions.first(where: { $0.id == id }) {
                MissionDetailView(mission: mission)
            }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
        }
    }

    /// The daily challenge card: today's featured challenge + streak.
    /// Premium-only. Each format completes through a REAL flow — no
    /// "I did it" button: Quiz Blitz via 5 quiz solves, Mission via a
    /// real mission completion, Teach-back via a real recording.
    @ViewBuilder
    private func dailyChallengeCard() -> some View {
        if !isUnlocked {
            // Locked: premium-only. Tapping opens the paywall.
            Button {
                showingPaywall = true
            } label: {
                HStack(spacing: 12) {
                    Text("\u{1F525}")
                        .font(.largeTitle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Streak Challenge")
                            .font(.headline)
                        Text("A new challenge every day — Premium only")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
        } else {
            let challenge = DailyChallenge.today()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Streak Challenge")
                        .font(.headline)
                    Spacer()
                    Text("\u{1F525} \(streakCount) day\(streakCount == 1 ? "" : "s")")
                        .font(.subheadline)
                        .bold()
                        .foregroundStyle(.orange)
                }
                HStack(spacing: 12) {
                    Text(challenge.icon)
                        .font(.largeTitle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(challenge.title)
                            .font(.subheadline)
                            .bold()
                        Text(challenge.format == .mission && allMissionsComplete
                             ? "You've finished every mission — amazing! Claim today's streak bonus below."
                             : challenge.prompt)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                challengeAction(challenge)
            }
            .padding()
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
            .sheet(isPresented: $showingQuizBlitz) {
                NavigationStack {
                    QuizFeedView(words: words, blitzMode: true)
                        .navigationTitle("Quiz Blitz")
                }
            }
            .sheet(item: $teachBackSession) { session in
                NavigationStack {
                    TeachBackView(words: session.words)
                }
            }
        }
    }

    /// The per-format action row. Done state when finished; otherwise a
    /// Start button that drops the kid into the real flow.
    @ViewBuilder
    private func challengeAction(_ challenge: DailyChallenge) -> some View {
        if dailyDoneToday {
            Label("Done for today! See you tomorrow.", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
        } else {
            switch challenge.format {
            case .mission:
                if allMissionsComplete {
                    // Every mission is done and locked — nothing left to
                    // complete for real, so the day is claimable. Same +15
                    // and same streak credit as any other format's finish.
                    Button("Claim today's bonus \u{2192}") {
                        Streak.markDailyDone()
                        Streak.recordMissionDone()
                        totalXP += challenge.xp
                    }
                    .buttonStyle(.borderedProminent)
                    Text("All missions complete — today's streak is yours for showing up. +15 XP")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    if let refID = challenge.refIDs.first,
                       let suggested = missions.first(where: { $0.id == refID }) {
                        Button("Start: \(suggested.titleEn) \u{2192}") {
                            selectedMissionID = suggested.id
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Text("Complete any mission below for real to finish — +15 XP bonus.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .quizBlitz:
                Button("Start Quiz Blitz \u{2192}") {
                    showingQuizBlitz = true
                }
                .buttonStyle(.borderedProminent)
                Text("Solve 5 quiz questions to finish today's challenge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .teachBack:
                Button("Start Teach-Back \u{2192}") {
                    let words = resolveTeachBackWords()
                    if !words.isEmpty {
                        teachBackSession = TeachBackSession(words: words)
                    }
                }
                .buttonStyle(.borderedProminent)
                Text("Hear the word, record yourself saying it. +15 XP")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The teach-back words: today's picks in order. A lone alphabet letter
    /// is too easy for a daily streak, so it expands to 5 letters.
    private func resolveTeachBackWords() -> [Word] {
        guard !words.isEmpty else { return [] }
        var result: [Word] = []
        for id in DailyChallenge.today().refIDs {
            if let w = words.first(where: { $0.id == id }) {
                result.append(w)
            }
        }
        // Fallback: a real word with audio — never a lone alphabet letter.
        if result.isEmpty {
            if let w = words.first(where: { ($0.hasAudio ?? true) && $0.devanagari.count > 1 }) {
                result = [w]
            } else if let w = words.first {
                result = [w]
            }
        }
        // Som's rule: recording one letter is too easy — make it 5.
        if result.count == 1, result[0].devanagari.count == 1 {
            let letters = Array(words.filter { $0.devanagari.count == 1 }.prefix(5))
            if letters.count == 5 { result = letters }
        }
        return result
    }

    /// A single mission card: emoji icon, titles, prompt, XP pill, status.
    private func missionCard(for mission: Mission) -> some View {
        let isVerified = verifiedIDs.contains(mission.id)
        let isDone = completedIDs.contains(mission.id)
        let accent = tint(isVerified: isVerified, isDone: isDone)
        return HStack(spacing: 12) {
            Text(icon(for: mission))
                .font(.largeTitle)
                .frame(width: 58, height: 58)
                .background(accent.opacity(0.15))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(mission.titleEn)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    if isVerified {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                    } else if isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(mission.promptEn)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack {
                    Text(mission.titleNe)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("+\(mission.xp) XP")
                        .font(.caption)
                        .bold()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(accent.opacity((isDone || isVerified) ? 0.5 : 0),
                              lineWidth: 2)
        )
    }
}

/// Owns the microphone for mission "proof" recordings: the kid records
/// themself doing or saying the mission, then a grown-up listens and
/// confirms. The .m4a lands in the app's documents folder — on the phone,
/// never uploaded anywhere (that's the COPPA-safe part).
///
/// Teaching notes:
/// - `ObservableObject` + `@Published`: when `isRecording` flips, every view
///   watching this object redraws. Same reactive idea as @State, but shared
///   between the detail view and the sheet.
/// - `AVAudioRecorder` writes straight to a file URL. No server involved.
/// - iOS shows the mic permission popup only when WE ask, and only from a
///   user tap — that's why `requestPermission` is called from the button,
///   not from `.onAppear`.
/// - The app must declare NSMicrophoneUsageDescription (in the Xcode target's
///   build settings) or iOS kills the app the moment recording starts.
final class MissionRecorder: ObservableObject {
    @Published var isRecording = false
    private var recorder: AVAudioRecorder?
    // Serial queue for audio-session work: setActive can block the main
    // thread (Xcode purple warning), and serial keeps start/stop from
    // racing each other.
    private let sessionQueue = DispatchQueue(label: "ghar.audioSession", qos: .userInitiated)

    func requestPermission(_ done: @escaping (Bool) -> Void) {
        // iOS 17+: AVAudioApplication replaces the deprecated
        // AVAudioSession.requestRecordPermission.
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    func start(to url: URL) {
        // Session setup goes through sessionQueue (off main thread).
        // The recorder also starts on sessionQueue — AVAudioRecorder.record()
        // internally activates the session, which triggers Xcode's purple
        // warning if called on main.
        sessionQueue.async { [weak self] in
            let session = AVAudioSession.sharedInstance()
            // .defaultToSpeaker: without it, .playAndRecord routes to the
            // earpiece and the grown-up can't hear the kid's recording.
            try? session.setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
            try? session.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try? AVAudioRecorder(url: url, settings: settings)
            recorder?.record()
            let isRecording = recorder?.isRecording ?? false
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.recorder = recorder
                self.isRecording = isRecording
            }
        }
    }

    func stop() {
        // Stop the recorder on sessionQueue too — stop() can deactivate
        // the session internally, which warns on main.
        sessionQueue.async { [weak self] in
            self?.recorder?.stop()
            DispatchQueue.main.async {
                self?.recorder = nil
                self?.isRecording = false
            }
            // Back to playback mode so word audio goes through the speaker.
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
        }
    }
}

/// Step 1 of "Prove it": the kid records themself. Big record button,
/// playback to check it sounds right, re-record as many times as they
/// want, then "Hand to a grown-up" moves to step 2.
struct ProveItSheet: View {
    let mission: Mission
    let proofURL: URL
    @ObservedObject var recorder: MissionRecorder
    let onHandOff: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var hasRecording = false
    @State private var showDenied = false
    // Anti-cheat: proof needs at least 2 seconds of audio.
    @State private var recordedSeconds = 0.0
    @State private var tickTimer: Timer?
    @State private var tooShort = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("🎤 Prove it")
                    .font(.largeTitle)
                    .bold()
                Text(mission.titleEn)
                    .font(.title2)
                Text("Say what you did — or say the Nepali words out loud — then hand the phone to a grown-up.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Button(action: recordTapped) {
                    Label(recorder.isRecording ? "Stop" : "● Record",
                          systemImage: recorder.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : .blue)

                // Live timer: the kid watches the seconds count up, and
                // proof under 2s doesn't count — no more empty "proof".
                if recorder.isRecording {
                    Text(recordedSeconds < 2.0
                         ? String(format: "%.0fs… keep talking!", recordedSeconds)
                         : String(format: "%.0fs — good, you can stop!", recordedSeconds))
                        .font(.headline)
                        .foregroundColor(recordedSeconds < 2.0 ? .secondary : .green)
                }
                if tooShort && !recorder.isRecording {
                    Text("Too short! Say it properly — at least 2 seconds.")
                        .font(.headline)
                        .foregroundStyle(.red)
                }

                if hasRecording && !recorder.isRecording {
                    Button(action: playProof) {
                        Label("▶ Play my recording", systemImage: "play.circle.fill")
                            .font(.title3)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(action: onHandOff) {
                        Label("Hand to a grown-up →", systemImage: "person.fill")
                            .font(.title3)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }

                Text("Your recording stays on this phone. Nobody else hears it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Prove it")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                hasRecording = FileManager.default.fileExists(atPath: proofURL.path)
            }
            .onDisappear {
                tickTimer?.invalidate()
                tickTimer = nil
                if recorder.isRecording { recorder.stop() }
            }
            .alert("Microphone is off", isPresented: $showDenied) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Turn on the microphone for Ghar in Settings to record your proof.")
            }
        }
    }

    private func recordTapped() {
        if recorder.isRecording {
            recorder.stop()
            tickTimer?.invalidate()
            tickTimer = nil
            // Anti-cheat: under 2 seconds of audio doesn't count. Delete
            // the stub so tap-record-tap-stop can't fake proof.
            if recordedSeconds < 2.0 {
                try? FileManager.default.removeItem(at: proofURL)
                hasRecording = false
                tooShort = true
            } else {
                hasRecording = true
                tooShort = false
            }
            return
        }
        recorder.requestPermission { granted in
            if granted {
                recordedSeconds = 0
                tooShort = false
                recorder.start(to: proofURL)
                tickTimer?.invalidate()
                tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                    recordedSeconds += 0.1
                }
            } else {
                showDenied = true
            }
        }
    }

    private func playProof() {
        player?.pause()
        player = AVPlayer(url: proofURL)
        player?.play()
    }
}

/// Step 2 of "Prove it": the grown-up's screen. They listen to the kid's
/// recording and press-and-hold to confirm — a grown-up hold after
/// hearing the whole recording is the verification.
struct GrownUpSheet: View {
    let mission: Mission
    let proofURL: URL
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    // Anti-cheat (strengthened 2026-10-19, Som's call): the Confirm used
    // to unlock the instant ▶ was tapped, so a kid could play one second
    // of their own humming and self-confirm for +25 XP. Now the recording
    // must play to the end AND the confirm is a 2.5s press-and-hold —
    // same gate idea as ParentalGateView, inline instead of a sheet.
    @State private var playbackDone = false
    @State private var endObserver: NSObjectProtocol?
    @State private var holdProgress = 0.0
    @State private var holdTimer: Timer?
    private let holdSeconds = 2.5

    /// How long the kid's recording is — a 2s mumble looks different
    /// from a real teach-back. Loaded async (sync .duration is deprecated).
    @State private var proofSeconds = 0

    private func loadProofDuration() {
        Task {
            if let d = try? await AVURLAsset(url: proofURL).load(.duration) {
                proofSeconds = max(0, Int(d.seconds.rounded()))
            }
        }
    }

    /// Play the proof and flip playbackDone only when it reaches the
    /// end — tapping play and confirming instantly used to work.
    private func playToEnd() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        let item = AVPlayerItem(url: proofURL)
        player = AVPlayer(playerItem: item)
        player?.play()
        playbackDone = false
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { _ in playbackDone = true }
    }

    private func startHold() {
        guard playbackDone, holdTimer == nil, holdProgress < 1 else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            DispatchQueue.main.async {
                holdProgress += 0.05 / holdSeconds
                if holdProgress >= 1 {
                    t.invalidate()
                    holdTimer = nil
                    onConfirm()
                }
            }
        }
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        if holdProgress < 1 { holdProgress = 0 }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("🧑‍🦰 Grown-up check")
                    .font(.largeTitle)
                    .bold()
                Text("Listen to the recording. Did they really do “\(mission.titleEn)”?")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Button(action: playToEnd) {
                    Label("▶ Play recording (\(proofSeconds)s)", systemImage: "play.circle.fill")
                        .font(.title2)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                // Hold-to-confirm gate: a 2.5s press that a quick tap
                // can't fake, unlocked only after the whole recording
                // has been heard. (Mirrors ParentalGateView inline.)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.systemGroupedBackground))
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.green)
                            .frame(width: geo.size.width * max(0, min(1, holdProgress)))
                    }
                    Text(holdProgress >= 1 ? "✓" : "✅ Hold to confirm — mission done")
                        .font(.title3)
                        .bold()
                        .frame(maxWidth: .infinity)
                }
                .frame(height: 60)
                .opacity(playbackDone ? 1 : 0.5)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in startHold() }
                        .onEnded { _ in cancelHold() }
                )
                .accessibilityLabel("Press and hold to confirm the mission")

                if !playbackDone {
                    Text("Play the whole recording first — then a grown-up holds to confirm.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button("Not yet") { dismiss() }
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Grown-up check")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { loadProofDuration() }
            .onDisappear {
                holdTimer?.invalidate()
                if let endObserver {
                    NotificationCenter.default.removeObserver(endObserver)
                }
            }
        }
    }
}

/// Tapping a mission row opens this: the full prompt in English + Nepali,
/// a play button for the recorded instruction, "I did it!" for the quick
/// path, and "Prove it" for the verified path: the kid records themself,
/// hands the phone to a grown-up, and the grown-up confirms.
///
/// Two ways to finish, two rewards:
/// - "I did it!" → +xp. Honor system, same as before.
/// - "Prove it 🎤" → record + grown-up confirm → +verifiedXp (bigger).
///   Proving a mission already done the plain way pays the difference.
/// Teach-back: the kid hears the word, records themselves saying it,
/// plays it back. The recording IS the proof — finishing one completes
/// the daily challenge. On-device, COPPA-safe, nothing uploads.
/// Wraps the teach-back words for .sheet(item:) — the sheet content is
/// guaranteed to have its data, so it can never present blank.
struct TeachBackSession: Identifiable {
    let id = UUID()
    let words: [Word]
}

struct TeachBackView: View {
    let words: [Word]
    @StateObject private var recorder = MissionRecorder()
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var micDenied = false
    @State private var didRecord = false
    @State private var audioPlayer: AVPlayer?
    @State private var clipPlayer: AVPlayer?
    // Anti-cheat (Som's call 2026-10-19): recordings under 2 seconds
    // don't count — before this, Record → instant Stop (pure silence)
    // collected the daily +15 XP. Same pattern as ProveItSheet.
    @State private var recordedSeconds = 0.0
    @State private var tickTimer: Timer?
    @State private var tooShort = false

    private var word: Word { words[index] }
    private var isLast: Bool { index == words.count - 1 }

    private var clipURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("teachback_\(word.id)_\(Streak.todayString).m4a")
    }

    /// Som's recording when the family recorded one, TTS otherwise.
    private func hearIt() {
        if word.hasAudio == true, let url = URL(string: GharAPI.baseURLString + word.audioUrl) {
            audioPlayer?.pause()
            audioPlayer = AVPlayer(url: url)
            audioPlayer?.play()
        } else {
            NepaliSpeaker.say(nepali: word.devanagari, romanized: word.romanized)
        }
    }

    private func advance() {
        didRecord = false
        recordedSeconds = 0
        tooShort = false
        audioPlayer?.pause(); audioPlayer = nil
        clipPlayer?.pause(); clipPlayer = nil
        if isLast {
            totalXP += DailyChallenge.today().xp
            Streak.markDailyDone()
            Streak.recordMissionDone()
            WinFanfare.play()
            dismiss()
        } else {
            index += 1
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Say it like a teacher!")
                .font(.title2)
                .bold()
            if words.count > 1 {
                Text("Word \(index + 1) of \(words.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(word.devanagari)
                .font(.system(size: 64))
            Text(word.romanized)
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Hear it", action: hearIt)
                .buttonStyle(.bordered)

            if didRecord {
                Label("Nice! You said it!", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Button("Hear yourself") {
                    clipPlayer?.pause()
                    clipPlayer = AVPlayer(url: clipURL)
                    clipPlayer?.play()
                }
                .buttonStyle(.bordered)
                Button(isLast ? "Finish +15 XP" : "Next word \u{2192}", action: advance)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else if micDenied {
                Text("Microphone is off — turn it on in Settings to record.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Button(recorder.isRecording ? "Stop recording" : "Record yourself") {
                    if recorder.isRecording {
                        recorder.stop()
                        tickTimer?.invalidate(); tickTimer = nil
                        if recordedSeconds >= 2.0 {
                            didRecord = true
                            tooShort = false
                        } else {
                            tooShort = true
                        }
                    } else {
                        recorder.requestPermission { granted in
                            if granted {
                                recordedSeconds = 0
                                tooShort = false
                                recorder.start(to: clipURL)
                                tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                                    recordedSeconds += 0.1
                                }
                            } else {
                                micDenied = true
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                // Live timer: the kid watches the seconds count up, and
                // recordings under 2s don't count — no more empty proof.
                if recorder.isRecording {
                    Text(recordedSeconds < 2.0
                         ? String(format: "%.0fs\u{2026} keep talking!", recordedSeconds)
                         : String(format: "%.0fs \u{2014} good, you can stop!", recordedSeconds))
                        .font(.headline)
                        .foregroundColor(recordedSeconds < 2.0 ? .secondary : .green)
                }
                if tooShort && !recorder.isRecording {
                    Text("Too short! Say it properly \u{2014} at least 2 seconds.")
                        .font(.headline)
                        .foregroundStyle(.red)
                }
                Text("Say the word out loud, then stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Teach-Back")
    }
}

///   The recording and both checkmarks live on the phone — nothing uploads.
///
/// Teaching notes:
/// - Done-state and verified-state are two separate @AppStorage sets, so
///   the XP math can tell "done" (+xp) apart from "verified" (+verifiedXp).
/// - The two sheets are separate structs owned by this view. Sheets
///   presenting sheets get glitchy, so "hand to grown-up" dismisses the
///   first sheet and raises the second a half-second later.
/// - `verifiedXp` has a default (25) so an older backend that doesn't send
///   the key yet can't break decoding — the app keeps working either way.
struct MissionDetailView: View {
    let mission: Mission
    @State private var player: AVPlayer?
    @StateObject private var recorder = MissionRecorder()
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.missions.completed") private var completedData = Data()
    @AppStorage("ghar.missions.verified") private var verifiedData = Data()
    @AppStorage("ghar.last.win") private var lastWin = ""
    @State private var showConfetti = false
    @State private var showingRecorder = false
    @State private var showingGrownUp = false
    // Re-entrancy guard: blocks rapid double-taps from awarding XP twice
    // before @AppStorage-backed completedIDs/verifiedIDs update.
    @State private var xpBusy = false

    private var completedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: completedData)) ?? []
    }
    private var verifiedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: verifiedData)) ?? []
    }
    private var isDone: Bool { completedIDs.contains(mission.id) }
    private var isVerified: Bool { verifiedIDs.contains(mission.id) }

    /// Teen missions skip the grown-up flow entirely: no recording,
    /// no grown-up sheet — the teen holds to confirm for themselves.
    private var isTeenMission: Bool { mission.difficulty == "teen" }
    @State private var holdProgress = 0.0
    @State private var holdTimer: Timer?
    private let holdSeconds = 2.5

    /// Teen completion: pays the full verified XP in one go and
    /// files the mission in BOTH sets (so its card shows the star),
    /// with the same streak + daily-challenge credit as the
    /// grown-up verified path — a teen proving it for real counts.
    private func markTeenDone() {
        guard !xpBusy, !completedIDs.contains(mission.id) else { return }
        xpBusy = true
        var ids = completedIDs
        var vids = verifiedIDs
        ids.insert(mission.id)
        vids.insert(mission.id)
        totalXP += mission.verifiedXp
        completedData = (try? JSONEncoder().encode(ids)) ?? Data()
        verifiedData = (try? JSONEncoder().encode(vids)) ?? Data()
        // Teen completion sound: the plain ding, not the voice
        // congratulations (Som's call, 2026-10-23).
        QuizDing.play()
        celebrate()
        lastWin = mission.titleEn
        Streak.recordMissionDone()
        if DailyChallenge.today().format == .mission, !Streak.dailyDoneToday {
            Streak.markDailyDone()
            totalXP += DailyChallenge.today().xp
            lastWin = "Daily challenge complete! +15 XP"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            xpBusy = false
        }
    }

    /// The 2.5s hold (mirrors GrownUpSheet's gate): a quick tap
    /// can't fake it, and letting go resets the fill.
    private func startTeenHold() {
        guard !isDone, holdTimer == nil else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            holdProgress += 0.05 / holdSeconds
            if holdProgress >= 1 {
                cancelTeenHold(reset: false)
                markTeenDone()
            }
        }
    }

    private func cancelTeenHold(reset: Bool = true) {
        holdTimer?.invalidate()
        holdTimer = nil
        if reset { holdProgress = 0 }
    }

    /// The proof recording's home: the app's documents folder, on-device.
    private var proofURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mission_\(mission.id)_proof.m4a")
    }

    /// Plain path: +xp once, then locked. No un-do — once a kid does the
    /// mission, they did it. XP never goes backwards.
    private func markDone() {
        guard !xpBusy, !completedIDs.contains(mission.id) else { return }
        xpBusy = true
        var ids = completedIDs
        ids.insert(mission.id)
        totalXP += mission.xp
        // The win moment: voice cheer + confetti.
        WinFanfare.play()
        celebrate()
        lastWin = mission.titleEn
        // Streak: a mission done today keeps the chain alive.
        Streak.recordMissionDone()
        // Daily challenge: completing any mission finishes a Mission day.
        if DailyChallenge.today().format == .mission, !Streak.dailyDoneToday {
            Streak.markDailyDone()
            totalXP += DailyChallenge.today().xp
            lastWin = "Daily challenge complete! +15 XP"
        }
        completedData = (try? JSONEncoder().encode(ids)) ?? Data()
        // Hold the lock briefly: @AppStorage writes are async, and a second
        // tap before they land would read the stale "not done" value and
        // pay XP again. 0.3s is plenty for storage to catch up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            xpBusy = false
        }
    }

    /// Verified path: pays verifiedXp in TOTAL — just the difference if the
    /// plain path already paid xp. Guarded, so it can never double-pay.
    private func markVerified() {
        guard !isVerified, !xpBusy else { return }
        xpBusy = true
        var ids = completedIDs
        var vids = verifiedIDs
        if ids.contains(mission.id) {
            totalXP += mission.verifiedXp - mission.xp
        } else {
            ids.insert(mission.id)
            totalXP += mission.verifiedXp
        }
        vids.insert(mission.id)
        completedData = (try? JSONEncoder().encode(ids)) ?? Data()
        verifiedData = (try? JSONEncoder().encode(vids)) ?? Data()
        WinFanfare.play()
        celebrate()
        lastWin = mission.titleEn
        // Streak parity with markDone (audit fix, 2026-10-21): proving a
        // mission is the most legitimate completion there is, so it must
        // count for the streak and finish a Mission-day challenge too.
        // Before this, a Prove-it-only day silently earned no streak
        // credit and could break the chain.
        Streak.recordMissionDone()
        if DailyChallenge.today().format == .mission, !Streak.dailyDoneToday {
            Streak.markDailyDone()
            totalXP += DailyChallenge.today().xp
            lastWin = "Daily challenge complete! +15 XP"
        }
        // Same async-storage guard as markDone: hold the lock until the
        // @AppStorage write lands, so a double-tap can't double-pay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            xpBusy = false
        }
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

                if isVerified {
                    Label(isTeenMission
                          ? "Done! You confirmed this one yourself."
                          : "Verified! A grown-up confirmed this mission.",
                          systemImage: "star.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if isTeenMission {
                    if !isDone {
                        // Hold-to-confirm: fill the bar over 2.5s to
                        // complete — a mash-tap can't fake a hold.
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(.systemGroupedBackground))
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color.green)
                                    .frame(width: geo.size.width * max(0, min(1, holdProgress)))
                            }
                            Text(holdProgress >= 1 ? "✓" : "✅ Hold to complete — +\(mission.verifiedXp) XP")
                                .font(.title3)
                                .bold()
                                .frame(maxWidth: .infinity)
                        }
                        .frame(height: 60)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in startTeenHold() }
                                .onEnded { _ in cancelTeenHold() }
                        )
                        .accessibilityLabel("Press and hold to complete the mission")
                        Text("No grown-up needed — teens confirm their own missions. Press and hold until it fills.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button(action: markDone) {
                        Label(isDone ? "Done!" : "I did it! +\(mission.xp) XP",
                              systemImage: isDone ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(isDone ? .green : .blue)
                    .disabled(isDone || xpBusy)
                }

                if !isVerified && !isTeenMission {
                    Button(action: { showingRecorder = true }) {
                        // Honest label: if "I did it!" already paid xp,
                        // Prove-it only pays the difference to verifiedXp.
                        let payout = isDone ? mission.verifiedXp - mission.xp : mission.verifiedXp
                        Label("Prove it 🎤 +\(payout) XP",
                              systemImage: "mic.circle.fill")
                            .font(.title3)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)

                    Text("Record yourself doing it, then hand the phone to a grown-up to confirm — worth more XP.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        .sheet(isPresented: $showingRecorder) {
            ProveItSheet(mission: mission, proofURL: proofURL, recorder: recorder) {
                // Sheet-to-sheet handoff: dismiss first, raise the grown-up
                // sheet a beat later so iOS doesn't drop the presentation.
                showingRecorder = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showingGrownUp = true
                }
            }
        }
        .sheet(isPresented: $showingGrownUp) {
            GrownUpSheet(mission: mission, proofURL: proofURL) {
                markVerified()
                showingGrownUp = false
            }
        }
    }

    /// Same streaming trick as DeckView: server address + path from JSON.
    /// Until you record the clips, the file isn't there — AVPlayer just
    /// stays quiet instead of crashing.
    /// The "Play instruction" button: your recording if it's in, TTS in the
    /// meantime so the button never silently does nothing. For bundled
    /// content we verify the file actually exists (not just the flag),
    /// so a stale flag can't mute your voice.
    private func play() {
        let urlString = GharAPI.baseURLString + mission.audioUrl
        if let url = URL(string: urlString) {
            let fileExists: Bool
            if url.isFileURL {
                fileExists = FileManager.default.fileExists(atPath: url.path)
            } else {
                fileExists = mission.hasAudio
            }
            if fileExists {
                player?.pause()
                player = AVPlayer(url: url)
                player?.play()
                return
            }
        }
        // Fallback reads the English instructions in an English voice.
        NepaliSpeaker.say(nepali: mission.promptNe, romanized: mission.promptEn)
    }
}

/// The deck's cover art in the Lessons list: loads from the backend
/// through the same /images route as the animal photos.
/// A deck without cover art just shows a book icon instead.
struct DeckCover: View {
    let deck: Deck

    var body: some View {
        Group {
            if deck.id == "colors" {
                // No photo cover for colors — its own swatches are the cover.
                colorDots
            } else if deck.id == "texting" {
                // Text Pack: chat bubble symbol.
                Image(systemName: "message.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.blue)
            } else if deck.id == "slang" {
                // Slang: fire symbol.
                Image(systemName: "flame.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
            } else if deck.id == "comebacks" {
                // Comebacks: speech bubbles.
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.purple)
            } else if deck.id == "captions" {
                // Captions: camera symbol.
                Image(systemName: "camera.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.pink)
            } else if deck.id == "lyrics" {
                // Lyric Breakdowns: music note.
                Image(systemName: "music.note")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
            } else if let cover = deck.coverImage, cover.hasPrefix("/") {
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

    /// 3×3 mini grid of the deck's own colors.
    private var colorDots: some View {
        let cols = [GridItem(.flexible(), spacing: 4),
                    GridItem(.flexible(), spacing: 4),
                    GridItem(.flexible(), spacing: 4)]
        return LazyVGrid(columns: cols, spacing: 4) {
            ForEach(deck.words.prefix(9)) { word in
                Circle()
                    .fill(Color(hex: word.colorHex ?? "#CCCCCC"))
                    .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
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
        stars: []
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
    } else if deck.kind == "colors" {
        ColorsView(deck: deck)
    } else if deck.kind == "numbers" {
        NumbersView(deck: deck)
    } else if deck.kind == "texting" {
        TextPackView(deck: deck)
    } else {
        DeckView(deck: deck)
    }
}

/// The subtitle under each deck title in the Lessons list.
func lessonSubtitle(for deck: Deck) -> String {
    switch deck.kind {
    case "festival": return "Interactive festival"
    case "convo": return "Interactive conversations"
    case "colors": return "10 colors"
    case "numbers": return "Count to 30"
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
    let word: Word

    var body: some View {
        ZStack {
            if let imagePath = word.image, imagePath.hasPrefix("/") {
                // Real illustration from the backend when the word has one
                // (Dashain); the hand-drawn art below stays as the fallback.
                AsyncImage(url: URL(string: GharAPI.baseURLString + imagePath)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure, .empty:
                        fallbackArt
                    @unknown default:
                        fallbackArt
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                fallbackArt
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
    }

    /// The original hand-drawn emoji art, kept for words without an illustration.
    @ViewBuilder
    private var fallbackArt: some View {
        ZStack {
            switch word.id {
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
    }
}

// The "show me" card: the animation up top, the word, and a Hear-it button.
// It says the word out loud as it opens.
struct TeachingCard: View {
    let word: Word
    let onClose: () -> Void
    @State private var player: AVPlayer?   // kept alive so Som's recording plays through

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            VStack(spacing: 10) {
                TeachingArt(word: word)
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
                        speak()
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
            speak()
        }
    }

    /// Plays Som's recording when one exists; falls back to the phone's
    /// own voice for words still waiting on a recording — the same
    /// pattern the picture quiz uses in its speak(_:).
    private func speak() {
        if word.hasAudio == true,
           let url = URL(string: GharAPI.baseURLString + word.audioUrl) {
            player?.pause()
            player = AVPlayer(url: url)
            player?.play()
        } else {
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
            hotspotFace(spot, word: word, isFound: isFound)
                .scaleEffect(isFound ? 1.18 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isFound)
        }
        .position(x: spot.x * size.width, y: spot.y * size.height)
    }

    // What a hotspot looks like: festivals with real illustrations (Dashain)
    // show them as picture badges; the swing is drawn, everything else is emoji.
    // Unlit diyos sit gray until tapped, then glow.
    @ViewBuilder
    private func hotspotFace(_ spot: FestivalHotspot, word: Word?, isFound: Bool) -> some View {
        if let imagePath = word?.image, imagePath.hasPrefix("/") {
            // Unlit diyos sit gray until tapped, then glow — same as the emoji path.
            let lit = !spot.startsUnlit || isFound
            AsyncImage(url: URL(string: GharAPI.baseURLString + imagePath)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure, .empty:
                    Color.gray.opacity(0.25)
                @unknown default:
                    Color.gray.opacity(0.25)
                }
            }
            .frame(width: 68, height: 68)
            .clipShape(Circle())
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .grayscale(lit ? 0 : 1)
            .opacity(spot.startsUnlit && !lit ? 0.55 : 1)
            .shadow(color: spot.startsUnlit && lit ? .orange : .black.opacity(0.3),
                    radius: spot.startsUnlit && lit ? 14 : 6)
            .scaleEffect(isFound ? 1.12 : 1.0)
            .modifier(HotspotMotionModifier(motion: spot.motion, anchor: .top))
        } else if spot.id == "dash_ping" {
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
                // "Say it this Dashain": its own tappable section, tap a phrase to hear it.
                // Only decks with phrases in the JSON (Dashain) show this section.
                if let phrases = deck.phrases, !phrases.isEmpty {
                    DisclosureGroup {
                        ForEach(phrases.indices, id: \.self) { i in
                            let phrase = phrases[i]
                            Button {
                                play(phrase: phrase)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(phrase.devanagari)
                                            .font(.headline)
                                        Text(phrase.english)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        Text("Say it this \(deck.title) 🗣️")
                            .font(.headline)
                    }
                    .padding(.horizontal)
                }
                ForEach(deck.words) { word in
                    WordRow(word: word, onPlay: play(word:),
                            deckID: deck.id, deckWords: deck.words)
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

    /// Same as DeckView's: builds the full audio URL and plays Som's recording.
    private func play(word: Word) {
        DeckProgress.markHeard(word.id)
        DeckProgress.evaluate(deck)
        guard let url = URL(string: GharAPI.baseURLString + word.audioUrl) else { return }
        player?.pause()
        player = AVPlayer(url: url)
        player?.play()
    }

    /// "Say it this Dashain/Tihar": Som's recording when he's recorded the
    /// phrase, otherwise the phone's own voice — same pattern as the
    /// teaching card's speak().
    private func play(phrase: FestivalPhrase) {
        if phrase.hasAudio == true,
           let audioUrl = phrase.audioUrl,
           let url = URL(string: GharAPI.baseURLString + audioUrl) {
            player?.pause()
            player = AVPlayer(url: url)
            player?.play()
        } else {
            NepaliSpeaker.say(nepali: phrase.devanagari, romanized: phrase.romanized)
        }
    }
}

/// Daily Conversations: the animated courtyard scene on top (tappable
/// phrase bubbles, same engine as the festival scenes), the Practice
/// role-play game in the middle, and the full phrase list below —
/// grouped by section like DeckView, each row opening a teaching card.
struct ConversationsView: View {
    let deck: Deck
    @State private var teachingWord: Word?   // open phrase = show the "show me" card
    @StateObject private var speaker = DialogueSpeaker()  // one voice for every dialogue card
    @State private var openSection: Int? = nil   // which conversation is expanded; nil = all closed
    private let sectionTints: [Color] = [.teal, .indigo, .pink]

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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    Text("Two friends talking — tap a conversation to open it, then hit ▶ to watch it play out, or tap a line to hear it.")
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
                        ConversationSection(
                            title: grouped[i].header ?? "Conversation",
                            words: grouped[i].words,
                            tint: sectionTints[i % sectionTints.count],
                            isOpen: openSection == i,
                            speaker: speaker,
                            onToggle: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    openSection = (openSection == i) ? nil : i
                                }
                                speaker.stop()   // cut any audio from the section being closed
                                if openSection == i {
                                    // Let the card finish expanding, then bring it into view.
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                        withAnimation { proxy.scrollTo("section-\(i)", anchor: .top) }
                                    }
                                }
                            },
                            onInfo: { teachingWord = $0 }
                        )
                        .id("section-\(i)")
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
        }
        .navigationTitle(deck.title)
        .overlay {
            if let word = teachingWord {
                TeachingCard(word: word) { teachingWord = nil }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: teachingWord?.id)
        .onAppear { DeckProgress.evaluate(deck) }
        .onDisappear { DeckProgress.evaluate(deck) }
    }
}

/// One text-to-speech voice shared by every dialogue card on this screen.
///
/// Why a delegate instead of a timer: `AVSpeechSynthesizerDelegate.didFinish`
/// fires the instant a line finishes speaking, so auto-play steps to the next
/// line with perfect timing — no guessing how long a sentence takes to say.
///
/// Two subtleties worth knowing:
/// - `stopSpeaking(at: .immediate)` triggers `didCancel`, never `didFinish`,
///   so cutting a line off can't accidentally advance the conversation.
/// - If card B hits play while card A is mid-line, A is "preempted": its
///   `onPreempt` resets its UI so it doesn't sit there looking stuck.
final class DialogueSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    // nonisolated(unsafe): AVSpeechSynthesizer isn't Sendable, but this
    // instance only ever speaks from the main thread via SwiftUI.
    private nonisolated(unsafe) let synth = AVSpeechSynthesizer()
    private var onFinish: (() -> Void)?
    private var onPreempt: (() -> Void)?
    /// Keeps a recording alive while it plays.
    private var player: AVPlayer?
    private var playerObserver: NSObjectProtocol?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Speak one line. `onFinish` runs on the main thread when the line ends
    /// on its own; `onPreempt` runs if a later `play` cuts it off first.
    /// Always called on the main thread (button taps and delegate callbacks).
    ///
    /// His recording wins when it exists — TTS is the fallback.
    func play(word: Word, onFinish: @escaping () -> Void, onPreempt: @escaping () -> Void) {
        DeckProgress.markHeard(word.id)
        if self.onFinish != nil {
            self.onPreempt?()   // someone else was mid-line — reset their UI first
        }
        self.onFinish = onFinish
        self.onPreempt = onPreempt
        stopAudio()

        if word.hasAudio == true,
           let url = URL(string: GharAPI.baseURLString + word.audioUrl) {
            let item = AVPlayerItem(url: url)
            player = AVPlayer(playerItem: item)
            // When the recording ends, fire the finish callback so the
            // conversation auto-play steps to the next line.
            playerObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item, queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                let cb = self.onFinish
                self.onFinish = nil
                self.onPreempt = nil
                self.stopAudio()
                if let cb = cb { cb() }
            }
            player?.play()
            return
        }
        playTTS(nepali: word.devanagari, romanized: word.romanized)
    }

    /// TTS-only path (for callers without a Word).
    func play(nepali: String, romanized: String, onFinish: @escaping () -> Void, onPreempt: @escaping () -> Void) {
        if self.onFinish != nil {
            self.onPreempt?()
        }
        self.onFinish = onFinish
        self.onPreempt = onPreempt
        stopAudio()
        playTTS(nepali: nepali, romanized: romanized)
    }

    private func playTTS(nepali: String, romanized: String) {
        synth.stopSpeaking(at: .immediate)
        let utterance: AVSpeechUtterance
        if let nepaliVoice = AVSpeechSynthesisVoice(language: "ne-NP") {
            utterance = AVSpeechUtterance(string: nepali)
            utterance.voice = nepaliVoice
        } else {
            // No Nepali voice on this device (simulators never have one):
            // fall back to the romanized spelling so it's still audible.
            utterance = AVSpeechUtterance(string: romanized)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        utterance.rate = 0.45   // slow — these are learners listening
        synth.speak(utterance)
    }

    /// Full stop: no finish callback, no preempt callback, silence now.
    func stop() {
        onFinish = nil
        onPreempt = nil
        stopAudio()
    }

    /// Stop any in-flight audio (recording or TTS) without firing callbacks.
    private func stopAudio() {
        if let obs = playerObserver {
            NotificationCenter.default.removeObserver(obs)
            playerObserver = nil
        }
        player?.pause()
        player = nil
        synth.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let cb = onFinish
        onFinish = nil
        onPreempt = nil
        if let cb = cb {
            DispatchQueue.main.async { cb() }
        }
    }
}

/// The brain of one dialogue card: which line is playing, who is talking.
///
/// A class, not a struct: the speech-finish callbacks need a stable reference
/// to mutate. `generation` guards against stale callbacks — every new line
/// bumps it, and a callback carrying an older generation is ignored.
final class DialoguePlayer: ObservableObject {
    @Published var autoIndex: Int? = nil        // nil = not auto-playing
    @Published var talkingSpeaker: String? = nil   // "A", "B", or nil
    @Published var speakingWord: Word? = nil   // the line on the "now speaking" bubble

    let words: [Word]
    private let speaker: DialogueSpeaker
    private var generation = 0

    init(words: [Word], speaker: DialogueSpeaker) {
        self.words = words
        self.speaker = speaker
    }

    /// Tap a bubble: stop everything else, hear just that line.
    func tapLine(_ index: Int) {
        guard words.indices.contains(index) else { return }
        stop()
        generation += 1
        let g = generation
        let word = words[index]
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
            talkingSpeaker = word.speaker
            speakingWord = word
        }
        speaker.play(word: word,
            onFinish: { [weak self] in
                guard let self = self, self.generation == g else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    self.talkingSpeaker = nil
                    self.speakingWord = nil
                }
            },
            onPreempt: { [weak self] in self?.handlePreempt() })
    }

    /// The ▶ / Stop button.
    func toggleAutoPlay() {
        if autoIndex != nil { stop() } else { startAutoPlay() }
    }

    func stop() {
        generation += 1
        autoIndex = nil
        talkingSpeaker = nil
        speakingWord = nil
        speaker.stop()
    }

    private func startAutoPlay() {
        guard !words.isEmpty else { return }
        autoIndex = 0
        playCurrent()
    }

    /// Speak the current auto-play line; when it finishes, `didFinishLine`
    /// steps to the next one — that callback chain IS the conversation loop.
    private func playCurrent() {
        guard let i = autoIndex, words.indices.contains(i) else { return }
        generation += 1
        let g = generation
        let word = words[i]
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
            talkingSpeaker = word.speaker
            speakingWord = word
        }
        speaker.play(word: word,
            onFinish: { [weak self] in
                guard let self = self, self.generation == g else { return }
                self.didFinishLine()
            },
            onPreempt: { [weak self] in self?.handlePreempt() })
    }

    private func didFinishLine() {
        guard let i = autoIndex else { return }
        let next = i + 1
        if next < words.count {
            // A beat between lines — a breath before the next person speaks.
            // speakingWord stays put so the bubble lingers on the line just
            // spoken; the characters go quiet for the pause.
            withAnimation(.easeOut(duration: 0.2)) { talkingSpeaker = nil }
            generation += 1
            let g = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self = self, self.generation == g, self.autoIndex == i else { return }
                self.autoIndex = next
                self.playCurrent()
            }
        } else {
            withAnimation(.easeOut(duration: 0.25)) {
                autoIndex = nil
                talkingSpeaker = nil
                speakingWord = nil
            }
        }
    }

    /// Another card took the shared speaker: reset the UI, ignore late callbacks.
    private func handlePreempt() {
        generation += 1
        autoIndex = nil
        talkingSpeaker = nil
        speakingWord = nil
    }
}

enum PersonAge { case boy, girl }

/// A and B as real illustrations (PNGs in Assets.xcassets),
/// instead of drawn shapes. Two frames per person — mouth closed and mouth
/// open — flipped on the bob timer while talking, so their mouths actually
/// move. The rest of the life (breathing float, listener nod, scale-up,
/// sound waves) is the same animation kit as before.
///
/// Teaching notes:
/// - The portraits live in the asset catalog as .imageset folders.
///   `Portraits` (below) loads each with `UIImage(named:)` — the standard
///   iOS way to use image assets, no extra code needed.
/// - The mouth flip-flops on `bob`, the same @State Bool that bobs the body:
///   every time the body bobs down, the mouth-open frame shows. Two frames
///   alternating fast reads as talking — classic cartoon trick.
struct IllustratedPerson: View {
    let age: PersonAge
    let facingRight: Bool   // A (left) looks right; B (right) looks left
    let talking: Bool
    let listening: Bool

    @State private var breathe = false
    @State private var bob = false
    @State private var nod = false

    private var neutral: UIImage? {
        age == .boy ? Portraits.boyNeutral : Portraits.girlNeutral
    }
    private var mouthOpen: UIImage? {
        age == .boy ? Portraits.boyTalking : Portraits.girlTalking
    }

    var body: some View {
        ZStack(alignment: facingRight ? .topTrailing : .topLeading) {
            Group {
                if let uiImage = (talking && bob ? mouthOpen : neutral) ?? neutral {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(height: age == .boy ? 148 : 126)
                } else {
                    // Portrait failed to decode — a placeholder so the card never breaks.
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 90))
                        .foregroundStyle(.secondary)
                }
            }
            .rotationEffect(.degrees((talking && bob ? 2.5 : 0) * (facingRight ? 1 : -1)))
            .offset(y: (breathe ? 1.5 : 0) + (bob ? -3 : 0) + (nod ? 3 : 0))
            .scaleEffect(talking ? 1.06 : 1.0)
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: talking)
            .background(alignment: .bottom) {
                // Soft ground shadow — plants their feet so they don't float.
                Ellipse()
                    .fill(.black.opacity(0.08))
                    .frame(width: 72, height: 12)
                    .offset(y: 4)
            }
            // Sound waves by the head while talking.
            if talking {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(age == .boy ? .blue : .orange)
                            .frame(width: 4, height: 8 + CGFloat(i) * 5)
                    }
                }
                .opacity(bob ? 1 : 0.35)
                .padding(facingRight ? .trailing : .leading, 6)
                .padding(.top, 26)
            }
        }
        .onAppear {
            breathe = false
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .onChange(of: talking) { _, isTalking in
            if isTalking {
                withAnimation(.easeInOut(duration: 0.32).repeatForever(autoreverses: true)) { bob = true }
            } else {
                withAnimation(.easeOut(duration: 0.25)) { bob = false }
            }
        }
        .onChange(of: listening) { _, isListening in
            if isListening {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) { nod = true }
            } else {
                withAnimation(.easeOut(duration: 0.4)) { nod = false }
            }
        }
    }
}

/// The line being spoken, floating above the speaker comic-style while the
/// conversation plays. The tail points down toward whoever's talking.
struct NowSpeakingBubble: View {
    let word: Word
    let isA: Bool

    var body: some View {
        VStack(spacing: 1) {
            Text(word.devanagari)
                .font(.subheadline.bold())
                .lineLimit(2)
            Text(word.romanized)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
        .overlay(alignment: isA ? .bottomLeading : .bottomTrailing) {
            ChatTail()
                .fill(.white)
                .frame(width: 18, height: 11)
                .offset(x: isA ? 22 : -22, y: 10)
        }
    }
}

/// The illustrated characters, loaded from Assets.xcassets.
/// (The four portrait PNGs live in their own .imageset folders there —
/// drag new art into the matching imageset to swap a character's look.)
/// `static let` = loaded lazily once, on first use — not at app launch.
enum Portraits {
    static let boyNeutral = UIImage(named: "boy-neutral")
    static let boyTalking = UIImage(named: "boy-talking")
    static let girlNeutral = UIImage(named: "girl-neutral")
    static let girlTalking = UIImage(named: "girl-talking")
}

/// A downward triangle — the little tail on a chat bubble.
/// (The file already has a `Triangle`, but that one points up for roofs
/// and prayer flags, so this gets its own name.)
struct ChatTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// One line of the conversation as a chat bubble: A's lines hug the left in
/// blue, B's hug the right in orange. Tap the bubble to hear it; ⓘ opens the
/// teaching card with the word-by-word breakdown.
struct DialogueBubble: View {
    let word: Word
    let isA: Bool
    let talking: Bool
    let onTap: () -> Void
    let onInfo: () -> Void

    private var tint: Color { isA ? .blue : .orange }

    var body: some View {
        HStack {
            if !isA { Spacer(minLength: 48) }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: isA ? .leading : .trailing, spacing: 3) {
                    Text(word.devanagari)
                        .font(.headline)
                    Text(word.romanized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(word.english)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(action: onInfo) {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .background(tint.opacity(0.13))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: isA ? .bottomLeading : .bottomTrailing) {
                ChatTail()
                    .fill(tint.opacity(0.13))
                    .frame(width: 16, height: 10)
                    .offset(x: isA ? 18 : -18, y: 5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(talking ? tint : .clear, lineWidth: 2.5)
            }
            .scaleEffect(talking ? 1.03 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: talking)
            .onTapGesture(perform: onTap)
            if isA { Spacer(minLength: 48) }
        }
    }
}

/// One conversation section as a stage: A (blue, left) and B (orange, right)
/// face each other up top; their lines play out as chat bubbles below.
/// ▶ plays the whole exchange line by line — whoever's line it is animates
/// while it's spoken. Tap any line to hear just that one.
/// One conversation in the accordion: a tappable header row that's always
/// visible, with the DialogueCard revealed underneath when open.
/// Only one section opens at a time — tapping another closes the current one
/// (its `onDisappear` stops any playback, so audio never overlaps).
struct ConversationSection: View {
    let title: String
    let words: [Word]
    let tint: Color
    let isOpen: Bool
    let speaker: DialogueSpeaker
    let onToggle: () -> Void
    let onInfo: (Word) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(tint.gradient)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("\(words.count) lines" + (isOpen ? "" : " · tap to open"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)

            if isOpen {
                // header: nil — the section row above already shows the title.
                DialogueCard(header: nil,
                             words: words,
                             speaker: speaker,
                             onInfo: onInfo)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .padding(.top, 10)
            }
        }
    }
}

struct DialogueCard: View {
    let header: String?
    @StateObject private var player: DialoguePlayer
    let onInfo: (Word) -> Void

    init(header: String?, words: [Word], speaker: DialogueSpeaker, onInfo: @escaping (Word) -> Void) {
        self.header = header
        self.onInfo = onInfo
        _player = StateObject(wrappedValue: DialoguePlayer(words: words, speaker: speaker))
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                if let header = header {
                    Text(header)
                        .font(.headline)
                }
                Spacer()
                Button(player.autoIndex != nil ? "Stop" : "▶ Play") {
                    player.toggleAutoPlay()
                }
                .buttonStyle(.bordered)
                .tint(player.autoIndex != nil ? .red : .accentColor)
            }
            // The "now speaking" bubble: while the conversation plays (or a
            // line is tapped), the active line floats above whoever's talking,
            // comic-style. The slot only exists during playback, so the card
            // never jumps mid-conversation.
            if player.autoIndex != nil || player.speakingWord != nil {
                ZStack {
                    if let word = player.speakingWord {
                        HStack(spacing: 0) {
                            if word.speaker != "B" {
                                NowSpeakingBubble(word: word, isA: true)
                                Spacer(minLength: 90)
                            } else {
                                Spacer(minLength: 90)
                                NowSpeakingBubble(word: word, isA: false)
                            }
                        }
                        .id(word.id)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .frame(height: 84)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            // The stage: two friends facing each other —
            // A the boy, B the girl, as real illustrations.
            HStack(alignment: .bottom, spacing: 0) {
                VStack(spacing: 4) {
                    IllustratedPerson(age: .boy, facingRight: true,
                                      talking: player.talkingSpeaker == "A",
                                      listening: player.talkingSpeaker == "B")
                    Text("A")
                        .font(.caption.bold())
                        .foregroundStyle(.blue)
                }
                Spacer()
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 44)
                Spacer()
                VStack(spacing: 4) {
                    IllustratedPerson(age: .girl, facingRight: false,
                                      talking: player.talkingSpeaker == "B",
                                      listening: player.talkingSpeaker == "A")
                    Text("B")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)
            // The conversation.
            VStack(spacing: 10) {
                ForEach(player.words.indices, id: \.self) { idx in
                    let word = player.words[idx]
                    let isA = word.speaker != "B"   // a missing speaker reads as A
                    DialogueBubble(word: word,
                                   isA: isA,
                                   talking: player.autoIndex == idx || (player.autoIndex == nil && player.speakingWord?.id == word.id),
                                   onTap: { player.tapLine(idx) },
                                   onInfo: { onInfo(word) })
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onDisappear { player.stop() }
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
    @StateObject private var speaker = DialogueSpeaker()

    @State private var round = 0
    @State private var options: [Word] = []
    @State private var solved = false
    @State private var wrongIDs: Set<String> = []
    @State private var correctCount = 0
    @State private var finished = false
    @State private var showConfetti = false
    // Real XP earned this run (missed replies pay +2, not +5) — the
    // finish screen shows this instead of correctCount * 5.
    @State private var earnedXP = 0

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
                Text("+\(earnedXP) XP")
                    .font(.title3).bold()
                    .foregroundStyle(.green)
                Button("Practice again") {
                    round = 0
                    correctCount = 0
                    earnedXP = 0
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
                        speaker.play(word: prompt, onFinish: {}, onPreempt: {})
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
                // Visible stakes (Som's ask 2026-10-19): the kid SEES the
                // value drop the moment a miss lands — +5 clean, +2 after.
                Text(wrongIDs.isEmpty ? "⭐ +5 XP" : "😅 +2 XP now")
                    .font(.subheadline)
                    .foregroundStyle(wrongIDs.isEmpty ? .green : .orange)
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
            speaker.play(word: prompt, onFinish: {}, onPreempt: {})
        }
    }

    private func answer(_ option: Word, correctID: String) {
        if option.id == correctID {
            solved = true
            correctCount += 1
            // Anti-mash (Som's call 2026-10-19): a clean first-try pays
            // +5; any miss on this question drops it to +2.
            totalXP += wrongIDs.isEmpty ? 5 : 2
            earnedXP += wrongIDs.isEmpty ? 5 : 2
            QuizStats.recordCorrect()
            // You "say" your line out loud — hearing yourself nail the
            // reply is the reward. (No voice fanfare here: it would talk
            // over your line. The big cheer waits for the finish.)
            speaker.play(word: option, onFinish: {}, onPreempt: {})
            celebrate()
        } else {
            wrongIDs.insert(option.id)
            WrongAnswerFeedback.play()
            QuizStats.recordWrong()
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

/// The Quiz tab menu: one card per quiz section. Words and Animals are
/// listening quizzes (hear the word, tap the meaning); Dashain and Tihar
/// are picture quizzes (see the illustration, tap the meaning). A section
/// with no recorded audio yet (like Animals right now) shows dimmed with
/// a "Coming soon" note — and wakes up on its own the moment Som's
/// recordings land, no code change needed.
struct QuizMenuView: View {
    let pack: ContentPack

    @AppStorage("ghar.premium.unlocked") private var isUnlocked = false
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.shop.owned") private var ownedData = Data()

    private var ownedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: ownedData)) ?? []
    }

    /// The quiz sticker ladder, in earn order.
    private var stickerLadder: [(id: String, icon: String, name: String, need: Int)] {
        [("quiz50", "✨", "Jhilimili", 50),
         ("quiz100", "☀️", "Surya", 100),
         ("quiz250", "🏔️", "Himal", 250),
         ("quiz500", "🗻", "Sagarmatha", 500)]
    }

    private let tierTitles = ["beginner": "🌱 Beginner", "intermediate": "🌿 Intermediate", "hard": "🌳 Hard", "teen": "🔥 Teen"]

    /// (title, icon, accent, words, picture?) per section, grouped by difficulty tier
    /// to match the Lessons tab. Balloon Pop stays featured at the top (it plays
    /// words from every deck, so it belongs to no tier).
    /// Animals and Colors get their own cards; everyday words play together
    /// under Words. Dashain and Tihar are PICTURE quizzes: their words have
    /// beautiful illustrations and no recordings yet, so kids play with eyes
    /// instead of ears. Colors is a LISTENING quiz with swatch answers:
    /// hear the Nepali word, tap the matching color.
    private var tieredSections: [(tier: String, title: String, sections: [(title: String, icon: String, accent: Color, words: [Word], picture: Bool)])] {
        let wordsFor = { (id: String) in pack.decks.first { $0.id == id }?.words ?? [] }
        let wordsForTier = { (tier: String, exclude: [String]) in
            pack.decks.filter { ($0.difficulty ?? "beginner") == tier && !exclude.contains($0.id) }.flatMap { $0.words }
        }
        return [
            ("beginner", tierTitles["beginner"]!, [
                ("Words", "💬", .blue, wordsForTier("beginner", ["animals", "colors"]), false),
                ("Animals", "🐾", .green, wordsFor("animals"), false),
                ("Colors", "🎨", .pink, wordsFor("colors"), false),
            ]),
            ("intermediate", tierTitles["intermediate"]!, [
                ("Words", "📚", .blue, wordsForTier("intermediate", []), false),
            ]),
            ("hard", tierTitles["hard"]!, [
                ("Words", "🧠", .blue, wordsForTier("hard", ["dashain", "tihar", "months"]), false),
                ("Months", "📅", .teal, wordsFor("months"), false),
                ("Dashain", "🪔", .orange, wordsFor("dashain"), true),
                ("Tihar", "✨", .purple, wordsFor("tihar"), true),
            ]),
            ("teen", tierTitles["teen"]!, [
                ("Text Pack", "💬", .blue, wordsFor("texting"), false),
                ("Slang", "🔥", .orange, wordsFor("slang"), false),
                ("Comebacks", "💥", .purple, wordsFor("comebacks"), false),
                ("Captions", "📸", .pink, wordsFor("captions"), false),
                ("Lyrics", "🎵", .green, wordsFor("lyrics"), false),
            ]),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Header: what quizzes are + the XP reward.
                HStack {
                    Text("🎮")
                        .font(.largeTitle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pick a quiz")
                            .font(.title2)
                            .bold()
                        Text("+5 XP per correct answer · ⭐ \(totalXP) XP")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding()
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)

                // Quiz sticker rewards: the ladder the kid is climbing,
                // with live progress toward the next sticker.
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("🏆 Quiz Rewards")
                            .font(.headline)
                        Spacer()
                        Text("\(QuizStats.correctTotal) answers right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        ForEach(stickerLadder, id: \.id) { step in
                            let earned = ownedIDs.contains(step.id)
                            VStack(spacing: 2) {
                                Text(step.icon)
                                    .font(.system(size: 26))
                                    .grayscale(earned ? 0 : 1)
                                    .opacity(earned ? 1 : 0.45)
                                Text(step.name)
                                    .font(.caption2).bold()
                                Text(earned ? "Earned! ✅" : "\(min(QuizStats.correctTotal, step.need))/\(step.need)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding()
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)

                // Balloon Pop: hear the word, pop its balloon. 60-second rounds.
                // Featured at the top — it plays words from every deck, all levels.
                NavigationLink {
                    BalloonPopView(words: pack.decks.flatMap { $0.words })
                } label: {
                    quizCard(title: "Balloon Pop", icon: "🎈",
                             accent: .red,
                             subtitle: "All levels · hear the word, pop its balloon! · 60s rounds",
                             count: 0)
                }
                .buttonStyle(.plain)

                // Bagh-Chal: the classic Nepali tiger-and-goats board game.
                // The kid is the goats; the phone plays the tigers.
                NavigationLink {
                    BaghChalView()
                } label: {
                    quizCard(title: "Bagh-Chal", icon: "🐯",
                             accent: .orange,
                             subtitle: "All levels · trap the tigers with your goats!",
                             count: 0)
                }
                .buttonStyle(.plain)

                ForEach(tieredSections, id: \.tier) { tierGroup in
                    // Tier header, matching the Lessons tab.
                    HStack {
                        Text(tierGroup.title)
                            .font(.title2)
                            .bold()
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 8)

                    // Sentence games live under Intermediate.
                    if tierGroup.tier == "intermediate" {
                        // Sentences: build your first Nepali sentences (यो ___ हो।).
                        if let lesson = SentenceLessons.lesson1(words: pack.decks.flatMap { $0.words }) {
                            NavigationLink {
                                // Premium gate (audit, 2026-10-23): Intermediate
                                // learning content, same rule as the decks.
                                if isUnlocked { SentencesView(lesson: lesson) } else { PaywallView() }
                            } label: {
                                SentencesEntryCard(lesson: lesson)
                            }
                            .buttonStyle(.plain)
                        }

                        // Sentence Builder: tap word tiles in order (म ___ ___छु।).
                        NavigationLink {
                            if isUnlocked { SentenceBuilderView(words: pack.decks.flatMap { $0.words }) } else { PaywallView() }
                        } label: {
                            SentenceBuilderEntryCard()
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(tierGroup.sections.indices, id: \.self) { i in
                        let section = tierGroup.sections[i]
                        let audible = section.words.filter { $0.hasAudio ?? true }
                        let pictured = section.words.filter { $0.image != nil || $0.colorHex != nil }
                        if tierGroup.tier == "teen", section.title == "Lyrics", !section.words.isEmpty {
                            // Lyrics quiz: "What does this song title mean?"
                            // The lyric english fields are paragraphs, so the
                            // options are the short quizShort glosses instead.
                            NavigationLink {
                                LyricsQuizView(words: section.words)
                                    .navigationTitle("Lyrics Quiz")
                            } label: {
                                quizCard(title: section.title, icon: section.icon,
                                         accent: section.accent,
                                         subtitle: "See the title, tap what it means",
                                         count: section.words.count)
                            }
                            .buttonStyle(.plain)
                        } else if !audible.isEmpty, !section.picture {
                            // Listening quiz: hear the word, tap what it means.
                            // Teen tier uses Prakash's voice for right/wrong feedback.
                            NavigationLink {
                                QuizFeedView(words: section.words, isTeen: tierGroup.tier == "teen")
                                    .navigationTitle("\(section.title) Quiz")
                            } label: {
                                quizCard(title: section.title, icon: section.icon,
                                         accent: section.accent,
                                         subtitle: "Hear the word, tap what it means",
                                         count: section.words.count)
                            }
                            .buttonStyle(.plain)
                        } else if section.picture, !pictured.isEmpty {
                            // Picture quiz: see the illustration, tap what it means.
                            NavigationLink {
                                PictureQuizFeedView(words: section.words)
                                    .navigationTitle("\(section.title) Quiz")
                            } label: {
                                quizCard(title: section.title, icon: section.icon,
                                         accent: section.accent,
                                         subtitle: "See the picture, tap what it means",
                                         count: section.words.count)
                            }
                            .buttonStyle(.plain)
                        } else {
                            // Nothing to play with yet — this card enables itself
                            // once recordings or illustrations exist.
                            quizCard(title: section.title, icon: section.icon,
                                     accent: .gray, subtitle: "Coming soon", count: 0)
                                .opacity(0.45)
                        }
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    /// A single quiz-section card: emoji icon, title, how it plays, count.
    private func quizCard(title: String, icon: String, accent: Color,
                          subtitle: String, count: Int) -> some View {
        HStack(spacing: 12) {
            Text(icon)
                .font(.largeTitle)
                .frame(width: 58, height: 58)
                .background(accent.opacity(0.15))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(count > 0 ? "\(subtitle) · \(count) words" : subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: count > 0 ? "chevron.right" : "speaker.slash.fill")
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
    }
}

/// One-card-per-swipe vertical pager for the quiz feeds.
///
/// The native paging ScrollView projects a hard flick's landing from
/// its velocity, so a fast swipe jumps TWO cards — kids hit this
/// constantly, and near the end of a set it lands on the "Set
/// complete!" card, silently skipping the last question or two
/// (the cousin's report, 2026-10-23; gentler swipes never showed
/// it). This pager tracks the finger 1:1 and one gesture can only
/// ever move a single page.
///
/// IDENTITY CONTRACT: pages are positioned by index, so callers
/// must stamp each page's content with `.id(...)` from its data
/// (the card's UUID). Without it, a re-dealt set reuses the old
/// card views at each position — solved state and all (the
/// "answers already shown after Shuffle & keep going" bug,
/// 2026-10-23).
struct StrictVerticalPager<Content: View>: View {
    let pageCount: Int
    @Binding var page: Int
    @ViewBuilder let content: (Int) -> Content
    @State private var dragY: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: 0) {
                ForEach(0..<pageCount, id: \.self) { i in
                    // Windowed rendering: only the current page and
                    // two either side are real views; the rest are
                    // empty placeholders of the same size. Rendering
                    // every card at once (49 for the alphabet set,
                    // each picture card decoding a full-size photo)
                    // made the feeds lag — the old lazy scroll view
                    // only ever built the cards near you.
                    if abs(i - page) <= 2 {
                        content(i)
                            .frame(width: geo.size.width, height: h)
                    } else {
                        Color.clear
                            .frame(width: geo.size.width, height: h)
                    }
                }
            }
            .offset(y: -CGFloat(page) * h + dragOffset)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in dragY = v.translation.height }
                    .onEnded { v in
                        let projected = v.predictedEndTranslation.height
                        var target = page
                        if projected < -70, page < pageCount - 1 { target = page + 1 }
                        if projected > 70, page > 0 { target = page - 1 }
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.92)) {
                            page = target
                            dragY = 0
                        }
                    }
            )
        }
    }

    /// Rubber-band past the first/last page so the ends feel solid.
    private var dragOffset: CGFloat {
        if page == 0, dragY > 0 { return dragY * 0.35 }
        if pageCount > 0, page == pageCount - 1, dragY < 0 { return dragY * 0.35 }
        return dragY
    }
}

/// The Quiz tab: a listening game. Hear a Nepali word, tap what it means.
/// +5 XP per correct answer — fed into the SAME total as missions.
///
/// Teaching notes:
/// - A "question" is just @State: the `current` word, the shuffled
/// TikTok-style quiz feed: one question per full-screen card, swipe up
/// for the next. Audio NEVER auto-plays — the kid taps the big speaker
/// button, so the word you hear always matches the card you see.
/// In blitz mode it's a 5-question sprint with a finish screen.
struct QuizFeedView: View {
    let words: [Word]
    var blitzMode = false
    var isTeen = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.last.win") private var lastWin = ""
    @AppStorage("ghar.premium.unlocked") private var isUnlocked = false
    @AppStorage("ghar.quiz.freeUsed") private var freeUsed = 0
    @State private var showingPaywall = false
    @State private var player: AVPlayer?
    @State private var cards: [QuizCardData] = []
    @State private var page = 0
    @State private var solvedCount = 0
    @State private var blitzDone = false
    @State private var showConfetti = false

    struct QuizCardData: Identifiable {
        // Fresh UUID per deal (not the word id): reshuffles get new
        // identities so the pager never jumps to a stale position.
        let id = UUID()
        let word: Word
        let options: [Word]
    }

    var body: some View {
        if !isUnlocked && freeUsed >= 5 {
            // Free tier lock: 5 questions total, then the paywall.
            VStack(spacing: 16) {
                Text("\u{1F512}").font(.system(size: 56))
                Text("You've used your 5 free questions!")
                    .font(.title2).bold()
                    .multilineTextAlignment(.center)
                Text("Unlock unlimited quizzes with Ghar Premium.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("See Premium") { showingPaywall = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding()
            .sheet(isPresented: $showingPaywall) { PaywallView() }
        } else if blitzMode && blitzDone {
            VStack(spacing: 16) {
                Text("\u{1F389}").font(.system(size: 64))
                Text("Quiz Blitz complete!")
                    .font(.title2).bold()
                Text("5 questions down. See you tomorrow.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding()
        } else if cards.isEmpty {
            // First frame, cards not dealt yet: a neutral loading
            // beat. Without this gate the pager opens on its only
            // page — the "Set complete!" end card — for a visible
            // flash before deal() lands: the first-question glitch.
            VStack(spacing: 12) {
                ProgressView()
                Text("Shuffling questions…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { deal() }
        } else {
            StrictVerticalPager(pageCount: cards.count + (blitzMode ? 0 : 1), page: $page) { i in
                if i < cards.count {
                    QuizFeedCard(data: cards[i], onPlay: playWord,
                                 onSolve: handleSolve, isTeen: isTeen)
                        .id(cards[i].id)
                } else {
                    // End of the set: reshuffle and keep going.
                    VStack(spacing: 16) {
                        Text("\u{1F389}").font(.system(size: 64))
                        Text("Set complete!")
                            .font(.title2).bold()
                        Button("Shuffle & keep going") { deal() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }
            }
            // Auto-play the card that settles on screen — never a preloaded
            // neighbor. Swiping away stops its audio first.
            .onChange(of: page) { _, newPage in
                player?.pause()
                if newPage < cards.count {
                    playWord(cards[newPage].word)
                }
            }
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
    }

    /// Deal a shuffled set of question cards. Free tier is capped so the
    /// lifetime 5-question limit holds.
    private func deal() {
        var audible = words.filter { $0.hasAudio ?? true }
        if blitzMode {
            // Lyrics titles have their own quiz now (LyricsQuizView:
            // short glosses, no audio) — the Blitz is a listening
            // sprint over plain vocab, so they stay out of this pool.
            audible = audible.filter { ($0.quizShort ?? "").isEmpty }
        }
        var count = blitzMode ? 5 : audible.count
        if !isUnlocked {
            count = min(count, max(0, 5 - freeUsed))
            freeUsed += count
        }
        cards = audible.shuffled().prefix(count).map { word in
            let distractors = audible.filter { $0.id != word.id }.shuffled().prefix(3)
            return QuizCardData(word: word,
                                options: ([word] + distractors).shuffled())
        }
        solvedCount = 0
        blitzDone = false
        // Back to the first card of the fresh set. Already on page 0
        // the page-change hook won't fire, so play the word directly;
        // from any other page the hook plays it when we land.
        if page == 0 {
            if let first = cards.first {
                // A small beat so the first word doesn't start under
                // the navigation animation; skipped if the kid has
                // already swiped on (the settle hook owns that card).
                let dealtID = first.word.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if page == 0, cards.first?.word.id == dealtID {
                        playWord(first.word)
                    }
                }
            }
        } else {
            page = 0
        }
    }

    /// Explicit tap only — pause anything playing first so audio from two
    /// cards can never overlap.
    private func playWord(_ word: Word) {
        player?.pause()
        guard let url = URL(string: GharAPI.baseURLString + word.audioUrl) else { return }
        player?.pause()
        player = AVPlayer(url: url)
        player?.play()
    }

    private func handleSolve(_ word: Word, _ missed: Bool) {
        // Anti-mash (Som's call 2026-10-19): clean first-try +5,
        // any miss on this card drops the solve to +2.
        totalXP += missed ? 2 : 5
        solvedCount += 1
        DailyQuiz.recordSolve()
        // Non-teen: ding and move on — no praise cheer per solve
        // (Som, 2026-10-23). Teen decks keep Prakash's cheers.
        if isTeen { WinFanfare.play(teen: true) } else { QuizDing.play() }
        celebrate()
        lastWin = "Quiz: \(word.english)"
        if DailyQuiz.checkBlitzComplete() {
            totalXP += DailyChallenge.today().xp
            lastWin = "Quiz Blitz complete! +15 XP"
        }
        if blitzMode && solvedCount >= 5 {
            blitzDone = true
        }
    }

    private func celebrate() {
        showConfetti = false
        DispatchQueue.main.async { showConfetti = true }
    }
}

/// One full-screen quiz card: big speaker button to hear the word,
/// tap the answer. Wrong taps fade; the right one goes green.
/// After solving, a big Next button (or swipe up) moves on.
/// Each card owns its state — the feed just counts solves.
struct QuizFeedCard: View {
    let data: QuizFeedView.QuizCardData
    let onPlay: (Word) -> Void
    /// missed: true when the kid tapped a wrong option on this card
    /// before solving — the parent pays +2 instead of +5 (anti-mash).
    let onSolve: (Word, Bool) -> Void
    var isTeen = false
    @State private var solved = false
    @State private var wrongIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("What did you hear?")
                .font(.title2).bold()
            Button(action: { onPlay(data.word) }) {
                Label("Hear the word", systemImage: "speaker.wave.2.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // Visible stakes (Som's ask 2026-10-19): the kid SEES the
            // value drop the moment a miss lands — +5 clean, +2 after.
            Text(wrongIDs.isEmpty ? "⭐ +5 XP" : "😅 +2 XP now")
                .font(.headline)
                .foregroundStyle(wrongIDs.isEmpty ? .green : .orange)
            ForEach(data.options) { option in
                Button(action: { answer(option) }) {
                    if let hex = option.colorHex {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(hex: hex))
                            .frame(height: 76)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(swatchBorder(for: option), lineWidth: 4)
                            )
                            .opacity(wrongIDs.contains(option.id) ? 0.35 : 1.0)
                    } else {
                        HStack(spacing: 12) {
                            if let imagePath = option.image, imagePath.hasPrefix("/") {
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
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            Text(option.english)
                                .font(.headline)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(background(for: option))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .disabled(solved)
            }
            if solved {
                VStack(spacing: 2) {
                    Text("Swipe")
                        .font(.title2)
                        .bold()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 44))
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func answer(_ option: Word) {
        guard !solved else { return }
        if option.id == data.word.id {
            solved = true
            QuizStats.recordCorrect()
            onSolve(data.word, !wrongIDs.isEmpty)
        } else {
            wrongIDs.insert(option.id)
            WrongAnswerFeedback.play(teen: isTeen)
            QuizStats.recordWrong()
        }
    }

    private func background(for option: Word) -> Color {
        if solved, option.id == data.word.id { return .green.opacity(0.25) }
        if wrongIDs.contains(option.id) { return .red.opacity(0.25) }
        return .gray.opacity(0.15)
    }

    private func swatchBorder(for option: Word) -> Color {
        if solved, option.id == data.word.id { return .green }
        return .primary.opacity(0.12)
    }
}

/// Lyrics quiz: "What does this song title mean?" — rebuilt 2026-10-19
/// because the lyric `english` fields are full paragraphs (walls of
/// text on quiz buttons). Options use the short `quizShort` gloss
/// instead, so each answer is 2-4 words. The card shows the title
/// big and the kid taps the meaning — and since 2026-10-23 the card
/// also SPEAKS THE TITLE on tap: a short Prakash clip (quiz_<id>)
/// recorded for the quiz. NOT the lessons' sung line — that clip
/// is the whole lyric, far too long for a quiz prompt (Som's call).
/// Solve feedback is the plain ding: no praise clip competes with
/// the question. Same +5 XP rules as the other quizzes.
struct LyricsQuizView: View {
    let words: [Word]
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.last.win") private var lastWin = ""
    @AppStorage("ghar.premium.unlocked") private var isUnlocked = false
    @AppStorage("ghar.quiz.freeUsed") private var freeUsed = 0
    @State private var showingPaywall = false
    @State private var cards: [LyricsCardData] = []
    @State private var page = 0
    @State private var player: AVPlayer?

    /// Speak the settled card's TITLE (short Prakash clip) — the
    /// quiz plays it on its own; the card's button is only a replay.
    /// Pause-first, so titles never overlap.
    private func playTitle(_ word: Word) {
        guard let url = URL(string: GharAPI.baseURLString + "/audio/nepal-v1/quiz_\(word.id)_np.m4a") else { return }
        player?.pause()
        player = AVPlayer(url: url)
        player?.play()
    }

    struct LyricsCardData: Identifiable {
        // Fresh UUID per deal (not the word id): reshuffles get new
        // identities so the pager never jumps to a stale position.
        let id = UUID()
        let word: Word
        let options: [Word]
    }

    private var playable: [Word] {
        words.filter { ($0.quizShort ?? "").isEmpty == false }
    }

    var body: some View {
        if !isUnlocked && freeUsed >= 5 {
            // Free tier lock: 5 questions total, then the paywall.
            VStack(spacing: 16) {
                Text("\u{1F512}").font(.system(size: 56))
                Text("You've used your 5 free questions!")
                    .font(.title2).bold()
                    .multilineTextAlignment(.center)
                Text("Unlock unlimited quizzes with Ghar Premium.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("See Premium") { showingPaywall = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding()
            .sheet(isPresented: $showingPaywall) { PaywallView() }
        } else if cards.isEmpty {
            // First frame, cards not dealt yet: a neutral loading
            // beat. Without this gate the pager opens on its only
            // page — the "Set complete!" end card — for a visible
            // flash before deal() lands: the first-question glitch.
            VStack(spacing: 12) {
                ProgressView()
                Text("Shuffling questions…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { deal() }
        } else {
            StrictVerticalPager(pageCount: cards.count + 1, page: $page) { i in
                if i < cards.count {
                    LyricsQuizCard(data: cards[i], onPlayTitle: playTitle, onSolve: handleSolve)
                        .id(cards[i].id)
                } else {
                    // End of the set: reshuffle and keep going.
                    VStack(spacing: 16) {
                        Text("\u{1F389}").font(.system(size: 64))
                        Text("Set complete!")
                            .font(.title2).bold()
                        Button("Shuffle & keep going") { deal() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }
            }
            // Auto-play the title of the card that settles on screen —
            // never a preloaded neighbor. Swiping away stops it first.
            .onChange(of: page) { _, newPage in
                player?.pause()
                if newPage < cards.count {
                    playTitle(cards[newPage].word)
                }
            }
        }
    }

    /// Deal a shuffled set of question cards. Free tier is capped so the
    /// lifetime 5-question limit holds.
    private func deal() {
        let playable = self.playable
        var count = playable.count
        if !isUnlocked {
            count = min(count, max(0, 5 - freeUsed))
            freeUsed += count
        }
        cards = playable.shuffled().prefix(count).map { word in
            let distractors = playable.filter { $0.id != word.id }.shuffled().prefix(3)
            return LyricsCardData(word: word,
                                  options: ([word] + distractors).shuffled())
        }
        // Back to the first card of the fresh set. Already on page 0
        // the page-change hook won't fire, so play its title directly;
        // from any other page the hook plays it when we land.
        if page == 0 {
            if let first = cards.first {
                // Same settle beat as the listening feed: don't start
                // the title under the navigation animation.
                let dealtID = first.word.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if page == 0, cards.first?.word.id == dealtID {
                        playTitle(first.word)
                    }
                }
            }
        } else {
            page = 0
        }
    }

    private func handleSolve(_ word: Word, _ missed: Bool) {
        // Anti-mash (Som's call 2026-10-19): clean first-try +5,
        // any miss on this card drops the solve to +2.
        totalXP += missed ? 2 : 5
        DailyQuiz.recordSolve()
        QuizStats.recordCorrect()
        // Ding, not Prakash praise: a cheer after every answer
        // would compete with the next question (Som's call,
        // 2026-10-23).
        QuizDing.play()
        lastWin = "Lyrics Quiz: \(word.romanized)"
    }
}

/// One full-screen lyrics quiz card: big song title, tap the meaning.
/// Wrong taps fade red and the kid retries — friendlier for learning
/// than one-strike. The +5 lands exactly once per card.
struct LyricsQuizCard: View {
    let data: LyricsQuizView.LyricsCardData
    /// missed: true when the kid tapped a wrong option on this card
    /// before solving — the parent pays +2 instead of +5 (anti-mash).
    /// Replay the title (the parent auto-plays it on settle).
    let onPlayTitle: (Word) -> Void
    let onSolve: (Word, Bool) -> Void
    @State private var solved = false
    @State private var wrongIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("What does this title mean?")
                .font(.title2).bold()
                .multilineTextAlignment(.center)
            Text(data.word.devanagari)
                .font(.system(size: 44)).bold()
                .multilineTextAlignment(.center)
            Text(data.word.romanized)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { onPlayTitle(data.word) } label: {
                Label("Hear the title", systemImage: "speaker.wave.2.fill")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // Visible stakes (Som's ask 2026-10-19): the kid SEES the
            // value drop the moment a miss lands — +5 clean, +2 after.
            Text(wrongIDs.isEmpty ? "⭐ +5 XP" : "😅 +2 XP now")
                .font(.headline)
                .foregroundStyle(wrongIDs.isEmpty ? .green : .orange)
            ForEach(data.options) { option in
                Button(action: { answer(option) }) {
                    HStack(spacing: 12) {
                        Text(option.quizShort ?? "")
                            .font(.headline)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(background(for: option))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(solved)
            }
            if solved {
                VStack(spacing: 2) {
                    Text("Swipe")
                        .font(.title2).bold()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 44))
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func answer(_ option: Word) {
        guard !solved else { return }
        if option.id == data.word.id {
            solved = true
            onSolve(data.word, !wrongIDs.isEmpty)
        } else {
            wrongIDs.insert(option.id)
            WrongAnswerFeedback.play(teen: true)
            QuizStats.recordWrong()
        }
    }

    private func background(for option: Word) -> Color {
        if solved, option.id == data.word.id { return .green.opacity(0.25) }
        if wrongIDs.contains(option.id) { return .red.opacity(0.25) }
        return .gray.opacity(0.15)
    }
}

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
    /// Quiz Blitz mode: a 5-question sprint with a finish screen.
    /// Normal quiz is endless; blitz ends after 5 solves.
    var blitzMode = false
    @State private var blitzSolves = 0
    @State private var blitzDone = false
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.last.win") private var lastWin = ""
    @AppStorage("ghar.premium.unlocked") private var isUnlocked = false
    @AppStorage("ghar.quiz.freeUsed") private var freeUsed = 0
    @State private var showingPaywall = false

    @State private var current: Word?
    @State private var options: [Word] = []
    @State private var solved = false
    @State private var wrongIDs: Set<String> = []
    @State private var showConfetti = false
    /// Shuffled deck of upcoming questions: every word gets asked once
    /// before anything repeats, so the quiz never feels stuck on one word.
    @State private var queue: [Word] = []

    var body: some View {
        // Free tier: 5 quiz questions total. After that, the quiz locks.
        if !isUnlocked && freeUsed >= 5 {
            VStack(spacing: 16) {
                Text("🔒").font(.system(size: 56))
                Text("You've used your 5 free questions!")
                    .font(.title2).bold()
                    .multilineTextAlignment(.center)
                Text("Unlock unlimited quizzes with Ghar Premium.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("See Premium") { showingPaywall = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding()
            .sheet(isPresented: $showingPaywall) { PaywallView() }
        } else if blitzMode && blitzDone {
            // Quiz Blitz finish: 5 solves, done. No endless questions.
            VStack(spacing: 16) {
                Text("\u{1F389}").font(.system(size: 64))
                Text("Quiz Blitz complete!")
                    .font(.title2).bold()
                Text("5 questions down. See you tomorrow.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding()
        } else {
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
            // Visible stakes (Som's ask 2026-10-19): the kid SEES the
            // value drop the moment a miss lands — +5 clean, +2 after.
            Text(wrongIDs.isEmpty ? "⭐ +5 XP" : "😅 +2 XP now")
                .font(.headline)
                .foregroundStyle(wrongIDs.isEmpty ? .green : .orange)

            ForEach(options) { option in
                Button(action: { answer(option) }) {
                    if let hex = option.colorHex {
                        // Colors quiz: hear the Nepali word, tap the matching
                        // swatch. No text — the color IS the answer.
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(hex: hex))
                            .frame(height: 76)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(swatchBorder(for: option), lineWidth: 4)
                            )
                            .opacity(wrongIDs.contains(option.id) ? 0.35 : 1.0)
                    } else {
                        HStack(spacing: 12) {
                            // Animals (and any word with a picture) show it
                            // right on the answer — tap what you see.
                            if let imagePath = option.image, imagePath.hasPrefix("/") {
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
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            Text(option.english)
                                .font(.headline)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(10)
                        .background(background(for: option))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
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
        } // closes the free-tier else
    }

    /// Fresh question: dealt from a shuffled queue, so every word is asked
    /// once before anything repeats. Plus up to 3 random distractors, all
    /// shuffled. Auto-plays the word.
    private func newQuestion() {
        // Free tier: 5 questions total. Count each new question.
        if !isUnlocked {
            guard freeUsed < 5 else { return }
            freeUsed += 1
        }
        // Only words with recorded audio can be quiz questions —
        // a listening game with nothing to hear isn't a game.
        // `?? true`: packs from before `has_audio` existed count as audible.
        let audible = words.filter { $0.hasAudio ?? true }
        if queue.isEmpty {
            queue = audible.filter { $0.id != current?.id }.shuffled()
            if queue.isEmpty { queue = audible.shuffled() } // single-word quiz
        }
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
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
        player?.pause()
        player = AVPlayer(url: url)
        player?.play()
    }

    private func answer(_ option: Word) {
        if option.id == current?.id {
            solved = true
            // Anti-mash (Som's call 2026-10-19): clean first-try +5,
            // any miss on this question drops the solve to +2.
            totalXP += wrongIDs.isEmpty ? 5 : 2
            QuizStats.recordCorrect()
            // The win moment: ding + confetti (no praise cheer —
            // Som, 2026-10-23).
            QuizDing.play()
            celebrate()
            lastWin = "Quiz: \(option.english)"
            // Daily challenge: 5 solves finishes a Quiz Blitz day.
            DailyQuiz.recordSolve()
            if blitzMode {
                blitzSolves += 1
                if blitzSolves >= 5 && !blitzDone {
                    blitzDone = true
                    if DailyQuiz.checkBlitzComplete() {
                        totalXP += DailyChallenge.today().xp
                        lastWin = "Quiz Blitz complete! +15 XP"
                    } else {
                        lastWin = "Quiz Blitz complete!"
                    }
                    WinFanfare.play()
                }
            } else if DailyQuiz.checkBlitzComplete() {
                totalXP += DailyChallenge.today().xp
                WinFanfare.play()
                lastWin = "Quiz Blitz complete! +15 XP"
            }
        } else {
            wrongIDs.insert(option.id)
            WrongAnswerFeedback.play()
            QuizStats.recordWrong()
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

    /// Border for color-swatch answers: green ring on the right answer,
    /// subtle otherwise. Wrong taps fade via opacity instead.
    private func swatchBorder(for option: Word) -> Color {
        if solved, option.id == current?.id { return .green }
        return .primary.opacity(0.12)
    }
}

/// The festival quiz: a PICTURE game. See the illustration, tap what it means.
/// +5 XP per correct answer — fed into the SAME total as everything else.
///
/// Why not listening like the rest? Dashain/Tihar words have gorgeous
/// watercolor art but no recordings yet. Eyes instead of ears — and the
/// day Som records them, they can join the listening quiz too.
///
/// Teaching notes:
/// - Same shape as QuizView on purpose: `current`, `options`, `solved`,
///   `wrongIDs` — once you understand one quiz, you understand both.
/// - The only real differences: the question shows an `AsyncImage`
///   (streamed from the backend, same as WordRow) instead of a Play
///   button, and the pool is words that HAVE illustrations.
struct PictureQuizView: View {
    let words: [Word]
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.last.win") private var lastWin = ""
    @AppStorage("ghar.premium.unlocked") private var isUnlocked = false
    @AppStorage("ghar.quiz.freeUsed") private var freeUsed = 0
    @State private var showingPaywall = false

    @State private var current: Word?
    @State private var options: [Word] = []
    /// Shuffled deck of upcoming questions: every picture gets asked once
    /// before anything repeats, so the quiz never feels stuck on one word.
    @State private var queue: [Word] = []
    /// The recording player: kept alive while the word plays, same trick
    /// as the listening quiz.
    @State private var player: AVPlayer?
    @State private var solved = false
    @State private var wrongIDs: Set<String> = []
    @State private var showConfetti = false

    var body: some View {
        // Free tier: 5 quiz questions total (shared with QuizView).
        if !isUnlocked && freeUsed >= 5 {
            VStack(spacing: 16) {
                Text("\u{1F512}").font(.system(size: 56))
                Text("You've used your 5 free questions!")
                    .font(.title2).bold()
                    .multilineTextAlignment(.center)
                Text("Unlock unlimited quizzes with Ghar Premium.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("See Premium") { showingPaywall = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding()
            .sheet(isPresented: $showingPaywall) { PaywallView() }
        } else {
        // ScrollView: the picture + hint + 4 answers + Next button is taller
        // than the screen, so without this the Next button gets pushed
        // off the bottom and can never be reached.
        ScrollView {
            VStack(spacing: 20) {
                Text("What is this?")
                    .font(.title2)
                    .bold()
                // Visible stakes (Som's ask 2026-10-19): the kid SEES
                // the value drop the moment a miss lands — +5 clean, +2 after.
                Text(wrongIDs.isEmpty ? "⭐ +5 XP" : "😅 +2 XP now")
                    .font(.subheadline)
                    .foregroundStyle(wrongIDs.isEmpty ? .green : .orange)

                if let current {
                    if let imagePath = current.image {
                        AsyncImage(url: URL(string: GharAPI.baseURLString + imagePath)) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFit()
                            case .failure, .empty:
                                ProgressView()
                            @unknown default:
                                ProgressView()
                            }
                        }
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(radius: 4)
                    } else if let hex = current.colorHex {
                        // Colors quiz: the swatch IS the picture.
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(hex: hex))
                            .frame(height: 220)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                            .shadow(radius: 4)
                    }
                }

                // A distinguishing hint for similar-looking pictures (Dashain).
                // Words without one just skip this — no empty space.
                if let hint = current?.quizHint {
                    Text(hint)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                ForEach(options) { option in
                    Button(action: { answer(option) }) {
                        VStack(spacing: 2) {
                            Text(option.english)
                                .font(.headline)
                            Text(option.devanagari)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(background(for: option))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(solved)
                }

                if solved {
                    Button("Next picture") { newQuestion() }
                        .buttonStyle(.bordered)
                        .padding(.bottom)
                }
            }
            .padding()
        }
        .onAppear { newQuestion() }
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
        } // closes the free-tier else
    }

    /// Fresh question: dealt from the shuffled queue, so every picture is
    /// asked once before anything repeats. Refills (minus the just-asked
    /// word, so the boundary never repeats either) when the queue runs out.
    private func newQuestion() {
        // Free tier: 5 questions total (shared with QuizView).
        if !isUnlocked {
            guard freeUsed < 5 else { return }
            freeUsed += 1
        }
        let pictured = words.filter { $0.image != nil || $0.colorHex != nil }
        if queue.isEmpty {
            queue = pictured.filter { $0.id != current?.id }.shuffled()
            if queue.isEmpty { queue = pictured.shuffled() } // single-word quiz
        }
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        current = next
        let distractors = pictured.filter { $0.id != next.id }.shuffled().prefix(3)
        options = ([next] + distractors).shuffled()
        solved = false
        wrongIDs = []
    }

    private func answer(_ option: Word) {
        // Say the tapped word out loud — the family recording once it
        // exists, otherwise the phone's own voice.
        speak(option)
        if option.id == current?.id {
            solved = true
            // Anti-mash (Som's call 2026-10-19): clean first-try +5,
            // any miss on this question drops the solve to +2.
            totalXP += wrongIDs.isEmpty ? 5 : 2
            QuizStats.recordCorrect()
            celebrate()
            lastWin = "Picture quiz: \(option.english)"
            // Daily challenge: 5 solves finishes a Quiz Blitz day.
            DailyQuiz.recordSolve()
            if DailyQuiz.checkBlitzComplete() {
                totalXP += DailyChallenge.today().xp
                WinFanfare.play()
                lastWin = "Quiz Blitz complete! +15 XP"
            }
        } else {
            wrongIDs.insert(option.id)
            WrongAnswerFeedback.play()
            QuizStats.recordWrong()
        }
    }

    /// Says the tapped word out loud: the family recording when it exists,
    /// otherwise the phone's own voice (Nepali if installed, else the
    /// romanized word in English) — so answers talk from day one, even
    /// before anything is recorded.
    private func speak(_ word: Word) {
        if word.hasAudio == true,
           let url = URL(string: GharAPI.baseURLString + word.audioUrl) {
            player?.pause()
            player = AVPlayer(url: url)
            player?.play()
        } else {
            NepaliSpeaker.say(nepali: word.devanagari, romanized: word.romanized)
        }
    }

    private func celebrate() {
        showConfetti = false
        DispatchQueue.main.async { showConfetti = true }
    }

    private func background(for option: Word) -> Color {
        if solved, option.id == current?.id { return .green.opacity(0.25) }
        if wrongIDs.contains(option.id) { return .red.opacity(0.25) }
        return .gray.opacity(0.15)
    }
}

/// TikTok-style PICTURE quiz feed: one picture per full-screen card, swipe
/// for the next. Same settled-card tracking as the listening feed, but NO
/// auto-play here — hearing the word would give away the answer. Instead,
/// tapping an answer speaks THAT word (family recording when it exists,
/// otherwise the phone's voice), so audio always matches the tapped card.
/// Dashain/Tihar rule kept: no praise cheers, only the tapped word talks.
struct PictureQuizFeedView: View {
    let words: [Word]
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.last.win") private var lastWin = ""
    @AppStorage("ghar.premium.unlocked") private var isUnlocked = false
    @AppStorage("ghar.quiz.freeUsed") private var freeUsed = 0
    @State private var showingPaywall = false
    @State private var player: AVPlayer?
    @State private var cards: [PictureCardData] = []
    @State private var page = 0
    @State private var showConfetti = false

    struct PictureCardData: Identifiable {
        let id = UUID()
        let word: Word
        let options: [Word]
    }

    var body: some View {
        // Free tier: 5 quiz questions total (shared with the listening quiz).
        if !isUnlocked && freeUsed >= 5 {
            VStack(spacing: 16) {
                Text("\u{1F512}").font(.system(size: 56))
                Text("You've used your 5 free questions!")
                    .font(.title2).bold()
                    .multilineTextAlignment(.center)
                Text("Unlock unlimited quizzes with Ghar Premium.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("See Premium") { showingPaywall = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding()
            .sheet(isPresented: $showingPaywall) { PaywallView() }
        } else if cards.isEmpty {
            // First frame, cards not dealt yet: a neutral loading
            // beat. Without this gate the pager opens on its only
            // page — the "Set complete!" end card — for a visible
            // flash before deal() lands: the first-question glitch.
            VStack(spacing: 12) {
                ProgressView()
                Text("Shuffling questions…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { deal() }
        } else {
            StrictVerticalPager(pageCount: cards.count + 1, page: $page) { i in
                if i < cards.count {
                    PictureQuizFeedCard(data: cards[i], onSpeak: speak,
                                        onSolve: handleSolve)
                        .id(cards[i].id)
                } else {
                    // End of the set: reshuffle and keep going.
                    VStack(spacing: 16) {
                        Text("\u{1F389}").font(.system(size: 64))
                        Text("Set complete!")
                            .font(.title2).bold()
                        Button("Shuffle & keep going") { deal() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }
            }
            // A tapped word keeps talking if you swipe mid-word — stop it.
            .onChange(of: page) { _, _ in player?.pause() }
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
    }

    /// Deal a shuffled set of picture cards. Free tier is capped so the
    /// lifetime 5-question limit holds (shared with the listening quiz).
    private func deal() {
        let pictured = words.filter { $0.image != nil || $0.colorHex != nil }
        var count = pictured.count
        if !isUnlocked {
            count = min(count, max(0, 5 - freeUsed))
            freeUsed += count
        }
        cards = pictured.shuffled().prefix(count).map { word in
            let distractors = pictured.filter { $0.id != word.id }.shuffled().prefix(3)
            return PictureCardData(word: word,
                                  options: ([word] + distractors).shuffled())
        }
        // Back to the first card of the fresh set.
        page = 0
    }

    /// Says the TAPPED word out loud: the family recording when it exists,
    /// otherwise the phone's own voice — so answers talk from day one.
    /// Pause first: two cards' audio can never overlap.
    private func speak(_ word: Word) {
        player?.pause()
        if word.hasAudio == true,
           let url = URL(string: GharAPI.baseURLString + word.audioUrl) {
            player?.pause()
            player = AVPlayer(url: url)
            player?.play()
        } else {
            NepaliSpeaker.say(nepali: word.devanagari, romanized: word.romanized)
        }
    }

    /// Correct tap: +5 XP, counts toward the daily Quiz Blitz. No praise
    /// cheers on Dashain/Tihar — only the tapped word talks (the fanfare
    /// below fires on the blitz milestone, not per question).
    private func handleSolve(_ word: Word, _ missed: Bool) {
        // Anti-mash (Som's call 2026-10-19): clean first-try +5,
        // any miss on this card drops the solve to +2.
        totalXP += missed ? 2 : 5
        DailyQuiz.recordSolve()
        celebrate()
        lastWin = "Picture quiz: \(word.english)"
        if DailyQuiz.checkBlitzComplete() {
            totalXP += DailyChallenge.today().xp
            WinFanfare.play()
            lastWin = "Quiz Blitz complete! +15 XP"
        }
    }

    private func celebrate() {
        showConfetti = false
        DispatchQueue.main.async { showConfetti = true }
    }
}

/// One full-screen picture card: "What is this?", the illustration, an
/// optional hint, and 4 answers. Tapping an answer speaks it; wrong taps
/// go red, the right one goes green. After solving, a big Swipe hint —
/// swipe for the next picture.
/// Each card owns its state — the feed just counts solves.
struct PictureQuizFeedCard: View {
    let data: PictureQuizFeedView.PictureCardData
    let onSpeak: (Word) -> Void
    /// missed: true when the kid tapped a wrong option on this card
    /// before solving — the parent pays +2 instead of +5 (anti-mash).
    let onSolve: (Word, Bool) -> Void
    @State private var solved = false
    @State private var wrongIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("What is this?")
                .font(.title2)
                .bold()
            // Visible stakes (Som's ask 2026-10-19): the kid SEES the
            // value drop the moment a miss lands — +5 clean, +2 after.
            Text(wrongIDs.isEmpty ? "⭐ +5 XP" : "😅 +2 XP now")
                .font(.subheadline)
                .foregroundStyle(wrongIDs.isEmpty ? .green : .orange)
            if let imagePath = data.word.image {
                AsyncImage(url: URL(string: GharAPI.baseURLString + imagePath)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure, .empty:
                        ProgressView()
                    @unknown default:
                        ProgressView()
                    }
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 4)
            } else if let hex = data.word.colorHex {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(hex: hex))
                    .frame(height: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(radius: 4)
            }
            // A distinguishing hint for similar-looking pictures (Dashain).
            // Words without one just skip this — no empty space.
            if let hint = data.word.quizHint {
                Text(hint)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            ForEach(data.options) { option in
                Button(action: { answer(option) }) {
                    VStack(spacing: 2) {
                        Text(option.english)
                            .font(.headline)
                        Text(option.devanagari)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(background(for: option))
                    .foregroundStyle(.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(solved)
            }
            if solved {
                VStack(spacing: 2) {
                    Text("Swipe")
                        .font(.title2)
                        .bold()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 44))
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func answer(_ option: Word) {
        guard !solved else { return }
        // Say the tapped word — right or wrong, the card always talks.
        onSpeak(option)
        if option.id == data.word.id {
            solved = true
            QuizStats.recordCorrect()
            onSolve(option, !wrongIDs.isEmpty)
        } else {
            wrongIDs.insert(option.id)
            WrongAnswerFeedback.play()
            QuizStats.recordWrong()
        }
    }

    private func background(for option: Word) -> Color {
        if solved, option.id == data.word.id { return .green.opacity(0.25) }
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

/// The win moment: voice cheer + confetti, everywhere EXCEPT the Dashain
/// and Tihar picture quizzes (on those the app says only the tapped word).
///
/// - Som's voice first: a random pick from his recorded Nepali praise
///   words (`praise` in the pack — स्याबास!, राम्रो!, बधाई छ!). The list
///   is set once when the pack loads (see ContentView.load).
/// - No recordings yet: falls back to the old TTS pool so wins still
///   feel like wins until he records.
/// - `stopSpeaking(at: .immediate)` cuts off the previous cheer: if the
///   kid is on a roll answering fast, cheers never pile up and talk over
///   each other.
/// - The synthesizer lives in a `static let` so nothing throws it away
///   mid-sentence — same keep-alive lesson as the AVPlayer in @State.
/// - `UINotificationFeedbackGenerator` = the iPhone success buzz. One
///   line, and it's the Apple-approved way to say "you did it!"
/// The real recorded dog bark, playable from anywhere.
/// (The unlock celebration lives in ContentView; the tap handler in MyGharView.)
enum DogBark {
    private static var player: AVPlayer?

    static func play() {
        guard let url = URL(string: GharAPI.baseURLString + "/audio/nepal-v1/dog_bark.m4a") else { return }
        player?.pause()
        player = AVPlayer(url: url)
        player?.play()
    }
}

/// Quiz milestone stickers: lifetime correct answers (tracked by
/// QuizStats for the leaderboard) earn trophy-shelf stickers at
/// 50 / 100 / 250 / 500. Granted once, straight into the shared owned
/// set — the same storage the streak prizes use.
enum QuizStickers {
    static let thresholds: [String: Int] = ["quiz50": 50, "quiz100": 100, "quiz250": 250, "quiz500": 500]

    /// Grants any newly-earned stickers. Returns true when one landed.
    @discardableResult
    static func check() -> Bool {
        let total = QuizStats.correctTotal
        var ids = (try? JSONDecoder().decode(Set<String>.self, from: UserDefaults.standard.data(forKey: "ghar.shop.owned") ?? Data())) ?? Set<String>()
        var changed = false
        for (id, need) in thresholds where total >= need && !ids.contains(id) {
            ids.insert(id)
            changed = true
        }
        if changed {
            UserDefaults.standard.set((try? JSONEncoder().encode(ids)) ?? Data(), forKey: "ghar.shop.owned")
        }
        return changed
    }
}

/// The correct-answer DING for the non-teen quizzes (Som's call
/// 2026-10-23): no spoken praise cheer on every solve — just the
/// ding (plus the success haptic WinFanfare used to give) and move
/// on. Teen quizzes keep their recorded praise clips, and
/// wrong-answer feedback is untouched. Synthesized — no audio file
/// needed, and it plays even with the silent switch on (uses the
/// playback audio session). Same bell as the Sentences/Builder one.
/// (Named QuizDing here: SentencesView and SentenceBuilderView each
/// keep a file-private CorrectDing, and Swift forbids the clash.)
enum QuizDing {
    private static var engine: AVAudioEngine?

    static func play() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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
                QuizDing.engine = nil
            }
        }
        player.play()
    }
}

enum WinFanfare {
    /// One synthesizer for the whole app, kept alive forever.
    private static let synth = AVSpeechSynthesizer()
    /// Keeps a praise recording alive while it plays.
    private static var player: AVPlayer?
    /// Som's recorded Nepali praise, set when the pack loads.
    static var praise: [Word] = []
    /// Prakash's recorded praise for teen quizzes.
    private static let teenPraiseClips = [
        "feedback_teen_correct_1_np.m4a",  // "सही!"
        "feedback_teen_correct_2_np.m4a",  // "राम्रो!"
        "feedback_teen_correct_3_np.m4a",  // "खत्रा!"
    ]

    static func play(teen: Bool = false) {
        // Haptic + voice both run from the button tap on the main thread.
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        // Teen mode: Prakash's voice wins.
        if teen {
            let file = teenPraiseClips.randomElement()!
            if let url = URL(string: GharAPI.baseURLString + "/audio/nepal-v1/" + file) {
                synth.stopSpeaking(at: .immediate)
                player?.pause()
                player = AVPlayer(url: url)
                player?.play()
                return
            }
        }

        // His voice wins: one random recorded praise word.
        let recorded = praise.filter { $0.hasAudio == true }
        if let cheer = recorded.randomElement(),
           let url = URL(string: GharAPI.baseURLString + cheer.audioUrl) {
            synth.stopSpeaking(at: .immediate)
            player?.pause()
            player = AVPlayer(url: url)
            player?.play()
            return
        }

        // Nothing recorded yet: the TTS pool.
        synth.stopSpeaking(at: .immediate)
        guard let cheer = cheers.randomElement() else { return }
        let utterance = AVSpeechUtterance(string: cheer.text)
        utterance.voice = AVSpeechSynthesisVoice(language: cheer.language)
        utterance.rate = 0.52            // a touch peppier than default
        utterance.pitchMultiplier = 1.15 // a touch more excited
        synth.speak(utterance)
    }

    /// The TTS fallback pool: (words, language code). Nepali lines join
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
/// - "Put away" moves a bought decoration into a second stored set — off
///   the house, free to put back anytime, never earns XP twice.
/// - Tap-to-speak uses NepaliSpeaker (AVSpeechSynthesizer): the real
///   Nepali voice when the device has one, otherwise the romanized word
///   via the English voice — zero audio files to record either way.
/// - The "poke" pattern from before is still here — now each tap both
///   speaks the Nepali name AND pops the decoration.
/// Keep Suga's name kid-safe: the naming sheet rejects any name containing
/// one of these (matched case-insensitively, whole words only — so "hello"
/// stays legal). Digits and emoji can't be typed in the first place.
fileprivate let BuddyBannedWords: Set<String> = [
    "fuck", "fucking", "shit", "bitch", "ass", "asshole", "dick", "cock",
    "pussy", "whore", "slut", "bastard", "damn", "dammit", "goddamn",
    "crap", "piss", "douche", "retard", "fag", "nigga",
]
/// Mystery box prizes: NOT for sale at any price. Earned only from the
/// lucky gift box after finishing a trace deck — one random unowned item
/// per box. Global so the gift box (TraceView.swift) can grant them.
let mysteryBoxPrizes: [ShopItem] = [
    ShopItem(id: "guleyli", nameEn: "Slingshot", nameNe: "गुलेली", romanized: "guleyli", icon: "🏹", cost: 0),
    ShopItem(id: "nanglo", nameEn: "Woven tray", nameNe: "नाङ्लो", romanized: "nanglo", icon: "🧺", cost: 0),
    ShopItem(id: "charkha", nameEn: "Spinning wheel", nameNe: "चर्खा", romanized: "charkha", icon: "☸️", cost: 0),
    ShopItem(id: "khukuri", nameEn: "Khukuri knife", nameNe: "खुकुरी", romanized: "khukuri", icon: "🗡️", cost: 0),
    ShopItem(id: "sarangi", nameEn: "Sarangi fiddle", nameNe: "सारंगी", romanized: "sarangi", icon: "🎻", cost: 0),
    ShopItem(id: "karuwa", nameEn: "Water pitcher", nameNe: "करुवा", romanized: "karuwa", icon: "🏺", cost: 0),
]


/// Teen mission rewards: NOT for sale. The soccer ball is the teen
/// parallel to Bhunte — finish all 8 teen missions to earn it. The
/// mystery prizes are a one-time random draw at 4 teen missions.
let teenBallItem = ShopItem(id: "goldsoccerball", nameEn: "Golden Soccer Ball", nameNe: "सुनको फुटबल", romanized: "sunko phutbal", icon: "⚽", cost: 0)

/// One prize per teen LESSON deck (Som's call, 2026-10-23): finish
/// the deck — hear every phrase — and its prize lands in My Ghar.
/// Granted inside DeckProgress.evaluate, the deck-completion path.
let teenDeckPrizes: [(deck: String, item: ShopItem)] = [
    (deck: "texting", item: ShopItem(id: "headphones", nameEn: "Headphones", nameNe: "हेडफोन", romanized: "hedfon", icon: "🎧", cost: 0)),
    (deck: "slang", item: ShopItem(id: "skateboard", nameEn: "Skateboard", nameNe: "स्केटबोर्ड", romanized: "skateboard", icon: "🛹", cost: 0)),
    (deck: "comebacks", item: ShopItem(id: "sunglasses", nameEn: "Sunglasses", nameNe: "चश्मा", romanized: "chasma", icon: "🕶️", cost: 0)),
    (deck: "captions", item: ShopItem(id: "camera", nameEn: "Camera", nameNe: "क्यामेरा", romanized: "kyamera", icon: "📷", cost: 0)),
    (deck: "lyrics", item: ShopItem(id: "guitar", nameEn: "Guitar", nameNe: "गितार", romanized: "gitar", icon: "🎸", cost: 0)),
]

/// The teen MYSTERY pool: one random draw at 4 teen missions.
let teenPrizeItems: [ShopItem] = [
    ShopItem(id: "sneakers", nameEn: "Sneakers", nameNe: "जुत्ता", romanized: "juttaa", icon: "👟", cost: 0),
    ShopItem(id: "basketball", nameEn: "Basketball", nameNe: "बास्केटबल", romanized: "basketbal", icon: "🏀", cost: 0),
    ShopItem(id: "controller", nameEn: "Game Controller", nameNe: "भिडियो गेम", romanized: "bhidiyo gem", icon: "🎮", cost: 0),
]

/// Every teen reward in display order (golden ball, lesson prizes,
/// mystery pool) — drives the My Ghar Teen Rewards shelf and the
/// tap-to-speak lookup.
let teenShowcaseItems: [ShopItem] = [teenBallItem] + teenDeckPrizes.map(\.item) + teenPrizeItems

/// Teen prize names are spoken by Prakash (ElevenLabs clips named
/// teenprize_<id>_np.m4a) — checked first in sayDecoration.
let teenPrizeAudioIDs: Set<String> = Set(teenShowcaseItems.map(\.id))

/// Memberwise init for code-built missions — Mission's own init is
/// decoder-only (Models.swift), and teen missions live in code, not
/// the pack, so pack mission counts (dog, streaks, free tier) stay
/// exactly as they were.
extension Mission {
    init(id: String, titleEn: String, titleNe: String, promptEn: String, promptNe: String,
         audioUrl: String, festival: String?, ageBand: String, xp: Int, verifiedXp: Int,
         hasAudio: Bool, difficulty: String?) {
        self.id = id
        self.titleEn = titleEn
        self.titleNe = titleNe
        self.promptEn = promptEn
        self.promptNe = promptNe
        self.audioUrl = audioUrl
        self.festival = festival
        self.ageBand = ageBand
        self.xp = xp
        self.verifiedXp = verifiedXp
        self.hasAudio = hasAudio
        self.difficulty = difficulty
    }
}

/// The teen mission set (Som's cousins asked for it, 2026-10-23):
/// real-world missions built on the teen decks — texting, slang,
/// captions, comebacks, lyrics. Self-serve completion: teens hold
/// to confirm and earn the full verified XP — no grown-up gate,
/// no recording. (Nepali titles/prompts are drafts pending Som's
/// sanity check, like all new copy.)
enum TeenMissions {
    static let all: [Mission] = [
        Mission(id: "teen-text-it", titleEn: "Text It For Real", titleNe: "साँच्चै मेसेज गर",
                promptEn: "Send a real text or DM to a family member using a Nepali phrase from the Texting deck — try 'ke chha?' (how are you?) or 'sanchai chhu' (I'm good).",
                promptNe: "परिवारलाई नेपालीमा मेसेज पठाऊ!",
                audioUrl: "/audio/nepal-v1/teen-text-it.m4a", festival: nil, ageBand: "rooted",
                xp: 10, verifiedXp: 25, hasAudio: true, difficulty: "teen"),
        Mission(id: "teen-teach-slang", titleEn: "Teach the Slang", titleNe: "स्ल्याङ सिकाऊ",
                promptEn: "Teach a friend one Nepali slang word from the Slang deck — and use it in a real sentence.",
                promptNe: "साथीलाई एउटा नेपाली स्ल्याङ शब्द सिकाऊ!",
                audioUrl: "/audio/nepal-v1/teen-teach-slang.m4a", festival: nil, ageBand: "rooted",
                xp: 10, verifiedXp: 25, hasAudio: true, difficulty: "teen"),
        Mission(id: "teen-caption", titleEn: "Caption That", titleNe: "क्याप्सन लेख",
                promptEn: "Write a Nepali caption for a real photo of yours — post it or send it to family.",
                promptNe: "आफ्नो फोटोको लागि नेपाली क्याप्सन लेख!",
                audioUrl: "/audio/nepal-v1/teen-caption.m4a", festival: nil, ageBand: "rooted",
                xp: 10, verifiedXp: 25, hasAudio: true, difficulty: "teen"),
        Mission(id: "teen-comeback", titleEn: "Comeback Ready", titleNe: "जवाफ दिन सिक",
                promptEn: "Learn one comeback from the Comebacks deck and say it out loud to someone at home.",
                promptNe: "एउटा जवाफ सिकेर घरमा भन!",
                audioUrl: "/audio/nepal-v1/teen-comeback.m4a", festival: nil, ageBand: "rooted",
                xp: 10, verifiedXp: 25, hasAudio: true, difficulty: "teen"),
        Mission(id: "teen-lyrics", titleEn: "Lyrics Check", titleNe: "गीतको अर्थ",
                promptEn: "Pick one line from the Lyrics deck, learn what it really means, and explain it to someone.",
                promptNe: "गीतको एउटा लाइनको अर्थ सिकेर बुझाऊ!",
                audioUrl: "/audio/nepal-v1/teen-lyrics.m4a", festival: nil, ageBand: "rooted",
                xp: 10, verifiedXp: 25, hasAudio: true, difficulty: "teen"),
        Mission(id: "teen-order", titleEn: "Order in Nepali", titleNe: "नेपालीमा अर्डर",
                promptEn: "Use Nepali to order or ask for food — numbers and food words count!",
                promptNe: "नेपालीमा खाना अर्डर गर!",
                audioUrl: "/audio/nepal-v1/teen-order.m4a", festival: nil, ageBand: "rooted",
                xp: 10, verifiedXp: 25, hasAudio: true, difficulty: "teen"),
        Mission(id: "teen-call-home", titleEn: "Call Home", titleNe: "घरमा फोन",
                promptEn: "Greet a grandparent or relative in Nepali on a call — a full sentence, not just 'hi'.",
                promptNe: "फोनमा नेपालीमा अभिवादन गर!",
                audioUrl: "/audio/nepal-v1/teen-call-home.m4a", festival: nil, ageBand: "rooted",
                xp: 10, verifiedXp: 25, hasAudio: true, difficulty: "teen"),
        Mission(id: "teen-teach-back", titleEn: "Teach It Back", titleNe: "सिकाएर देखाऊ",
                promptEn: "Teach someone at home one Nepali word — say it, have them repeat it back.",
                promptNe: "घरमा कसैलाई एउटा नेपाली शब्द सिकाऊ!",
                audioUrl: "/audio/nepal-v1/teen-teach-back.m4a", festival: nil, ageBand: "rooted",
                xp: 10, verifiedXp: 25, hasAudio: true, difficulty: "teen"),
    ]
}

/// Bundled My Ghar art: the generated room, dog poses and decoration
/// sprites live in Content/images/myghar (copied by BundleContent.sh).
/// Decoded-sprite cache. Without it, every redraw of My Ghar re-read
/// and re-decoded every PNG from disk — and that screen redraws
/// constantly (dog timers, bobbing, swaying) — so the tab stuttered.
/// Decode each picture once per launch, then serve it from memory.
private let myGharImageCache = NSCache<NSString, UIImage>()

func myGharUIImage(_ name: String) -> UIImage? {
    if let cached = myGharImageCache.object(forKey: name as NSString) {
        return cached
    }
    guard let url = Bundle.main.url(forResource: name, withExtension: "png",
                                    subdirectory: "Content/images/myghar"),
          let img = UIImage(contentsOfFile: url.path) else { return nil }
    myGharImageCache.setObject(img, forKey: name as NSString)
    return img
}

func myGharSprite(_ name: String) -> Image? {
    guard let ui = myGharUIImage(name) else { return nil }
    return Image(uiImage: ui)
}

/// The pet dog as real art. Same inputs the parent already drives
/// (pose, phases, flip, bounce, spin) — only the rendering changed:
/// a pose sprite instead of hand-drawn shapes. `stage` picks the art
/// set: 0 puppy, 1 young dog, 2 big dog — grown with bones 🦴.
struct SpriteDogView: View {
    var pose: DogPose = .idle
    var walkPhase: Double = 0
    var wagPhase: Double = 0
    var blinking: Bool = false
    var facingRight: Bool = true
    var carryingBall: Bool = false
    var bounce: Double = 0
    var spinDegrees: Double = 0
    var stage: Int = 0

    private var assetName: String {
        let prefix = stage >= 2 ? "dog_adult" : stage == 1 ? "dog_young" : "dog_puppy"
        if carryingBall { return "\(prefix)_ball" }
        switch pose {
        case .sitting: return "\(prefix)_sitting"
        case .walking: return stage >= 2 ? "\(prefix)_standing" : "\(prefix)_walking"
        case .idle: return "\(prefix)_standing"
        }
    }

    var body: some View {
        Group {
            if let img = myGharSprite(assetName) {
                img.resizable().scaledToFit()
            } else {
                Text("🐕").font(.system(size: 60))
            }
        }
        .scaleEffect(x: facingRight ? 1 : -1, y: 1)
        .rotationEffect(.degrees(spinDegrees))
        .offset(y: -bounce * 22 + (pose == .walking ? -abs(sin(walkPhase)) * 5 : 0))
    }
}

/// First-open tour of My Ghar (Som's ask, 2026-10-22): four stops —
/// the room, the Trophy Shelf, the shop, Arrange — each narrated by
/// Som's clone (myghar_tour1..4 in the pack audio). Runs once ever.
enum MyGharTourStep: CaseIterable {
    case room, trophies, shop, arrange

    var anchorID: String {
        switch self {
        case .room: return "myghar.room"
        case .trophies: return "myghar.trophies"
        case .shop: return "myghar.shop"
        case .arrange: return "myghar.arrange"
        }
    }
    var emoji: String {
        switch self {
        case .room: return "🏠"
        case .trophies: return "🏆"
        case .shop: return "🏪"
        case .arrange: return "🔀"
        }
    }
    var nepali: String {
        switch self {
        case .room: return "यो तिम्रो घर हो!"
        case .trophies: return "इनामहरू यहाँ बस्छन्!"
        case .shop: return "XP ले घर सजाऊ!"
        case .arrange: return "सारेर आफ्नो कोठा मिलाऊ!"
        }
    }
    var english: String {
        switch self {
        case .room: return "This is your Ghar — everything you earn lives here"
        case .trophies: return "Prizes live here — earned, not bought"
        case .shop: return "Spend XP to decorate your Ghar"
        case .arrange: return "Drag decorations to arrange your room"
        }
    }
}

/// One stop of the My Ghar tour — same banner shape as the lesson tour,
/// floating at the bottom of the tab while the page scrolls to the stop.
struct MyGharTourBanner: View {
    let step: MyGharTourStep
    let isLast: Bool
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(step.emoji).font(.system(size: 40))
            VStack(alignment: .leading, spacing: 2) {
                Text(step.nepali).font(.title3).bold()
                Text(step.english).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button(isLast ? "Done ✓" : "Next ➜", action: onNext)
                .buttonStyle(.borderedProminent)
            Button(action: onSkip) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 8, y: 4)
    }
}

/// Which room animal the under-room action bar is controlling.
enum RoomPal {
    case dog, parrot
}

struct MyGharView: View {
    let pack: ContentPack
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.house.name") private var houseName = ""
    @AppStorage("ghar.house.roof") private var roofChoice = 0
    @AppStorage("ghar.house.walls") private var wallChoice = 0
    @AppStorage("ghar.last.win") private var lastWin = ""
    @AppStorage("ghar.shop.owned") private var ownedData = Data()
    @AppStorage("ghar.missions.verified") private var verifiedData = Data()
    @AppStorage("ghar.missions.completed") private var completedData = Data()
    @AppStorage("ghar.sets.awarded") private var awardedSetsData = Data()
    // Suga the parrot: his name, the word ids he's been taught,
    // how many times he's been fed, and big-ticket upgrades owned.
    // All on-device in @AppStorage — COPPA-safe, survives restarts.
    @AppStorage("ghar.buddy.name") private var buddyName = ""
    @AppStorage("ghar.buddy.taught") private var taughtData = Data()
    @AppStorage("ghar.buddy.fed") private var feedCount = 0
    @AppStorage("ghar.upgrades.owned") private var upgradesData = Data()
    @AppStorage("ghar.upgrades.stored") private var storedUpgradesData = Data()
    // Storage: decorations the kid bought but put away. They're not on
    // the house, cost nothing to put back, and never earn XP twice.
    @AppStorage("ghar.shop.stored") private var storedData = Data()
    @AppStorage("ghar.premium.unlocked") private var isUnlocked = false
    @State private var showingPaywall = false

    /// Free tier: 3 decorations. The auto-granted Prove-it prizes
    /// (goldenDiyo, starBadge, mukut) and streak milestones
    /// (flameDiyo, streakCrown) don't count — they're earned, not bought.
    private var purchasableOwnedCount: Int {
        ownedIDs.subtracting(["goldenDiyo", "starBadge", "mukut", "flameDiyo", "streakCrown", "quiz50", "quiz100", "quiz250", "quiz500"]).count
    }
    // Arrange mode: drag deltas per decoration id, so kids can reposition
    // things. [x, y] pairs added on top of each item's home spot.
    @AppStorage("ghar.layout") private var layoutData = Data()

    // Poke-state: the id of the thing currently popping (nil = nothing).
    // One state for all 18 decorations instead of 18 separate Bools.
    @State private var poppedID: String? = nil
    @State private var sunSpin = false
    @State private var smokeRise = false
    /// Keeps a decoration recording alive while it plays.
    @State private var decoPlayer: AVPlayer?
    // Collapsible sections: the shop/sets/prizes start closed so My Ghar
    // doesn't scroll forever. Counts on the headers say what's inside.
    @State private var shopOpen = false
    @State private var setsOpen = false
    @State private var prizesOpen = false
    @State private var mysteryOpen = false
    @State private var upgradesOpen = false
    @State private var parrotOpen = false
    // Dog buddy: unlocked by completing ALL missions. More interactive than Suga.
    @State private var dogOpen = false
    @AppStorage("ghar.dog.name") private var dogName = "Bhunte"
    // Bones 🦴: the dog's own currency. Earned 1:1 alongside XP anywhere
    // in the app (synced from the XP total — see syncBones), used for
    // nothing but growing: 50 🦴 -> young dog, 150 🦴 -> big dog.
    // The stage itself is claimed with the Level Up button.
    @AppStorage("ghar.dog.bones") private var bones = 0
    @AppStorage("ghar.dog.bonesSyncedXP") private var bonesSyncedXP = 0
    @AppStorage("ghar.dog.bonesInit") private var bonesInit = false
    @AppStorage("ghar.dog.stage") private var dogStage = 0
    @State private var renamingDog = false
    @State private var dogNameDraft = ""
    @State private var dogNameError: String?
    @State private var teachingTrick = false
    @State private var trickName = ""
    @AppStorage("ghar.dog.tricks") private var dogTricksData = Data()
    @State private var fetching = false
    // @AppStorage, not @State (audit fix, 2026-10-21): as @State the
    // daily fetch cap silently reset whenever the app relaunched —
    // kill the app, reopen, 5 more paid throws. Persisted, the cap is
    // a real cap (the date guard in throwBall resets it per day).
    @AppStorage("ghar.dog.fetchCount") private var fetchCount = 0
    @AppStorage("ghar.dog.fetchDate") private var lastFetchDate = ""
    @State private var petting = false
    // Living-dog animation clocks, driven by Timers in startDogTimers().
    @State private var dogPose: DogPose = .idle
    @State private var dogWalkPhase = 0.0
    @State private var dogWagPhase = 0.0
    @State private var dogBlinking = false
    @State private var dogFacingRight = true
    @State private var dogCarryingBall = false
    @State private var dogBounce = 0.0
    @State private var dogSpinDegrees = 0.0
    @State private var dogRoamX: CGFloat = 0
    // First-open tour of My Ghar (Som's ask, 2026-10-22): once ever,
    // four stops, his clone narrating each (tour1..4 in the pack).
    @AppStorage("ghar.myghar.toured") private var myGharToured = false
    @State private var myTourStep: MyGharTourStep? = nil
    @State private var roomSelection: RoomPal? = nil
    @State private var fetchBallX: CGFloat = 0
    @State private var fetchBallVisible = false
    @State private var dogTimer: Timer?
    @State private var dogRoamTimer: Timer?
    // Keyboard focus for house name field — Done button dismisses it.
    @FocusState private var houseNameFocused: Bool
    // Naming sheet after adopting Suga; teach sheet for new words.
    @State private var namingBuddy = false
    @State private var teachingBuddy = false
    @State private var renamingBuddy = false
    @State private var mimickingBuddy = false
    @State private var buddyNameDraft = ""
    // Mimic mode: kid records, Suga squawks it back pitched-up.
    @State private var mimicRecorder: AVAudioRecorder?
    @State private var mimicURL: URL?
    @State private var mimicRecording = false
    @State private var mimicEngine: AVAudioEngine?
    @State private var sugaEngine: AVAudioEngine?
    /// Serial queue for mimic recording — keeps it off the main thread.
    private let mimicQueue = DispatchQueue(label: "ghar.mimic", qos: .userInitiated)
    // Living-house animation flags: gentle loops that never stop.
    @State private var buddyBob = false
    @State private var flameFlicker = false
    @State private var flagWave = false
    @State private var butterflyFly = false
    // Arrange mode: drag decorations around the house. dragDeltas holds
    // the live in-progress drag per id until the finger lifts.
    @State private var arranging = false
    @State private var dragDeltas: [String: CGSize] = [:]
    // Garden sway + the feeding treat shown at Suga's beak.
    @State private var flowerSway = false
    @State private var feedEmoji: String? = nil
    // Glistening mountain snow.
    @State private var snowTwinkle = false

    // The shop: 15 decorations, priced 5 → 250 XP. Buying EVERYTHING costs
    // 1,200 XP — with verified missions paying 25, that's a real long-term
    // chase, not a day-one sweep. Nothing is auto-added: kids spend XP.
    private let shopItems: [ShopItem] = [
        ShopItem(id: "diyo", nameEn: "Diyo lamp", nameNe: "दियो", romanized: "diyo", icon: "🪔", cost: 5),
        ShopItem(id: "windows", nameEn: "Windows", nameNe: "झ्याल", romanized: "jhyaal", icon: "🪟", cost: 10),
        ShopItem(id: "tulsi", nameEn: "Tulsi plant", nameNe: "तुलसी", romanized: "tulsi", icon: "🪴", cost: 15),
        ShopItem(id: "sayapatri", nameEn: "Marigold", nameNe: "सयपत्री", romanized: "sayapatri", icon: "🌼", cost: 20),
        ShopItem(id: "door", nameEn: "Door", nameNe: "ढोका", romanized: "dhoka", icon: "🚪", cost: 20),
        ShopItem(id: "jamara", nameEn: "Jamara", nameNe: "जमरा", romanized: "jamara", icon: "🌱", cost: 30),
        ShopItem(id: "flags", nameEn: "Prayer flags", nameNe: "प्रार्थना झण्डा", romanized: "prarthana jhanda", icon: "🚩", cost: 35),
        ShopItem(id: "rangoli", nameEn: "Rangoli", nameNe: "रंगोली", romanized: "rangoli", icon: "🎨", cost: 45),
        ShopItem(id: "mala", nameEn: "Garland", nameNe: "माला", romanized: "mala", icon: "🌸", cost: 55),
        ShopItem(id: "buddy", nameEn: "Suga (Parrot)", nameNe: "सुगा", romanized: "suga", icon: "🦜", cost: 140),
        ShopItem(id: "changa", nameEn: "Kite", nameNe: "चङ्गा", romanized: "changa", icon: "🪁", cost: 85),
        ShopItem(id: "himal", nameEn: "Himalayas", nameNe: "हिमाल", romanized: "himal", icon: "🏔️", cost: 105),
        ShopItem(id: "ghanta", nameEn: "Temple bell", nameNe: "घण्टा", romanized: "ghanta", icon: "🔔", cost: 125),
        ShopItem(id: "mandir", nameEn: "Temple", nameNe: "मन्दिर", romanized: "mandir", icon: "🛕", cost: 175),
    ]

    // Prove-it prizes: NOT for sale at any price. Each unlocks when the
    // kid's verified-mission count hits the requirement — the recording
    // flow made tangible. The shop shows them as locked goals.
    private let exclusiveItems: [ShopItem] = [
        ShopItem(id: "goldenDiyo", nameEn: "Golden Diyo", nameNe: "सुनौलो दियो", romanized: "sunaulo diyo", icon: "🪔", cost: 0),
        ShopItem(id: "starBadge", nameEn: "Star Badge", nameNe: "तारा", romanized: "tara", icon: "⭐", cost: 0),
        ShopItem(id: "mukut", nameEn: "Mukut Crown", nameNe: "मुकुट", romanized: "mukut", icon: "👑", cost: 0),
        ShopItem(id: "flameDiyo", nameEn: "Flame Diyo", nameNe: "ज्वाला दियो", romanized: "jwala diyo", icon: "🔥", cost: 0),
        ShopItem(id: "streakCrown", nameEn: "Streak Crown", nameNe: "लगातार मुकुट", romanized: "lagatar mukut", icon: "👑", cost: 0),
        ShopItem(id: "quiz50", nameEn: "Jhilimili Sticker", nameNe: "झिलिमिली", romanized: "jhilimili", icon: "✨", cost: 0),
        ShopItem(id: "quiz100", nameEn: "Surya Sticker", nameNe: "सूर्य", romanized: "surya", icon: "☀️", cost: 0),
        ShopItem(id: "quiz250", nameEn: "Himal Sticker", nameNe: "हिमाल", romanized: "himal", icon: "🏔️", cost: 0),
        ShopItem(id: "quiz500", nameEn: "Sagarmatha Sticker", nameNe: "सगरमाथा", romanized: "sagarmatha", icon: "🗻", cost: 0),
    ]
    private let exclusiveNeed = ["goldenDiyo": 1, "starBadge": 3, "mukut": 5]

    /// The room stage: designed at 310x400, scaled up to fill the screen
    /// width. Scene offsets and sizes multiply by stageK so the whole
    /// diorama grows together. The 760 cap is sized for iPad — every
    /// iPhone's width lands below it, so phones are unaffected.
    private var stageW: CGFloat { min(UIScreen.main.bounds.width - 24, 760) }
    private var stageK: CGFloat { stageW / 310 }
    private var stageH: CGFloat { 400 * stageK }

    /// One small action chip for the under-room pal bar.
    private func palChip(_ title: String, icon: String, cost: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.callout)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.callout).bold()
                    Text(cost).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(disabled)
    }


    // Big-ticket upgrades: long-term XP goals that change the yard.
    // Garden (phulbari) blooms flowers; chautari grows the classic
    // Nepali rest-stop tree with its stone platform.
    // Decoration sets: own every item in a set, pocket a bonus. The long game.
    private let decoSets: [DecoSet] = [
        DecoSet(id: "tihar", nameEn: "Tihar Set", itemIds: ["diyo", "sayapatri", "rangoli", "mala"], bonus: 40),
        DecoSet(id: "garden", nameEn: "Garden Set", itemIds: ["tulsi", "jamara"], bonus: 50),
        DecoSet(id: "home", nameEn: "Home Set", itemIds: ["door", "windows", "flags", "buddy"], bonus: 60),
        DecoSet(id: "sky", nameEn: "Sky & Temple Set", itemIds: ["changa", "himal", "ghanta", "mandir"], bonus: 100),
    ]

    /// IDs of owned decorations (bought + prizes), decoded from storage.
    private var ownedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: ownedData)) ?? []
    }

    /// IDs of grown-up-verified missions — drives the Prove-it prizes.
    private var verifiedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: verifiedData)) ?? []
    }

    /// IDs of completed missions — drives the dog unlock (all missions done).
    private var completedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: completedData)) ?? []
    }

    /// Set ids whose completion bonus was already paid (paid once, ever).
    private var awardedSets: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: awardedSetsData)) ?? []
    }

    /// Word ids Suga has learned — taught by the kid, 10 XP each.
    private var taughtIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: taughtData)) ?? []
    }

    /// Big-ticket upgrade ids owned (garden, chautari…).
    private var upgradeIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: upgradesData)) ?? []
    }

    /// Upgrade ids put away in storage — off the house, free to put back.
    private var storedUpgradeIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: storedUpgradesData)) ?? []
    }

    /// Decoration ids bought but put away in storage — off the house.
    private var storedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: storedData)) ?? []
    }

    /// Saved drag deltas per decoration id: [dx, dy] added on top of each
    /// item's home spot. Empty = everything sits where it started.
    private var layoutDeltas: [String: [Double]] {
        (try? JSONDecoder().decode([String: [Double]].self, from: layoutData)) ?? [:]
    }

    /// Home spots (design coords) per decoration id, remembered from the
    /// last render so commitDrag clamps against the same geometry
    /// placedOffset draws with. Static on purpose: it is written during
    /// body evaluation and must never trigger a re-render.
    private static var homeSpots: [String: CGPoint] = [:]

    /// Keep an item's center inside the room stage (16pt margin), so an
    /// arranged decoration can never be dragged off-screen and lost —
    /// spots are saved, so an unclamped drop would be unrecoverable
    /// (there is no reset-layout button). Items may still overhang an
    /// edge; the center just can't leave the room.
    private func clampToStage(_ offset: CGSize) -> CGSize {
        CGSize(
            width: min(max(offset.width, -stageW / 2 + 16), stageW / 2 - 16),
            height: min(max(offset.height, -stageH / 2 + 16), stageH / 2 - 16)
        )
    }

    /// A decoration's final offset: its home spot + saved drag + the live
    /// drag in progress (so it follows the finger), clamped to the stage.
    /// Clamping at render also rescues spots saved outside the room
    /// before this clamp existed — they snap back to the nearest edge.
    private func placedOffset(_ id: String, x: CGFloat, y: CGFloat) -> CGSize {
        Self.homeSpots[id] = CGPoint(x: x, y: y)
        let s = layoutDeltas[id] ?? [0, 0]
        let live = dragDeltas[id] ?? .zero
        return clampToStage(CGSize(
            width: x * stageK + CGFloat(s[0]) + live.width,
            height: y * stageK + CGFloat(s.count > 1 ? s[1] : 0) + live.height
        ))
    }

    /// Finger lifted: fold the drag into the saved layout — clamped to
    /// the stage via the item's home spot, so storage can never hold an
    /// out-of-room position (which would leave the item stuck at the
    /// edge for the first part of its next drag).
    private func commitDrag(_ id: String, translation: CGSize) {
        var deltas = layoutDeltas
        let cur = deltas[id] ?? [0, 0]
        var dx = cur[0] + Double(translation.width)
        var dy = (cur.count > 1 ? cur[1] : 0) + Double(translation.height)
        if let home = Self.homeSpots[id] {
            let clamped = clampToStage(CGSize(
                width: home.x * stageK + CGFloat(dx),
                height: home.y * stageK + CGFloat(dy)))
            dx = Double(clamped.width - home.x * stageK)
            dy = Double(clamped.height - home.y * stageK)
        }
        deltas[id] = [dx, dy]
        layoutData = (try? JSONEncoder().encode(deltas)) ?? Data()
        dragDeltas[id] = nil
    }

    // MARK: My Ghar first-open tour

    /// First open ever: flag it immediately (a mid-tour quit doesn't
    /// re-run it), settle a beat, then start at the room with his
    /// clone narrating.
    private func startMyGharTourIfNeeded() {
        guard !myGharToured else { return }
        myGharToured = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            myTourStep = .room
            sayDecoration(id: "tour1", nepali: "यो तिम्रो घर हो!", romanized: "yo timro ghar ho!")
        }
    }

    private func advanceMyGharTour() {
        guard let step = myTourStep else { return }
        switch step {
        case .room:
            myTourStep = .trophies
            sayDecoration(id: "tour2", nepali: "इनामहरू यहाँ बस्छन्!", romanized: "inaamharu yahaa baschhan!")
        case .trophies:
            myTourStep = .shop
            sayDecoration(id: "tour3", nepali: "XP ले घर सजाऊ!", romanized: "XP le ghar sajaau!")
        case .shop:
            myTourStep = .arrange
            sayDecoration(id: "tour4", nepali: "सारेर आफ्नो कोठा मिलाऊ!", romanized: "saarera aafno kotha milaau!")
        case .arrange:
            myTourStep = nil
        }
    }

    /// What the kid named the parrot — "Suga" until they pick a name.
    /// Sanitized on read too, so a name saved before the sanity checks
    /// can't show anything rude.
    private var buddyDisplayName: String {
        let trimmed = buddyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, buddyNameError(trimmed) == nil else { return "Suga" }
        return trimmed
    }

    /// Parrot-name sanity: short, letters only (Latin + Devanagari, plus
    /// space/hyphen/apostrophe), nothing rude. Empty is fine — it just
    /// keeps the default "Suga". Returns the problem, or nil when OK.
    private func buddyNameError(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if name.count > 14 { return "Keep it short — 14 letters max" }
        let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: " -'"))
        if name.rangeOfCharacter(from: allowed.inverted) != nil {
            return "Letters only, please!"
        }
        let words = name.lowercased().split { !$0.isLetter }
        if words.contains(where: { BuddyBannedWords.contains(String($0)) }) {
            return "Let's pick a nicer name 🦜"
        }
        return nil
    }

    /// Every word in the pack — the teach-a-word picker list.
    private var allWords: [Word] {
        pack.decks.flatMap { $0.words }
    }

    private func word(_ id: String) -> Word? {
        allWords.first { $0.id == id }
    }

    /// Every decoration, shop or prize — for tap-to-speak lookup.
    private func shopItem(_ id: String) -> ShopItem {
        shopItems.first { $0.id == id }
            ?? exclusiveItems.first { $0.id == id }
            ?? mysteryBoxPrizes.first { $0.id == id }
            ?? teenShowcaseItems.first { $0.id == id }
            ?? shopItems[0]
    }

    /// Says a decoration or scene name out loud: Som's recording when he's
    /// recorded it (`mygharAudio` in the pack), otherwise the phone's own
    /// voice — the same recording-first pattern as everywhere else.
    private func sayDecoration(id: String, nepali: String, romanized: String) {
        // Teen prizes speak in Prakash's voice (ElevenLabs clips) —
        // the teen surface is his, not the clone's or the robot's.
        if teenPrizeAudioIDs.contains(id),
           let url = URL(string: GharAPI.baseURLString + "/audio/nepal-v1/teenprize_\(id)_np.m4a") {
            decoPlayer?.pause()
            decoPlayer = AVPlayer(url: url)
            decoPlayer?.play()
            return
        }
        // If this exact word was already recorded for the decks (दियो, चङ्गा,
        // जमरा…), reuse that clip — same voice, same tone, nothing to record.
        if let w = allWords.first(where: { $0.devanagari == nepali && $0.hasAudio == true }),
           let url = URL(string: GharAPI.baseURLString + w.audioUrl) {
            decoPlayer?.pause()
            decoPlayer = AVPlayer(url: url)
            decoPlayer?.play()
            return
        }
        if pack.mygharAudio?[id] == true,
           let url = URL(string: GharAPI.baseURLString + "/audio/nepal-v1/myghar_\(id)_np.m4a") {
            decoPlayer?.pause()
            decoPlayer = AVPlayer(url: url)
            decoPlayer?.play()
        } else {
            NepaliSpeaker.say(nepali: nepali, romanized: romanized)
        }
    }

    /// ShopItem convenience: the Nepali name comes from the item itself.
    private func sayDecoration(_ item: ShopItem) {
        sayDecoration(id: item.id, nepali: item.nameNe, romanized: item.romanized)
    }

    /// Status title from the XP total — the number means something forever,
    /// even after the shop is bought out.
    private var xpTitle: (en: String, ne: String) {
        switch totalXP {
        case 800...: ("Nayak", "नायक")       // hero
        case 400...: ("Ghar-muli", "घरमूली") // head of the household
        case 150...: ("Saathi", "साथी")       // friend
        default: ("Pahuna", "पाहुना")         // guest
        }
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
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 16) {
                // The nameplate: whatever the kid named their ghar.
                Text(houseName.isEmpty ? "My Ghar" : "\(houseName)'s Ghar")
                    .font(.title)
                    .bold()

                Text("Earn XP to decorate your house 🏠")
                    .font(.title3)
                    .bold()

                Text("⭐ \(totalXP) XP · \(xpTitle.en)")
                    .font(.headline)

                // Growth: bones grow the dog — puppy, young, big dog.
                if ownedIDs.contains("dog") {
                    VStack(spacing: 3) {
                        HStack(spacing: 8) {
                            growthIcon("dog_puppy_standing", size: 26)
                                .opacity(dogStage == 0 ? 1 : 0.45)
                            ProgressView(value: growthProgress, total: 1.0)
                                .tint(.orange)
                            growthIcon("dog_adult_standing", size: 34)
                                .opacity(dogStage == 2 ? 1 : 0.45)
                        }
                        HStack {
                            Text("🦴 \(bones) bones")
                                .font(.caption)
                                .bold()
                            Spacer()
                            Text(growthLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                // How it all works: one plain line, no guessing.
                Text("🎯 Missions +10 · 🎤 Verified +25 · 🎮 Quiz +5")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Empty ghar: tell the kid exactly what to do. If everything
                // is just in storage, nudge them to put it back instead.
                if ownedIDs.isEmpty {
                    Text(storedIDs.isEmpty
                         ? "👆 Your ghar is empty! Do a mission or play the quiz to earn XP, then come back and decorate."
                         : "📦 Everything is in storage! Open the Ghar Shop below to put decorations back.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.orange.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal)
                }

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

                // The house scene: a Himalayan morning — sun, clouds, snowy
                // peaks, and your ghar with its tiered roof.
                // Mystery treasures: earned from the gift box, displayed on
                // a shelf above the house. Tap one to hear its Nepali name.
                let mysteryOwned = mysteryBoxPrizes.filter { ownedIDs.contains($0.id) }
                if !mysteryOwned.isEmpty {
                    VStack(spacing: 8) {
                        Text("🎁 Mystery Treasures")
                            .font(.headline)
                        HStack(spacing: 16) {
                            ForEach(mysteryOwned) { item in
                                Button(action: { sayDecoration(id: item.id, nepali: item.nameNe, romanized: item.romanized) }) {
                                    VStack(spacing: 4) {
                                        AsyncImage(url: URL(string: GharAPI.baseURLString + "/images/nepal-v1/mystery_\(item.id).jpg")) { phase in
                                            if case .success(let image) = phase {
                                                image.resizable().scaledToFit()
                                            } else {
                                                Text(item.icon)
                                                    .font(.system(size: 40))
                                            }
                                        }
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        Text(item.nameNe)
                                            .font(.caption)
                                            .bold()
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                        .background(.purple.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)
                }
                ZStack {
                    // The room: a cozy Nepali interior in generated art.
                    // The dog and the decorations live inside it now.
                    Group {
                        if let bg = myGharSprite("room_bg") {
                            bg.resizable().scaledToFill()
                        } else {
                            Rectangle().fill(.orange.opacity(0.15))
                        }
                    }
                    .frame(width: stageW, height: stageH)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // His name hangs on the wooden sign in the room.
                    if ownedIDs.contains("dog") {
                        Text(dogName)
                            .font(.system(size: 16 * stageK, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.36, green: 0.22, blue: 0.08))
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .frame(width: 78 * stageK)
                            .offset(x: -1 * stageK, y: -47 * stageK)
                    }

                    // Prayer flags drape across the top of the room.
                    flagsOverlay
                        .offset(x: 0, y: -160 * stageK)

                    // Windows: the dressed-up window covers the room's
                    // own window exactly — same spot, same size. LOCKED
                    // there: no Arrange drag and no saved layout delta,
                    // so it can never end up pasted on the bare wall.
                    if ownedIDs.contains("windows") {
                        Group {
                            if let img = myGharSprite("windows") {
                                img.resizable().scaledToFill()
                            } else {
                                Text("🪟").font(.system(size: 40 * stageK))
                            }
                        }
                        .frame(width: 119 * stageK, height: 198 * stageK)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .scaleEffect(poppedID == "windows" ? 1.05 : 1.0)
                        .onTapGesture {
                            sayDecoration(shopItem("windows"))
                            poke("windows")
                        }
                        .offset(x: 95 * stageK, y: -101 * stageK)
                    }

                    // The Himalayas, framed big on the wall.
                    mountainRange

                    // A carved door panel standing by the window.
                    if ownedIDs.contains("door") {
                        deco("door", size: 76)
                            .offset(placedOffset("door", x: -122, y: 116))
                            .arrange("door", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
                    }

                    // The diyo glows at the rug's edge.
                    diyo
                        .offset(placedOffset("diyo", x: -112, y: 146))
                        .arrange("diyo", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
                        .scaleEffect(poppedID == "diyo" ? 1.35 : 1.0)
                        .onTapGesture {
                            if ownedIDs.contains("diyo") {
                                sayDecoration(shopItem("diyo"))
                                poke("diyo")
                            }
                        }

                    // On the shelves and walls: garland, bell, prizes.
                    bodyDeco

                    // Suga perches on the middle shelf — tap him to talk.
                    buddy
                        .offset(placedOffset("buddy", x: 108, y: 100))
                        .arrange("buddy", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
                        .onTapGesture {
                            if ownedIDs.contains("buddy") {
                                buddyTalk()
                                poke("buddy")
                                if !arranging { roomSelection = .parrot }
                            }
                        }

                    // The feeding moment: the treat pops up at Suga's beak.
                    if let emoji = feedEmoji {
                        Text(emoji)
                            .font(.system(size: 30))
                            .offset(placedOffset("buddy", x: 126, y: 13))
                            .transition(.scale.combined(with: .opacity))
                    }

                    // The living dog — real art now — walks the rug.
                    // Tap to hear a happy bark. Draggable in Arrange mode.
                    if ownedIDs.contains("dog") {
                        SpriteDogView(
                            pose: dogPose,
                            walkPhase: dogWalkPhase,
                            wagPhase: dogWagPhase,
                            blinking: dogBlinking,
                            facingRight: dogFacingRight,
                            carryingBall: dogCarryingBall,
                            bounce: petting ? 1.0 : dogBounce,
                            spinDegrees: dogSpinDegrees,
                            stage: dogStage
                        )
                        .frame(width: 118 * stageK, height: 168 * stageK)
                        .offset(placedOffset("dog", x: -14 + dogRoamX, y: 110 + (poppedID == "dog" ? -12 : 0)))
                        .arrange("dog", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
                        .onTapGesture {
                            dogTalk()
                            poke("dog")
                            if !arranging { roomSelection = .dog }
                        }
                        // Fetch ball: flies out, the dog carries it back.
                        if fetchBallVisible {
                            Text("🎾")
                                .font(.system(size: 26 * stageK))
                                .offset(placedOffset("dog", x: -14 + dogRoamX + fetchBallX, y: 90))
                                .transition(.scale)
                        }
                    }

                    // The yard and sky: bought decorations around the house.
                    sceneDeco
                }
                .id("myghar.room")
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(myTourStep == .room ? Color.orange : Color.clear, lineWidth: 3))

                // Pal action bar: appears under the room when you tap
                // Bhunte or Suga IN the room, so the buttons and the
                // animal they control stay on screen together. Actions
                // and learned tricks share one sideways-scrolling row
                // of small chips: every trick stays reachable on any
                // phone width, nothing buried below the fold.
                if let sel = roomSelection {
                    VStack(spacing: 6) {
                        HStack {
                            Text(sel == .dog ? "🐕 \(dogName)" : "🦜 \(buddyDisplayName)")
                                .font(.subheadline)
                                .bold()
                            Spacer()
                            Button {
                                roomSelection = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                if sel == .parrot {
                                    palChip("Feed", icon: "fork.knife", cost: "5 XP", disabled: totalXP < 5) { feedBuddy() }
                                    palChip("Teach", icon: "graduationcap", cost: "10 XP", disabled: totalXP < 10) { teachingBuddy = true }
                                    palChip("Mimic", icon: "mic.fill", cost: "20 XP", disabled: totalXP < 20) { startMimic() }
                                    palChip("Rename", icon: "pencil", cost: "25 XP", disabled: totalXP < 25) { renamingBuddy = true }
                                } else {
                                    palChip("Pet", icon: "hand.raised.fill", cost: "free") { petDog() }
                                    palChip("Fetch", icon: "tennisball.fill", cost: "+2 XP", disabled: fetchCount >= 5 && lastFetchDate == Streak.todayString) { playFetch() }
                                    palChip("Teach trick", icon: "graduationcap.fill", cost: "\(dogTricks.count) known") { teachingTrick = true }
                                    palChip("Rename", icon: "pencil", cost: "free") {
                                        dogNameDraft = dogName
                                        dogNameError = nil
                                        renamingDog = true
                                    }
                                    if !dogTricks.isEmpty {
                                        Divider().frame(height: 28)
                                        ForEach(dogTricks, id: \.self) { trick in
                                            Button(action: { performTrick(trick) }) {
                                                HStack(spacing: 4) {
                                                    Text("🐾").font(.callout)
                                                    Text(trick).font(.callout)
                                                }
                                                .padding(.horizontal, 4)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(10)
                    .background(sel == .dog ? Color.orange.opacity(0.10) : Color.green.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.2), value: roomSelection)
                }

                // Trophy shelf: prizes that can't be bought — only earned.
                VStack(alignment: .leading, spacing: 6) {
                    Text("🏆 Trophy Shelf")
                        .font(.headline)
                        .padding(.horizontal)
                        .id("myghar.trophies")
                        .background(myTourStep == .trophies ? Color.orange.opacity(0.25) : Color.clear)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(exclusiveItems) { item in
                                let earned = ownedIDs.contains(item.id)
                                VStack(spacing: 4) {
                                    Group {
                                        if let img = myGharSprite(item.id) {
                                            img.resizable().scaledToFit()
                                        } else {
                                            Text(item.icon).font(.system(size: 32))
                                        }
                                    }
                                    .frame(width: 54, height: 54)
                                    .grayscale(earned ? 0 : 1)
                                    .opacity(earned ? 1 : 0.45)
                                    Text(item.nameEn)
                                        .font(.caption2)
                                        .bold()
                                    Text(earned ? "Earned! 🌟" : trophyHint(item.id))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(width: 78)
                                .onTapGesture {
                                    if earned {
                                        sayDecoration(item)
                                        poke(item.id)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                // Teen rewards shelf: lesson prizes, mystery prizes
                // and the golden ball — earned on the teen surface.
                VStack(alignment: .leading, spacing: 6) {
                    Text("🎁 Teen Rewards")
                        .font(.headline)
                        .padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(teenShowcaseItems) { item in
                                let earned = ownedIDs.contains(item.id)
                                VStack(spacing: 4) {
                                    Group {
                                        if let img = myGharSprite(item.id) {
                                            img.resizable().scaledToFit()
                                        } else {
                                            Text(item.icon).font(.system(size: 32))
                                        }
                                    }
                                    .frame(width: 54, height: 54)
                                    .grayscale(earned ? 0 : 1)
                                    .opacity(earned ? 1 : 0.45)
                                    Text(item.nameEn)
                                        .font(.caption2)
                                        .bold()
                                        .multilineTextAlignment(.center)
                                    Text(earned ? "Earned! 🌟" : teenHint(item.id))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(width: 78)
                                .onTapGesture {
                                    if earned {
                                        sayDecoration(item)
                                        poke(item.id)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                // Arrange mode: drag anything in the scene to move it.
                // Spots are saved, so the house keeps your layout.
                // Pushed to the side so it doesn't cover the dog's spot.
                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Button(arranging ? "Done arranging" : "🔀 Arrange house") {
                            arranging.toggle()
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .id("myghar.arrange")
                        .background(myTourStep == .arrange ? Color.orange.opacity(0.25) : Color.clear)
                        if arranging {
                            Text("Drag decorations to move them — taps still make them talk!")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Suga's corner: feed him, teach him words. Only shows
                // once he's adopted from the shop. Collapsible like the shop.
                if ownedIDs.contains("buddy") {
                    DisclosureGroup(isExpanded: $parrotOpen) {
                        VStack(spacing: 10) {
                            if feedCount > 0 {
                                Text("Fed \(feedCount) time\(feedCount == 1 ? "" : "s") 🍌")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("Tap Suga in the house — his buttons appear under the room!")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(.green.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    } label: {
                        HStack {
                            Text("🦜 \(buddyDisplayName) (parrot)")
                                .font(.headline)
                            Spacer()
                            Text("knows \(taughtIDs.count + 2) phrases")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)
                }

                // Dog buddy: unlocked by completing ALL missions. More
                // interactive than Suga — pet, teach tricks, play fetch.
                if ownedIDs.contains("dog") {
                    DisclosureGroup(isExpanded: $dogOpen) {
                        VStack(spacing: 10) {
                            // Bones balance + the big Level Up moment.
                            HStack {
                                Text("🦴 \(bones) bones")
                                    .font(.headline)
                                Spacer()
                                Text(dogStageName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if canLevelUp {
                                Button(action: levelUpDog) {
                                    Text("🎉 Level Up! Grow to \(nextStageName)")
                                        .font(.headline)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                            }
                            Text("Tap \(dogName) in the house — his play buttons appear under the room!")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .background(.orange.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    } label: {
                        HStack {
                            Text("🐕 \(dogName) (dog)")
                                .font(.headline)
                            Spacer()
                            Text("mission master reward")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    .sheet(isPresented: $teachingTrick) {
                        NavigationStack {
                            VStack(spacing: 16) {
                                Text("🐕 Teach \(dogName) a trick!")
                                    .font(.title2)
                                    .bold()
                                Text("Type a trick name in Nepali or English — like \"bas\" (sit) or \"ghum\" (spin).")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                TextField("Trick name…", text: $trickName)
                                    .textFieldStyle(.roundedBorder)
                                    .padding(.horizontal)
                                Button("Teach it!") { saveTrick() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(trickName.trimmingCharacters(in: .whitespaces).isEmpty)
                                Button("Cancel") { teachingTrick = false }
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                            .navigationTitle("New trick")
                            .navigationBarTitleDisplayMode(.inline)
                        }
                    }
                    .sheet(isPresented: $renamingDog) {
                        NavigationStack {
                            VStack(spacing: 16) {
                                Text("🐕 Rename your dog")
                                    .font(.title2)
                                    .bold()
                                TextField("Dog's name…", text: $dogNameDraft)
                                    .textFieldStyle(.roundedBorder)
                                    .padding(.horizontal)
                                if let err = dogNameError {
                                    Text(err)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                                Button("Save") {
                                    let name = dogNameDraft.trimmingCharacters(in: .whitespaces)
                                    if name.isEmpty {
                                        dogNameError = "Name can't be empty."
                                    } else if name.count > 14 {
                                        dogNameError = "Keep it under 14 letters."
                                    } else {
                                        dogName = name
                                        renamingDog = false
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                Button("Cancel") { renamingDog = false }
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                            .navigationTitle("Rename dog")
                            .navigationBarTitleDisplayMode(.inline)
                        }
                    }
                }

                // Name your ghar.
                TextField("Name your ghar…", text: $houseName)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 40)
                    .focused($houseNameFocused)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("Done") { houseNameFocused = false }
                        }
                    }

                // Ghar Shop: spend XP to add decorations to your house.
                // Collapsed by default — tap the header to open.
                DisclosureGroup(isExpanded: $shopOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                    Text("Earn XP from missions and the quiz, then spend it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(shopItems) { item in
                        HStack(spacing: 12) {
                            shopIcon(item)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.nameNe).font(.headline)
                                Text("\(item.romanized) · \(item.nameEn)").font(.caption).foregroundStyle(.secondary)
                            }
                            Button(action: { sayDecoration(item) }) {
                                Image(systemName: "speaker.wave.2.fill")
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            if ownedIDs.contains(item.id) {
                                Button("Put away") { storeItem(item) }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.title3)
                            } else if storedIDs.contains(item.id) {
                                Button("Put back") { placeItem(item) }
                                    .buttonStyle(.bordered)
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
                } label: {
                    HStack {
                        Text("🏪 Ghar Shop")
                            .font(.headline)
                            .id("myghar.shop")
                            .background(myTourStep == .shop ? Color.orange.opacity(0.25) : Color.clear)
                        Spacer()
                        Text("\(shopItems.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.gray.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                .padding()
                .background(.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                // Prove-it Prizes: earned by verifying missions, never sold.
                // Showing them locked advertises the recording flow.
                // Collapsed by default — tap the header to open.
                DisclosureGroup(isExpanded: $prizesOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                    Text("Verify missions with a grown-up, keep a streak going, or answer quiz questions to earn these. They can't be bought.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(exclusiveItems) { item in
                        let need = exclusiveNeed[item.id] ?? 99
                        let have = min(verifiedIDs.count, need)
                        HStack(spacing: 12) {
                            shopIcon(item)
                                .opacity(ownedIDs.contains(item.id) ? 1 : 0.4)
                                .grayscale(ownedIDs.contains(item.id) ? 0 : 1)
                            VStack(alignment: .leading, spacing: 2) {
                                if ownedIDs.contains(item.id) {
                                    Text(item.nameNe).font(.headline)
                                    Text("✅ Earned!").font(.caption).foregroundStyle(.green)
                                } else if item.id == "flameDiyo" || item.id == "streakCrown" {
                                    Text(item.id == "flameDiyo" ? "🔥 Keep a 7-day streak" : "👑 Keep a 15-day streak")
                                        .font(.headline)
                                    Text("\(item.nameNe) · \(item.nameEn)")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if let qneed = QuizStickers.thresholds[item.id] {
                                    Text("🎯 Get \(qneed) quiz answers right")
                                        .font(.headline)
                                    Text("\(item.nameNe) · \(item.nameEn)")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("🎤 Verify \(need) mission\(need == 1 ? "" : "s")")
                                        .font(.headline)
                                    Text("\(item.nameNe) · \(item.nameEn)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Button(action: { sayDecoration(item) }) {
                                Image(systemName: "speaker.wave.2.fill")
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            if ownedIDs.contains(item.id) {
                                if !item.id.hasPrefix("quiz") {
                                    Button("Put away") { storeItem(item) }
                                        .font(.caption)
                                        .buttonStyle(.bordered)
                                }
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.title3)
                            } else if storedIDs.contains(item.id) {
                                Button("Put back") { placeItem(item) }
                                    .buttonStyle(.bordered)
                            } else if item.id == "flameDiyo" {
                                Text("🔒 7-day streak")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if item.id == "streakCrown" {
                                Text("🔒 15-day streak")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if let qneed = QuizStickers.thresholds[item.id] {
                                Text("🔒 \(min(QuizStats.correctTotal, qneed))/\(qneed) right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("🔒 \(have)/\(need) verified")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    }
                } label: {
                    HStack {
                        Text("🏆 Prove-it Prizes")
                            .font(.headline)
                        Spacer()
                        Text("\(exclusiveItems.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.gray.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                .padding()
                .background(.yellow.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                // Mystery Prizes: earned from the gift box, never sold.
                // Collapsed by default — tap the header to open.
                DisclosureGroup(isExpanded: $mysteryOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                    Text("Finish a tracing section to earn these — they can't be bought.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(mysteryBoxPrizes) { item in
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: GharAPI.baseURLString + "/images/nepal-v1/mystery_\(item.id).jpg")) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFit()
                                } else {
                                    shopIcon(item)
                                }
                            }
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .opacity(ownedIDs.contains(item.id) ? 1 : 0.4)
                            .grayscale(ownedIDs.contains(item.id) ? 0 : 1)
                            VStack(alignment: .leading, spacing: 2) {
                                if ownedIDs.contains(item.id) {
                                    Text(item.nameNe).font(.headline)
                                    Text("✅ Earned!").font(.caption).foregroundStyle(.green)
                                } else {
                                    Text("🎁 Mystery box").font(.headline)
                                    Text("\(item.nameNe) · \(item.nameEn)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Button(action: { sayDecoration(item) }) {
                                Image(systemName: "speaker.wave.2.fill")
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            if !ownedIDs.contains(item.id) {
                                Text("🔒")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    }
                } label: {
                    HStack {
                        Text("🎁 Mystery Prizes")
                            .font(.headline)
                        Spacer()
                        Text("\(mysteryBoxPrizes.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.gray.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                .padding()
                .background(.purple.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                // Decoration Sets: complete a set, pocket a bonus.
                // Collapsed by default — tap the header to open.
                DisclosureGroup(isExpanded: $setsOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                    Text("Own every item in a set to pocket its bonus — each set pays once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(decoSets) { set in
                        let got = set.itemIds.filter { ownedIDs.contains($0) }.count
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(set.nameEn).font(.headline)
                                Text("\(got)/\(set.itemIds.count) · bonus +\(set.bonus) XP")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if awardedSets.contains(set.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.title3)
                            } else {
                                HStack(spacing: 4) {
                                    ForEach(set.itemIds, id: \.self) { id in
                                        shopIcon(shopItem(id), size: 26)
                                            .opacity(ownedIDs.contains(id) ? 1 : 0.3)
                                            .grayscale(ownedIDs.contains(id) ? 0 : 1)
                                    }
                                }
                            }
                        }
                    }
                    }
                } label: {
                    HStack {
                        Text("🎁 Decoration Sets")
                            .font(.headline)
                        Spacer()
                        Text("\(decoSets.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.gray.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                .padding()
                .background(.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)


                Text("Tap a decoration in the room to hear its Nepali name 🗣️")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical)
        }
        .onAppear {
            grantExclusives()
            grantDog()
            grantBall()
            syncBones()
            checkSets()
            startDogTimers()
        }
        .onDisappear {
            stopDogTimers()
        }
        // Paywall: pops when a free-tier kid tries a 4th decoration.
        .sheet(isPresented: $showingPaywall) {
            PaywallView()
        }
        // Naming sheet: pops right after adopting Suga.
        .sheet(isPresented: $namingBuddy) {
            NavigationStack {
                VStack(spacing: 16) {
                    Text("🦜").font(.system(size: 64))
                    Text("You adopted a parrot!")
                        .font(.title2).bold()
                    Text("What will you name him?")
                        .foregroundStyle(.secondary)
                    TextField("Name...", text: $buddyNameDraft)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 40)
                    if let err = buddyNameError(buddyNameDraft) {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button("Meet \(buddyNameDraft.trimmingCharacters(in: .whitespaces).isEmpty ? "Suga" : buddyNameDraft.trimmingCharacters(in: .whitespaces))!") {
                        buddyName = buddyNameDraft.trimmingCharacters(in: .whitespaces)
                        namingBuddy = false
                        poke("buddy")
                        sayDecoration(id: "sugaGreeting", nepali: "नमस्ते! म सुगा हुँ!", romanized: "namaste! ma suga hun!")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(buddyNameError(buddyNameDraft) != nil)
                }
                .padding()
                .navigationTitle("New friend")
            }
        }
        // Rename sheet: change Suga's name for 25 XP.
        .sheet(isPresented: $renamingBuddy) {
            NavigationStack {
                VStack(spacing: 16) {
                    Text("🦜").font(.system(size: 64))
                    Text("Rename your parrot")
                        .font(.title2).bold()
                    Text("25 XP — what should we call him now?")
                        .foregroundStyle(.secondary)
                    TextField("New name...", text: $buddyNameDraft)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 40)
                        .onAppear { buddyNameDraft = buddyDisplayName == "Suga" ? "" : buddyDisplayName }
                    if let err = buddyNameError(buddyNameDraft) {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button("Rename · 25 XP") {
                        let newName = buddyNameDraft.trimmingCharacters(in: .whitespaces)
                        guard buddyNameError(newName) == nil, totalXP >= 25 else { return }
                        totalXP -= 25
                        buddyName = newName
                        buddyNameDraft = ""
                        renamingBuddy = false
                        poke("buddy")
                        lastWin = "Say hi to \(buddyDisplayName)! 🦜"
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(buddyNameError(buddyNameDraft) != nil || totalXP < 25)
                }
                .padding()
                .navigationTitle("Rename parrot")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { renamingBuddy = false; buddyNameDraft = "" }
                    }
                }
            }
        }
        // Mimic sheet: record a clip, Suga squawks it back in parrot voice.
        .sheet(isPresented: $mimickingBuddy) {
            NavigationStack {
                VStack(spacing: 20) {
                    Text("🦜").font(.system(size: 64))
                    Text("\(buddyDisplayName) the Mimic")
                        .font(.title2).bold()
                    Text("Record something, then hear Suga squawk it back!")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button(action: toggleMimicRecord) {
                        Label(mimicRecording ? "Stop" : (mimicURL == nil ? "Record" : "Re-record"),
                              systemImage: mimicRecording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(mimicRecording ? .red : .blue)
                    if mimicRecording {
                        Text("🔴 Recording…")
                            .foregroundStyle(.red)
                            .font(.headline)
                    }
                    if mimicURL != nil && !mimicRecording {
                        Button(action: playMimicAsParrot) {
                            Label("Hear Suga say it! 🦜", systemImage: "speaker.wave.2.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                }
                .padding()
                .navigationTitle("Parrot Mimic")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            mimicRecorder?.stop()
                            mimicRecorder = nil
                            mimicRecording = false
                            mimicEngine?.stop()
                            mimickingBuddy = false
                        }
                    }
                }
            }
        }
        // Teach sheet: pick any word from the pack, 10 XP, Suga learns it.
        .sheet(isPresented: $teachingBuddy) {
            NavigationStack {
                List(allWords) { w in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(w.devanagari).font(.headline)
                            Text("\(w.romanized) · \(w.english)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if taughtIDs.contains(w.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button("Teach · 10 XP") { teachBuddy(w) }
                                .buttonStyle(.bordered)
                                .disabled(totalXP < 10)
                        }
                    }
                }
                .navigationTitle("Teach \(buddyDisplayName)")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { teachingBuddy = false }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let step = myTourStep {
                MyGharTourBanner(step: step,
                                 isLast: step == .arrange,
                                 onNext: advanceMyGharTour,
                                 onSkip: { myTourStep = nil })
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { startMyGharTourIfNeeded() }
        .onChange(of: myTourStep) { _, step in
            guard let step else { return }
            withAnimation { proxy.scrollTo(step.anchorID, anchor: .top) }
        }
        }
    }

    /// Buy a decoration: must be affordable and not already owned.
    /// Deducts the XP, marks it owned, speaks its Nepali name as a little
    /// celebration — then checks whether a set just got completed.
    private func buy(_ item: ShopItem) {
        guard !ownedIDs.contains(item.id), totalXP >= item.cost else { return }
        // Free tier: 3 decorations max. The 4th opens the paywall.
        if !isUnlocked && purchasableOwnedCount >= 3 {
            showingPaywall = true
            return
        }
        totalXP -= item.cost
        var ids = ownedIDs
        ids.insert(item.id)
        ownedData = (try? JSONEncoder().encode(ids)) ?? Data()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        sayDecoration(item)
        checkSets(silent: true)   // a purchase speaks the item's name ONLY (Som's call, 2026-10-22)
        if item.id == "buddy" {
            buddyNameDraft = ""
            namingBuddy = true
        }
    }

    /// Tapping Suga: he says a random phrase — greetings plus every word
    /// the kid has taught him. Reuses recordings that already exist
    /// (the राम्रो! praise cheer, the नमस्ते! conversation line, each
    /// taught word's own clip) so nothing is recorded twice — anything
    /// still unrecorded falls back to the phone's voice.
    /// Play a clip in Suga's own voice: pitched up +800 cents
    /// (about two-thirds of an octave) so the parrot sounds like a
    /// parrot, not like the grown-up clone. The pitch shifter is
    /// primed with a beat of silence so its start-up smear lands in
    /// the silence instead of on the word's first syllable, and the
    /// engine stops only once the sound has actually played out —
    /// short words keep their endings. Used for taught words (any
    /// word can be taught, so those can't be pre-rendered); Suga's
    /// staple lines are pre-pitched files played plainly instead.
    private func sugaPlay(_ url: URL) {
        sugaEngine?.stop()
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let format = file.processingFormat
        guard let raw = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { return }
        do { try file.read(into: raw) } catch { return }
        let primeFrames = AVAudioFrameCount(format.sampleRate * 0.25)
        guard let primed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: raw.frameLength + primeFrames),
              let src = raw.floatChannelData, let dst = primed.floatChannelData else { return }
        primed.frameLength = raw.frameLength + primeFrames
        for ch in 0..<Int(format.channelCount) {
            for i in 0..<Int(primeFrames) { dst[ch][i] = 0 }
            for i in 0..<Int(raw.frameLength) { dst[ch][Int(primeFrames) + i] = src[ch][i] }
        }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.pitch = 800
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: format)
        engine.connect(pitch, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return }
        player.scheduleBuffer(primed, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
            DispatchQueue.main.async {
                self.sugaEngine?.stop()
            }
        }
        player.play()
        sugaEngine = engine
    }

    private func buddyTalk() {
        // (nepali, romanized, audioUrl, hasAudio, prePitchedFile)
        // The two staples ship as pre-pitched files (rendered once,
        // perfectly); taught words go through the pitch engine.
        var options: [(String, String, String, Bool, String?)] = []
        if let ramro = pack.praise?.first(where: { $0.id == "ramro" }) {
            options.append(("राम्रो छ!", "ramro chha!", ramro.audioUrl, ramro.hasAudio == true, "suga_praise_ramro_np.m4a"))
        }
        if let namaste = word("convo_namaste") {
            options.append(("नमस्ते!", "namaste!", namaste.audioUrl, namaste.hasAudio == true, "suga_convo_namaste_np.m4a"))
        }
        for id in taughtIDs {
            if let w = word(id) {
                options.append((w.devanagari, w.romanized, w.audioUrl, w.hasAudio == true, nil))
            }
        }
        guard let pick = options.randomElement() else { return }
        if let pre = pick.4, let url = URL(string: GharAPI.baseURLString + "/audio/nepal-v1/" + pre) {
            decoPlayer?.pause()
            decoPlayer = AVPlayer(url: url)
            decoPlayer?.play()
        } else if pick.3, let url = URL(string: GharAPI.baseURLString + pick.2) {
            sugaPlay(url)
        } else {
            NepaliSpeaker.say(nepali: pick.0, romanized: pick.1)
        }
    }

    /// Feed Suga: 5 XP. A treat pops up at his beak and he hops and
    /// eats it, saying it's delicious. The recurring sink — there's
    /// always a reason to earn more XP.
    private func feedBuddy() {
        guard ownedIDs.contains("buddy"), totalXP >= 5 else { return }
        totalXP -= 5
        feedCount += 1
        let foods = ["🍎", "🍌", "🌽", "🍇"]
        let yum = foods.randomElement() ?? "🍎"
        withAnimation { feedEmoji = yum }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation { feedEmoji = nil }
        }
        poke("buddy")
        lastWin = buddyDisplayName + " loved the " + yum + "!"
        if let url = URL(string: GharAPI.baseURLString + "/audio/nepal-v1/suga_mitho_np.m4a") {
            decoPlayer?.pause()
            decoPlayer = AVPlayer(url: url)
            decoPlayer?.play()
        } else {
            NepaliSpeaker.say(nepali: "मिठो छ!", romanized: "mitho chha!")
        }
    }

    /// Mimic mode: 20 XP. Kid records a clip, Suga squawks it back
    /// pitched-up like a parrot. Deducts XP and opens the sheet.
    private func startMimic() {
        guard ownedIDs.contains("buddy"), totalXP >= 20 else { return }
        totalXP -= 20
        mimicURL = nil
        mimicRecording = false
        mimickingBuddy = true
    }

    /// Start/stop the mimic recording. Uses a temp file in caches.
    private func toggleMimicRecord() {
        if mimicRecording {
            mimicRecorder?.stop()
            mimicRecorder = nil
            mimicRecording = false
        } else {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("suga-mimic-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            // Record off-main (same pattern as MissionRecorder.sessionQueue).
            mimicQueue.async {
                let session = AVAudioSession.sharedInstance()
                try? session.setCategory(.playAndRecord, mode: .default, options: .defaultToSpeaker)
                try? session.setActive(true)
                let rec = try? AVAudioRecorder(url: url, settings: settings)
                rec?.record()
                let isRec = rec?.isRecording ?? false
                DispatchQueue.main.async {
                    self.mimicRecorder = rec
                    self.mimicURL = url
                    self.mimicRecording = isRec
                }
            }
        }
    }

    /// Play the mimic clip back through a pitch-shifter for the
    /// squeaky parrot voice (+1200 cents = one octave up).
    private func playMimicAsParrot() {
        guard let url = mimicURL else { return }
        // Stop any existing playback first.
        mimicEngine?.stop()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.pitch = 800
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: nil)
        engine.connect(pitch, to: engine.mainMixerNode, format: nil)
        guard let file = try? AVAudioFile(forReading: url) else { return }
        do {
            try engine.start()
        } catch { return }
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { _ in
            DispatchQueue.main.async {
                self.mimicEngine?.stop()
            }
        }
        player.play()
        mimicEngine = engine
        poke("buddy")
        lastWin = buddyDisplayName + " says it back! 🦜"
    }

    /// Teach Suga a word: 10 XP. He learns it, says it on the spot, and
    /// it joins his tap-to-talk rotation from then on.
    private func teachBuddy(_ w: Word) {
        guard !taughtIDs.contains(w.id), totalXP >= 10 else { return }
        totalXP -= 10
        var ids = taughtIDs
        ids.insert(w.id)
        taughtData = (try? JSONEncoder().encode(ids)) ?? Data()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        lastWin = buddyDisplayName + " learned " + w.romanized + "!"
        // The word's own recording when it exists — no re-recording.
        if w.hasAudio == true,
           let url = URL(string: GharAPI.baseURLString + w.audioUrl) {
            sugaPlay(url)
        } else {
            NepaliSpeaker.say(nepali: w.devanagari, romanized: w.romanized)
        }
    }

    /// Build a big-ticket upgrade: deduct XP, mark owned, celebrate.
    /// The yard redraws itself on the next render — no restart needed.
    private func buyUpgrade(_ item: ShopItem) {
        guard !upgradeIDs.contains(item.id), totalXP >= item.cost else { return }
        totalXP -= item.cost
        var ids = upgradeIDs
        ids.insert(item.id)
        upgradesData = (try? JSONEncoder().encode(ids)) ?? Data()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        lastWin = item.nameEn + " built!"
        sayDecoration(item)
    }

    /// Put a decoration away into storage: off the house, no XP refund.
    /// Putting it back is free, anytime.
    private func storeItem(_ item: ShopItem) {
        guard ownedIDs.contains(item.id) else { return }
        var ids = ownedIDs
        ids.remove(item.id)
        ownedData = (try? JSONEncoder().encode(ids)) ?? Data()
        var stored = storedIDs
        stored.insert(item.id)
        storedData = (try? JSONEncoder().encode(stored)) ?? Data()
    }

    /// Put a stored decoration back on the house — free.
    private func placeItem(_ item: ShopItem) {
        guard storedIDs.contains(item.id) else { return }
        var stored = storedIDs
        stored.remove(item.id)
        storedData = (try? JSONEncoder().encode(stored)) ?? Data()
        var ids = ownedIDs
        ids.insert(item.id)
        ownedData = (try? JSONEncoder().encode(ids)) ?? Data()
        poke(item.id)
    }

    /// Put a built upgrade into storage — off the house, free to put back.
    private func storeUpgrade(_ item: ShopItem) {
        guard upgradeIDs.contains(item.id) else { return }
        var ids = upgradeIDs
        ids.remove(item.id)
        upgradesData = (try? JSONEncoder().encode(ids)) ?? Data()
        var stored = storedUpgradeIDs
        stored.insert(item.id)
        storedUpgradesData = (try? JSONEncoder().encode(stored)) ?? Data()
    }

    /// Put a stored upgrade back on the house — free.
    private func placeUpgrade(_ item: ShopItem) {
        guard storedUpgradeIDs.contains(item.id) else { return }
        var stored = storedUpgradeIDs
        stored.remove(item.id)
        storedUpgradesData = (try? JSONEncoder().encode(stored)) ?? Data()
        var ids = upgradeIDs
        ids.insert(item.id)
        upgradesData = (try? JSONEncoder().encode(ids)) ?? Data()
        poke(item.id)
    }

    /// Prove-it prizes: grant every exclusive whose verified-mission
    /// requirement is met. Runs on appear, so prizes land the moment the
    /// grown-up confirms — even if the kid is already on this tab.
    private func grantExclusives() {
        var ids = ownedIDs
        var changed = false
        for item in exclusiveItems {
            let need = exclusiveNeed[item.id] ?? Int.max
            if verifiedIDs.count >= need && !ids.contains(item.id) {
                ids.insert(item.id)
                changed = true
                lastWin = "\(item.nameEn) earned! 🏆"
            }
        }
        for (id, need) in QuizStickers.thresholds where QuizStats.correctTotal >= need && !ids.contains(id) {
            ids.insert(id)
            changed = true
            if let item = exclusiveItems.first(where: { $0.id == id }) {
                lastWin = "\(item.nameEn) earned! 🏆"
            }
        }
        if changed {
            ownedData = (try? JSONEncoder().encode(ids)) ?? Data()
            WinFanfare.play()
        }
    }

    /// Soccer ball: unlocked when ALL teen missions are complete —
    /// the teen parallel to the dog.
    private func grantBall() {
        guard !ownedIDs.contains("goldsoccerball") else { return }
        guard !TeenMissions.all.isEmpty else { return }
        let done = TeenMissions.all.filter { completedIDs.contains($0.id) }.count
        if done >= TeenMissions.all.count {
            var ids = ownedIDs
            ids.insert("goldsoccerball")
            ownedData = (try? JSONEncoder().encode(ids)) ?? Data()
            lastWin = "⚽ You finished every teen mission! A GOLDEN soccer ball for your Ghar!"
            QuizDing.play()
        }
    }

    /// Dog buddy: unlocked when ALL missions are complete. The ultimate prize.
    private func grantDog() {
        guard !ownedIDs.contains("dog") else { return }
        let totalMissions = pack.missions.count
        guard totalMissions > 0 else { return }
        let doneCount = pack.missions.filter { completedIDs.contains($0.id) }.count
        if doneCount >= totalMissions {
            var ids = ownedIDs
            ids.insert("dog")
            ownedData = (try? JSONEncoder().encode(ids)) ?? Data()
            lastWin = "🐕 You did every mission! Meet \(dogName)!"
            WinFanfare.play()
        }
    }

    /// Bones ride along with XP: every XP earned anywhere in the app
    /// also earns a bone. Synced lazily from the shared XP total, so
    /// every award site (quiz, missions, tracing...) counts without
    /// being touched. Bones start at 0 the day the dog arrives — XP
    /// earned before he existed doesn't count. A refund never takes
    /// bones back.
    private func syncBones() {
        guard ownedIDs.contains("dog") else { return }
        if !bonesInit {
            bonesSyncedXP = totalXP
            bonesInit = true
            return
        }
        let delta = totalXP - bonesSyncedXP
        if delta > 0 { bones += delta }
        if delta != 0 { bonesSyncedXP = totalXP }
    }

    private var canLevelUp: Bool {
        (dogStage == 0 && bones >= 50) || (dogStage == 1 && bones >= 150)
    }

    private var dogStageName: String {
        ["Puppy", "Young Dog", "Big Dog"][min(max(dogStage, 0), 2)]
    }

    private var nextStageName: String {
        dogStage == 0 ? "Young Dog" : "Big Dog"
    }

    private var growthProgress: Double {
        switch dogStage {
        case 0: return min(Double(bones) / 50.0, 1)
        case 1: return min(Double(max(bones - 50, 0)) / 100.0, 1)
        default: return 1
        }
    }

    private var growthLabel: String {
        switch dogStage {
        case 0: return canLevelUp ? "Ready to grow! 🎉" : "\(50 - bones) 🦴 to Young Dog"
        case 1: return canLevelUp ? "Ready to grow! 🎉" : "\(150 - bones) 🦴 to Big Dog"
        default: return "All grown up! 🎉"
        }
    }

    /// Level Up: the big moment — bones become growth, with fanfare.
    private func levelUpDog() {
        guard canLevelUp else { return }
        dogStage += 1
        lastWin = "🎉 \(dogName) grew into a \(dogStageName)!"
        WinFanfare.play()
        dogTalk()
    }

    /// Pet the dog: press and hold for tail wags. Pure joy, no XP.
    private func petDog() {
        petting = true
        dogTalk()
        // Happy bark via TTS-friendly sound — using system sound for now.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            petting = false
        }
    }

    /// The dog speaks: real bark sound, not TTS.
    private func dogTalk() {
        let barkFile = dogStage == 0 ? "dog_bark" : "dog_bark_big"
        let urlString = GharAPI.baseURLString + "/audio/nepal-v1/\(barkFile).m4a"
        if let url = URL(string: urlString) {
            decoPlayer?.pause()
            decoPlayer = AVPlayer(url: url)
            decoPlayer?.play()
        }
    }

    /// Teach the dog a trick: save the trick name. The dog "does" it on tap.
    private func saveTrick() {
        let name = trickName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var tricks = dogTricks
        tricks.append(name)
        dogTricksData = (try? JSONEncoder().encode(tricks)) ?? Data()
        trickName = ""
        teachingTrick = false
        lastWin = "🐕 \(dogName) learned \"\(name)\"!"
        WinFanfare.play()
    }

    private var dogTricks: [String] {
        (try? JSONDecoder().decode([String].self, from: dogTricksData)) ?? []
    }

    /// Fetch: the ball flies out, the dog RUNS to it, grabs it,
    /// and carries it back. +2 XP, max 10/day.
    private func playFetch() {
        let today = Streak.todayString
        // Reset daily count if it's a new day.
        if lastFetchDate != today {
            fetchCount = 0
            lastFetchDate = today
        }
        guard fetchCount < 5 else { return } // 5 throws × 2 XP = 10 XP/day max
        guard !fetching else { return }
        fetching = true
        fetchCount += 1
        totalXP += 2
        let home = dogRoamX // wherever the dog happens to be
        // Ball flies out.
        fetchBallVisible = true
        fetchBallX = 0
        withAnimation(.easeOut(duration: 0.5)) { fetchBallX = 80 }
        // Dog runs to the ball...
        dogFacingRight = true
        dogPose = .walking
        withAnimation(.easeInOut(duration: 0.9)) { dogRoamX = home + 80 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            // ...grabs it (ball vanishes into mouth)...
            self.dogCarryingBall = true
            self.fetchBallVisible = false
            // ...and carries it home.
            self.dogFacingRight = false
            withAnimation(.easeInOut(duration: 0.9)) { self.dogRoamX = home }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.dogCarryingBall = false
            self.dogPose = .idle
            self.dogFacingRight = true
            self.fetching = false
            self.dogTalk() // proud bark!
        }
    }

    /// Perform a trick: the dog actually DOES it.
    /// "bas"/"sit" → real sitting pose. "ghum"/"spin" → full spin.
    /// Anything else → happy hop.
    private func performTrick(_ trick: String) {
        let lower = trick.lowercased()
        if lower.contains("bas") || lower.contains("sit") {
            dogPose = .sitting
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if self.dogPose == .sitting { self.dogPose = .idle }
            }
        } else if lower.contains("ghum") || lower.contains("spin") {
            withAnimation(.easeInOut(duration: 0.7)) { dogSpinDegrees += 360 }
        } else {
            // Happy hop for any other trick.
            withAnimation(.spring(response: 0.35, dampingFraction: 0.4)) { dogBounce = 1.0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.spring(response: 0.35)) { self.dogBounce = 0.0 }
            }
        }
        dogTalk()
    }

    // MARK: - Living-dog timers

    /// Starts the animation clocks: tail wag + walk cycle + blinks,
    /// plus a roam timer so the dog wanders the yard on its own.
    private func startDogTimers() {
        stopDogTimers()
        dogTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
            dogWagPhase += 0.35
            if dogPose == .walking { dogWalkPhase += 0.5 }
            // Random blink.
            if Int.random(in: 0..<70) == 0 {
                dogBlinking = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    dogBlinking = false
                }
            }
        }
        dogRoamTimer = Timer.scheduledTimer(withTimeInterval: 9, repeats: true) { _ in
            guard ownedIDs.contains("dog"), dogPose == .idle, !fetching else { return }
            let target = CGFloat.random(in: -70...30)
            dogFacingRight = target > dogRoamX
            dogPose = .walking
            withAnimation(.easeInOut(duration: 1.4)) { dogRoamX = target }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if !fetching && dogPose == .walking { dogPose = .idle }
            }
        }
    }

    private func stopDogTimers() {
        dogTimer?.invalidate()
        dogTimer = nil
        dogRoamTimer?.invalidate()
        dogRoamTimer = nil
    }

    /// Set bonuses: own every item in a set, pocket the bonus — once ever.
    /// Also runs on appear, so sets completed before this update pay out
    /// as a welcome-back surprise instead of being missed.
    /// Awards set-completion bonuses. `silent` (purchases) skips the
    /// praise fanfare — buying speaks the item's name and nothing else.
    private func checkSets(silent: Bool = false) {
        var awarded = awardedSets
        var changed = false
        for set in decoSets where !awarded.contains(set.id) {
            if set.itemIds.allSatisfy(ownedIDs.contains) {
                awarded.insert(set.id)
                totalXP += set.bonus
                changed = true
                lastWin = "\(set.nameEn) complete! +\(set.bonus) XP 🎁"
            }
        }
        if changed {
            awardedSetsData = (try? JSONEncoder().encode(awarded)) ?? Data()
            if !silent { WinFanfare.play() }
        }
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
    /// back after a beat. One id state serves all 18 decorations — the view
    /// checks `poppedID == "diyo"` instead of its own Bool.
    private func poke(_ id: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.35)) { poppedID = id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                if poppedID == id { poppedID = nil }
            }
        }
    }

    /// One emoji decoration in the scene: pops + speaks its Nepali name on
    /// tap. Callers wrap it in `if ownedIDs.contains(...)` and position it.
    /// A yard decoration: its watercolor illustration once landed on the
    /// backend, emoji while it loads. Callers wrap it in
    /// `if ownedIDs.contains(...)` and position it.
    /// A small dog-growth icon for the progress bar.
    private func growthIcon(_ name: String, size: CGFloat) -> some View {
        Group {
            if let img = myGharSprite(name) {
                img.resizable().scaledToFit()
            } else {
                Text("🐕").font(.system(size: size * 0.7))
            }
        }
        .frame(width: size, height: size)
    }

    /// Trophy shelf captions for prizes not yet earned.
    private func teenHint(_ id: String) -> String {
        switch id {
        case "goldsoccerball": return "All 8 teen missions"
        case "headphones": return "Finish the Texting deck"
        case "skateboard": return "Finish the Slang deck"
        case "sunglasses": return "Finish the Comebacks deck"
        case "camera": return "Finish the Captions deck"
        case "guitar": return "Finish the Lyrics deck"
        default: return "Teen mystery prize"
        }
    }

    private func trophyHint(_ id: String) -> String {
        switch id {
        case "goldenDiyo": return "1 verified mission"
        case "starBadge": return "3 verified missions"
        case "mukut": return "5 verified missions"
        case "flameDiyo": return "7-day streak"
        case "streakCrown": return "15-day streak"
        case "quiz50": return "50 quiz answers right"
        case "quiz100": return "100 quiz answers right"
        case "quiz250": return "250 quiz answers right"
        case "quiz500": return "500 quiz answers right"
        default: return "Keep going!"
        }
    }

    /// Prayer flags across the top of the room: real garland art,
    /// greyed until bought, rippling forever once they fly.
    private var flagsOverlay: some View {
        Group {
            if let img = myGharSprite("flags") {
                img.resizable().scaledToFit()
            } else {
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { i in
                        Triangle()
                            .fill(ownedIDs.contains("flags") ? flagColors[i % flagColors.count] : .gray.opacity(0.25))
                            .frame(width: 24, height: 20)
                    }
                }
            }
        }
        .frame(width: 252 * stageK, height: 54 * stageK)
        .grayscale(ownedIDs.contains("flags") ? 0 : 1)
        .opacity(ownedIDs.contains("flags") ? 1 : 0.4)
        .rotationEffect(.degrees((poppedID == "flags" ? 8 : 0) + (flagWave ? 2.5 : -2.5)))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                flagWave = true
            }
        }
        .onTapGesture {
            if ownedIDs.contains("flags") {
                sayDecoration(shopItem("flags"))
                poke("flags")
            }
        }
    }

    private func deco(_ id: String, size: CGFloat) -> some View {
        Group {
            if let img = myGharSprite(id) {
                img.resizable().scaledToFit()
            } else {
                Text(shopItem(id).icon)
                    .font(.system(size: size))
            }
        }
        .frame(width: size * stageK, height: size * stageK)
        .scaleEffect(poppedID == id ? 1.3 : 1.0)
        .onTapGesture {
            sayDecoration(shopItem(id))
            poke(id)
        }
    }

    /// Shop row icon: the watercolor illustration (Suga uses his parrot
    /// portrait), falling back to emoji while it loads.
    private func shopIcon(_ item: ShopItem, size: CGFloat = 44) -> some View {
        Group {
            if let img = myGharSprite(item.id == "buddy" ? "suga" : item.id) {
                img.resizable().scaledToFit()
            } else {
                Text(item.icon)
                    .font(.title2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// The Himalayas, drawn with snowy peaks — revealed when you buy them.
    /// Tapping says the name out loud like any other decoration.
    private var mountainRange: some View {
        Group {
            if ownedIDs.contains("himal") {
                // The watercolor range — snow glistens on the peaks.
                ZStack {
                    Group {
                        if let img = myGharSprite("himal") {
                            img.resizable().scaledToFit()
                        } else {
                            Triangle()
                                .fill(.indigo.opacity(0.3))
                                .frame(width: 80, height: 55)
                        }
                    }
                    .frame(width: 66 * stageK, height: 70 * stageK)
                    ForEach(0..<4, id: \.self) { i in
                        Circle()
                            .fill(.white)
                            .frame(width: 4, height: 4)
                            .offset(x: [-18, -6, 8, 20][i], y: [-22, -26, -24, -18][i])
                            .opacity(snowTwinkle ? 0.95 : 0.25)
                            .animation(
                                .easeInOut(duration: 1.2)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.4),
                                value: snowTwinkle
                            )
                    }
                }
                .offset(placedOffset("himal", x: -3, y: -139))
                .arrange("himal", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
                .scaleEffect(poppedID == "himal" ? 1.05 : 1.0)
                .onAppear { snowTwinkle = true }
                .onTapGesture {
                    sayDecoration(shopItem("himal"))
                    poke("himal")
                }
            }
        }
    }

    /// Chimney + smoke: the chimney sits on the roof slope (the roof draws
    /// over its base), and a puff of smoke rises and fades on a loop.
    private var chimneySmoke: some View {
        Group {
            Rectangle()
                .fill(Color(red: 0.55, green: 0.35, blue: 0.25))
                .frame(width: 24, height: 60)
                .offset(x: 75, y: -60)
            Circle()
                .fill(.gray.opacity(0.35))
                .frame(width: 16, height: 16)
                .offset(x: 75, y: smokeRise ? -130 : -95)
                .opacity(smokeRise ? 0 : 0.6)
                .onAppear {
                    withAnimation(.easeOut(duration: 2.2).repeatForever(autoreverses: false)) {
                        smokeRise = true
                    }
                }
        }
    }

    /// The yard and sky: bought decorations placed around the house.
    private var sceneDeco: some View {
        Group {
            if ownedIDs.contains("changa") {
                deco("changa", size: 40)
                    .offset(placedOffset("changa", x: 102, y: -128))
                    .arrange("changa", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("mandir") {
                deco("mandir", size: 46)
                    .offset(placedOffset("mandir", x: -106, y: -24))
                    .arrange("mandir", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("tulsi") {
                deco("tulsi", size: 46)
                    .offset(placedOffset("tulsi", x: 97, y: -30))
                    .arrange("tulsi", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("jamara") {
                deco("jamara", size: 38)
                    .offset(placedOffset("jamara", x: -76, y: 166))
                    .arrange("jamara", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("sayapatri") {
                deco("sayapatri", size: 42)
                    .offset(placedOffset("sayapatri", x: 94, y: 164))
                    .arrange("sayapatri", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("goldsoccerball") {
                deco("goldsoccerball", size: 40)
                    .offset(placedOffset("goldsoccerball", x: 34, y: 156))
                    .arrange("goldsoccerball", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("guitar") {
                deco("guitar", size: 46)
                    .offset(placedOffset("guitar", x: -46, y: 148))
                    .arrange("guitar", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("sneakers") {
                deco("sneakers", size: 38)
                    .offset(placedOffset("sneakers", x: 64, y: 136))
                    .arrange("sneakers", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("skateboard") {
                deco("skateboard", size: 48)
                    .offset(placedOffset("skateboard", x: 130, y: 170))
                    .arrange("skateboard", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("headphones") {
                deco("headphones", size: 36)
                    .offset(placedOffset("headphones", x: -110, y: 150))
                    .arrange("headphones", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("sunglasses") {
                deco("sunglasses", size: 34)
                    .offset(placedOffset("sunglasses", x: 104, y: 128))
                    .arrange("sunglasses", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("camera") {
                deco("camera", size: 36)
                    .offset(placedOffset("camera", x: -8, y: 168))
                    .arrange("camera", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("basketball") {
                deco("basketball", size: 38)
                    .offset(placedOffset("basketball", x: 78, y: 158))
                    .arrange("basketball", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("controller") {
                deco("controller", size: 38)
                    .offset(placedOffset("controller", x: -84, y: 118))
                    .arrange("controller", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            // Mystery Box treasures: winnable for ages, but they had
            // NO room blocks — owned, yet nowhere to live in the
            // house (Som's report, 2026-10-23). Now they render and
            // arrange like every other decoration.
            if ownedIDs.contains("guleyli") {
                deco("guleyli", size: 36)
                    .offset(placedOffset("guleyli", x: -128, y: 96))
                    .arrange("guleyli", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("nanglo") {
                deco("nanglo", size: 44)
                    .offset(placedOffset("nanglo", x: -60, y: 176))
                    .arrange("nanglo", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("charkha") {
                deco("charkha", size: 46)
                    .offset(placedOffset("charkha", x: 140, y: 96))
                    .arrange("charkha", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("khukuri") {
                deco("khukuri", size: 40)
                    .offset(placedOffset("khukuri", x: -140, y: -8))
                    .arrange("khukuri", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("sarangi") {
                deco("sarangi", size: 44)
                    .offset(placedOffset("sarangi", x: 146, y: 30))
                    .arrange("sarangi", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("karuwa") {
                deco("karuwa", size: 36)
                    .offset(placedOffset("karuwa", x: -96, y: 168))
                    .arrange("karuwa", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("rangoli") {
                rangoli
                    .offset(placedOffset("rangoli", x: -8, y: 16))
                    .arrange("rangoli", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
                    .scaleEffect(poppedID == "rangoli" ? 1.2 : 1.0)
                    .onTapGesture {
                        sayDecoration(shopItem("rangoli"))
                        poke("rangoli")
                    }
            }
        }
    }

    /// On the house body: garland on the door, bell hanging by the roof,
    /// and the Prove-it prizes (golden diyo, star badge, crown).
    private var bodyDeco: some View {
        Group {
            if ownedIDs.contains("mala") {
                deco("mala", size: 58)
                    .offset(placedOffset("mala", x: -104, y: -132))
                    .arrange("mala", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("ghanta") {
                VStack(spacing: 0) {
                    Rectangle().fill(.gray).frame(width: 4, height: 22)
                    deco("ghanta", size: 34)
                }
                .offset(placedOffset("ghanta", x: 104, y: -52))
                .arrange("ghanta", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("goldenDiyo") {
                goldenDiyo
                    .offset(placedOffset("goldenDiyo", x: -107, y: -92))
                    .arrange("goldenDiyo", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
                    .scaleEffect(poppedID == "goldenDiyo" ? 1.3 : 1.0)
                    .onTapGesture {
                        sayDecoration(shopItem("goldenDiyo"))
                        poke("goldenDiyo")
                    }
            }
            if ownedIDs.contains("starBadge") {
                deco("starBadge", size: 34)
                    .offset(placedOffset("starBadge", x: -64, y: -18))
                    .arrange("starBadge", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("mukut") {
                deco("mukut", size: 36)
                    .offset(placedOffset("mukut", x: -72, y: 42))
                    .arrange("mukut", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            // Quiz stickers: a row along the wall under the rangoli
            // as the kid earns them.
            if ownedIDs.contains("quiz50") {
                deco("quiz50", size: 24)
                    .offset(placedOffset("quiz50", x: -138, y: -128))
                    .arrange("quiz50", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("quiz100") {
                deco("quiz100", size: 24)
                    .offset(placedOffset("quiz100", x: -114, y: -128))
                    .arrange("quiz100", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("quiz250") {
                deco("quiz250", size: 24)
                    .offset(placedOffset("quiz250", x: -90, y: -128))
                    .arrange("quiz250", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
            if ownedIDs.contains("quiz500") {
                deco("quiz500", size: 24)
                    .offset(placedOffset("quiz500", x: -66, y: -128))
                    .arrange("quiz500", enabled: arranging, dragDeltas: $dragDeltas, commit: commitDrag)
            }
        }
    }

    /// A window: dark wood frame, four panes with a glass reflection
    /// streak, and a sill — or a grey silhouette when not yet bought.
    private var window: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(red: 0.35, green: 0.22, blue: 0.12))
                .frame(width: 52, height: 52)
            RoundedRectangle(cornerRadius: 3)
                .fill(ownedIDs.contains("windows")
                      ? Color(red: 0.5, green: 0.75, blue: 0.95)
                      : .gray.opacity(0.25))
                .frame(width: 44, height: 44)
            if ownedIDs.contains("windows") {
                Rectangle().fill(Color(red: 0.35, green: 0.22, blue: 0.12)).frame(width: 44, height: 5)
                Rectangle().fill(Color(red: 0.35, green: 0.22, blue: 0.12)).frame(width: 5, height: 44)
                Rectangle()
                    .fill(.white.opacity(0.35))
                    .frame(width: 8, height: 44)
                    .rotationEffect(.degrees(20))
                    .offset(x: -9)
            }
            RoundedRectangle(cornerRadius: 2)
                .fill(.white.opacity(0.9))
                .frame(width: 58, height: 8)
                .offset(y: 30)
        }
    }

    /// The diyo lamp: the watercolor illustration with a warm glow behind
    /// it. It "breathes" gently forever — alive, not a sticker. Grey
    /// placeholder until bought from the shop.
    private var diyo: some View {
        ZStack {
            if ownedIDs.contains("diyo") {
                Circle()
                    .fill(.orange.opacity(0.3))
                    .frame(width: 64 * stageK, height: 64 * stageK)
                    .blur(radius: 12)
                Group {
                    if let img = myGharSprite("diyo") {
                        img.resizable().scaledToFit()
                    } else {
                        Text("🪔").font(.system(size: 34))
                    }
                }
                .frame(width: 50 * stageK, height: 50 * stageK)
                .scaleEffect(flameFlicker ? 1.06 : 0.97)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                        flameFlicker = true
                    }
                }
            } else {
                Group {
                    if let img = myGharSprite("diyo") {
                        img.resizable().scaledToFit()
                    } else {
                        Text("🪔").font(.system(size: 34))
                    }
                }
                .frame(width: 50 * stageK, height: 50 * stageK)
                .grayscale(1)
                .opacity(0.35)
            }
        }
    }

    /// The golden diyo prize: the watercolor illustration with a golden
    /// glow, breathing gently like the clay diyo.
    private var goldenDiyo: some View {
        ZStack {
            Circle()
                .fill(.yellow.opacity(0.35))
                .frame(width: 56 * stageK, height: 56 * stageK)
                .blur(radius: 10)
            Group {
                if let img = myGharSprite("goldenDiyo") {
                    img.resizable().scaledToFit()
                } else {
                    Text("🪔").font(.system(size: 30))
                }
            }
            .frame(width: 46 * stageK, height: 46 * stageK)
            .scaleEffect(flameFlicker ? 1.06 : 0.97)
        }
    }

    /// A rangoli: concentric colored circles hung on the wall like a
    /// medallion — there's no good rangoli emoji, and circles are prettier.
    private var rangoli: some View {
        Group {
            if let img = myGharSprite("rangoli") {
                img.resizable().scaledToFit().frame(width: 46 * stageK, height: 46 * stageK)
            } else {
                ZStack {
                    Circle().fill(.red).frame(width: 46, height: 46)
                    Circle().fill(.orange).frame(width: 34, height: 34)
                    Circle().fill(.yellow).frame(width: 22, height: 22)
                    Circle().fill(.pink).frame(width: 10, height: 10)
                }
            }
        }
    }

    /// Suga by the door: a realistic watercolor parrot portrait from the
    /// backend, with the hand-drawn bird as fallback while it loads.
    /// He bobs gently forever — alive, not a sticker — and hops when
    /// tapped or fed. Grey circle until he's adopted from the shop.
    private var buddy: some View {
        let owned = ownedIDs.contains("buddy")
        return ZStack {
            if owned {
                // His own perch stand; Suga bobs on top of it.
                if let stand = myGharSprite("suga_stand") {
                    stand.resizable().scaledToFit()
                        .frame(width: 92 * stageK, height: 118 * stageK)
                }
                Group {
                    if let img = myGharSprite("suga") {
                        img.resizable().scaledToFit()
                    } else {
                        buddyDrawn
                    }
                }
                .frame(width: 62 * stageK, height: 75 * stageK)
                .offset(y: (-71 + (buddyBob ? -3 : 3)) * stageK)
                .scaleEffect(poppedID == "buddy" ? 1.18 : 1.0)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        buddyBob = true
                    }
                }
                // His name, painted on the front of the stand's base —
                // same lettering as the dog's wooden sign.
                Text(buddyDisplayName)
                    .font(.system(size: 13 * stageK, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.36, green: 0.22, blue: 0.08))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: 74 * stageK)
                    .offset(y: 42 * stageK)
            } else {
                Circle()
                    .fill(.gray.opacity(0.25))
                    .frame(width: 56, height: 56)
            }
        }
    }

    /// Hand-drawn fallback parrot — shows inside the portrait circle if
    /// the watercolor image hasn't loaded yet.
    private var buddyDrawn: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(.blue)
                .frame(width: 13, height: 36)
                .offset(x: -16, y: 2)
                .rotationEffect(.degrees(16))
            Ellipse()
                .fill(.green)
                .frame(width: 36, height: 46)
                .offset(y: -4)
            Ellipse()
                .fill(Color(red: 0.12, green: 0.42, blue: 0.18))
                .frame(width: 16, height: 30)
                .offset(x: -7, y: 0)
            Circle()
                .fill(.green)
                .frame(width: 30, height: 30)
                .offset(x: 4, y: -32)
            Circle().fill(.white).frame(width: 10, height: 10).offset(x: 9, y: -34)
            Circle().fill(.black).frame(width: 5, height: 5).offset(x: 10, y: -34)
            Triangle()
                .fill(.orange)
                .frame(width: 13, height: 11)
                .rotationEffect(.degrees(90))
                .offset(x: 21, y: -30)
        }
        .scaleEffect(1.1)
    }
}

/// Drag-to-move for arrange mode in My Ghar. When enabled, dragging a
/// decoration moves it and the drop point is saved; plain taps still fall
/// through to the view's own onTapGesture (speak + poke).
private struct ArrangeModifier: ViewModifier {
    let id: String
    let enabled: Bool
    @Binding var dragDeltas: [String: CGSize]
    let commit: (String, CGSize) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.gesture(
                DragGesture()
                    .onChanged { dragDeltas[id] = $0.translation }
                    .onEnded { commit(id, $0.translation) }
            )
        } else {
            content
        }
    }
}

extension View {
    /// Attach arrange-mode dragging to a My Ghar decoration.
    func arrange(_ id: String, enabled: Bool, dragDeltas: Binding<[String: CGSize]>, commit: @escaping (String, CGSize) -> Void) -> some View {
        modifier(ArrangeModifier(id: id, enabled: enabled, dragDeltas: dragDeltas, commit: commit))
    }
}

/// A cloud that drifts side to side forever, all by itself.
/// `repeatForever(autoreverses: true)` on a linear animation = endless
/// gentle motion with no timer and nothing to get stuck.
struct DriftingCloud: View {
    let startX: CGFloat
    let y: CGFloat
    /// MyGharView passes its recording-first speaker: the cloud says
    /// "बादल" in Som's voice once he's recorded it.
    let speak: () -> Void
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
            speak()
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

/// A decoration set: own every item, pocket the bonus — paid once, ever.
struct DecoSet: Identifiable {
    let id: String
    let nameEn: String
    let itemIds: [String]
    let bonus: Int
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
        } else if !romanized.isEmpty {
            utterance = AVSpeechUtterance(string: romanized)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        } else {
            // No Nepali voice on this device and nothing romanized —
            // speak the Devanagari with the default voice rather than
            // staying silent. Mispronounced beats mute.
            utterance = AVSpeechUtterance(string: nepali)
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
/// Lesson tour steps (Som's idea, 2026-10-20): point a new kid at the
/// three buttons that matter in a deck — hear it, write it, say it.
enum LessonTourStep: CaseIterable {
    case listen, write, speak
}

/// One tour stop: Som's line in Nepali, big, with his voice playing
/// (the clips ship in the pack audio as tour_<step>_np.m4a).
struct LessonTourBanner: View {
    let step: LessonTourStep
    let isLast: Bool
    let onNext: () -> Void
    let onSkip: () -> Void

    private var emoji: String {
        switch step {
        case .listen: return "🔊"
        case .write: return "✍️"
        case .speak: return "🎤"
        }
    }
    private var nepali: String {
        switch step {
        case .listen: return "यहाँ थिचेर सुन्नुस!"
        case .write: return "यहाँबाट लेख्न सिक्नुस!"
        case .speak: return "यहाँ थिचेर बोल्न सिक्नुस!"
        }
    }
    private var english: String {
        switch step {
        case .listen: return "Tap the speaker button to hear the word"
        case .write: return "Learn to write from here"
        case .speak: return "Tap the microphone to practice speaking"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(emoji).font(.system(size: 40))
            VStack(alignment: .leading, spacing: 2) {
                Text(nepali).font(.title3).bold()
                Text(english).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button(isLast ? "Done ✓" : "Next ➜", action: onNext)
                .buttonStyle(.borderedProminent)
            Button(action: onSkip) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }
}

struct DeckView: View {
    let deck: Deck
    @State private var player: AVPlayer?
    @AppStorage("ghar.premium.unlocked") private var isUnlocked = false
    @State private var showingPaywall = false
    @State private var showingWriting = false
    @State private var tourStep: LessonTourStep? = nil
    @State private var tourPlayer: AVPlayer?
    // Lesson tour: first time EVER only (Som's call, 2026-10-22 — it
    // used to re-run on every app launch, which got old fast).
    @AppStorage("ghar.lessonTour.done") private var lessonTourDone = false

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

    @AppStorage("ghar.traced.words") private var tracedData = Data()
    @AppStorage("ghar.giftbox.opened") private var giftBoxData = Data()
    @State private var showingGiftBox = false

    private var tracedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: tracedData)) ?? Set<String>()
    }
    private var giftBoxOpenedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: giftBoxData)) ?? Set<String>()
    }
    /// True when every traceable word in this deck is done.
    private var traceDeckComplete: Bool {
        let traceIDs = deck.words.filter { $0.tracePoints != nil }.map(\.id)
        return !traceIDs.isEmpty && traceIDs.allSatisfy({ tracedIDs.contains($0) })
    }

    /// The mystery box banner: teaser while working, tappable claim when
    /// the deck is done (covers kids who finished before this feature),
    /// quiet once claimed.
    @ViewBuilder
    private var mysteryBoxBanner: some View {
        let traceWords = deck.words.filter { $0.tracePoints != nil }
        let tracedCount = traceWords.filter { tracedIDs.contains($0.id) }.count
        if giftBoxOpenedIDs.contains(deck.id) {
            HStack(spacing: 12) {
                Text("🎁").font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mystery box claimed!").font(.headline)
                    Text("Nice work finishing every tracing")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        } else if traceDeckComplete {
            Button(action: { showingGiftBox = true }) {
                HStack(spacing: 12) {
                    Text("🎁").font(.largeTitle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mystery box ready!").font(.headline)
                        Text("You traced every word — tap to open your gift")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showingGiftBox) {
                GiftBoxView(deckID: deck.id)
            }
        } else {
            HStack(spacing: 12) {
                Text("🎁").font(.largeTitle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mystery box!").font(.headline)
                    Text("Trace every word below to earn a mystery gift box (\(tracedCount)/\(traceWords.count) done)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    var body: some View {
        List {
            // Lesson tour banner: first writing deck of the launch.
            if let step = tourStep {
                Section {
                    LessonTourBanner(step: step,
                                     isLast: step == tourSteps.last,
                                     onNext: advanceTour,
                                     onSkip: { tourStep = nil })
                }
            }
            // Mystery box teaser: only on decks with trace-the-picture words.
            if deck.words.contains(where: { $0.tracePoints != nil }) {
                Section {
                    mysteryBoxBanner
                }
            }
            if deck.id == "alphabet" {
                // Learn to WRITE the letters, not just read them.
                // Mystery box teaser: trace every letter to unlock the gift!
                Section(header: Text("👇 🎁 Trace every letter to unlock the mystery box! 🎁 👇").font(.subheadline).bold()) {
                    Button {
                        if isUnlocked { showingWriting = true }
                        else { showingPaywall = true }
                    } label: {
                        HStack(spacing: 14) {
                            Text("✍️").font(.largeTitle)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Practice writing").font(.headline)
                                    Text("🎁").font(.headline)
                                }
                                Text("Watch, trace, and write each letter")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isUnlocked {
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            } else {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 10).fill(tourStep == .write ? Color.orange.opacity(0.15) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tourStep == .write ? Color.orange : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .navigationDestination(isPresented: $showingWriting) {
                        WritingPracticeView(deck: deck)
                            .onAppear { DeckIntro.play(for: "writing") }
                    }
                    .sheet(isPresented: $showingPaywall) {
                        PaywallView()
                    }
                }
            }
            ForEach(grouped.indices, id: \.self) { i in
                if let header = grouped[i].header {
                    // Section header as a plain label — all words visible at once.
                    // (Kids tap letters directly; no extra tap to open a group.)
                    Section(header: Text(header).font(.headline)) {
                        ForEach(grouped[i].words) { word in
                            WordRow(word: word, onPlay: play(word:),
                                    deckID: deck.id, deckWords: deck.words, tourTarget: tourTargetFor(word))
                        }
                    }
                } else {
                    // Decks with no sections (Food, Family): plain list, as before.
                    // Festivals deck: tap a word to open its story page.
                    Section {
                        ForEach(grouped[i].words) { word in
                            if deck.id == "festivals", word.story != nil {
                                NavigationLink(destination: FestivalStoryView(word: word)) {
                                    WordRow(word: word, onPlay: play(word:),
                                            deckID: deck.id, deckWords: deck.words, tourTarget: tourTargetFor(word))
                                }
                            } else {
                                WordRow(word: word, onPlay: play(word:),
                                        deckID: deck.id, deckWords: deck.words, tourTarget: tourTargetFor(word))
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(deck.title)
        .onAppear { startTourIfNeeded() }
    }

    // MARK: Lesson tour

    /// The tour runs on the alphabet deck only (Som's call,
    /// 2026-10-20): it's where writing starts, letter by letter.
    private var deckHasTour: Bool {
        deck.id == "alphabet"
    }

    private var tourSteps: [LessonTourStep] {
        var steps: [LessonTourStep] = [.listen]
        if deckHasTour { steps.append(.write) }
        steps.append(.speak)
        return steps
    }

    private func startTourIfNeeded() {
        guard deckHasTour, !lessonTourDone else { return }
        lessonTourDone = true
        tourStep = .listen
        // The deck intro ("अक्षरहरू सिकौं!") fires on this same appear —
        // let it finish before the tour speaks, or the two voices talk
        // over each other. If the kid already moved on, stay silent.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if tourStep == .listen { playTourClip(.listen) }
        }
    }

    private func advanceTour() {
        guard let current = tourStep,
              let idx = tourSteps.firstIndex(of: current) else { tourStep = nil; return }
        if idx + 1 < tourSteps.count {
            tourStep = tourSteps[idx + 1]
            playTourClip(tourSteps[idx + 1])
        } else {
            tourStep = nil
        }
    }

    private func playTourClip(_ step: LessonTourStep) {
        let name: String
        switch step {
        case .listen: name = "tour_listen_np"
        case .write: name = "tour_write_np"
        case .speak: name = "tour_speak_np"
        }
        guard let url = URL(string: GharAPI.baseURLString + "/audio/nepal-v1/\(name).m4a") else { return }
        tourPlayer?.pause()
        tourPlayer = AVPlayer(url: url)
        tourPlayer?.play()
    }

    /// Which tour target (if any) a row should highlight right now:
    /// listen/speak ring the FIRST row's buttons; write rings the
    /// first traceable row's pencil. (The alphabet highlights its
    /// Practice writing row instead — see the deck body.)
    private func tourTargetFor(_ word: Word) -> LessonTourStep? {
        guard let step = tourStep else { return nil }
        switch step {
        case .listen, .speak:
            return word.id == deck.words.first?.id ? step : nil
        case .write:
            guard deck.id != "alphabet" else { return nil }
            return word.id == deck.words.first(where: { $0.tracePoints != nil })?.id ? .write : nil
        }
    }

    /// Builds the full audio URL and plays it:
    ///   server address + path from the JSON
    ///   http://localhost:8000 + /audio/nepal-v1/food_momo_np.m4a
    private func play(word: Word) {
        DeckProgress.markHeard(word.id)
        DeckProgress.evaluate(deck)
        guard let url = URL(string: GharAPI.baseURLString + word.audioUrl) else { return }
        player?.pause()
        player = AVPlayer(url: url)
        player?.play()
    }
}

/// One row in a deck: optional animal photo, the word, and its speaker button.
struct WordRow: View {
    let word: Word
    let onPlay: (Word) -> Void
    /// For the trace gift box: which deck this row is in, and its words.
    var deckID: String? = nil
    var deckWords: [Word] = []
    /// Lesson tour: which button (if any) to ring on this row.
    var tourTarget: LessonTourStep? = nil
    @State private var showingTrace = false
    @State private var showingSpeakCheck = false
    @AppStorage("ghar.traced.words") private var tracedData = Data()

    /// Green check if this word's tracing is done.
    private var isTraced: Bool {
        guard word.tracePoints != nil else { return false }
        let traced = (try? JSONDecoder().decode(Set<String>.self, from: tracedData)) ?? Set<String>()
        return traced.contains(word.id)
    }

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
            // Trace-the-picture: only on words that have outline data
            // (Animals, Fruits, Body Parts decks).
            if word.tracePoints != nil {
                Button(action: { showingTrace = true }) {
                    Image(systemName: "pencil.line")
                        .font(.title2)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .overlay(alignment: .topTrailing) {
                    // Green check once this word is traced.
                    if isTraced {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .background(.white)
                            .clipShape(Circle())
                            .offset(x: 8, y: -8)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange, lineWidth: 3).padding(-5).opacity(tourTarget == .write ? 1 : 0))
                .scaleEffect(tourTarget == .write ? 1.12 : 1.0)
                .sheet(isPresented: $showingTrace) {
                    TraceView(word: word, deckID: deckID, deckWords: deckWords)
                }
            }
            // Record-and-compare: hear the word, record yourself, play both back.
            Button(action: { showingSpeakCheck = true }) {
                Image(systemName: "mic.fill")
                    .font(.title2)
            }
            .buttonStyle(.bordered)
            .tint(.blue)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange, lineWidth: 3).padding(-5).opacity(tourTarget == .speak ? 1 : 0))
            .scaleEffect(tourTarget == .speak ? 1.12 : 1.0)
            .accessibilityLabel("Practice saying this word")
            .sheet(isPresented: $showingSpeakCheck) {
                SpeakCheckView(word: word)
            }
            Button(action: { onPlay(word) }) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.title2)
            }
            .buttonStyle(.bordered)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange, lineWidth: 3).padding(-5).opacity(tourTarget == .listen ? 1 : 0))
            .scaleEffect(tourTarget == .listen ? 1.12 : 1.0)
            // No recording yet → dimmed and disabled, instead of a
            // button that silently does nothing when tapped.
            .disabled(!(word.hasAudio ?? true))
            .opacity((word.hasAudio ?? true) ? 1 : 0.35)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Colors + counting (workbook pages in app form)

/// Festival story page: tap a festival in the Festivals deck to learn
/// what it is, when it happens, what people do, and a fun fact.
/// Content comes from the pack JSON (story/when/customs/fun_fact).
struct FestivalStoryView: View {
    let word: Word
    @State private var player: AVPlayer?

    private func play() {
        let urlString = GharAPI.baseURLString + word.audioUrl
        if let url = URL(string: urlString) {
            player?.pause()
            player = AVPlayer(url: url)
            player?.play()
        } else {
            NepaliSpeaker.say(nepali: word.devanagari, romanized: word.romanized)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Big festival picture.
                if let imagePath = word.image, imagePath.hasPrefix("/") {
                    AsyncImage(url: URL(string: GharAPI.baseURLString + imagePath)) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure, .empty:
                            Color.gray.opacity(0.1)
                        @unknown default:
                            Color.gray.opacity(0.1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                // Title + play button.
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(word.devanagari)
                            .font(.largeTitle)
                            .bold()
                        Text("\(word.romanized) — \(word.english)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: play) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.title)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!(word.hasAudio ?? true))
                    .opacity((word.hasAudio ?? true) ? 1 : 0.35)
                }

                // What is it?
                if let story = word.story {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What is it?")
                            .font(.headline)
                        Text(story)
                            .font(.body)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // When?
                if let when = word.when {
                    HStack(spacing: 12) {
                        Text("📅").font(.title)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("When?").font(.headline)
                            Text(when).font(.body)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // What do people do?
                if let customs = word.customs, !customs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("What do people do?").font(.headline)
                        ForEach(customs, id: \.self) { custom in
                            Text(custom).font(.body)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.green.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // Did you know?
                if let fact = word.funFact {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("💡 Did you know?").font(.headline)
                        Text(fact).font(.body).italic()
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.purple.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
        }
        .navigationTitle(word.english)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Hex strings from the pack ("#E53935") become real SwiftUI colors.
extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/// Colors: a grid of color swatches, like the workbook's रङहरूको ज्ञान page.
/// Tap a swatch to hear its Nepali name — Som's recording when it exists,
/// the phone's voice until then.
struct ColorsView: View {
    let deck: Deck
    @State private var player: AVPlayer?

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(deck.words) { word in
                    Button(action: { speak(word) }) {
                        VStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(Color(hex: word.colorHex ?? "#CCCCCC"))
                                .frame(height: 92)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                )
                            Text(word.devanagari)
                                .font(.title2).bold()
                            Text(word.english)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(deck.title)
    }

    private func speak(_ word: Word) {
        DeckProgress.markHeard(word.id)
        DeckProgress.evaluate(deck)
        if word.hasAudio == true,
           let url = URL(string: GharAPI.baseURLString + word.audioUrl) {
            player?.pause()
            player = AVPlayer(url: url)
            player?.play()
        } else {
            NepaliSpeaker.say(nepali: word.devanagari, romanized: word.romanized)
        }
    }
}

/// Numbers: the word list with a "Counting practice" card on top —
/// bunches of things to count, like the workbook's गन्ती गर्ने अभ्यास page.
struct NumbersView: View {
    let deck: Deck
    @State private var player: AVPlayer?
    @AppStorage("ghar.premium.unlocked") private var isUnlocked = false
    @State private var showingPaywall = false
    @State private var showingWriting = false

    var body: some View {
        List {
            Section {
                NavigationLink(destination: CountingView(deck: deck)) {
                    HStack(spacing: 12) {
                        Text("🔢").font(.largeTitle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Counting practice").font(.headline)
                            Text("Tap each one and count along!")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Section {
                Button {
                    if isUnlocked { showingWriting = true }
                    else { showingPaywall = true }
                } label: {
                    HStack(spacing: 12) {
                        Text("✍️").font(.largeTitle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Practice writing").font(.headline)
                            Text("Watch, trace, and write each number")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !isUnlocked {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .navigationDestination(isPresented: $showingWriting) {
                    WritingPracticeView(deck: deck)
                        .onAppear { DeckIntro.play(for: "writing") }
                }
                .sheet(isPresented: $showingPaywall) {
                    PaywallView()
                }
            }
            Section {
                ForEach(deck.words) { word in
                    WordRow(word: word, onPlay: play(word:),
                            deckID: deck.id, deckWords: deck.words)
                }
            }
        }
        .navigationTitle(deck.title)
    }

    private func play(word: Word) {
        DeckProgress.markHeard(word.id)
        DeckProgress.evaluate(deck)
        guard let url = URL(string: GharAPI.baseURLString + word.audioUrl) else { return }
        player?.pause()
        player = AVPlayer(url: url)
        player?.play()
    }
}

/// Counting practice: a bunch of things (🍎🍎🍎…) — the kid taps each one
/// and counts along. Every tap speaks the next number (एक, दुई…);
/// finishing the bunch earns a Nepali cheer.
struct CountingView: View {
    let deck: Deck   // numbers deck: words[0] = 1, words[1] = 2, …
    @State private var player: AVPlayer?
    @State private var target = Int.random(in: 2...10)
    @State private var counted: Set<Int> = []
    @State private var emoji = "🍎"
    @State private var showConfetti = false

    private let bunches = ["🍎", "🌼", "🐦", "⭐", "🐟", "🎈", "🦋", "🍊", "🐘", "🌙"]
    private let columns = [GridItem(.adaptive(minimum: 68), spacing: 10)]

    private var done: Bool { counted.count == target }

    var body: some View {
        VStack(spacing: 18) {
            Text("Tap each one and count!")
                .font(.title2).bold()
            Text("\(counted.count) / \(target)")
                .font(.headline)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(0..<target, id: \.self) { i in
                    Button(action: { tap(i) }) {
                        ZStack {
                            Text(emoji)
                                .font(.system(size: 46))
                                .opacity(counted.contains(i) ? 0.25 : 1)
                            if counted.contains(i) {
                                Text("✓")
                                    .font(.title).bold()
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(counted.contains(i))
                }
            }
            .padding()

            if done {
                Text("🎉").font(.system(size: 56))
                Button("New bunch") { reset() }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding()
        .navigationTitle("Counting")
        .overlay {
            if showConfetti {
                ConfettiBurst().allowsHitTesting(false)
            }
        }
    }

    private func tap(_ i: Int) {
        counted.insert(i)
        let n = counted.count
        if n <= deck.words.count { speakNumber(deck.words[n - 1]) }
        if n == target {
            // The last number gets its moment first — the cheer waits a beat
            // so the two don't talk over each other.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                WinFanfare.play()
            }
            showConfetti = false
            DispatchQueue.main.async { showConfetti = true }
        }
    }

    private func reset() {
        target = Int.random(in: 2...10)
        counted = []
        emoji = bunches.randomElement() ?? "🍎"
        showConfetti = false
    }

    private func speakNumber(_ word: Word) {
        if word.hasAudio == true,
           let url = URL(string: GharAPI.baseURLString + word.audioUrl) {
            player?.pause()
            player = AVPlayer(url: url)
            player?.play()
        } else {
            NepaliSpeaker.say(nepali: word.devanagari, romanized: word.romanized)
        }
    }
}

// Character portraits live in Assets.xcassets (see the Portraits enum).

// MARK: - Writing practice (alphabet deck)
//
// "Practice writing ✍️" inside the Alphabets deck. For each letter:
//   1. GUIDE — "Watch 👀" plays the letter drawing itself, pen tip and all;
//      a faint template sits underneath to trace.
//   2. VERIFY — the kid traces with a finger (Trace mode) or writes freehand
//      (Try-it mode). Strokes must cover the letter's shape to count.
//   3. CONGRATULATE — Som's recorded praise, a star burst, +5 XP the first
//      time per letter, and a star on the letter in the picker.
//
// Verification in one paragraph: the letter is rasterized once to a 36×36
// grid; every touch marks the cells under the fingertip (3×3 neighborhood).
// Covering ≥60% of the letter's cells passes. Deliberately generous — the
// goal is time spent shaping the letter, not penmanship judging.

/// English → Devanagari transliteration for names. Rule-based v1: handles
/// common Nepali name spellings; the parent confirms the result before
/// it becomes the practice word, so imperfections are caught by human eyes.
///
/// How it works: scan left-to-right, longest match first. Consonants carry
/// the inherent 'a' — a following 'a' is absorbed, other vowels become
/// matras, and a consonant before another consonant gets a halant.
fileprivate enum DevanagariTransliterator {
    /// (english, devanagari consonant) — longest first for greedy matching.
    private static let consonants: [(String, String)] = [
        ("ksh", "क्ष"), ("tra", "त्र"), ("gya", "ज्ञ"),
        ("kh", "ख"), ("gh", "घ"), ("chh", "छ"), ("jh", "झ"),
        ("th", "थ"), ("dh", "ध"), ("ph", "फ"), ("bh", "भ"),
        ("sh", "श"), ("k", "क"), ("g", "ग"), ("ng", "ङ"),
        ("ch", "च"), ("j", "ज"), ("ny", "ञ"),
        ("T", "ट"), ("Th", "ठ"), ("D", "ड"), ("Dh", "ढ"), ("N", "ण"),
        ("t", "त"), ("d", "द"), ("n", "न"),
        ("p", "प"), ("b", "ब"), ("m", "म"),
        ("y", "य"), ("r", "र"), ("l", "ल"), ("v", "व"), ("w", "व"),
        ("s", "स"), ("h", "ह"),
    ]

    /// Independent vowels (word-start or after a vowel).
    private static let vowels: [(String, String)] = [
        ("ai", "ऐ"), ("au", "औ"),
        ("aa", "आ"), ("ee", "ई"), ("ii", "ई"),
        ("oo", "ऊ"), ("uu", "ऊ"),
        ("a", "अ"), ("i", "इ"), ("u", "उ"),
        ("e", "ए"), ("o", "ओ"),
    ]

    /// Matras (dependent vowels, after a consonant). "a" is inherent — no sign.
    private static let matras: [(String, String)] = [
        ("ai", "ै"), ("au", "ौ"),
        ("aa", "ा"), ("ee", "ी"), ("ii", "ी"),
        ("oo", "ू"), ("uu", "ू"),
        ("i", "ि"), ("u", "ु"),
        ("e", "े"), ("o", "ो"),
    ]

    static func transliterate(_ english: String) -> String {
        let s = english.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "" }
        let lower = s.lowercased()
        var result = ""
        var i = lower.startIndex
        var prevWasConsonant = false

        while i < lower.endIndex {
            // Try consonants (longest first).
            var matched = false
            for (en, de) in consonants {
                if lower[i...].hasPrefix(en) {
                    // Check if next char starts another consonant (needs halant).
                    let after = lower.index(i, offsetBy: en.count, limitedBy: lower.endIndex) ?? lower.endIndex
                    var needsHalant = false
                    if after < lower.endIndex {
                        let nextStr = String(lower[after...])
                        // Next is a consonant (not a vowel) → halant.
                        let nextIsVowel = vowels.contains { nextStr.hasPrefix($0.0) }
                        let nextIsConsonant = consonants.contains { nextStr.hasPrefix($0.0) }
                        if nextIsConsonant && !nextIsVowel {
                            needsHalant = true
                        }
                    }
                    result += de
                    if needsHalant { result += "्" }
                    i = after
                    prevWasConsonant = !needsHalant
                    matched = true
                    break
                }
            }
            if matched { continue }

            // Try vowels/matras.
            let table = prevWasConsonant ? matras : vowels
            var vowelMatched = false
            for (en, de) in table {
                if lower[i...].hasPrefix(en) {
                    // "a" after consonant is inherent — skip it.
                    if !(prevWasConsonant && en == "a") {
                        result += de
                    }
                    i = lower.index(i, offsetBy: en.count, limitedBy: lower.endIndex) ?? lower.endIndex
                    prevWasConsonant = false
                    vowelMatched = true
                    break
                }
            }
            if vowelMatched { continue }

            // Unknown character — skip it.
            i = lower.index(after: i)
            prevWasConsonant = false
        }
        return result
    }
}

/// Shared constants for the writing canvas.
fileprivate enum WritingMetrics {
    /// Working size in points. Template image, outline path and coverage grid
    /// are all derived from the same layout, so they can never disagree.
    static let canvas: CGFloat = 300
    static let grid = 36
    static let passThreshold = 0.6
    // Path-based validation (2026-10-08): did the ink follow the lines?
    /// Trace mode: recall ≥ 0.4. Your good trace scores 0.48; a scribble
    /// scores 0.38. The gap is small, so precision does the heavy lifting.
    static let tracePathRecall = 0.4
    /// Trace mode: precision ≥ 0.58. Your good trace: 0.72. Scribble: 0.44.
    /// Clean separation.
    static let tracePathPrecision = 0.58
    /// Try-it: 55% of ink must be near the path (rejects scribbles).
    static let tryItPathPrecision = 0.55
    /// Try-it: must touch 30% of the path (sanity check — drew something
    /// substantial, not just a dot). Precision is the real gate.
    static let tryItPathRecall = 0.3
    static let xpReward = 5
}

/// Everything the canvas needs for one letter, baked once per letter.
///
/// Single source of truth: the outline path. The visible template, the
/// coverage grid, and the Watch animation are ALL derived from it, so they
/// can never disagree. (No rasterized images — CoreGraphics text drawing
/// proved unreliable in this context.)
fileprivate struct LetterGuide {
    let outline: CGPath     // the letter as a path, 300×300 UIKit coords
    let targets: Set<Int>   // grid cells the letter fills (row * 36 + col)
    let sampler: PathSampler
    let bbox: CGRect        // outline's TIGHT bounding box (boundingBoxOfPath,
                            // NOT boundingBox — that one includes curve control
                            // points and inflates the box for round letters
                            // like ग and ट, which broke Try-it grading for
                            // them: ink was mapped onto a box bigger than
                            // the letter and could never line up. 2026-10-23)
    let pathCells: Set<Int> // DENSE: cells near the outline path — for
                            // PRECISION ("is the ink near the letter?").
    let pathRecallSamples: Set<Int> // SPARSE: 25 samples — for RECALL
                                    // ("did they cover the whole letter?").
    let skeletonDots: [CGPoint]    // Single-line dots down the middle of
                                    // each stroke — Trace mode's targets
                                    // (animal-tracing style).

    static func make(for text: String) -> LetterGuide {
        let S = WritingMetrics.canvas
        let attr = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 220), .foregroundColor: UIColor.black
        ])
        let line = CTLineCreateWithAttributedString(attr)

        // One combined outline in font space (y-up, baseline origin).
        // The run's own font is the only safe source for paths: glyph IDs
        // are font-specific, and CoreText may have substituted a fallback.
        let combined = CGMutablePath()
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let rf = attrs.object(forKey: kCTFontAttributeName) as! CTFont
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRangeMake(0, n), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, n), &positions)
            for i in 0..<n {
                if let gp = CTFontCreatePathForGlyph(rf, glyphs[i], nil) {
                    let t = CGAffineTransform(translationX: positions[i].x,
                                             y: positions[i].y)
                    combined.addPath(gp, transform: t)
                }
            }
        }
        var box = combined.boundingBox
        if box.isNull || box.width < 1 || box.height < 1 {
            box = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        // Font space (y-up) → 300×300 UIKit (y-down), centered, small margin.
        // Manual math (not CGAffineTransform): x' = (x-minX)*s + tx,
        // y' = (maxY-y)*s + ty. Direct arithmetic cannot silently fail.
        let s = min(S / box.width, S / box.height) * 0.9
        let tx = (S - box.width * s) / 2, ty = (S - box.height * s) / 2
        let minX = box.minX, maxY = box.maxY
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - minX) * s + tx,
                    y: (maxY - p.y) * s + ty)
        }

        // Build the outline point-by-point with the manual map.
        // Subpaths are closed explicitly as we go, so contains() works.
        let outline = CGMutablePath()
        var open = false
        combined.applyWithBlock { el in
            let t = el.pointee.type
            if t == .moveToPoint {
                if open { outline.closeSubpath() }
                outline.move(to: map(el.pointee.points[0]))
                open = true
            } else if t == .addLineToPoint {
                outline.addLine(to: map(el.pointee.points[0]))
            } else if t == .addQuadCurveToPoint {
                outline.addQuadCurve(to: map(el.pointee.points[1]),
                                     control: map(el.pointee.points[0]))
            } else if t == .addCurveToPoint {
                outline.addCurve(to: map(el.pointee.points[2]),
                                 control1: map(el.pointee.points[0]),
                                 control2: map(el.pointee.points[1]))
            } else if t == .closeSubpath {
                outline.closeSubpath()
                open = false
            }
        }
        if open { outline.closeSubpath() }

        // Coverage grid: a cell is a target if its center falls inside the
        // outline. The outline is transformed, closed, and in 300-box
        // UIKit coords — point-in-path just works. Row 0 = top.
        let g = WritingMetrics.grid
        let cell = S / CGFloat(g)
        var targets = Set<Int>()
        for row in 0..<g {
            for col in 0..<g {
                let pt = CGPoint(x: (CGFloat(col) + 0.5) * cell,
                                y: (CGFloat(row) + 0.5) * cell)
                if outline.contains(pt, using: .evenOdd) {
                    targets.insert(row * g + col)
                }
            }
        }
        // Path cells (DENSE): every sampler point, ±1 cell. Used for
        // PRECISION — "is the ink near the letter?" A dense path means a
        // good trace has high overlap; a scribble has low overlap.
        let sampler = PathSampler(outline)
        var pathCells = Set<Int>()
        for pt in sampler.points {
            let cc = Int(pt.x / cell), cr = Int(pt.y / cell)
            for dr in -1...1 {
                for dc in -1...1 {
                    let r = cr + dr, c = cc + dc
                    if r >= 0, r < g, c >= 0, c < g {
                        pathCells.insert(r * g + c)
                    }
                }
            }
        }
        // Path recall samples (SPARSE): 25 evenly-spaced points, ±1 cell.
        // Used for RECALL — "did they cover the whole letter?" Sparse so
        // a complete trace scores high without needing pixel-perfection.
        var pathRecallSamples = Set<Int>()
        let numSamples = 25
        for i in 0..<numSamples {
            let d = CGFloat(i) / CGFloat(numSamples) * sampler.total
            let pt = sampler.point(at: d)
            let cc = Int(pt.x / cell), cr = Int(pt.y / cell)
            for dr in -1...1 {
                for dc in -1...1 {
                    let r = cr + dr, c = cc + dc
                    if r >= 0, r < g, c >= 0, c < g {
                        pathRecallSamples.insert(r * g + c)
                    }
                }
            }
        }
        return LetterGuide(outline: outline,
                           targets: targets, sampler: sampler,
                           bbox: outline.boundingBoxOfPath, pathCells: pathCells,
                           pathRecallSamples: pathRecallSamples,
                           skeletonDots: Self.skeletonDots(outline: outline))
    }

    /// The letter's single-line skeleton, as dots. Rasterize the
    /// glyph fill on a fine grid, thin it to the medial axis
    /// (Zhang–Suen), then pick evenly-spaced dots along what's
    /// left. The result follows how the letter is actually
    /// written — one line through the middle of every stroke —
    /// instead of a ring around the outline ("big lettering").
    private static func skeletonDots(outline: CGPath) -> [CGPoint] {
        let F = 90
        let cs = WritingMetrics.canvas / CGFloat(F)
        var grid = [Bool](repeating: false, count: F * F)
        for r in 0..<F {
            for c in 0..<F {
                let pt = CGPoint(x: (CGFloat(c) + 0.5) * cs,
                                 y: (CGFloat(r) + 0.5) * cs)
                if outline.contains(pt, using: .evenOdd) {
                    grid[r * F + c] = true
                }
            }
        }
        func n(_ r: Int, _ c: Int) -> Bool {
            (r >= 0 && r < F && c >= 0 && c < F) ? grid[r * F + c] : false
        }
        var changed = true
        while changed {
            changed = false
            for sub in 0..<2 {
                var kill: [Int] = []
                for r in 1..<(F - 1) {
                    for c in 1..<(F - 1) {
                        guard grid[r * F + c] else { continue }
                        let p2 = n(r - 1, c), p3 = n(r - 1, c + 1),
                            p4 = n(r, c + 1), p5 = n(r + 1, c + 1),
                            p6 = n(r + 1, c), p7 = n(r + 1, c - 1),
                            p8 = n(r, c - 1), p9 = n(r - 1, c - 1)
                        let ring = [p2, p3, p4, p5, p6, p7, p8, p9]
                        let b = ring.filter { $0 }.count
                        guard b >= 2 && b <= 6 else { continue }
                        var a = 0
                        for i in 0..<8 where !ring[i] && ring[(i + 1) % 8] { a += 1 }
                        guard a == 1 else { continue }
                        if sub == 0 {
                            if p2 && p4 && p6 { continue }
                            if p4 && p6 && p8 { continue }
                        } else {
                            if p2 && p4 && p8 { continue }
                            if p2 && p6 && p8 { continue }
                        }
                        kill.append(r * F + c)
                    }
                }
                if !kill.isEmpty { changed = true }
                for i in kill { grid[i] = false }
            }
        }
        var dots: [CGPoint] = []
        let minGap: CGFloat = 9
        for r in 0..<F {
            for c in 0..<F where grid[r * F + c] {
                let p = CGPoint(x: (CGFloat(c) + 0.5) * cs,
                                y: (CGFloat(r) + 0.5) * cs)
                if dots.allSatisfy({ hypot($0.x - p.x, $0.y - p.y) >= minGap }) {
                    dots.append(p)
                }
            }
        }
        return dots
    }
}

/// Flattens a CGPath into a point list. Curves are subdivided; the result is
/// in the path's own coordinates.
fileprivate final class PathWalker {
    private(set) var pts: [CGPoint] = []
    private var cur = CGPoint.zero
    private var subStart = CGPoint.zero

    private func add(_ p: CGPoint) {
        if pts.last != p { pts.append(p) }
    }
    private func quad(_ c: CGPoint, _ p: CGPoint) {
        let p0 = cur
        for i in 1...12 {
            let t = CGFloat(i) / 12, mt = 1 - t
            add(CGPoint(x: mt * mt * p0.x + 2 * mt * t * c.x + t * t * p.x,
                        y: mt * mt * p0.y + 2 * mt * t * c.y + t * t * p.y))
        }
        cur = p
    }
    private func cubic(_ c1: CGPoint, _ c2: CGPoint, _ p: CGPoint) {
        let p0 = cur
        for i in 1...16 {
            let t = CGFloat(i) / 16, mt = 1 - t
            add(CGPoint(x: mt*mt*mt*p0.x + 3*mt*mt*t*c1.x + 3*mt*t*t*c2.x + t*t*t*p.x,
                        y: mt*mt*mt*p0.y + 3*mt*mt*t*c1.y + 3*mt*t*t*c2.y + t*t*t*p.y))
        }
        cur = p
    }

    func run(_ path: CGPath) {
        path.apply(info: Unmanaged.passUnretained(self).toOpaque()) { info, elPtr in
            let w = Unmanaged<PathWalker>.fromOpaque(info!).takeUnretainedValue()
            let el = elPtr.pointee
            switch el.type {
            case .moveToPoint:
                w.cur = el.points[0]; w.subStart = el.points[0]; w.add(el.points[0])
            case .addLineToPoint:
                w.add(el.points[0]); w.cur = el.points[0]
            case .addQuadCurveToPoint:
                w.quad(el.points[0], el.points[1])
            case .addCurveToPoint:
                w.cubic(el.points[0], el.points[1], el.points[2])
            case .closeSubpath:
                w.add(w.subStart); w.cur = w.subStart
            @unknown default:
                break
            }
        }
    }
}

/// Point-at-distance along a flattened path — drives the pen tip in Watch mode.
fileprivate struct PathSampler {
    let points: [CGPoint]
    let lengths: [CGFloat]  // cumulative; lengths[i] = distance to points[i]
    let total: CGFloat

    init(_ path: CGPath) {
        let w = PathWalker()
        w.run(path)
        points = w.pts
        var ls: [CGFloat] = [0]
        for i in 1..<w.pts.count {
            let d = hypot(w.pts[i].x - w.pts[i - 1].x, w.pts[i].y - w.pts[i - 1].y)
            ls.append(ls.last! + d)
        }
        lengths = ls
        total = ls.last ?? 0
    }

    func point(at distance: CGFloat) -> CGPoint {
        guard total > 0, points.count > 1 else { return points.first ?? .zero }
        let d = min(max(distance, 0), total)
        var lo = 0, hi = lengths.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if lengths[mid] < d { lo = mid + 1 } else { hi = mid }
        }
        let i = max(lo, 1)
        let seg = lengths[i] - lengths[i - 1]
        guard seg > 0 else { return points[i] }
        let t = (d - lengths[i - 1]) / seg
        return CGPoint(x: points[i - 1].x + (points[i].x - points[i - 1].x) * t,
                       y: points[i - 1].y + (points[i].y - points[i - 1].y) * t)
    }
}

/// Watch 👀 — the letter draws itself as a pure SwiftUI view. `t` goes
/// 0→1; the blue stroke grows along the outline and a pen-tip dot rides
/// the end. Plain View inputs, so every `t` tick redraws. (The Canvas
/// version silently swallowed its redraws, which is why Watch did nothing.)
fileprivate struct WatchOverlayView: View {
    let t: Double
    let guide: LetterGuide
    let size: CGSize

    var body: some View {
        let s = min(size.width, size.height) / WritingMetrics.canvas
        let ox = (size.width - WritingMetrics.canvas * s) / 2
        let oy = (size.height - WritingMetrics.canvas * s) / 2
        let toCanvas = CGAffineTransform(scaleX: s, y: s)
            .translatedBy(x: ox, y: oy)
        let tp = Path(guide.outline).applying(toCanvas)
        let tip = guide.sampler.point(at: CGFloat(t) * guide.sampler.total)
        let c = CGPoint(x: tip.x * s + ox, y: tip.y * s + oy)
        ZStack {
            tp.trimmedPath(from: 0, to: CGFloat(t))
                .stroke(.blue,
                        style: StrokeStyle(lineWidth: 10 * s, lineCap: .round))
            Circle()
                .fill(.blue)
                .frame(width: 18 * s, height: 18 * s)
                .position(c)
        }
    }
}

/// One letter's practice screen: watch it, trace it, get cheered for it.
struct LetterPracticeView: View {
    let words: [Word]
    @State private var idx: Int
    @State private var guide: LetterGuide?
    @State private var strokes: [[CGPoint]] = []
    @State private var currentStroke: [CGPoint] = []
    @State private var dotHits = Set<Int>()
    @State private var showTraceHint = false
    @State private var tryItCoverage = 0.0
    @State private var watching = false
    @State private var watchStart = Date()
    @State private var tryIt = false
    @State private var canvasSize: CGSize = .zero
    @State private var celebrated = false
    @State private var justEarned = false
    @State private var player: AVPlayer?
    @AppStorage("ghar.xp.total") private var totalXP = 0
    @AppStorage("ghar.writing.done") private var doneIDs = ""
    @AppStorage("ghar.writing.traced") private var tracedIDs = ""

    init(words: [Word], index: Int) {
        self.words = words
        _idx = State(initialValue: index)
    }

    private var word: Word { words[idx] }
    /// Trace-mode checkpoints (animal-tracing style, 2026-10-23):
    /// the letter's single-line skeleton dots, baked into the guide.
    /// The kid drags through them, each dot lights up as the finger
    /// passes, and lighting ~70% completes the trace. No precision
    /// score and no stretch normalization in Trace mode — progress
    /// only goes up, so a good trace can't be failed by the grader.
    private var checkpoints: [CGPoint] {
        guide?.skeletonDots ?? []
    }

    private var dotFraction: Double {
        let total = checkpoints.count
        guard total > 0 else { return 0 }
        return Double(dotHits.count) / Double(total)
    }

    /// Progress bar: dots lit in Trace mode, skeleton coverage in
    /// Try-it (both grade the NEW single-line lettering).
    private var progress: Double {
        tryIt ? tryItCoverage : dotFraction
    }

    /// Watch animation duration: scales with the word length so a full
    /// name gets time to draw. ~3.5s per character, minimum 5s — slow
    /// enough for little eyes to follow each stroke.
    private var watchDuration: Double {
        max(5.0, 3.5 * Double(word.devanagari.count))
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            canvasCard
            ProgressView(value: progress)
                .tint(.orange)
                .padding(.horizontal)
            Text(tryIt ? "Write it yourself — no tracing! Earn XP ⭐" : "Trace with your finger — practice, no XP yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            // (Debug readout lives in a top-level overlay below, so the
            // celebration card can't cover it.)
            // Gentle nudge: lots of ink but not on the letter — tell the
            // kid what to fix instead of silently withholding the cheer.
            // Hint: in Try-it mode, if there's a decent amount of ink but
            // it's not near the path, nudge them to follow the lines.
            if tryIt, !celebrated, tryItCoverage >= 0.3, tryItCoverage < 0.6 {
                Text("Hmm — that's not quite the letter's shape yet ✍️")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            // Trace anti-scribble: dots all lit but the ink sprayed
            // everywhere — say so instead of silently withholding.
            if !tryIt, showTraceHint, !celebrated {
                Text("Too much ink off the line — tap ↺ and follow the dots ✏️")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            controls
            Spacer()
        }
        .padding()
        .navigationTitle(word.devanagari)
        .navigationBarTitleDisplayMode(.inline)
        .overlay { celebration }
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: celebrated)
        .onAppear { setupLetter() }
        .onChange(of: idx) { _, _ in setupLetter() }
        // Switching Trace ↔ Try-it is a fresh attempt: clear the ink.
        .onChange(of: tryIt) { _, _ in
            strokes = []
            currentStroke = []
            dotHits = []
            showTraceHint = false
            tryItCoverage = 0
            celebrated = false
            justEarned = false
        }
    }

    /// (Re)builds the guide and plays the letter's sound — on open and on
    /// every Next-tap. One explicit call each, no task lifecycle surprises.
    private func setupLetter() {
        guide = LetterGuide.make(for: word.devanagari)
        reset()
        hearLetter()
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 16) {
            Text(word.devanagari)
                .font(.system(size: 64))
                .frame(width: 90)
            VStack(alignment: .leading, spacing: 2) {
                Text(word.romanized).font(.title2).bold()
                Text(word.english).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { hearLetter() } label: {
                Image(systemName: "speaker.wave.2.fill").font(.title2)
            }
            .buttonStyle(.bordered)
        }
    }

    private var canvasCard: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Canvas { ctx, _ in drawCanvas(&ctx, size: size) }
                    .onAppear { canvasSize = size }
                    .onChange(of: size) { _, new in canvasSize = new }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { v in
                                guard !celebrated else { return }
                                if currentStroke.isEmpty { showTraceHint = false }
                                let prev = currentStroke.last
                                currentStroke.append(v.location)
                                if !tryIt {
                                    hitTestSegment(from: prev ?? v.location, to: v.location)
                                }
                            }
                            .onEnded { _ in
                                if !currentStroke.isEmpty {
                                    strokes.append(currentStroke)
                                    currentStroke = []
                                }
                                if tryIt { checkDone() } else { checkTraceDone() }
                            }
                    )
                // Watch 👀 via TimelineView: it ticks 60×/s on its own and
                // hands us the elapsed time — no Timer, no state-thrashing,
                // no missed redraws.
                if watching, let g = guide {
                    TimelineView(.animation(minimumInterval: 1/60)) { timeline in
                        let t = min(timeline.date.timeIntervalSince(watchStart) / watchDuration, 1.0)
                        WatchOverlayView(t: t, guide: g, size: size)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .background(RoundedRectangle(cornerRadius: 20)
            .fill(Color(.secondarySystemBackground)))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { watch() } label: {
                Label("Watch", systemImage: "eye.fill")
            }
            .buttonStyle(.bordered)
            .disabled(watching)
            Picker("Mode", selection: $tryIt) {
                Text("Trace").tag(false)
                Text("Try it").tag(true)
            }
            .pickerStyle(.segmented)
            Button { reset() } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var celebration: some View {
        if celebrated {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { _ in
                        Image(systemName: "sparkles")
                            .foregroundStyle(.yellow)
                            .font(.title)
                    }
                }
                Text("स्याबास!").font(.system(size: 52)).bold()
                Text(word.devanagari).font(.system(size: 84))
                Text("You wrote \(word.romanized)!").font(.headline)
                if justEarned {
                    Text("+\(WritingMetrics.xpReward) XP")
                        .font(.headline)
                        .foregroundStyle(.orange)
                } else if !tryIt {
                    Text("Nice tracing! Try Try-it mode to earn XP ⭐")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    Button("Again") { reset() }.buttonStyle(.bordered)
                    if idx + 1 < words.count {
                        Button("Next →") { idx += 1 }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(36)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(radius: 12)
            .padding(32)
            .transition(.scale.combined(with: .opacity))
        }
    }

    // MARK: - Drawing

    private func drawCanvas(_ ctx: inout GraphicsContext, size: CGSize) {
        guard let g = guide else { return }
        let s = min(size.width, size.height) / WritingMetrics.canvas
        let ox = (size.width - WritingMetrics.canvas * s) / 2
        let oy = (size.height - WritingMetrics.canvas * s) / 2

        // A whisper of the letter behind the dots (Som, 2026-10-23):
        // the heavy "big lettering" outline stays gone — the dots
        // are the guide — but a faint shape underneath makes the
        // letter read clearly while tracing. Try-it stays blank.
        if !tryIt {
            let toCanvas = CGAffineTransform(scaleX: s, y: s)
                .translatedBy(x: ox, y: oy)
            let templatePath = Path(g.outline).applying(toCanvas)
            ctx.stroke(templatePath, with: .color(.black.opacity(0.13)), lineWidth: 3)
        }

        // The kid's ink.
        for stroke in strokes { paint(stroke, in: &ctx, scale: s) }
        paint(currentStroke, in: &ctx, scale: s)

        // Trace-mode dots, drawn last so their state reads over the
        // ink: pale = not yet touched, green = lit.
        if !tryIt {
            let cps = checkpoints
            for (i, cp) in cps.enumerated() {
                let c = CGPoint(x: cp.x * s + ox, y: cp.y * s + oy)
                let r: CGFloat = 5.5 * s
                let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
                if dotHits.contains(i) {
                    ctx.fill(Path(ellipseIn: rect), with: .color(.green))
                } else {
                    ctx.fill(Path(ellipseIn: rect), with: .color(.gray.opacity(0.35)))
                    ctx.stroke(Path(ellipseIn: rect), with: .color(.gray.opacity(0.6)), lineWidth: 1)
                }
            }
        }
        // (Watch animation lives in WatchOverlayView, a real SwiftUI view
        // layered above — Canvas was silently swallowing its redraws.)
    }

    private func paint(_ stroke: [CGPoint], in ctx: inout GraphicsContext, scale s: CGFloat) {
        guard !stroke.isEmpty else { return }
        if stroke.count == 1 {
            let p = stroke[0]
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 7 * s, y: p.y - 7 * s,
                                            width: 14 * s, height: 14 * s)),
                     with: .color(.orange))
            return
        }
        var p = Path()
        p.addLines(stroke)
        ctx.stroke(p, with: .color(.orange),
                   style: StrokeStyle(lineWidth: 14 * s, lineCap: .round, lineJoin: .round))
    }
    // MARK: - Flow

    private func checkDone() {
        // Path-based validation (2026-10-08): did the ink follow the
        // template's lines? Replaces the pixel-blur heuristics that
        // couldn't tell scribbles from traces.
        //
        // Trace mode (hollow outline visible): recall (touch 80% of the
        // lines) + precision (50% of ink on the lines — rejects coloring
        // in instead of tracing).
        //
        // Try-it mode (from memory): precision (is ink near the lines?
        // rejects scribbles) + recall (did you draw enough?).
        //
        // Only Try-it earns XP; Trace is practice, cheer without payout.
        // Try-it only: Trace mode completes through its dots —
        // celebrateCompletion() fires from the dot hit-test at 75%.
        guard !celebrated, tryIt else { return }
        // No stroke cap: the lab-validated grader below punishes
        // extra ink through its length and distance scores, and a
        // careful drawing may take many strokes.
        let r = gradeTryIt()
        tryItCoverage = r.coverage
        guard r.passed else { return }
        celebrateCompletion()
    }

    /// Try-it grading — $1-recognizer style, LAB-VALIDATED
    /// (2026-10-23): verified offline against 200+ synthetic
    /// drawings (wobbled / proportion-morphed / rescaled correct
    /// letters vs lines, stripes, blobs, half-letters, wrong
    /// letters) before shipping; every earlier grader was tuned
    /// blind against live tests and swung between too strict and
    /// too lenient. Method: sample the ink evenly, normalize
    /// BOTH the ink and the letter's skeleton checkpoints by
    /// center + RMS spread, compare as point clouds — mean
    /// nearest-neighbor distance both ways plus the template's
    /// 90th-percentile distance (a smooth score, no cliff-edge
    /// radius). Guards: total ink length must be 0.8–2.7× the
    /// skeleton's normalized length (kills blobs and stripes —
    /// far too much ink — and half-letters — too little), and
    /// ≥18% of the ink must run vertically-ish (kills line
    /// cheats). Known limit, measured in the lab: a neatly drawn
    /// look-alike letter (थ for ग) can pass — no geometry-only
    /// grader separates those reliably, and it is the ONLY
    /// failure family left in the test battery.
    private func gradeTryIt() -> (coverage: Double, passed: Bool, debug: String) {
        let cps = checkpoints
        guard !cps.isEmpty, canvasSize.width > 0 else { return (0, false, "") }
        let s = min(canvasSize.width, canvasSize.height) / WritingMetrics.canvas
        guard s > 0 else { return (0, false, "") }
        let ox = (canvasSize.width - WritingMetrics.canvas * s) / 2
        let oy = (canvasSize.height - WritingMetrics.canvas * s) / 2

        // Ink: evenly stepped samples + true segment lengths,
        // per stroke (no pen jumps counted).
        var samples: [CGPoint] = []
        var inkLen: CGFloat = 0
        var vertLen: CGFloat = 0
        for stroke in strokes {
            var prev: CGPoint? = nil
            for p in stroke {
                let bp = CGPoint(x: (p.x - ox) / s, y: (p.y - oy) / s)
                if let pv = prev {
                    let dx = bp.x - pv.x, dy = bp.y - pv.y
                    let d = hypot(dx, dy)
                    inkLen += d
                    if abs(dy) > abs(dx) { vertLen += d }
                    let steps = max(1, Int(d / 5))
                    for i in 1...steps {
                        let t = CGFloat(i) / CGFloat(steps)
                        samples.append(CGPoint(x: pv.x + dx * t,
                                               y: pv.y + dy * t))
                    }
                }
                prev = bp
            }
        }
        guard samples.count > 4, inkLen > 0 else { return (0, false, "") }

        func centroid(_ ps: [CGPoint]) -> CGPoint {
            CGPoint(x: ps.map(\.x).reduce(0, +) / CGFloat(ps.count),
                    y: ps.map(\.y).reduce(0, +) / CGFloat(ps.count))
        }
        func spread(_ ps: [CGPoint], _ c: CGPoint) -> CGFloat {
            sqrt(ps.map { hypot($0.x - c.x, $0.y - c.y) }
                   .map { $0 * $0 }.reduce(0, +) / CGFloat(ps.count))
        }
        let ic = centroid(samples), kc = centroid(cps)
        let ispr = spread(samples, ic), kspr = spread(cps, kc)
        guard ispr > 2, kspr > 2 else { return (0, false, "") }
        let A = samples.map { CGPoint(x: ($0.x - ic.x) / ispr,
                                      y: ($0.y - ic.y) / ispr) }
        let B = cps.map { CGPoint(x: ($0.x - kc.x) / kspr,
                                  y: ($0.y - kc.y) / kspr) }

        var dT: [CGFloat] = []
        for b in B {
            var best = CGFloat.greatestFiniteMagnitude
            for a in A { best = min(best, hypot(a.x - b.x, a.y - b.y)) }
            dT.append(best)
        }
        var dI: [CGFloat] = []
        for a in A {
            var best = CGFloat.greatestFiniteMagnitude
            for b in B { best = min(best, hypot(a.x - b.x, a.y - b.y)) }
            dI.append(best)
        }
        let mean = (dT.reduce(0, +) / CGFloat(dT.count)
                    + dI.reduce(0, +) / CGFloat(dI.count)) / 2
        let sortedDT = dT.sorted()
        let p90 = sortedDT[min(sortedDT.count - 1,
                               Int(0.9 * Double(sortedDT.count)))]
        let coverage = Double(dT.filter { $0 <= 0.30 }.count) / Double(dT.count)

        // Skeleton length: greedy nearest-neighbor chain over the
        // arc-spaced checkpoints tracks the line's true length.
        var skelLen: CGFloat = 0
        if cps.count > 1 {
            var unvisited = Set(cps.indices)
            var cur = cps.startIndex
            unvisited.remove(cur)
            while !unvisited.isEmpty {
                var bestD = CGFloat.greatestFiniteMagnitude
                var bestI = cur
                for i in unvisited {
                    let d = hypot(cps[i].x - cps[cur].x, cps[i].y - cps[cur].y)
                    if d < bestD { bestD = d; bestI = i }
                }
                skelLen += bestD
                cur = bestI
                unvisited.remove(cur)
            }
        }
        guard skelLen > 0 else { return (coverage, false, "") }
        let nratio = (inkLen / ispr) / (skelLen / kspr)
        let vert = vertLen / inkLen
        // Gates recalibrated 2026-10-23 on the first REAL data
        // point (Som's careful ग: mean .20, tail .44, len 0.6,
        // vert .68 — synthetic ink had been ~40% too faithful:
        // real hands shorten headlines, displace whole parts, and
        // chord the curves, so real scores run worse than every
        // lab positive). Margins sit ~20% beyond his numbers;
        // the garbage families still fail by ~2x (line mean
        // .43+, stripes vert ~0, blob len 4.4+).
        let passed = mean <= 0.24 && p90 <= 0.50
            && nratio >= 0.50 && nratio <= 2.7 && vert >= 0.18
        return (coverage, passed, "")
    }


    /// The shared finish line: Try-it arrives by passing its grader,
    /// Trace arrives by lighting ~70% of its dots. Marks the word
    /// heard, pays Try-it XP, files the trace for the gift box, and
    /// plays the cheer.
    private func celebrateCompletion() {
        celebrated = true
        DeckProgress.markHeard(word.id)
        if tryIt {
            var done = Set(doneIDs.split(separator: ",").map(String.init))
            if done.insert(word.id).inserted {
                doneIDs = done.sorted().joined(separator: ",")
                totalXP += WritingMetrics.xpReward
                justEarned = true
            }
            // Writing it freehand proves the tracing skill too —
            // file it as traced so the mystery-box count and the
            // section boxes credit it (Som's report, 2026-10-23:
            // "completed both but it didn't count").
            var tracedToo = Set(tracedIDs.split(separator: ",").map(String.init))
            if tracedToo.insert(word.id).inserted {
                tracedIDs = tracedToo.sorted().joined(separator: ",")
            }
        } else {
            // Trace mode: mark as traced (for the mystery gift box).
            // No XP — trace is practice, per the existing design.
            var traced = Set(tracedIDs.split(separator: ",").map(String.init))
            if traced.insert(word.id).inserted {
                tracedIDs = traced.sorted().joined(separator: ",")
            }
        }
        // His voice does the congratulating — स्याबास! / राम्रो! / बधाई छ!
        WinFanfare.play()
    }

    /// Mark every checkpoint the finger just passed near. Ink points
    /// arrive in canvas coords; checkpoints live in the 300-box, so
    /// convert with the same transform the coverage code uses. The
    /// segment is stepped every ~5 units so a fast flick can't jump
    /// clean over a dot.
    private func hitTestSegment(from a: CGPoint, to b: CGPoint) {
        guard guide != nil, canvasSize.width > 0, !celebrated else { return }
        let s = min(canvasSize.width, canvasSize.height) / WritingMetrics.canvas
        guard s > 0 else { return }
        let ox = (canvasSize.width - WritingMetrics.canvas * s) / 2
        let oy = (canvasSize.height - WritingMetrics.canvas * s) / 2
        let pa = CGPoint(x: (a.x - ox) / s, y: (a.y - oy) / s)
        let pb = CGPoint(x: (b.x - ox) / s, y: (b.y - oy) / s)
        let dist = hypot(pb.x - pa.x, pb.y - pa.y)
        let steps = max(1, Int(dist / 5))
        let radius: CGFloat = 17
        let cps = checkpoints
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let p = CGPoint(x: pa.x + (pb.x - pa.x) * t,
                            y: pa.y + (pb.y - pa.y) * t)
            for (i, cp) in cps.enumerated() where !dotHits.contains(i) {
                if hypot(cp.x - p.x, cp.y - p.y) <= radius {
                    dotHits.insert(i)
                }
            }
        }
    }

    /// Trace mode's finish line, judged when the finger lifts:
    /// 75% of the dots lit AND at least ~55% of the ink actually
    /// on the line. The second test is the anti-scribble — spraying
    /// ink over the whole letter lights the dots but puts most ink
    /// off the line, so it earns the hint instead of the cheer.
    private func checkTraceDone() {
        guard !celebrated, !tryIt else { return }
        guard dotFraction >= 0.75 else { return }
        if onLineFraction >= 0.55 {
            celebrateCompletion()
        } else {
            showTraceHint = true
        }
    }

    /// What fraction of the ink (sampled along every stroke) lies
    /// within ~14 units of a checkpoint — i.e., on the letter's
    /// single line. Honest tracing lives near the line even when
    /// it's wobbly; scribbles don't.
    private var onLineFraction: Double {
        let cps = checkpoints
        guard !cps.isEmpty, canvasSize.width > 0 else { return 0 }
        let s = min(canvasSize.width, canvasSize.height) / WritingMetrics.canvas
        guard s > 0 else { return 0 }
        let ox = (canvasSize.width - WritingMetrics.canvas * s) / 2
        let oy = (canvasSize.height - WritingMetrics.canvas * s) / 2
        var total = 0, onLine = 0
        for stroke in strokes {
            var prev: CGPoint? = nil
            for p in stroke {
                let bp = CGPoint(x: (p.x - ox) / s, y: (p.y - oy) / s)
                if let pv = prev {
                    let d = hypot(bp.x - pv.x, bp.y - pv.y)
                    let steps = max(1, Int(d / 5))
                    for i in 1...steps {
                        let t = CGFloat(i) / CGFloat(steps)
                        let q = CGPoint(x: pv.x + (bp.x - pv.x) * t,
                                        y: pv.y + (bp.y - pv.y) * t)
                        total += 1
                        if cps.contains(where: { hypot($0.x - q.x, $0.y - q.y) <= 14 }) {
                            onLine += 1
                        }
                    }
                }
                prev = bp
            }
        }
        guard total > 0 else { return 0 }
        return Double(onLine) / Double(total)
    }

    private func reset() {
        strokes = []
        currentStroke = []
        dotHits = []
        showTraceHint = false
        tryItCoverage = 0
        celebrated = false
        justEarned = false
        watching = false
    }

    private func watch() {
        guard !watching, guide != nil else { return }
        strokes = []
        currentStroke = []
        dotHits = []
        showTraceHint = false
        tryItCoverage = 0
        // TimelineView drives the animation from watchStart; we just flip
        // `watching` on and off. Nothing to invalidate, nothing to leak.
        watchStart = Date()
        watching = true
        DispatchQueue.main.asyncAfter(deadline: .now() + watchDuration + 0.6) {
            watching = false
        }
    }

    /// The letter's sound: his recording first, the phone's voice as backup.
    private func hearLetter() {
        if word.hasAudio == true,
           let url = URL(string: GharAPI.baseURLString + word.audioUrl) {
            player?.pause()
            player = AVPlayer(url: url)
            player?.play()
        } else {
            NepaliSpeaker.say(nepali: word.devanagari, romanized: word.romanized)
        }
    }
}

/// "Practice writing ✍️" — the letter picker. Vowels and consonants get
/// their own sections; practiced letters earn a star.
///
/// The practice screen is a full-screen cover (one instance at a time —
/// a NavigationLink stack was spawning a practice view per letter, so
/// tapping one letter played every letter's audio). The cover carries its
/// own chevron back button, so it feels like a push and always lands back
/// on the picker.
struct WritingPracticeView: View {
    let deck: Deck
    @AppStorage("ghar.writing.done") private var doneIDs = ""
    @AppStorage("ghar.writing.traced") private var tracedIDs = ""
    @AppStorage("ghar.giftbox.opened") private var giftBoxData = Data()
    @AppStorage("ghar.myname.devanagari") private var myName = ""
    @AppStorage("ghar.myname.english") private var myNameEnglish = ""
    @State private var selection: LetterSelection?
    @State private var showingNameSetup = false
    @State private var namePractice: LetterSelection?
    @State private var giftBoxDeckID: String?
    @State private var showingGiftBox = false

    private var done: Set<String> {
        Set(doneIDs.split(separator: ",").map(String.init))
    }
    private var traced: Set<String> {
        Set(tracedIDs.split(separator: ",").map(String.init))
    }
    private var giftBoxOpenedIDs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: giftBoxData)) ?? Set<String>()
    }
    /// True when every letter in the section is traced and its box is unclaimed.
    private func sectionBoxReady(_ letters: [Word], deckID: String) -> Bool {
        !letters.isEmpty
            && letters.allSatisfy({ traced.contains($0.id) || done.contains($0.id) })
            && !giftBoxOpenedIDs.contains(deckID)
    }

    /// Section header with a 🎁 button when the section is done but its
    /// mystery box hasn't been claimed yet.
    private func writingSectionHeader(title: String, letters: [Word], deckID: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            let got = letters.filter({ traced.contains($0.id) }).count
            Text("\(got)/\(letters.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if sectionBoxReady(letters, deckID: deckID) {
                Button(action: {
                    giftBoxDeckID = deckID
                    showingGiftBox = true
                }) {
                    Text("🎁")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
    }
    private var vowels: [Word] {
        deck.words.filter { $0.section?.hasPrefix("Vowels") == true }
    }
    private var consonants: [Word] {
        deck.words.filter { $0.section?.hasPrefix("Consonants") == true }
    }
    private var digits: [Word] {
        // Devanagari digits ०-९: single-character words in the numbers deck.
        deck.words.filter { $0.devanagari.count == 1 && $0.devanagari.first?.isNumber == true }
    }
    private var teenNumbers: [Word] {
        // Multi-digit numbers (१० and up): practice writing the full numeral.
        deck.words.filter { $0.devanagari.count > 1 && $0.devanagari.allSatisfy({ $0.isNumber }) }
    }

    /// A synthetic Word for the kid's name, so the existing practice view
    /// (Watch/Trace/Try-it + grading) works on it unchanged. The English
    /// spelling rides in `romanized` so the TTS fallback has something to
    /// say when there's no Nepali voice on the device.
    private var nameWord: Word {
        Word(id: "myname", devanagari: myName, romanized: myNameEnglish,
             english: "My name", audioUrl: "", hasAudio: false,
             section: nil, image: nil, exampleSentenceNp: nil,
             exampleSentenceEn: nil, breakdown: nil, speaker: nil,
             colorHex: nil, quizHint: nil)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Text("🎁").font(.largeTitle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mystery box!").font(.headline)
                        let allLetters = vowels + consonants + digits
                        let doneCount = allLetters.filter({ traced.contains($0.id) || done.contains($0.id) }).count
                        Text("Finish a section below to earn a mystery gift box (\(doneCount)/\(allLetters.count) letters done)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("\u{2605} = wrote it on their own (earns XP) \u{B7} \u{2713} = traced it")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section("My Name") {
                Button {
                    if myName.isEmpty {
                        showingNameSetup = true
                    } else {
                        namePractice = LetterSelection(words: [nameWord], index: 0)
                    }
                } label: {
                    HStack {
                        Text("✏️")
                            .font(.largeTitle)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(myName.isEmpty ? "Write my name" : myName)
                                .font(.title2).bold()
                                .foregroundStyle(.primary)
                            Text(myName.isEmpty
                                 ? "Set it up, then practice writing it"
                                 : "Tap to practice")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !myName.isEmpty {
                            Button("Edit") { showingNameSetup = true }
                                .font(.caption)
                        }
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            if !vowels.isEmpty {
                Section(header: writingSectionHeader(title: "Vowels (स्वर)", letters: vowels, deckID: "writing-vowels")) { letterGrid(vowels) }
            }
            if !consonants.isEmpty {
                Section(header: writingSectionHeader(title: "Consonants (व्यञ्जन)", letters: consonants, deckID: "writing-consonants")) { letterGrid(consonants) }
            }
            if !digits.isEmpty {
                Section(header: writingSectionHeader(title: "Digits (अङ्क)", letters: digits, deckID: "writing-digits")) { letterGrid(digits) }
            }
            if !teenNumbers.isEmpty {
                Section("Bigger numbers") { letterGrid(teenNumbers) }
            }
        }
        .navigationTitle("Practice writing ✍️")
        .sheet(isPresented: $showingNameSetup) {
            NameSetupView(savedName: $myName, savedEnglish: $myNameEnglish)
        }
        .sheet(isPresented: $showingGiftBox) {
            GiftBoxView(deckID: giftBoxDeckID)
        }
        .fullScreenCover(item: $selection) { sel in
            NavigationStack {
                LetterPracticeView(words: sel.words, index: sel.index)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                selection = nil
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                        .font(.headline)
                                    Text("Letters")
                                }
                            }
                        }
                    }
            }
        }
        .fullScreenCover(item: $namePractice) { sel in
            NavigationStack {
                LetterPracticeView(words: sel.words, index: sel.index)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                namePractice = nil
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                        .font(.headline)
                                    Text("Writing")
                                }
                            }
                        }
                    }
            }
        }
    }

    private func letterGrid(_ letters: [Word]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76))], spacing: 12) {
            ForEach(letters.indices, id: \.self) { i in
                let w = letters[i]
                Button {
                    selection = LetterSelection(words: letters, index: i)
                } label: {
                    VStack(spacing: 2) {
                        ZStack(alignment: .topTrailing) {
                            Text(w.devanagari)
                                .font(.system(size: 40))
                                .frame(maxWidth: .infinity)
                            if done.contains(w.id) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption)
                            } else if traced.contains(w.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                        }
                        Text(w.romanized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Which letter the full-screen practice cover shows.
fileprivate struct LetterSelection: Identifiable {
    let id = UUID()
    let words: [Word]
    let index: Int
}

/// Set up the kid's name for writing practice. Parent types the name in
/// English, the app transliterates to Devanagari, parent confirms or
/// corrects it, then it becomes a practice word (Watch/Trace/Try-it).
/// TTS speaks the name after typing (and on tap of the speaker button)
/// so the parent hears what the kid will hear.
struct NameSetupView: View {
    @Binding var savedName: String
    @Binding var savedEnglish: String
    @Environment(\.dismiss) private var dismiss
    @State private var englishName = ""
    @State private var devanagariName = ""
    @State private var didEditDevanagari = false
    @State private var speakWorkItem: DispatchWorkItem?

    /// Auto-transliteration, unless the parent has hand-corrected it.
    private var preview: String {
        didEditDevanagari ? devanagariName
            : DevanagariTransliterator.transliterate(englishName)
    }

    /// Speak the current Nepali name via TTS.
    private func speakName() {
        let text = preview
        guard !text.isEmpty else { return }
        NepaliSpeaker.say(nepali: text, romanized: englishName)
    }

    /// Debounced auto-speak: waits 1s after the last keystroke so it
    /// doesn't talk over the parent while they're still typing.
    private func scheduleSpeak() {
        speakWorkItem?.cancel()
        let work = DispatchWorkItem { speakName() }
        speakWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name in English") {
                    TextField("e.g. Aarav", text: $englishName)
                        .textInputAutocapitalization(.words)
                        .onChange(of: englishName) {
                            didEditDevanagari = false
                            scheduleSpeak()
                        }
                        .onSubmit { speakName() }
                }
                Section("Name in Nepali") {
                    HStack {
                        TextField("नेपालीमा नाम", text: $devanagariName)
                            .font(.title)
                            .onChange(of: devanagariName) { didEditDevanagari = true }
                        Button(action: speakName) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.title3)
                        }
                        .disabled(preview.isEmpty)
                    }
                    if !englishName.isEmpty, !didEditDevanagari {
                        Text(preview)
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                    Text("Check the spelling — tap the Nepali name to fix it if needed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Save my name") {
                        let final = didEditDevanagari ? devanagariName : preview
                        if !final.isEmpty {
                            savedName = final
                            savedEnglish = englishName
                            dismiss()
                        }
                    }
                    .disabled((didEditDevanagari ? devanagariName : preview).isEmpty)
                    if !savedName.isEmpty {
                        Button("Remove saved name", role: .destructive) {
                            savedName = ""
                            savedEnglish = ""
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("My Name")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                // If editing an existing name, preload it.
                if !savedName.isEmpty {
                    devanagariName = savedName
                    englishName = savedEnglish
                    didEditDevanagari = true
                }
            }
            .onDisappear { speakWorkItem?.cancel() }
        }
    }
}

#Preview {
    ContentView()
}
