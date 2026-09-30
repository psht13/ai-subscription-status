# AI Subscription Status

A native macOS menu-bar utility for the locally authenticated Codex CLI.

The menu-bar percentage is the lowest known remaining quota across providers that expose live quota data. Colors follow the reference behavior: normal above 20%, orange at 11–20%, and red at 10% or below.

Open the menu for a readable usage summary: the plan, allowance window, percentage remaining, progress bar, reset time, and a separate credits balance. **Refresh Usage** and **Open Usage Dashboard** are directly below the summary. The installed Codex version is in **CLI Updates**.

## Data sources

- GPT / Codex: live ChatGPT plan windows and credits through `codex app-server` and `account/rateLimits/read`.

## Build and install

```sh
./Scripts/build-app.sh
open "$HOME/Applications/AI Subscription Status.app"
```

The app refreshes every five minutes, shortly after waking from sleep, and whenever its menu opens after being stale for 90 seconds. `⌘R` refreshes immediately. Failed requests retry automatically after 15 seconds, backing off to at most five minutes. The last successful usage stays visible during failures with an orange `~` percentage and an explicit stale timestamp in the menu; this cache is kept only in memory. Requests have a 30-second deadline, and the menu retains the actual error while retrying.

## Idle CLI updates

Open **CLI Updates** in the menu and enable **Automatically Update When Idle** to opt in. Automatic checks run every 12 hours. A CLI with an active terminal, IDE, daemon, or agent process is skipped and retried after 15 minutes.

- Codex uses its supported `codex update` command.
Automatic updates are off by default. **Update Idle CLIs Now** performs the same idle checks on demand, so it never deliberately updates a CLI with a detected active process. A process can still start in the small interval after the final check, so the app also relies on each CLI's own updater locking and atomic replacement behavior.

Run the parser, refresh-recovery, and app-server transport checks with `swift run AISubscriptionStatus --self-test`.
Use `swift run AISubscriptionStatus --dump-status` to print the live, credential-safe menu rows in Terminal.
Use `swift run AISubscriptionStatus --dump-update-plan` to inspect the resolved update commands and idle/busy decisions without executing an update.
