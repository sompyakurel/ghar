import SwiftUI

// MARK: - Quiz stats (streak + totals, tracked on-device)
//
// The four leaderboard boards need stats the app didn't track before:
// how many quiz answers were right in a row (best streak) and total
// correct answers. XP and missions were already in UserDefaults.
// These helpers are called from each quiz's answer() — one line each.

enum QuizStats {
    private static let correctKey = "ghar.quiz.correctTotal"
    private static let bestKey = "ghar.quiz.streakBest"
    private static let currentKey = "ghar.quiz.currentStreak"
    private static let defaults = UserDefaults.standard

    static var correctTotal: Int { defaults.integer(forKey: correctKey) }
    static var streakBest: Int { defaults.integer(forKey: bestKey) }

    /// Call on every correct quiz answer.
    static func recordCorrect() {
        defaults.set(correctTotal + 1, forKey: correctKey)
        let run = defaults.integer(forKey: currentKey) + 1
        defaults.set(run, forKey: currentKey)
        if run > streakBest { defaults.set(run, forKey: bestKey) }
        LeaderboardSync.shared.syncSoon()
        // Quiz milestone stickers grant the moment a threshold is
        // crossed (50/100/250/500 lifetime correct) — with a fanfare.
        if QuizStickers.check() { WinFanfare.play() }
    }

    /// Call on every wrong quiz tap — the streak resets.
    static func recordWrong() {
        defaults.set(0, forKey: currentKey)
    }
}

// MARK: - Leaderboard networking

/// One player row from GET /leaderboard/{code}.
struct LeaderboardPlayer: Codable, Identifiable {
    var id: String { nickname }
    let nickname: String
    let xp: Int
    let quizStreakBest: Int
    let quizCorrectTotal: Int
    let missionsDone: Int

    private enum CodingKeys: String, CodingKey {
        case nickname, xp
        case quizStreakBest = "quiz_streak_best"
        case quizCorrectTotal = "quiz_correct_total"
        case missionsDone = "missions_done"
    }
}

private struct GroupResponse: Decodable { let code: String; let name: String? }
private struct RankingsResponse: Decodable {
    let code: String
    let name: String?
    let players: [LeaderboardPlayer]
}

enum LeaderboardAPI {
    static let base = "https://backend-patient-wave-3724.fly.dev"

