import Foundation

enum StatusSelfTestError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

enum StatusSelfTests {
    static func run() throws {
        try testCodexParser()
        try testKimiParser()
        try testCLIIdleDetection()
        try testKimiUpdateOutput()
        try check(StatusFormatting.quotaWindow(minutes: 300) == "5h", "300 minutes should format as 5h")
        try check(StatusFormatting.quotaWindow(minutes: 10_080) == "7d", "10080 minutes should format as 7d")
        let now = Date()
        try check(StatusFormatting.relative(now, now: now) == "just now", "Current refreshes should say just now")
    }

    private static func testCodexParser() throws {
        let result: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "planType": "pro",
                    "primary": [
                        "usedPercent": 25,
                        "windowDurationMins": 10_080,
                        "resetsAt": 1_900_000_000,
                    ],
                    "credits": [
                        "hasCredits": true,
                        "balance": "123.5",
                    ],
                ],
                "codex_spark": [
                    "limitName": "GPT Spark",
                    "planType": "pro",
                    "primary": [
                        "usedPercent": 10,
                        "windowDurationMins": 300,
                        "resetsAt": 1_900_000_000,
                    ],
                ],
            ],
        ]

        let snapshot = CodexStatusParser.parse(result: result, versionLabel: "Codex 1.2.3")
        try check(snapshot.health == .ready, "Codex fixture should be ready")
        try check(snapshot.detail == "Pro · Codex 1.2.3", "Codex plan/version parsing failed")
        try check(snapshot.metrics.count == 2, "Codex should expose two fixture windows")
        try check(snapshot.metrics.first?.label == "Codex · 7d", "Codex window label parsing failed")
        try check(snapshot.minimumRemainingPercent == 75, "Codex used-to-remaining conversion failed")
        try check(snapshot.footer?.hasPrefix("Credits balance: 123") == true, "Codex credits parsing failed")
    }

    private static func testKimiParser() throws {
        let data: [String: Any] = [
            "kind": "ok",
            "summary": [
                "label": "Weekly limit",
                "used": 19,
                "limit": 100,
                "reset_hint": "resets in 4d",
            ],
            "limits": [
                [
                    "label": "5h limit",
                    "used": 9,
                    "limit": 100,
                    "reset_hint": "resets in 3h",
                ],
            ],
            "extra_usage": NSNull(),
        ]

        let snapshot = KimiStatusParser.parse(
            data: data,
            versionLabel: "Kimi 0.29.2",
            modelLabel: "K3"
        )
        try check(snapshot.health == .ready, "Kimi fixture should be ready")
        try check(snapshot.detail == "OAuth · K3 · Kimi 0.29.2", "Kimi detail parsing failed")
        try check(snapshot.metrics.map(\.value) == ["81% left", "91% left"], "Kimi remaining quota parsing failed")
        try check(snapshot.metrics.map(\.resetText) == ["resets in 4d", "resets in 3h"], "Kimi reset parsing failed")
        try check(snapshot.minimumRemainingPercent == 81, "Kimi minimum quota failed")

        let currentWireSnapshot = KimiStatusParser.parse(
            data: [
                "summary": [
                    "window": ["duration": 1, "unit": "week"],
                    "used": 19,
                    "limit": 100,
                    "reset_at": "2030-08-05T11:48:39.017482Z",
                ],
                "limits": [],
            ],
            versionLabel: nil,
            modelLabel: nil
        )
        try check(currentWireSnapshot.metrics.first?.label == "1w limit", "Kimi current window label parsing failed")
        try check(currentWireSnapshot.metrics.first?.resetText != nil, "Kimi fractional reset timestamp parsing failed")
    }

    private static func testCLIIdleDetection() throws {
        let processes = [
            RunningProcess(
                pid: 100,
                parentPID: 1,
                command: "/Applications/AI Subscription Status.app/Contents/MacOS/AISubscriptionStatus",
                arguments: ""
            ),
            RunningProcess(pid: 101, parentPID: 100, command: "kimi-code", arguments: ""),
            RunningProcess(
                pid: 200,
                parentPID: 1,
                command: "/Users/test/.nvm/lib/node_modules/@openai/codex/bin/codex",
                arguments: ""
            ),
        ]
        let ignored = RunningProcessScanner.statusAppProcessTree(in: processes)
        try check(ignored.contains(101), "The status app's Kimi server should be ignored")
        try check(
            !CLIIdleDetector.isInUse(
                providerID: .kimi,
                executable: "/Users/test/.kimi-code/bin/kimi",
                processes: processes,
                ignoredProcessIDs: ignored
            ),
            "The status app's own Kimi server must not block updates"
        )
        try check(
            CLIIdleDetector.isInUse(
                providerID: .codex,
                executable: "/Users/test/.nvm/bin/codex",
                processes: processes,
                ignoredProcessIDs: ignored
            ),
            "An external Codex session should block updates"
        )
    }

    private static func testKimiUpdateOutput() throws {
        try check(
            KimiUpdateOutput.isCurrent("Kimi Code is already up to date (v0.31.1)."),
            "Kimi current-version output should be recognized"
        )
        try check(
            KimiUpdateOutput.targetVersion(
                "A newer version of @moonshot-ai/kimi-code is available (0.31.1 -> 0.32.0)."
            ) == "0.32.0",
            "Kimi update target parsing failed"
        )
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw StatusSelfTestError.failed(message) }
    }
}
