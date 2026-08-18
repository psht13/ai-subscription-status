import Foundation

final class KimiStatusProvider {
    private let executable: String?
    private var versionLabel: String? {
        executable.flatMap { ProcessRunner.version(executable: $0, productName: "Kimi") }
    }
    private let operationLock = NSLock()
    private var ownedServer: Process?
    private var activePort: Int?

    init() {
        executable = ExecutableLocator.find(
            "kimi",
            preferred: ["~/.kimi-code/bin/kimi"]
        )
    }

    func fetch() -> ProviderSnapshot {
        operationLock.withLock {
            fetchLocked()
        }
    }

    func stop() {
        operationLock.withLock {
            if let ownedServer, ownedServer.isRunning {
                ownedServer.terminate()
                let deadline = Date().addingTimeInterval(2)
                while ownedServer.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            ownedServer = nil
            activePort = nil
        }
    }

    private func fetchLocked() -> ProviderSnapshot {
        guard executable != nil else {
            return unavailableSnapshot(message: "Kimi CLI was not found")
        }

        do {
            let connection = try ensureServer()
            let url = URL(
                string: "http://127.0.0.1:\(connection.port)/api/v1/oauth/usage?provider=managed%3Akimi-code"
            )!
            let response = try SynchronousHTTP.get(
                url: url,
                bearerToken: connection.token,
                timeout: 15
            )
            guard response.statusCode == 200 else {
                throw StatusError.unavailable("Kimi usage request returned HTTP \(response.statusCode)")
            }
            let object = try JSONSerialization.jsonObject(with: response.data)
            guard let envelope = object as? [String: Any],
                  let data = envelope["data"] as? [String: Any] else {
                throw StatusError.invalidResponse("Kimi returned an invalid usage response")
            }
            if JSONAccess.string(data["kind"]) == "error" {
                throw StatusError.unavailable(
                    JSONAccess.string(data["message"]) ?? "Kimi could not read account usage"
                )
            }
            return KimiStatusParser.parse(
                data: data,
                versionLabel: versionLabel,
                modelLabel: configuredModelLabel()
            )
        } catch {
            return unavailableSnapshot(message: error.localizedDescription)
        }
    }

    private func ensureServer() throws -> (port: Int, token: String) {
        if let activePort,
           let token = readServerToken(),
           serverResponds(port: activePort, token: token) {
            return (activePort, token)
        }

        activePort = nil
        if let ownedServer, !ownedServer.isRunning {
            self.ownedServer = nil
        }

        if let token = readServerToken() {
            for port in 58_627...58_638 where serverResponds(port: port, token: token) {
                activePort = port
                return (port, token)
            }
        }

        guard let executable else {
            throw StatusError.executableNotFound("Kimi")
        }

        for port in 58_631...58_640 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [
                "web",
                "--port", String(port),
                "--no-open",
                "--log-level", "silent",
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                continue
            }

            for _ in 0..<80 {
                if let token = readServerToken(), serverResponds(port: port, token: token) {
                    ownedServer = process
                    activePort = port
                    return (port, token)
                }
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.1)
            }

            if process.isRunning {
                process.terminate()
            }
        }

        throw StatusError.timedOut("Kimi local usage server did not become ready")
    }

    private func serverResponds(port: Int, token: String) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/v1/meta"),
              let response = try? SynchronousHTTP.get(
                url: url,
                bearerToken: token,
                timeout: 0.8
              ) else {
            return false
        }
        return response.statusCode == 200
    }

    private func readServerToken() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/server.token")
        guard let value = try? String(contentsOf: path, encoding: .utf8) else {
            return nil
        }
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func configuredModelLabel() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/config.toml")
        guard let config = try? String(contentsOf: path, encoding: .utf8) else {
            return nil
        }
        for line in config.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("default_model"),
                  let firstQuote = trimmed.firstIndex(of: "\""),
                  let lastQuote = trimmed.lastIndex(of: "\""),
                  firstQuote < lastQuote else {
                continue
            }
            let raw = String(trimmed[trimmed.index(after: firstQuote)..<lastQuote])
            let model = raw.split(separator: "/").last.map(String.init) ?? raw
            if model.lowercased() == "k3" { return "K3" }
            return model
                .replacingOccurrences(of: "kimi-for-coding-highspeed", with: "K2.7 HighSpeed")
                .replacingOccurrences(of: "kimi-for-coding", with: "K2.7")
        }
        return nil
    }

    private func unavailableSnapshot(message: String) -> ProviderSnapshot {
        ProviderSnapshot(
            id: .kimi,
            name: "Kimi",
            detail: [configuredModelLabel(), versionLabel].compactMap { $0 }.joined(separator: " · "),
            health: .unavailable,
            metrics: [],
            footer: message,
            dashboardURL: URL(string: "https://www.kimi.com/code/console?from=kfc_overview_topbar")!
        )
    }
}

