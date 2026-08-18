import Foundation

final class SubscriptionCoordinator {
    private let codex = CodexStatusProvider()
    private let kimi = KimiStatusProvider()

    func refresh() async -> OverallSnapshot {
        let snapshots = await withTaskGroup(of: ProviderSnapshot.self) { group in
            group.addTask { self.codex.fetch() }
            group.addTask { self.kimi.fetch() }

            var output: [ProviderSnapshot] = []
            for await snapshot in group {
                output.append(snapshot)
            }
            return output.sorted { $0.id < $1.id }
        }
        return OverallSnapshot(providers: snapshots, refreshedAt: Date())
    }

    func shutdown() {
        kimi.stop()
    }

    func prepareForCLIUpdate(_ providerID: ProviderID) {
        if providerID == .kimi {
            kimi.stop()
        }
    }
}
