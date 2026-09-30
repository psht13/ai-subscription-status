# AI Subscription Status

A native macOS menu-bar utility for the locally authenticated Codex CLI.

The menu-bar percentage is the lowest known remaining quota across providers that expose live quota data. Colors follow the reference behavior: normal above 20%, orange at 11–20%, and red at 10% or below.

## Data sources

- GPT / Codex: live ChatGPT plan windows and credits through `codex app-server` and `account/rateLimits/read`.

## Build and install

```sh
./Scripts/build-app.sh
open "$HOME/Applications/AI Subscription Status.app"
```

The app refreshes every five minutes and whenever its menu opens after being stale for 90 seconds. `⌘R` refreshes immediately.

## Idle CLI updates

Open **CLI Updates** in the menu and enable **Automatically Update When Idle** to opt in. Automatic checks run every 12 hours. A CLI with an active terminal, IDE, daemon, or agent process is skipped and retried after 15 minutes.

- Codex uses its supported `codex update` command.
Automatic updates are off by default. **Update Idle CLIs Now** performs the same idle checks on demand, so it never deliberately updates a CLI with a detected active process. A process can still start in the small interval after the final check, so the app also relies on each CLI's own updater locking and atomic replacement behavior.

Run the focused parser checks with `swift run AISubscriptionStatus --self-test`.
Use `swift run AISubscriptionStatus --dump-status` to print the live, credential-safe menu rows in Terminal.
Use `swift run AISubscriptionStatus --dump-update-plan` to inspect the resolved update commands and idle/busy decisions without executing an update.
