import AppKit
import Darwin

@main
struct AISubscriptionStatusApplication {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            do {
                try StatusSelfTests.run()
                print("AI Subscription Status self-tests passed")
            } catch {
                FileHandle.standardError.write(Data("Self-test failed: \(error)\n".utf8))
                Darwin.exit(1)
            }
            return
        }

        if CommandLine.arguments.contains("--dump-status") {
            StatusDiagnostics.printLiveStatus()
            return
        }

        if CommandLine.arguments.contains("--dump-update-plan") {
            StatusDiagnostics.printCLIUpdatePlan()
            return
        }

        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        application.run()
    }
}
