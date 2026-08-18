import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let coordinator = SubscriptionCoordinator()
    private let updateManager = CLIUpdateManager()
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var updateTimer: Timer?
    private var snapshot: OverallSnapshot?
    private var latestUpdateRun: CLIUpdateRun?
    private var isRefreshing = false
    private var isUpdatingCLIs = false
    private var pendingForcedUpdate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "gauge.with.dots.needle.50percent",
                accessibilityDescription: "AI subscription status"
            ) ?? NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            button.toolTip = "AI Subscription Status"
        }

        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        renderLoadingMenu()
        refreshNow(nil)

        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow(nil)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        let cliTimer = Timer(timeInterval: CLIUpdateManager.retryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.requestCLIUpdates(force: false)
            }
        }
        RunLoop.main.add(cliTimer, forMode: .common)
        updateTimer = cliTimer
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        updateTimer?.invalidate()
        coordinator.shutdown()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard !isRefreshing, !isUpdatingCLIs else { return }
        if let snapshot, Date().timeIntervalSince(snapshot.refreshedAt) >= 90 {
            refreshNow(nil)
            return
        }
        requestCLIUpdates(force: false)
    }

    @objc private func refreshNow(_ sender: Any?) {
        guard !isRefreshing, !isUpdatingCLIs else { return }
        isRefreshing = true
        showRefreshingTitle()

        Task { [weak self] in
            guard let self else { return }
            let newSnapshot = await coordinator.refresh()
            snapshot = newSnapshot
            isRefreshing = false
            render(snapshot: newSnapshot)
            if pendingForcedUpdate {
                pendingForcedUpdate = false
                requestCLIUpdates(force: true)
            } else {
                requestCLIUpdates(force: false)
            }
        }
    }

    @objc private func toggleAutomaticCLIUpdates(_ sender: NSMenuItem) {
        updateManager.automaticUpdatesEnabled.toggle()
        if let snapshot {
            render(snapshot: snapshot)
        }
        if updateManager.automaticUpdatesEnabled {
            requestCLIUpdates(force: false)
        }
    }

    @objc private func updateIdleCLIsNow(_ sender: NSMenuItem) {
        requestCLIUpdates(force: true)
    }

    private func requestCLIUpdates(force: Bool) {
        guard !isUpdatingCLIs else { return }
        if isRefreshing {
            pendingForcedUpdate = pendingForcedUpdate || force
            return
        }
        guard force || updateManager.shouldRunAutomaticUpdate() else { return }

        isUpdatingCLIs = true
        if let snapshot {
            render(snapshot: snapshot)
        }

        let updateManager = self.updateManager
        let coordinator = self.coordinator
        Task { [weak self] in
            let run = await Task.detached(priority: .utility) {
                updateManager.performUpdates(force: force) { providerID in
                    coordinator.prepareForCLIUpdate(providerID)
                }
            }.value
            guard let self else { return }
            latestUpdateRun = run
            isUpdatingCLIs = false
            if let snapshot {
                render(snapshot: snapshot)
            }
            refreshNow(nil)
        }
    }

    @objc private func openDashboard(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openProjectFolder(_ sender: NSMenuItem) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/ai-subscription-status", isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func renderLoadingMenu() {
        statusItem.button?.title = " …"
        menu.removeAllItems()
        menu.addItem(headerItem(title: "AI Subscription Status"))
        menu.addItem(disabledItem(title: "Reading GPT and Kimi…", color: .secondaryLabelColor))
        addFooterActions()
    }

    private func render(snapshot: OverallSnapshot) {
        updateStatusBar(snapshot: snapshot)
        menu.removeAllItems()
        menu.addItem(headerItem(title: "AI Subscription Status"))
        menu.addItem(
            disabledItem(
                title: "Updated \(StatusFormatting.relative(snapshot.refreshedAt)) · refreshes every 5m",
                color: .secondaryLabelColor,
                size: 11
            )
        )
        menu.addItem(.separator())

        for (index, provider) in snapshot.providers.enumerated() {
            addProvider(provider)
            if index < snapshot.providers.count - 1 {
                menu.addItem(.separator())
            }
        }

        addFooterActions()
    }

    private func addProvider(_ provider: ProviderSnapshot) {
        let headerColor = healthColor(provider.health)
        let providerTitle = "\(healthSymbol(provider.health))  \(provider.name)"
        menu.addItem(
            disabledItem(
                title: providerTitle,
                color: headerColor,
                font: .systemFont(ofSize: 13, weight: .semibold)
            )
        )
        if !provider.detail.isEmpty {
            menu.addItem(
                disabledItem(
                    title: "     \(provider.detail)",
                    color: .secondaryLabelColor,
                    size: 11
                )
            )
        }

        for metric in provider.metrics {
            let reset = metric.resetText.map { " · \($0)" } ?? ""
            let title = "     \(metric.label): \(metric.value)\(reset)"
            menu.addItem(
                disabledItem(
                    title: title,
                    color: metricColor(metric.remainingPercent),
                    font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                )
            )
        }

        if let footer = provider.footer {
            for line in wrapped(footer, width: 76) {
                menu.addItem(
                    disabledItem(
                        title: "     \(line)",
                        color: .tertiaryLabelColor,
                        size: 10
                    )
                )
            }
        }
    }

    private func addFooterActions() {
        menu.addItem(.separator())

        addCLIUpdateActions()

        let dashboards = NSMenuItem(title: "Open Usage Dashboards", action: nil, keyEquivalent: "")
        dashboards.identifier = NSUserInterfaceItemIdentifier("ai_subscription_dashboards_menu")
        let dashboardMenu = NSMenu(title: "Open Usage Dashboards")
        for provider in snapshot?.providers ?? fallbackDashboardProviders() {
            let item = NSMenuItem(
                title: provider.name,
                action: #selector(openDashboard(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = provider.dashboardURL
            item.identifier = NSUserInterfaceItemIdentifier(
                "ai_subscription_\(providerIdentifier(provider.id))_dashboard_link"
            )
            dashboardMenu.addItem(item)
        }
        dashboards.submenu = dashboardMenu
        menu.addItem(dashboards)

        let refresh = NSMenuItem(
            title: isRefreshing ? "Refreshing…" : (isUpdatingCLIs ? "CLI Update in Progress…" : "Refresh Now"),
            action: #selector(refreshNow(_:)),
            keyEquivalent: "r"
        )
        refresh.target = self
        refresh.keyEquivalentModifierMask = [.command]
        refresh.isEnabled = !isRefreshing && !isUpdatingCLIs
        refresh.identifier = NSUserInterfaceItemIdentifier("ai_subscription_refresh_button")
        menu.addItem(refresh)

        let source = NSMenuItem(
            title: "Open Project Folder",
            action: #selector(openProjectFolder(_:)),
            keyEquivalent: ""
        )
        source.target = self
        source.identifier = NSUserInterfaceItemIdentifier("ai_subscription_project_folder_link")
        menu.addItem(source)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = [.command]
        quit.identifier = NSUserInterfaceItemIdentifier("ai_subscription_quit_button")
        menu.addItem(quit)
    }

    private func addCLIUpdateActions() {
        let parent = NSMenuItem(
            title: isUpdatingCLIs ? "CLI Updates · Working…" : "CLI Updates",
            action: nil,
            keyEquivalent: ""
        )
        parent.identifier = NSUserInterfaceItemIdentifier("ai_subscription_cli_updates_menu")

        let submenu = NSMenu(title: "CLI Updates")
        let automatic = NSMenuItem(
            title: "Automatically Update When Idle",
            action: #selector(toggleAutomaticCLIUpdates(_:)),
            keyEquivalent: ""
        )
        automatic.target = self
        automatic.state = updateManager.automaticUpdatesEnabled ? .on : .off
        automatic.identifier = NSUserInterfaceItemIdentifier(
            "ai_subscription_cli_auto_update_toggle"
        )
        submenu.addItem(automatic)

        let updateNow = NSMenuItem(
            title: isUpdatingCLIs ? "Updating Idle CLIs…" : "Update Idle CLIs Now",
            action: #selector(updateIdleCLIsNow(_:)),
            keyEquivalent: "u"
        )
        updateNow.target = self
        updateNow.keyEquivalentModifierMask = [.command]
        updateNow.isEnabled = !isUpdatingCLIs && !isRefreshing
        updateNow.identifier = NSUserInterfaceItemIdentifier(
            "ai_subscription_cli_update_now_button"
        )
        submenu.addItem(updateNow)
        submenu.addItem(.separator())

        if isUpdatingCLIs {
            submenu.addItem(
                disabledItem(
                    title: "Checking one idle CLI at a time…",
                    color: .secondaryLabelColor,
                    size: 11
                )
            )
        }

        let results = Dictionary(
            uniqueKeysWithValues: updateManager.savedResults().map { ($0.providerID, $0) }
        )
        for providerID in ProviderID.allCases {
            if let result = results[providerID] {
                submenu.addItem(
                    disabledItem(
                        title: "\(updateSymbol(result.state))  \(updateProviderName(providerID)): \(result.detail)",
                        color: updateColor(result.state),
                        size: 11
                    )
                )
            } else {
                submenu.addItem(
                    disabledItem(
                        title: "○  \(updateProviderName(providerID)): not checked yet",
                        color: .secondaryLabelColor,
                        size: 11
                    )
                )
            }
        }

        submenu.addItem(.separator())
        let footer: String
        if updateManager.automaticUpdatesEnabled {
            footer = "Checks every 12h · busy CLIs retry every 15m"
        } else {
            footer = "Automatic updates are off"
        }
        submenu.addItem(disabledItem(title: footer, color: .tertiaryLabelColor, size: 10))
        if let latestUpdateRun {
            let mode = latestUpdateRun.automatic ? "Automatic" : "Manual"
            submenu.addItem(
                disabledItem(
                    title: "\(mode) check completed \(StatusFormatting.relative(latestUpdateRun.completedAt))",
                    color: .tertiaryLabelColor,
                    size: 10
                )
            )
        }

        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func updateStatusBar(snapshot: OverallSnapshot) {
        let title: String
        let color: NSColor
        if let remaining = snapshot.minimumRemainingPercent {
            title = " \(StatusFormatting.percent(remaining))%"
            color = metricColor(remaining)
        } else if snapshot.hasUnavailableProvider {
            title = " !"
            color = .systemRed
        } else {
            title = " AI"
            color = .labelColor
        }

        statusItem.button?.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: color,
            ]
        )
        statusItem.button?.toolTip = snapshot.hasUnavailableProvider
            ? "AI subscriptions · one or more sources unavailable"
            : "AI subscriptions · lowest known quota: \(title.trimmingCharacters(in: .whitespaces))"
    }

    private func showRefreshingTitle() {
        guard snapshot == nil else { return }
        statusItem.button?.attributedTitle = NSAttributedString(
            string: " …",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
    }

    private func headerItem(title: String) -> NSMenuItem {
        disabledItem(
            title: title,
            color: .labelColor,
            font: .systemFont(ofSize: 14, weight: .bold)
        )
    }

    private func disabledItem(
        title: String,
        color: NSColor,
        size: CGFloat = 12,
        font: NSFont? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: font ?? NSFont.systemFont(ofSize: size),
                .foregroundColor: color,
            ]
        )
        return item
    }

    private func healthColor(_ health: ProviderHealth) -> NSColor {
        switch health {
        case .ready: return .systemGreen
        case .configured: return .systemBlue
        case .warning: return .systemOrange
        case .unavailable: return .systemRed
        }
    }

    private func healthSymbol(_ health: ProviderHealth) -> String {
        switch health {
        case .ready: return "●"
        case .configured: return "◐"
        case .warning: return "▲"
        case .unavailable: return "×"
        }
    }

    private func metricColor(_ remaining: Double?) -> NSColor {
        guard let remaining else { return .labelColor }
        if remaining <= 10 { return .systemRed }
        if remaining <= 20 { return .systemOrange }
        return .labelColor
    }

    private func updateColor(_ state: CLIUpdateResultState) -> NSColor {
        switch state {
        case .current, .updated: return .systemGreen
        case .busy: return .systemOrange
        case .failed, .unavailable: return .systemRed
        }
    }

    private func updateSymbol(_ state: CLIUpdateResultState) -> String {
        switch state {
        case .current: return "✓"
        case .updated: return "↑"
        case .busy: return "◷"
        case .failed: return "!"
        case .unavailable: return "×"
        }
    }

    private func updateProviderName(_ providerID: ProviderID) -> String {
        switch providerID {
        case .codex: return "GPT / Codex"
        case .kimi: return "Kimi"
        }
    }

    private func wrapped(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ").map(String.init) {
            if current.isEmpty {
                current = word
            } else if current.count + word.count + 1 <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private func fallbackDashboardProviders() -> [ProviderSnapshot] {
        [
            ProviderSnapshot(
                id: .codex,
                name: "GPT / Codex",
                detail: "",
                health: .configured,
                metrics: [],
                footer: nil,
                dashboardURL: URL(string: "https://chatgpt.com/codex/settings/usage")!
            ),
            ProviderSnapshot(
                id: .kimi,
                name: "Kimi",
                detail: "",
                health: .configured,
                metrics: [],
                footer: nil,
                dashboardURL: URL(string: "https://www.kimi.com/code/console?from=kfc_overview_topbar")!
            ),
        ]
    }

    private func providerIdentifier(_ id: ProviderID) -> String {
        switch id {
        case .codex: return "gpt"
        case .kimi: return "kimi"
        }
    }
}
