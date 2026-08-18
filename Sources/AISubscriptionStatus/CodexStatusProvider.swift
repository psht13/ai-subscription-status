import Foundation

final class CodexStatusProvider {
    private let executable: String?

    private var versionLabel: String? {
        executable.flatMap { ProcessRunner.version(executable: $0, productName: "Codex") }
    }

    init() {
        executable = ExecutableLocator.find("codex")
    }

    func fetch() -> ProviderSnapshot {
        guard let executable else {
            return unavailableSnapshot(message: "Codex CLI was not found")
        }

        do {
            let result = try CodexAppServerClient(executable: executable).readRateLimits()
            return CodexStatusParser.parse(result: result, versionLabel: versionLabel)
        } catch {
            return unavailableSnapshot(message: error.localizedDescription)
        }
    }

    private func unavailableSnapshot(message: String) -> ProviderSnapshot {
        ProviderSnapshot(
            id: .codex,
            name: "GPT / Codex",
            detail: versionLabel ?? "Codex CLI unavailable",
            health: .unavailable,
            metrics: [],
            footer: message,
            dashboardURL: URL(string: "https://chatgpt.com/codex/settings/usage")!
        )
    }
}

private final class CodexAppServerClient {
    private let executable: String

    init(executable: String) {
        self.executable = executable
    }

    func readRateLimits() throws -> [String: Any] {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        try process.run()

        let timeoutItem = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 12, execute: timeoutItem)

        defer {
            timeoutItem.cancel()
            try? stdin.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
        }

        try send(
            [
                "method": "initialize",
                "id": 1,
                "params": [
                    "clientInfo": [
                        "name": "ai_subscription_status",
                        "title": "AI Subscription Status",
                        "version": "0.1.0",
                    ],
                ],
            ],
            to: stdin.fileHandleForWriting
        )

        var buffer = Data()
        var initialized = false

        while true {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty {
                break
            }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }

                let id = JSONAccess.int(object["id"])
                if id == 1, !initialized {
                    initialized = true
                    try send(
                        ["method": "initialized", "params": [:]],
                        to: stdin.fileHandleForWriting
                    )
                    try send(
                        ["method": "account/rateLimits/read", "id": 2, "params": [:]],
                        to: stdin.fileHandleForWriting
                    )
                    continue
                }

                guard id == 2 else { continue }
                if let result = object["result"] as? [String: Any] {
                    return result
                }
                if let error = object["error"] as? [String: Any],
                   let message = JSONAccess.string(error["message"]) {
                    throw StatusError.unavailable(message)
                }
                throw StatusError.invalidResponse("Codex returned an invalid rate-limit response")
            }
        }

        if initialized {
            throw StatusError.timedOut("Codex rate-limit request timed out")
        }
        throw StatusError.unavailable("Codex app-server did not initialize")
    }

    private func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }
}

enum CodexStatusParser {
    static func parse(result: [String: Any], versionLabel: String?) -> ProviderSnapshot {
        let buckets = rateLimitBuckets(from: result)
        var metrics: [StatusMetric] = []
        var plan: String?
        var creditsBalance: Double?

        for (bucketID, bucket) in buckets.sorted(by: { $0.key < $1.key }) {
            if plan == nil, let rawPlan = JSONAccess.string(bucket["planType"]) {
                plan = StatusFormatting.titleCasePlan(rawPlan)
            }

            if creditsBalance == nil,
               let credits = JSONAccess.dictionary(bucket["credits"]),
               (credits["hasCredits"] as? Bool) == true {
                creditsBalance = JSONAccess.double(credits["balance"])
            }

            let bucketName = displayName(for: bucketID, bucket: bucket)
            for key in ["primary", "secondary"] {
                guard let window = JSONAccess.dictionary(bucket[key]),
                      let usedPercent = JSONAccess.double(window["usedPercent"]),
                      let durationMinutes = JSONAccess.int(window["windowDurationMins"]) else {
                    continue
                }

                let remaining = max(0, min(100, 100 - usedPercent))
                let windowLabel = StatusFormatting.quotaWindow(minutes: durationMinutes)
                let resetText: String?
                if let resetEpoch = JSONAccess.double(window["resetsAt"]) {
                    resetText = StatusFormatting.resetText(
                        for: Date(timeIntervalSince1970: resetEpoch)
                    )
                } else {
                    resetText = nil
                }

                metrics.append(
                    StatusMetric(
                        label: "\(bucketName) · \(windowLabel)",
                        value: "\(StatusFormatting.percent(remaining))% left",
                        remainingPercent: remaining,
                        resetText: resetText
                    )
                )
            }
        }

        metrics.sort {
            if $0.label == $1.label {
                return ($0.remainingPercent ?? 0) < ($1.remainingPercent ?? 0)
            }
            if $0.label.hasPrefix("Codex ·") != $1.label.hasPrefix("Codex ·") {
                return $0.label.hasPrefix("Codex ·")
            }
            return $0.label < $1.label
        }

        var detailParts: [String] = []
        if let plan { detailParts.append(plan) }
        if let versionLabel { detailParts.append(versionLabel) }

        let footer: String?
        if let creditsBalance {
            footer = "Credits balance: \(formattedCredits(creditsBalance))"
        } else if metrics.isEmpty {
            footer = "Signed in, but no ChatGPT quota windows were returned."
        } else {
            footer = nil
        }

        return ProviderSnapshot(
            id: .codex,
            name: "GPT / Codex",
            detail: detailParts.isEmpty ? "ChatGPT account" : detailParts.joined(separator: " · "),
            health: metrics.isEmpty ? .warning : .ready,
            metrics: metrics,
            footer: footer,
            dashboardURL: URL(string: "https://chatgpt.com/codex/settings/usage")!
        )
    }

    private static func rateLimitBuckets(from result: [String: Any]) -> [String: [String: Any]] {
        if let rawBuckets = result["rateLimitsByLimitId"] as? [String: Any] {
            let buckets = rawBuckets.reduce(into: [String: [String: Any]]()) { output, item in
                if let bucket = item.value as? [String: Any] {
                    output[item.key] = bucket
                }
            }
            if !buckets.isEmpty { return buckets }
        }
        if let single = result["rateLimits"] as? [String: Any] {
            let key = JSONAccess.string(single["limitId"]) ?? "codex"
            return [key: single]
        }
        return [:]
    }

    private static func displayName(for bucketID: String, bucket: [String: Any]) -> String {
        if let limitName = JSONAccess.string(bucket["limitName"]), limitName != bucketID {
            return limitName
        }
        if bucketID == "codex" { return "Codex" }
        return bucketID
            .replacingOccurrences(of: "codex_", with: "", options: [.anchored])
            .replacingOccurrences(of: "_", with: " ")
    }

    private static func formattedCredits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}
