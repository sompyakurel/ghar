import SwiftUI

/// "For Grown-ups": a simple progress screen for parents.
/// Everything here is read straight from on-device UserDefaults.
/// Ghar has no accounts and no tracking; the only data that ever
/// leaves the device is a leaderboard nickname + scores, and only
/// when a family chooses to join a group.
struct ParentsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var premium = PremiumManager.shared
    @AppStorage("ghar.premium.unlocked") private var isUnlockedFlag = false

    private var totalXP: Int {
        UserDefaults.standard.integer(forKey: "ghar.xp.total")
    }

    private var missionsDone: Int {
        let data = UserDefaults.standard.data(forKey: "ghar.missions.completed") ?? Data()
        return (try? JSONDecoder().decode(Set<String>.self, from: data))?.count ?? 0
    }

    private var quizCorrect: Int {
        UserDefaults.standard.integer(forKey: "ghar.quiz.correctTotal")
    }

    private var quizBestStreak: Int {
        UserDefaults.standard.integer(forKey: "ghar.quiz.streakBest")
    }

    private var dayStreak: Int {
        UserDefaults.standard.integer(forKey: "ghar.streak.count")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Everything below lives on this device. Ghar has no accounts, no tracking, and no ads. If your family joins a leaderboard group, the nickname and scores you share there are the one exception.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Progress") {
                    statRow("Total XP", value: "\(totalXP)")
                    statRow("Missions completed", value: "\(missionsDone)")
                    statRow("Quiz answers right", value: "\(quizCorrect)")
                    statRow("Best quiz streak", value: "\(quizBestStreak) in a row")
                    statRow("Day streak", value: dayStreak == 1 ? "1 day" : "\(dayStreak) days")
                }

                Section("Premium") {
                    HStack {
                        Text("Ghar Premium")
                        Spacer()
                        Text(isUnlockedFlag ? "Unlocked ✓" : "Locked")
                            .foregroundStyle(isUnlockedFlag ? .green : .secondary)
                            .bold(isUnlockedFlag)
                    }
                    Text("One-time purchase, handled securely by Apple. No subscription.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("For Grown-ups")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .bold()
                .monospacedDigit()
        }
    }
}
