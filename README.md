# Claude Companion

A small macOS menu bar app for people who use [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with more than one account. It also helps if you just don't want to keep checking the terminal.

- **Account switcher.** Pick Personal, Work or Backup (or add your own) from the menu bar. New `claude` sessions use that account.
- **Notifications** when Claude finishes, needs permission, or is waiting for you. Each one shows the account, the project and Claude's last message. Clicking one takes you to that exact session: the right Terminal or iTerm2 tab, or the right VS Code (or Cursor/Windsurf) window with the Claude conversation open. The first time, macOS asks to let Claude Companion control Terminal; that's what selects the right tab.
- **A menu bar popover** in a warm "Ember" style: account avatars, the 5-hour window as a ring, today's cost, a 7-day trend, and an activity feed with an **Open** button for sessions waiting on you. The menu bar icon shows when Claude is working or needs you.
- **A different sound** for each account and event, so you can tell which account finished without looking. You can import your own sounds.
- **Flick**, a little animated ember who shows what Claude is doing: he flickers while Claude works, hops when a session needs your OK, cheers when it's done and naps when it's quiet. His friendly messages can be turned off in Settings › Flick.
- **Sessions window** (⌥⌘S): every running and recent session across accounts, with how long it has run, what it cost, and a button to jump back to it.
- **Usage alerts** you can turn on or off one by one: monthly budget per account (80% and 100%), a busy 5-hour window, a window that just reset, and a daily summary.
- **Global shortcuts** you can record yourself: switch accounts (⌥⌘1/2/3 by default), open the menu (⌥⌘C), show sessions (⌥⌘S).
- **Make Flick yours:** Ember, Glacier, Mint or the active account's color; small, medium or large; and a calm mode that keeps him still.
- **Usage dashboard** for all accounts: the current 5-hour window, today, and the last 7 or 30 days. It includes a daily chart and breakdowns by model and project. Export any view as CSV.

> Unofficial community project. Not affiliated with or endorsed by Anthropic.

## Install

Paste this in Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/remi-dc/claude-companion/main/install.sh | sh
```

It downloads the latest release (a universal app for Apple Silicon and Intel), installs it in `/Applications` and launches it. Then click the chat-bubble icon in the menu bar and **Install** in the orange banner. That's it.

You need macOS 14 (Sonoma) or later and [Claude Code](https://docs.anthropic.com/en/docs/claude-code). You can [read the script](install.sh) before running it.

**Updates are built in.** The app checks GitHub for a new release every few hours. When there is one, a banner in the popover offers **Update**: it downloads the new version, checks it, swaps it in and relaunches. You can also use Settings › Setup › **Check for updates**. The check is one anonymous request to GitHub's public API.

> **Why a Terminal command and not a download link?** The app isn't notarized by Apple (that needs a paid developer account), so macOS blocks it when it's downloaded in a browser. Downloads made with `curl` don't get that block.

### Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`):

```sh
git clone https://github.com/remi-dc/claude-companion.git
cd claude-companion
./scripts/build.sh --install   # builds, copies to /Applications, launches
```

`./scripts/build.sh` on its own builds `build/Claude Companion.app` without installing it; `--universal --zip` makes a release zip. The app icon is generated from code, so there are no image assets to manage. The app has no Dock icon; look for it in the menu bar.

## Setup

Open the menu bar icon → **Settings** → **Setup** and work through the steps:

0. **Allow notifications.** macOS asks on first launch. If you missed the prompt, use **Open Notification Settings**. Until you allow them, you get plain AppleScript banners (shown as "Script Editor"). Sounds play either way.
1. **Install hooks.** This adds `Stop`, `Notification`, `UserPromptSubmit` and `PostToolUse` hooks to each account's `settings.json`. The hooks hand events to the app in the background, so Claude waits only a few milliseconds. If you installed hooks with an earlier version, the button reads **Update hooks**. A `settings.json.companion-backup` copy is saved first, and your other settings and hooks are kept.
2. **Install shell integration.** This installs a `claude` wrapper in `~/.claude-companion/bin` and adds one line to `~/.zshrc` to put it on your PATH. Open a new terminal tab afterwards.
3. **VS Code** (optional). **Configure** sets the Claude Code extension's `claudeCode.claudeProcessWrapper` setting so the extension follows the active account too. It also works for Cursor, Windsurf and VS Code Insiders. Your editor settings keep their comments and formatting, and a backup is saved.
4. **Log in to each account.** Go to Settings → Accounts → **Log in…** and type `/login` in the Terminal window that opens. If you use several browser profiles (say a Work profile in Chrome), pick it under **Sign in with** for that account first: the sign-in page then opens there, both for **Log in…** and for `/login` inside a session.
5. **Test.** The buttons send sample notifications.

Default accounts:

