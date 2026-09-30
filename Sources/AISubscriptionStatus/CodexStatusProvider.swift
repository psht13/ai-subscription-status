import Darwin
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
        let version = versionLabel
        return ProviderSnapshot(
            id: .codex,
            name: "GPT / Codex",
            detail: version ?? "Codex CLI unavailable",
            health: .unavailable,
            metrics: [],
            footer: message,
            dashboardURL: URL(string: "https://chatgpt.com/codex/settings/usage")!,
            versionLabel: version
        )
    }
}

final class CodexAppServerClient {
    private let executable: String
    private let timeout: TimeInterval

    init(executable: String, timeout: TimeInterval = 30) {
        self.executable = executable
        self.timeout = timeout
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

        let deadline = ProcessInfo.processInfo.systemUptime + timeout

        defer {
            try? stdin.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
            try? stdout.fileHandleForReading.close()
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
            let chunk = try readChunk(from: stdout.fileHandleForReading, deadline: deadline)
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
                guard id == 1 || id == 2 else { continue }
                if let error = object["error"] as? [String: Any],
                   let message = JSONAccess.string(error["message"]) {
                    throw StatusError.unavailable(message)
                }
                if id == 1, !initialized {
                    guard object["result"] is [String: Any] else {
                        throw StatusError.invalidResponse("Codex returned an invalid initialization response")
                    }
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
                throw StatusError.invalidResponse("Codex returned an invalid rate-limit response")
            }
        }

        if initialized {
            throw StatusError.unavailable("Codex app-server closed before returning usage")
        }
        throw StatusError.unavailable("Codex app-server did not initialize")
    }

    // A deadline on the read itself also works if a CLI child keeps stdout open
    // after its parent exits. Killing only the parent can leave availableData blocked.
    private func readChunk(from handle: FileHandle, deadline: TimeInterval) throws -> Data {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                throw StatusError.timedOut("Codex rate-limit request timed out")
            }
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, Int32(ceil(remaining * 1_000)))
            if result == 0 { continue }
            if result < 0 {
                if errno == EINTR { continue }
                throw StatusError.unavailable("Could not read from Codex app-server")
            }
            var bytes = [UInt8](repeating: 0, count: 65_536)
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw StatusError.unavailable("Could not read from Codex app-server")
            }
            return Data(bytes.prefix(count))
        }
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
            dashboardURL: URL(string: "https://chatgpt.com/codex/settings/usage")!,
            planLabel: plan,
            versionLabel: versionLabel
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
