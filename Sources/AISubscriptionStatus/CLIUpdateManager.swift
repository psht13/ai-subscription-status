import Darwin
import Foundation

enum CLIUpdateResultState: String {
    case current
    case updated
    case busy
    case failed
    case unavailable
}

struct CLIUpdateResult {
    let providerID: ProviderID
    let state: CLIUpdateResultState
    let detail: String
    let checkedAt: Date
}

struct CLIUpdateRun {
    let results: [CLIUpdateResult]
    let completedAt: Date
    let automatic: Bool
}

struct CLIUpdatePreview {
    let providerID: ProviderID
    let executable: String?
    let inUse: Bool
    let commandDescription: String
}

private enum CLIUpdateStrategy {
    case selfUpdate(arguments: [String])
    case kimiNative
}

private struct CLIUpdateSpec {
    let providerID: ProviderID
    let executable: String?
    let strategy: CLIUpdateStrategy
    let commandDescription: String
}

final class CLIUpdateManager {
    static let automaticCheckInterval: TimeInterval = 12 * 60 * 60
    static let retryInterval: TimeInterval = 15 * 60

    private let preferences: CLIUpdatePreferences

    init(defaults: UserDefaults = .standard) {
        preferences = CLIUpdatePreferences(defaults: defaults)
    }

    var automaticUpdatesEnabled: Bool {
        get { preferences.automaticUpdatesEnabled }
        set { preferences.automaticUpdatesEnabled = newValue }
    }

    func shouldRunAutomaticUpdate(now: Date = Date()) -> Bool {
        guard automaticUpdatesEnabled else { return false }
        return ProviderID.enabledCases.contains { preferences.isDue($0, now: now) }
    }

    func savedResults() -> [CLIUpdateResult] {
        ProviderID.enabledCases.compactMap(preferences.savedResult)
    }

    func preview() -> [CLIUpdatePreview] {
        let processes = (try? RunningProcessScanner.snapshot()) ?? []
        let ignored = RunningProcessScanner.statusAppProcessTree(in: processes)
        return specs().map { spec in
            CLIUpdatePreview(
                providerID: spec.providerID,
                executable: spec.executable,
                inUse: spec.executable.map {
                    CLIIdleDetector.isInUse(
                        providerID: spec.providerID,
                        executable: $0,
                        processes: processes,
                        ignoredProcessIDs: ignored
                    )
                } ?? false,
                commandDescription: spec.commandDescription
            )
        }
    }

    func performUpdates(
        force: Bool,
        prepareForUpdate: (ProviderID) -> Void
    ) -> CLIUpdateRun {
        let automatic = !force
        let now = Date()
        let dueSpecs = specs().filter { force || preferences.isDue($0.providerID, now: now) }
        var results: [CLIUpdateResult] = []

        for spec in dueSpecs {
            let checkedAt = Date()
            guard let executable = spec.executable else {
                let result = CLIUpdateResult(
                    providerID: spec.providerID,
                    state: .unavailable,
                    detail: "CLI not found",
                    checkedAt: checkedAt
                )
                preferences.record(result)
                results.append(result)
                continue
            }

            do {
                let processes = try RunningProcessScanner.snapshot()
                let ignored = RunningProcessScanner.statusAppProcessTree(in: processes)
                if CLIIdleDetector.isInUse(
                    providerID: spec.providerID,
                    executable: executable,
                    processes: processes,
                    ignoredProcessIDs: ignored
                ) {
                    let result = CLIUpdateResult(
                        providerID: spec.providerID,
                        state: .busy,
                        detail: "in use · will retry",
                        checkedAt: checkedAt
                    )
                    preferences.record(result)
                    results.append(result)
                    continue
                }

                prepareForUpdate(spec.providerID)

                let finalProcesses = try RunningProcessScanner.snapshot()
                let finalIgnored = RunningProcessScanner.statusAppProcessTree(in: finalProcesses)
                if CLIIdleDetector.isInUse(
                    providerID: spec.providerID,
                    executable: executable,
                    processes: finalProcesses,
                    ignoredProcessIDs: finalIgnored
                ) {
                    let result = CLIUpdateResult(
                        providerID: spec.providerID,
                        state: .busy,
                        detail: "became active · will retry",
                        checkedAt: checkedAt
                    )
                    preferences.record(result)
                    results.append(result)
                    continue
                }

                let result = update(spec: spec, executable: executable, checkedAt: checkedAt)
                preferences.record(result)
                results.append(result)
            } catch {
                let result = CLIUpdateResult(
                    providerID: spec.providerID,
                    state: .failed,
                    detail: "failed · \(compactError(error))",
                    checkedAt: checkedAt
                )
                preferences.record(result)
                results.append(result)
            }
        }

        return CLIUpdateRun(results: results, completedAt: Date(), automatic: automatic)
    }

