import Foundation

final class SubscriptionCoordinator {
    private let codex = CodexStatusProvider()

    func refresh() async -> OverallSnapshot {
        let snapshots = [codex.fetch()]
        return OverallSnapshot(providers: snapshots, refreshedAt: Date())
    }

    func shutdown() {}

    func prepareForCLIUpdate(_ providerID: ProviderID) {}
}