| Account | Config directory | "Finished" sound |
| --- | --- | --- |
| Personal | `~/.claude` (Claude Code's default) | Glass |
| Work | `~/.claude-work` | Hero |
| Backup | `~/.claude-backup` | Purr |

You can rename accounts, change their directories, or add more in Settings → Accounts. Re-run **Install hooks** after adding one.

## How it works

**Account switching.** Each account is a separate Claude Code config directory (`CLAUDE_CONFIG_DIR`), so it has its own login, settings and history. The menu bar writes the active directory to `~/.claude-companion/active-config-dir`. The `claude` wrapper reads that file, exports `CLAUDE_CONFIG_DIR`, and runs the real `claude`. The Personal account (`~/.claude`) leaves the variable unset. The wrapper does nothing if you've set `CLAUDE_CONFIG_DIR` yourself or set `CLAUDE_COMPANION_BYPASS=1`. In VS Code, the extension runs `claude-vscode-wrapper <bundled claude> <args>`. That wrapper applies the same rule and then runs the bundled binary.

**Notifications.** The hooks run `~/.claude-companion/bin/claude-companion-hook`, a tiny shim that calls the app binary in CLI mode. The app rewrites the shim on every launch, so moving the app doesn't break it. The CLI reads the hook JSON from stdin and passes the event to the running app, which plays the account's sound and posts the notification. If the app isn't running, the CLI shows an AppleScript notification itself. Hooks exit 0 in well under a second and never block Claude.

**Usage.** The app reads Claude Code's local transcripts in `<config dir>/projects/**/*.jsonl` (last 35 days). It removes duplicate responses and prices tokens at Anthropic API list prices, including cache reads and writes. It refreshes every minute and after each finished turn.

## Command line

The app binary has a few CLI subcommands:

```sh
APP="/Applications/Claude Companion.app/Contents/MacOS/ClaudeCompanion"
"$APP" usage              # per-account usage summary in the terminal
"$APP" check-update       # compare with the latest GitHub release
"$APP" open dashboard     # show the dashboard (or: open settings)
"$APP" open popover       # show the menu bar popover in a regular window (handy for screenshots)
"$APP" render-icon <dir>  # write the app icon PNGs (used by build.sh)
```

## Publishing a release (maintainers)

```sh
./scripts/release.sh 1.2.0 "What's new, in one line"
```

It bumps the version, builds the universal app, commits, pushes and creates the GitHub release. Every running copy then offers the update within a few hours. It needs the [GitHub CLI](https://cli.github.com) (`gh auth login`).

## Troubleshooting

- **No notifications from real sessions, but the test buttons work:** the hooks aren't installed. The popover shows an orange banner with **Install** when that's the case. Sessions opened before installing need a restart, because Claude Code loads hooks when a session starts.
- **Notifications appear in Notification Center but don't pop up:** your display is probably mirrored or shared. Turn on "Allow notifications when mirroring or sharing the display" in System Settings › Notifications.
- **See what a hook sends:** `echo '{"cwd":"/tmp/x"}' | CLAUDE_COMPANION_DEBUG=1 "/Applications/Claude Companion.app/Contents/MacOS/ClaudeCompanion" hook stop --account personal`

## Limitations

- The **Claude desktop app** always uses the Personal account (`~/.claude`). Notifications still work for it.
- **Sessions that are already running** keep their account. Switching only affects new terminal sessions and new VS Code conversations.
- **Costs are estimates** at API list prices. Subscription plans (Pro or Max) aren't billed per token, and your plan's actual usage-limit percentage isn't stored locally. Use the numbers to compare accounts and spot heavy sessions.
- Model prices are hard-coded in `Sources/ClaudeCompanion/Usage.swift`. Update them when pricing changes.

## Uninstall

1. Settings → Setup → **Remove hooks**, and **Remove** next to each configured editor
2. Delete the `# Claude Companion` line from `~/.zshrc`
3. Quit the app, then delete `/Applications/Claude Companion.app` and `~/.claude-companion`

Your Claude Code config directories, logins and history are left as they are. The `*.companion-backup` files next to your settings can be deleted once you're happy.

## Project layout

```text
Sources/ClaudeCompanion/
  Entry.swift          app entry point and CLI subcommands
  HookCLI.swift        hook handler (runs inside Claude Code's hook)
  Integration.swift    settings.json hooks, claude wrapper, login helper
  Notifier.swift       notifications and sounds
  Flick.swift          the animated mascot
  Theme.swift          Ember colors and shared styles
  MenuBarIcon.swift    menu bar glyph and its states
  AppIcon.swift        app icon, rendered at build time
  Usage.swift          transcript parser, pricing, aggregations
  AppState.swift       app state
  WindowManager.swift  dashboard and settings windows
  Views/               menu bar, dashboard, settings
scripts/build.sh       builds the .app bundle
```

## License

MIT. See [LICENSE](LICENSE).
