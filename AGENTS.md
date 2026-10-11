# AGENTS.md

Guidance for coding agents (and people) working on Claude Switcher. User-facing docs live in [README.md](README.md).

## What this is

A macOS menu bar app (AppKit, no SwiftUI) that launches one copy of the Claude desktop app per account, each with its own `--user-data-dir` profile. It also shows each account's plan usage and the live status of its Claude Code sessions.

## Layout

| Path | Purpose |
| --- | --- |
| `main.swift` | The whole app: data model, readers for Claude's local files, menu UI, and the `--dump` CLI. |
| `build.sh` | Compiles `main.swift` with `swiftc`, writes the bundle and `Info.plist` to `~/Applications/Claude Switcher.app`, ad-hoc signs it. |
| `ping-haiku.sh` | Sends one Haiku message per Claude Code CLI login to start each 5-hour usage window. |
| `install-ping.sh` | Installs or removes (`--uninstall`) the launchd agent that runs `ping-haiku.sh`. |
| `tools/screenshots/` | Renders `docs/menu-light.png` and `docs/menu-dark.png` from demo data. |
| `docs/` | README images only. |

There is no Xcode project, Swift package, dependency or test target, and that's intentional. Keep it a single `main.swift` that builds with one `swiftc` call.

## Build, run, check

```bash
# Type-check and print what the menu would show, without installing anything.
swiftc -swift-version 5 main.swift -o /tmp/ClaudeSwitcher && /tmp/ClaudeSwitcher --dump

# Install into ~/Applications and restart the running copy.
./build.sh
osascript -e 'tell application id "local.mueed.claude-switcher" to quit'
open ~/Applications/"Claude Switcher.app"

# Re-render the README screenshots after any visible menu change.
./tools/screenshots/make.sh
```

There are no automated tests. Verify changes this way:

1. `--dump` for data and parsing changes. It prints every account, its status line, and its Code sessions.
2. `tools/screenshots/make.sh` for menu layout changes. Look at both PNGs in `docs/`. It works without Screen Recording permission because the app draws its own menu windows into images. A spare menu bar icon flashes while it runs.
3. For menu behavior that can't be rendered (hover, clicks, keyboard), say what you couldn't check rather than claiming it works.

## Where the data comes from

All of these are internal files of Claude for Mac or Claude Code, not public APIs. Read them defensively: every field is optional, a missing or unparsable file must degrade gracefully, and never write to them.

| Data | Source |
| --- | --- |
| Account list | `~/Library/Application Support/ClaudeSwitcher/accounts.json`, the only file this app writes. Seeded with five slots on first run. |
| Running apps and session processes | `ps -axww -o pid=,command=`. A main app process is `/Applications/Claude.app/Contents/MacOS/Claude` with `--user-data-dir=<profile>`; no flag means the default `Claude` profile. A Code session process is a binary under `<profile>/claude-code/`. |
| Session title, project and status | `~/.claude/sessions/<pid>.json`: `name`, `cwd`, `status` (`busy` / `waiting` / `idle`), `waitingFor` (`"permission prompt"`, `"input needed"`, …), `statusUpdatedAt` in ms. Desktop sessions don't set `CLAUDE_CONFIG_DIR`, so every account writes here. |
| Plan usage | `<profile>/plan-usage-history.json`: last entry of `samples`, with `t` (ms), `u.fh` (5-hour %) and `u.sd` (7-day %). Only updated while that profile's app runs. |
| Account email | `<profile>/config.json` → `lastKnownAccountUuid`, matched against `oauthAccount.accountUuid` / `emailAddress` in `~/.claude.json`, `~/.claude.json.*` and `~/.claude-*/.claude.json`. |

## Conventions

- Swift 5 language mode, AppKit only, `@MainActor` on the app delegate. The minimum is macOS 14.4 because the menu relies on `NSMenuItem.subtitle`; keep `LSMinimumSystemVersion` in `build.sh` in sync if that changes.
- Match the existing style: small value types (`Account`, `Usage`, `CodeSession`, `ProcessSnapshot`) with static loaders, and short comments only where the reason isn't obvious from the code.
- The menu is rebuilt from scratch in `menuNeedsUpdate`; a 20-second timer refreshes the menu bar count. Keep reads cheap, since they run every time the menu opens.
- Don't change the bundle ID (`local.mueed.claude-switcher`) or the launchd label (`local.mueed.claude-ping`). Existing installs depend on them for Open at Login and for removing the ping agent.

## Gotchas

- An `NSMenuItem` with a submenu never sends its own action. That's why a running account's **Switch to…** and **Quit…** live inside its submenu. Put the ⌘ number on the submenu's **Switch to…** item: `NSMenu.performKeyEquivalent` recurses into submenus and fires it.
- Match profile paths with a trailing separator (`path + "/claude-code/"`, `path + " --"`). Otherwise `Claude-Desktop` would also match `Claude-Desktop-2`.
- `ping-haiku.sh` runs under launchd's bare `PATH`, so it looks for `claude` in fixed install locations rather than relying on `PATH`.

## Privacy

Real menus contain account emails, client names and session titles. Never commit screenshots, logs or `--dump` output from a real machine. Use `tools/screenshots/make.sh`, which only renders the demo accounts defined in `tools/screenshots/harness.swift`.
