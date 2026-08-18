import Foundation

enum StatusError: LocalizedError {
    case executableNotFound(String)
    case processFailed(String)
    case timedOut(String)
    case invalidResponse(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(name):
            return "\(name) CLI was not found"
        case let .processFailed(message),
             let .timedOut(message),
             let .invalidResponse(message),
             let .unavailable(message):
            return message
        }
    }
}

enum ExecutableLocator {
    static func find(_ name: String, preferred: [String] = []) -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates = preferred.map { expandHome($0, home: home) }

        if name == "codex" {
            let nodeVersions = "\(home)/.nvm/versions/node"
            if let versionDirectories = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: nodeVersions),
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) {
                let nvmCandidates = versionDirectories
                    .sorted { lhs, rhs in
                        let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        return left > right
                    }
                    .map { $0.appendingPathComponent("bin/codex").path }
                candidates.append(contentsOf: nvmCandidates)
            }
        }

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                String($0) + "/" + name
            })
        }

        candidates.append(contentsOf: [
            "\(home)/.local/bin/\(name)",
            "\(home)/.kimi-code/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ])

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func expandHome(_ path: String, home: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return home + path.dropFirst()
    }
}

enum ProcessRunner {
    static func output(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 5
    ) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let timeoutItem = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutItem.cancel()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw StatusError.processFailed(message?.isEmpty == false ? message! : "Process exited with status \(process.terminationStatus)")
        }
        return String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func version(executable: String, productName: String) -> String? {
        guard let version = bareVersion(executable: executable) else {
            return nil
        }
        return "\(productName) \(version)"
    }

    static func bareVersion(executable: String) -> String? {
        guard let raw = try? output(executable: executable, arguments: ["--version"], timeout: 3),
              !raw.isEmpty else {
            return nil
        }
        let firstLine = raw.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? raw
        return firstLine
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .first(where: { token in
                let candidate = token.hasPrefix("v") ? String(token.dropFirst()) : token
                return candidate.first?.isNumber == true && candidate.contains(".")
            })?
            .trimmingCharacters(in: CharacterSet(charactersIn: "v"))
    }
}

enum JSONAccess {
    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func string(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = double(value) else { return nil }
        return Int(number.rounded(.towardZero))
    }
}

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