    static func createGroup(name: String) async throws -> (code: String, name: String?) {
        var req = URLRequest(url: URL(string: base + "/leaderboard/group")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try JSONDecoder().decode(GroupResponse.self, from: data)
        return (resp.code, resp.name)
    }

    static func joinCheck(code: String) async throws -> Bool {
        let url = URL(string: base + "/leaderboard/\(code.uppercased())")!
        let (_, resp) = try await URLSession.shared.data(from: url)
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    static func fetchRankings(code: String) async throws -> (players: [LeaderboardPlayer], name: String?) {
        let url = URL(string: base + "/leaderboard/\(code.uppercased())")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(RankingsResponse.self, from: data)
        return (decoded.players, decoded.name)
    }

    static func submitScore(groupCode: String, nickname: String) async {
        let d = UserDefaults.standard
        let completed: Set<String> =
            (try? JSONDecoder().decode(Set<String>.self,
                from: d.data(forKey: "ghar.missions.completed") ?? Data())) ?? []
        let body: [String: Any] = [
            "group_code": groupCode,
            "nickname": nickname,
            "xp": d.integer(forKey: "ghar.xp.total"),
            "quiz_streak_best": QuizStats.streakBest,
            "quiz_correct_total": QuizStats.correctTotal,
            "missions_done": completed.count,
        ]
        var req = URLRequest(url: URL(string: base + "/leaderboard/score")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // Fire and forget — a missed sync just retries next time.
        _ = try? await URLSession.shared.data(for: req)
    }

    static func deleteScore(groupCode: String, nickname: String) async throws {
        var components = URLComponents(string: base + "/leaderboard/\(groupCode.uppercased())/score")!
        components.queryItems = [URLQueryItem(name: "nickname", value: nickname)]
        var req = URLRequest(url: components.url!)
        req.httpMethod = "DELETE"
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
}

// MARK: - Sync coordinator

/// Debounced background sync. Quiz answers call syncSoon(); the actual
/// POST happens at most once every 10s so rapid-fire quizzes don't spam.
final class LeaderboardSync: ObservableObject {
    static let shared = LeaderboardSync()
    private var lastSync = Date.distantPast
    private var pending = false

    private init() {}

    func syncSoon() {
        guard let code = UserDefaults.standard.string(forKey: "ghar.leaderboard.groupCode"),
              let name = UserDefaults.standard.string(forKey: "ghar.leaderboard.nickname"),
              !code.isEmpty, !name.isEmpty else { return }
        let now = Date()
        if now.timeIntervalSince(lastSync) < 10 {
            // Too soon — mark pending so the next window picks it up.
            if !pending {
                pending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    self?.pending = false
                    self?.syncSoon()
                }
            }
            return
        }
        lastSync = now
        Task { await LeaderboardAPI.submitScore(groupCode: code, nickname: name) }
    }
}

// MARK: - Leaderboard view (the 🏆 tab)

struct LeaderboardView: View {
    @AppStorage("ghar.leaderboard.groupCode") private var groupCode = ""
    @AppStorage("ghar.leaderboard.nickname") private var nickname = ""
    @AppStorage("ghar.leaderboard.groupName") private var groupName = ""

    @State private var players: [LeaderboardPlayer] = []
    @State private var selectedBoard = 0
    @State private var loading = false
    @State private var error: String?
    @State private var staleNotice = false

    // Join/create form state
    @State private var setupStep = 1 // 1 = nickname, 2 = create or join
    @State private var nameInput = ""
    @State private var confirmedName = ""
    @State private var groupNameInput = ""
    @State private var codeInput = ""
    @State private var busy = false
    @State private var joinError: String?
    @State private var showingDeleteConfirm = false
    @State private var showingLeaveConfirm = false
    @State private var showingShareCode = false
    @State private var codeCopied = false

    private let boards = ["⭐ XP", "🔥 Streak", "🎯 Quiz", "🚩 Missions"]

    var body: some View {
        Group {
            if groupCode.isEmpty || nickname.isEmpty {
                setupView
            } else {
                rankingsView
            }
        }
        .navigationTitle("Leaderboard")
    }

    // MARK: Setup (two steps: nickname first, then create or join)

    private var setupView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("🏆").font(.system(size: 64))
                Text("Family Leaderboard")
                    .font(.title2).bold()
                Text("Family & friends. May the best Nepali win.\nNo accounts — just a nickname and a group code.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .font(.subheadline)

                if setupStep == 1 {
                    TextField("Pick a nickname", text: $nameInput)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .padding(.horizontal)

                    Button("Continue →") {
                        // Server caps nicknames at 20 chars — cap here too,
                        // or a longer name silently never syncs (audit fix).
                        confirmedName = String(nameInput.trimmingCharacters(in: .whitespaces).prefix(20))
                        joinError = nil
                        setupStep = 2
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(nameInput.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                } else {
                    Text("Hey, \(confirmedName)! 👋")
                        .font(.headline)

                    TextField("Name your group (e.g. Pyakurel Family)", text: $groupNameInput)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .padding(.horizontal)

                    Button("Create a new group") {
                        Task { await createGroup() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)

                    Text("You'll get a code like PYAKUREL-42 to share with family & friends.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider().padding(.horizontal)

                    Text("…or join with a code").font(.subheadline).foregroundStyle(.secondary)
                    TextField("Code (like TIGER-42)", text: $codeInput)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .padding(.horizontal)

                    Button("Join group") {
                        Task { await joinGroup() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(codeInput.trimmingCharacters(in: .whitespaces).isEmpty || busy)

                    Button("← Change nickname") {
                        setupStep = 1
                        joinError = nil
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if busy { ProgressView() }
                if let joinError {
                    Text(joinError).foregroundStyle(.red).font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
    }

    private func createGroup() async {
        busy = true; joinError = nil
        defer { busy = false }
        do {
            let (code, name) = try await LeaderboardAPI.createGroup(name: groupNameInput.trimmingCharacters(in: .whitespaces))
            nickname = confirmedName
            groupCode = code
            groupName = name ?? ""
            LeaderboardSync.shared.syncSoon()
            showingShareCode = true
            await refresh()
        } catch {
            joinError = "Couldn't create a group. Check your connection."
        }
    }

    private func joinGroup() async {
        busy = true; joinError = nil
        defer { busy = false }
        let code = codeInput.trimmingCharacters(in: .whitespaces).uppercased()
        do {
            guard try await LeaderboardAPI.joinCheck(code: code) else {
                joinError = "That code doesn't exist. Check it and try again."
                return
            }
            // Nickname must be unique in the group — no silent overwrites.
            let (players, fetchedName) = try await LeaderboardAPI.fetchRankings(code: code)
            if players.contains(where: { $0.nickname.lowercased() == confirmedName.lowercased() }) {
                joinError = "\"\(confirmedName)\" is already taken in this group — pick another nickname."
                setupStep = 1
                return
            }
            nickname = confirmedName
            groupCode = code
            groupName = fetchedName ?? ""
            LeaderboardSync.shared.syncSoon()
            await refresh()
        } catch {
            joinError = "Couldn't reach the leaderboard. Check your connection."
        }
    }

    // MARK: Rankings

    private var rankingsView: some View {
        VStack(spacing: 0) {
            Picker("Board", selection: $selectedBoard) {
                ForEach(boards.indices, id: \.self) { i in
                    Text(boards[i]).tag(i)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            if loading && players.isEmpty {
                Spacer(); ProgressView(); Spacer()
            } else if let error {
                Spacer()
                Text(error).foregroundStyle(.secondary)
                Button("Try again") { Task { await refresh() } }
                    .buttonStyle(.bordered)
                Spacer()
            } else if players.isEmpty {
                Spacer()
                Text("Nobody's on the board yet.\nPlay a quiz — your score will show up here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                if staleNotice {
                    Text("Couldn't reach the server — showing your last saved board.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
                List(sortedPlayers.enumerated().map { $0 }, id: \.element.id) { index, player in
                    HStack {
                        Text(medal(for: index)).font(.title2)
                        Text(player.nickname).font(.headline)
                        if player.nickname == nickname {
                            Text("you")
                                .font(.caption).bold()
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.15))
                                .clipShape(Capsule())
                        }
                        Spacer()
                        Text(scoreText(for: player))
                            .font(.headline).monospacedDigit()
                    }
                    .listRowBackground(player.nickname == nickname
                        ? Color.accentColor.opacity(0.08) : nil)
                }
                .listStyle(.plain)
            }

            // Group code footer with leave + delete-scores buttons
            HStack {
                Text(groupName.isEmpty ? "Group: \(groupCode)" : "\(groupName) · \(groupCode)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Delete my scores") { showingDeleteConfirm = true }
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Leave") { showingLeaveConfirm = true }
                .font(.caption)
            }
            .padding()
            .confirmationDialog("Leave this group?", isPresented: $showingLeaveConfirm, titleVisibility: .visible) {
                Button("Leave group", role: .destructive) {
                    groupCode = ""; nickname = ""; groupName = ""; players = []
                    setupStep = 1; nameInput = ""; codeInput = ""; confirmedName = ""
                }
                Button("Stay", role: .cancel) { }
            } message: {
                Text("You'll stop seeing this group's leaderboard. Your scores stay on the board unless you delete them.")
            }
            .confirmationDialog("Delete your scores?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
                Button("Delete my scores", role: .destructive) {
                    Task {
                        try? await LeaderboardAPI.deleteScore(groupCode: groupCode, nickname: nickname)
                        groupCode = ""; nickname = ""; groupName = ""; players = []
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This removes your scores from the group forever. This can't be undone.")
            }
            .sheet(isPresented: $showingShareCode) {
                VStack(spacing: 20) {
                    Text("🎉").font(.system(size: 64))
                    Text("Group created!")
                        .font(.title2).bold()
                    Text("Share this code with family & friends so they can join:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Text(groupCode)
                        .font(.system(size: 40, weight: .bold, design: .monospaced))
                        .padding()
                        .background(Color.accentColor.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    Button {
                        UIPasteboard.general.string = groupCode
                        codeCopied = true
                    } label: {
                        Label(codeCopied ? "Copied!" : "Copy code",
                              systemImage: codeCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)

                    Button("Done") { showingShareCode = false; codeCopied = false }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .presentationDetents([.medium])
            }
        }
        .task {
            loadCachedPlayers()
            await refresh()
        }
        .refreshable { await refresh() }
    }

    private var sortedPlayers: [LeaderboardPlayer] {
        switch selectedBoard {
        case 1: return players.sorted { $0.quizStreakBest > $1.quizStreakBest }
        case 2: return players.sorted { $0.quizCorrectTotal > $1.quizCorrectTotal }
        case 3: return players.sorted { $0.missionsDone > $1.missionsDone }
        default: return players.sorted { $0.xp > $1.xp }
        }
    }

    private func scoreText(for p: LeaderboardPlayer) -> String {
        switch selectedBoard {
        case 1: return "\(p.quizStreakBest) in a row"
        case 2: return "\(p.quizCorrectTotal) right"
        case 3: return "\(p.missionsDone) done"
        default: return "\(p.xp) XP"
        }
    }

    private func medal(for index: Int) -> String {
        switch index {
        case 0: return "🥇"
        case 1: return "🥈"
        case 2: return "🥉"
        default: return "\(index + 1)."
        }
    }

    private func refresh() async {
        guard !groupCode.isEmpty else { return }
        // Push our latest stats first, then pull the board.
        LeaderboardSync.shared.syncSoon()
        let hadPlayers = !players.isEmpty
        if !hadPlayers { loading = true }
        error = nil; staleNotice = false
        // The backend sleeps when idle — the first request after a while can
        // fail while the server wakes up. Retry a few times before giving up.
        for attempt in 0..<3 {
            if Task.isCancelled { return }
            do {
                let (fetched, fetchedName) = try await LeaderboardAPI.fetchRankings(code: groupCode)
                players = fetched
                if let fetchedName, !fetchedName.isEmpty { groupName = fetchedName }
                saveCachedPlayers()
                loading = false
                return
            } catch {
                if attempt < 2 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            }
        }
        loading = false
        if players.isEmpty {
            error = "Couldn't load the board. Pull to retry."
        } else {
            // Keep showing the last saved board, just flag that it's stale.
            staleNotice = true
        }
    }

    // MARK: - Cached board (so the tab never opens to an error screen)

    private func saveCachedPlayers() {
        if let data = try? JSONEncoder().encode(players) {
            UserDefaults.standard.set(data, forKey: "ghar.leaderboard.cachedPlayers")
        }
    }

    private func loadCachedPlayers() {
        guard players.isEmpty,
              let data = UserDefaults.standard.data(forKey: "ghar.leaderboard.cachedPlayers"),
              let cached = try? JSONDecoder().decode([LeaderboardPlayer].self, from: data)
        else { return }
        players = cached
    }
}