    private func update(
        spec: CLIUpdateSpec,
        executable: String,
        checkedAt: Date
    ) -> CLIUpdateResult {
        let before = ProcessRunner.bareVersion(executable: executable) ?? "unknown"
        var expectedVersion: String?

        do {
            switch spec.strategy {
            case let .selfUpdate(arguments):
                let command = try CLICommandRunner.run(
                    executable: executable,
                    arguments: arguments,
                    environment: updateEnvironment(for: executable),
                    timeout: 10 * 60
                )
                guard command.exitCode == 0 else {
                    throw CLIUpdateError.commandFailed(command.summary)
                }

            case .kimiNative:
                let check = try CLICommandRunner.run(
                    executable: executable,
                    arguments: ["update"],
                    timeout: 90
                )
                guard check.exitCode == 0 else {
                    throw CLIUpdateError.commandFailed(check.summary)
                }
                if KimiUpdateOutput.isCurrent(check.output) {
                    return CLIUpdateResult(
                        providerID: spec.providerID,
                        state: .current,
                        detail: "up to date · \(before)",
                        checkedAt: checkedAt
                    )
                }
                guard let target = KimiUpdateOutput.targetVersion(check.output) else {
                    throw CLIUpdateError.invalidOutput("Kimi did not return an update version")
                }
                expectedVersion = target

                guard executable.hasSuffix("/.kimi-code/bin/kimi") else {
                    throw CLIUpdateError.invalidOutput(
                        "Kimi's current install source needs a manual update"
                    )
                }

                let installDirectory = URL(fileURLWithPath: executable)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .path
                var environment = ProcessInfo.processInfo.environment
                environment["KIMI_VERSION"] = target
                environment["KIMI_INSTALL_DIR"] = installDirectory
                environment["KIMI_NO_MODIFY_PATH"] = "1"

                let install = try CLICommandRunner.run(
                    executable: "/bin/bash",
                    arguments: [
                        "-c",
                        "set -o pipefail; /usr/bin/curl -fsSL https://code.kimi.com/kimi-code/install.sh | /bin/bash",
                    ],
                    environment: environment,
                    timeout: 10 * 60
                )
                guard install.exitCode == 0 else {
                    throw CLIUpdateError.commandFailed(install.summary)
                }
            }

            let after = ProcessRunner.bareVersion(executable: executable) ?? before
            if let expectedVersion, expectedVersion != before, after == before {
                throw CLIUpdateError.invalidOutput(
                    "updater completed, but Kimi remained on \(before)"
                )
            }
            if after != before {
                return CLIUpdateResult(
                    providerID: spec.providerID,
                    state: .updated,
                    detail: "updated \(before) → \(after)",
                    checkedAt: checkedAt
                )
            }
            return CLIUpdateResult(
                providerID: spec.providerID,
                state: .current,
                detail: "up to date · \(after)",
                checkedAt: checkedAt
            )
        } catch {
            return CLIUpdateResult(
                providerID: spec.providerID,
                state: .failed,
                detail: "failed · \(compactError(error))",
                checkedAt: checkedAt
            )
        }
    }

    private func updateEnvironment(for executable: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let executableDirectory = URL(fileURLWithPath: executable)
            .deletingLastPathComponent()
            .path
        let existingPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let pathEntries = existingPath.split(separator: ":").map(String.init)
        if !pathEntries.contains(executableDirectory) {
            environment["PATH"] = executableDirectory + ":" + existingPath
        }
        return environment
    }

    private func specs() -> [CLIUpdateSpec] {
        [
            CLIUpdateSpec(
                providerID: .codex,
                executable: ExecutableLocator.find("codex"),
                strategy: .selfUpdate(arguments: ["update"]),
                commandDescription: "codex update"
            ),
        ]
    }

    private func compactError(_ error: Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let singleLine = raw
            .split(whereSeparator: { $0.isNewline || $0.isWhitespace })
            .joined(separator: " ")
        if singleLine.count <= 110 { return singleLine }
        return String(singleLine.prefix(107)) + "…"
    }
}

private final class CLIUpdatePreferences {
    private let defaults: UserDefaults
    private let automaticKey = "cli_updates_automatic_enabled"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var automaticUpdatesEnabled: Bool {
        get { defaults.bool(forKey: automaticKey) }
        set { defaults.set(newValue, forKey: automaticKey) }
    }

    func isDue(_ providerID: ProviderID, now: Date) -> Bool {
        guard let result = savedResult(providerID) else { return true }
        let interval: TimeInterval
        switch result.state {
        case .current, .updated:
            interval = CLIUpdateManager.automaticCheckInterval
        case .busy, .failed, .unavailable:
            interval = CLIUpdateManager.retryInterval
        }
        return now.timeIntervalSince(result.checkedAt) >= interval
    }

    func record(_ result: CLIUpdateResult) {
        defaults.set(result.state.rawValue, forKey: key(result.providerID, "state"))
        defaults.set(result.detail, forKey: key(result.providerID, "detail"))
        defaults.set(result.checkedAt, forKey: key(result.providerID, "checked_at"))
    }

