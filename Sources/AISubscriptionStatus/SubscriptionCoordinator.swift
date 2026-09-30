import Foundation

final class SubscriptionCoordinator {
    private let codex = CodexStatusProvider()
    private var refreshState = UsageRefreshState()

    var nextRefreshInterval: TimeInterval { refreshState.nextRefreshInterval }

    func refresh() async -> OverallSnapshot {
        let provider = await Task.detached(priority: .utility) { [codex] in
            codex.fetch()
        }.value
        return refreshState.record(provider, at: Date())
    }

    func shutdown() {}

    func prepareForCLIUpdate(_ providerID: ProviderID) {}
}