private enum SynchronousHTTP {
    struct Response {
        let statusCode: Int
        let data: Data
    }

    static func get(url: URL, bearerToken: String, timeout: TimeInterval) throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var capturedData: Data?
        var capturedResponse: URLResponse?
        var capturedError: Error?

        let task = session.dataTask(with: request) { data, response, error in
            resultLock.withLock {
                capturedData = data
                capturedResponse = response
                capturedError = error
            }
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            throw StatusError.timedOut("Request to \(url.host ?? "provider") timed out")
        }
        session.finishTasksAndInvalidate()

        return try resultLock.withLock {
            if let capturedError { throw capturedError }
            guard let response = capturedResponse as? HTTPURLResponse else {
                throw StatusError.invalidResponse("Provider returned no HTTP response")
            }
            return Response(statusCode: response.statusCode, data: capturedData ?? Data())
        }
    }
}

enum KimiStatusParser {
    static func parse(
        data: [String: Any],
        versionLabel: String?,
        modelLabel: String?
    ) -> ProviderSnapshot {
        var rows: [[String: Any]] = []
        if let summary = data["summary"] as? [String: Any] {
            rows.append(summary)
        }
        if let limits = data["limits"] as? [[String: Any]] {
            rows.append(contentsOf: limits)
        } else if let limits = data["limits"] as? [Any] {
            rows.append(contentsOf: limits.compactMap { $0 as? [String: Any] })
        }

        let metrics = rows.compactMap(parseRow)
        var detailParts = ["OAuth"]
        if let modelLabel { detailParts.append(modelLabel) }
        if let versionLabel { detailParts.append(versionLabel) }

        return ProviderSnapshot(
            id: .kimi,
            name: "Kimi",
            detail: detailParts.joined(separator: " · "),
            health: metrics.isEmpty ? .warning : .ready,
            metrics: metrics,
            footer: extraUsageFooter(data["extra_usage"]),
            dashboardURL: URL(string: "https://www.kimi.com/code/console?from=kfc_overview_topbar")!
        )
    }

    private static func parseRow(_ row: [String: Any]) -> StatusMetric? {
        guard let used = JSONAccess.double(row["used"]),
              let limit = JSONAccess.double(row["limit"]),
              limit > 0 else {
            return nil
        }
        let usedPercent = max(0, min(100, used / limit * 100))
        let remaining = 100 - usedPercent
        let label = JSONAccess.string(row["label"])
            ?? JSONAccess.string(row["name"])
            ?? windowLabel(row["window"])
            ?? "Quota"

        var resetText = JSONAccess.string(row["reset_hint"])
        if resetText == nil,
           let rawDate = JSONAccess.string(row["reset_at"]),
           let date = parseISO8601(rawDate) {
            resetText = StatusFormatting.resetText(for: date)
        }

        return StatusMetric(
            label: label,
            value: "\(StatusFormatting.percent(remaining))% left",
            remainingPercent: remaining,
            resetText: resetText
        )
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func windowLabel(_ value: Any?) -> String? {
        guard let window = value as? [String: Any],
              let duration = JSONAccess.int(window["duration"]),
              let unit = JSONAccess.string(window["unit"]) else {
            return nil
        }
        let suffix: String
        switch unit {
        case "minute": suffix = "m"
        case "hour": suffix = "h"
        case "day": suffix = "d"
        case "week": suffix = "w"
        default: suffix = unit
        }
        return "\(duration)\(suffix) limit"
    }

    private static func extraUsageFooter(_ value: Any?) -> String? {
        guard let extra = value as? [String: Any],
              let balanceCents = JSONAccess.double(extra["balance_cents"]),
              let currency = JSONAccess.string(extra["currency"]) else {
            return nil
        }
        let amount = balanceCents / 100
        return String(format: "Extra usage: %.2f %@ available", amount, currency)
    }
}
