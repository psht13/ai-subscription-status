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
        try testUsageRefreshRecovery()
        try testCodexTransport()
        try testKimiParser()
        try testCLIIdleDetection()
        try testKimiUpdateOutput()
        try check(StatusFormatting.quotaWindow(minutes: 300) == "5-hour allowance", "300 minutes should have a readable window label")
        try check(StatusFormatting.quotaWindow(minutes: 10_080) == "Weekly allowance", "10080 minutes should format as a weekly allowance")
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
        try check(snapshot.metrics.first?.label == "Codex · Weekly allowance", "Codex window label parsing failed")
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

    private static func testUsageRefreshRecovery() throws {
        var state = UsageRefreshState()
        let now = Date()
        let ready = CodexStatusParser.parse(result: [
            "rateLimits": [
                "primary": ["usedPercent": 25, "windowDurationMins": 10_080],
            ],
        ], versionLabel: nil)
        let failed = ProviderSnapshot(
            id: .codex, name: "GPT / Codex", detail: "", health: .unavailable,
            metrics: [], footer: "Request timed out", dashboardURL: ready.dashboardURL
        )
        let firstFailure = state.record(failed, at: now)
        try check(firstFailure.minimumRemainingPercent == nil, "Do not invent usage before the first success")
        try check(state.nextRefreshInterval == 15, "First failure should retry after 15 seconds")
        _ = state.record(ready, at: now)
        try check(state.nextRefreshInterval == 300, "Success should restore normal polling")

        for (index, interval) in [15.0, 30, 60, 120, 240, 300, 300].enumerated() {
            let snapshot = state.record(failed, at: now.addingTimeInterval(Double(index + 1) * 60))
            try check(snapshot.minimumRemainingPercent == 75, "Failures must retain the last known quota")
            try check(snapshot.hasUnavailableProvider && snapshot.hasCachedUsage, "Cached usage must remain visibly unavailable/stale")
            try check(snapshot.providers[0].cachedAt == now, "Repeated failures must not advance the success timestamp")
            try check(snapshot.providers[0].footer == failed.footer, "Retain the actual error with cached usage")
            try check(state.nextRefreshInterval == interval, "Failure retries should back off and stop at five minutes")
        }
        let recovered = state.record(ready, at: now.addingTimeInterval(600))
        try check(!recovered.hasCachedUsage && !recovered.hasUnavailableProvider, "Recovery should clear the stale/error state")
        try check(state.nextRefreshInterval == 300, "Recovery should reset retry backoff")

        let empty = CodexStatusParser.parse(result: [:], versionLabel: nil)
        _ = state.record(empty, at: now)
        let afterEmpty = state.record(failed, at: now)
        try check(!afterEmpty.hasCachedUsage, "An authoritative empty quota must clear older cached usage")
    }

    private static func testCodexTransport() throws {
        let initialize = """
        IFS= read -r request
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r notification
        IFS= read -r request
        """
        try withCodexServer(script: initialize + """

        printf '%s\\n' '{"method":"account/updated","params":{}}'
        printf '%s' '{"id":2,"result":'
        sleep 0.1
        printf '%s\\n' '{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":10080}}}}'
        """) { client in
            let result = try client.readRateLimits()
            let snapshot = CodexStatusParser.parse(result: result, versionLabel: nil)
            try check(snapshot.minimumRemainingPercent == 75, "Read complete JSON across split writes and ignore notifications")
        }
        try withCodexServer(script: """
        IFS= read -r request
        printf '%s\\n' '{"id":1,"error":{"code":-32600,"message":"Initialization rejected"}}'
        """) { client in
            do {
                _ = try client.readRateLimits()
                throw StatusSelfTestError.failed("Initialization errors must fail immediately")
            } catch let error as StatusError {
                try check(error.localizedDescription == "Initialization rejected", "Do not mask initialization errors as timeouts")
            }
        }
        try withCodexServer(script: initialize + """

        printf '%s\\n' '{"id":2,"error":{"code":-32000,"message":"Sign in required"}}'
        """) { client in
            do {
                _ = try client.readRateLimits()
                throw StatusSelfTestError.failed("Authentication errors must not be accepted as usage")
            } catch let error as StatusError {
                try check(error.localizedDescription == "Sign in required", "Preserve authentication errors")
            }
        }
        try withCodexServer(script: initialize + "\nexit 0\n") { client in
            do {
                _ = try client.readRateLimits()
                throw StatusSelfTestError.failed("An early exit must fail")
            } catch let error as StatusError {
                try check(error.localizedDescription == "Codex app-server closed before returning usage", "An early exit is not a timeout")
            }
        }
        try withCodexServer(script: initialize + "\nexec /bin/sleep 5\n", timeout: 0.2) { client in
            let start = ProcessInfo.processInfo.systemUptime
            do {
                _ = try client.readRateLimits()
                throw StatusSelfTestError.failed("A hung server must time out")
            } catch let error as StatusError {
                guard case .timedOut = error else {
                    throw StatusSelfTestError.failed("A hung server should report a timeout")
                }
                try check(ProcessInfo.processInfo.systemUptime - start < 2, "The read deadline must bound a hung server")
            }
        }
    }

    private static func withCodexServer(
        script: String,
        timeout: TimeInterval = 2,
        checkClient: (CodexAppServerClient) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex-fixture")
        try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try checkClient(CodexAppServerClient(executable: executable.path, timeout: timeout))
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
