import Foundation

final class SubscriptionCoordinator {
    private let codex = CodexStatusProvider()
    private let kimi = KimiStatusProvider()
    private var codexRefreshState = UsageRefreshState()
    private var kimiRefreshState = UsageRefreshState()

    var nextRefreshInterval: TimeInterval {
        min(codexRefreshState.nextRefreshInterval, kimiRefreshState.nextRefreshInterval)
    }

    func refresh() async -> OverallSnapshot {
        async let codexProvider = Task.detached(priority: .utility) { [codex] in
            codex.fetch()
        }.value
        async let kimiProvider = Task.detached(priority: .utility) { [kimi] in
            kimi.fetch()
        }.value
        let providers = await (codexProvider, kimiProvider)
        let now = Date()
        let codexSnapshot = codexRefreshState.record(providers.0, at: now)
        let kimiSnapshot = kimiRefreshState.record(providers.1, at: now)
        return OverallSnapshot(
            providers: codexSnapshot.providers + kimiSnapshot.providers,
            refreshedAt: now
        )
    }

    func shutdown() {
        kimi.stop()
    }

    func prepareForCLIUpdate(_ providerID: ProviderID) {
        if providerID == .kimi { kimi.stop() }
    }
}