    func savedResult(_ providerID: ProviderID) -> CLIUpdateResult? {
        guard let rawState = defaults.string(forKey: key(providerID, "state")),
              let state = CLIUpdateResultState(rawValue: rawState),
              let detail = defaults.string(forKey: key(providerID, "detail")),
              let checkedAt = defaults.object(forKey: key(providerID, "checked_at")) as? Date else {
            return nil
        }
        return CLIUpdateResult(
            providerID: providerID,
            state: state,
            detail: detail,
            checkedAt: checkedAt
        )
    }

    private func key(_ providerID: ProviderID, _ suffix: String) -> String {
        "cli_updates_\(providerID.defaultsName)_\(suffix)"
    }
}

struct RunningProcess: Equatable {
    let pid: Int32
    let parentPID: Int32
    let command: String
    let arguments: String
}

enum RunningProcessScanner {
    static func snapshot() throws -> [RunningProcess] {
        let commands = try ProcessRunner.output(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,comm="],
            timeout: 5
        )
        let arguments = try ProcessRunner.output(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,args="],
            timeout: 5
        )

        var argsByPID: [Int32: String] = [:]
        for line in arguments.split(separator: "\n") {
            let pieces = line.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: { $0.isWhitespace }
            )
            guard pieces.count == 2, let pid = Int32(pieces[0]) else { continue }
            argsByPID[pid] = String(pieces[1])
        }

        return commands.split(separator: "\n").compactMap { line in
            let pieces = line.split(
                maxSplits: 2,
                omittingEmptySubsequences: true,
                whereSeparator: { $0.isWhitespace }
            )
            guard pieces.count == 3,
                  let pid = Int32(pieces[0]),
                  let parentPID = Int32(pieces[1]) else {
                return nil
            }
            return RunningProcess(
                pid: pid,
                parentPID: parentPID,
                command: String(pieces[2]),
                arguments: argsByPID[pid] ?? ""
            )
        }
    }

    static func statusAppProcessTree(in processes: [RunningProcess]) -> Set<Int32> {
        let currentPID = Int32(ProcessInfo.processInfo.processIdentifier)
        var ignored = Set(
            processes.compactMap { process -> Int32? in
                let text = (process.command + " " + process.arguments).lowercased()
                if process.pid == currentPID ||
                    text.contains("ai subscription status.app/contents/macos/aisubscriptionstatus") {
                    return process.pid
                }
                return nil
            }
        )
        ignored.insert(currentPID)

        var changed = true
        while changed {
            changed = false
            for process in processes where ignored.contains(process.parentPID) {
                if ignored.insert(process.pid).inserted {
                    changed = true
                }
            }
        }
        return ignored
    }
}

enum CLIIdleDetector {
    static func isInUse(
        providerID: ProviderID,
        executable: String,
        processes: [RunningProcess],
        ignoredProcessIDs: Set<Int32>
    ) -> Bool {
        let executableLower = executable.lowercased()
        return processes.contains { process in
            guard !ignoredProcessIDs.contains(process.pid) else { return false }
            let command = process.command.lowercased()
            let arguments = process.arguments.lowercased()
            let combined = command + " " + arguments
            let basename = URL(fileURLWithPath: process.command).lastPathComponent.lowercased()

            if combined.contains(executableLower) { return true }
            switch providerID {
            case .codex:
                return basename == "codex" ||
                    basename == "codex-code-mode-host" ||
                    combined.contains("/@openai/codex") ||
                    combined.contains("/codex-darwin-")
            case .kimi:
                return basename == "kimi" ||
                    basename == "kimi-code" ||
                    combined.contains("/.kimi-code/bin/kimi")
            }
        }
    }
}

enum KimiUpdateOutput {
    static func isCurrent(_ output: String) -> Bool {
        output.lowercased().contains("already up to date")
    }

    static func targetVersion(_ output: String) -> String? {
        let pattern = #"->\s*([0-9A-Za-z.+-]+)\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
              ),
              let range = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return String(output[range])
    }
}

private struct CLICommandResult {
    let exitCode: Int32
    let output: String

    var summary: String {
        let singleLine = output
            .split(whereSeparator: { $0.isNewline || $0.isWhitespace })
            .joined(separator: " ")
        if singleLine.isEmpty { return "process exited with status \(exitCode)" }
        if singleLine.count <= 180 { return singleLine }
        return String(singleLine.suffix(180))
    }
}

private enum CLICommandRunner {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) throws -> CLICommandResult {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-subscription-update-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
            throw CLIUpdateError.commandFailed("could not create a temporary update log")
        }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw CLIUpdateError.timedOut
        }

        process.waitUntilExit()
        try? outputHandle.synchronize()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        let output = String(data: data, encoding: .utf8) ?? ""
        return CLICommandResult(exitCode: process.terminationStatus, output: output)
    }
}

private enum CLIUpdateError: LocalizedError {
    case commandFailed(String)
    case invalidOutput(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message), let .invalidOutput(message):
            return message
        case .timedOut:
            return "update timed out"
        }
    }
}

private extension ProviderID {
    var defaultsName: String {
        switch self {
        case .codex: return "gpt"
        case .kimi: return "kimi"
        }
    }
}
