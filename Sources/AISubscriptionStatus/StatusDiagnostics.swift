import Foundation

enum StatusDiagnostics {
    static func printLiveStatus() {
        let codex = CodexStatusProvider()
        let kimi = KimiStatusProvider()
        defer { kimi.stop() }

        let providers = [codex.fetch(), kimi.fetch()]
        for provider in providers {
            print("\(provider.name) | \(healthName(provider.health)) | \(provider.detail)")
            for metric in provider.metrics {
                let reset = metric.resetText.map { " | \($0)" } ?? ""
                print("  \(metric.label) | \(metric.value)\(reset)")
            }
            if let footer = provider.footer {
                print("  note | \(footer)")
            }
        }
    }

    static func printCLIUpdatePlan() {
        let manager = CLIUpdateManager()
        print("Automatic CLI updates | \(manager.automaticUpdatesEnabled ? "enabled" : "disabled")")
        for item in manager.preview() {
            let availability = item.executable == nil ? "not found" : (item.inUse ? "in use" : "idle")
            print("\(providerName(item.providerID)) | \(availability) | \(item.commandDescription)")
        }
        print("Dry run only; no update commands were executed.")
    }

    private static func healthName(_ health: ProviderHealth) -> String {
        switch health {
        case .ready: return "ready"
        case .configured: return "configured"
        case .warning: return "warning"
        case .unavailable: return "unavailable"
        }
    }

    private static func providerName(_ providerID: ProviderID) -> String {
        switch providerID {
        case .codex: return "GPT / Codex"
        case .kimi: return "Kimi"
        }
    }
}
