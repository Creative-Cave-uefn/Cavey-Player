# Cavey DevKit · React terminal

DevKit uses [claude-code-kit](https://github.com/Minnzen/claude-code-kit) 0.4.0 and React 19.2.4. The old PowerShell TUI is deleted. The existing build/release command engine is kept as a **noninteractive backend**, not as another UI.

## Requirements

- Windows 10/11 with Windows Terminal recommended.
- Node.js 22+ and npm are provisioned automatically. If system Node is older, DevKit downloads **portable Node.js 22.23.5** from the official nodejs.org archive, checks SHA-256 from `SHASUMS256.txt`, and stores it in `%LOCALAPPDATA%\CaveyDevKit\runtime`. System Node remains unchanged.
- PowerShell 5.1 for build commands; Git and GitHub CLI for repository/release operations; Flutter/Inno Setup for Windows packaging.

## Update

```powershell
git fetch origin
git switch feat/keivi-devkit-20261117
git pull --ff-only origin feat/keivi-devkit-20261117
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\install-devkit-shortcuts.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\cavey-devkit.ps1
```

Existing **Cavey DevKit** shortcuts continue to use `tools/cavey-devkit.ps1`; on first launch it installs React dependencies. The **Cavey DevKit Terminal** shortcut opens a real PowerShell, not the old TUI.

## Interface

The layout follows Claude Code: a welcome box, a transcript, one spinner line while work runs, and a rounded input box with a single hint line. Every color comes from `src/theme.ts` (text, dim, border, accent, success, error, warning); components must not add others.

- **Transcript.** Typed commands appear as `> /build`. Each run is a `⏺ Title` entry with its output under `⎿`. Output is collapsed to the last lines; error lines are always kept visible and coloured. `Ctrl+O` expands or collapses all output. Builds show their stages on the first `⎿` line (`✓ Source 2s  ✓ Prepare 41s  ◆ Compile …`).
- **Status in one place.** While something runs, the spinner line shows the current stage, elapsed time, an ETA from recent builds (`history.jsonl`) and `esc to interrupt`. The window title, tab status dot and Windows Terminal taskbar progress follow the same state. A long run that finishes while the terminal is unfocused rings the bell.
- **Footer.** `? for shortcuts` on the left; project, branch, `●` for uncommitted changes and `↑/↓` for ahead/behind on the right. Short notices (copied text, "press Ctrl+C again") replace the left hint for a moment.
- **Dialogs.** Guided steps are questions in a rounded box (“Build which branch?”) with numbered options. Short lists pick on a digit key; long lists (branches, channels, versions) take a typed filter. Each pick is written to the transcript as one `⏺` line; Esc (or Backspace on an empty filter) goes back one step and removes that line. Confirmations show a plan (source, channel, what will be removed, checks, estimated time) instead of a one-line summary.
- **Selection.** Mouse tracking stays on for clicks and the wheel; drag to select text and it is copied immediately. `Ctrl+C` also copies an active selection.

## Keyboard

| Keys | Action |
| --- | --- |
| `/` | Core commands; type to see the rest |
| `?` | Shortcut sheet (empty input) |
| `Enter`, `Tab` | Run / complete a command, pick an option |
| `1`–`9` | Pick a numbered option |
| `↑` / `↓` | History, or move in a list |
| `Esc` | Interrupt a run · go back a step · clear input |
| `Ctrl+C` | Copy selection · interrupt · exit when pressed twice |
| `Ctrl+O` | Expand / collapse output |
| `Ctrl+F` | Search the transcript |
| `Ctrl+J` | PowerShell in a Windows Terminal tab |
| `Ctrl+L` | Clear the transcript |
| `PgUp`, `PgDn`, wheel | Scroll the transcript or a long list |

## Guided flows

`/build` asks for a branch (with last commit time, author and the channel that already carries it), then the build type: local, new test release, or update a channel (the branch's own channel is suggested first). A new test release allocates a unique channel (`devkit/<source>/<timestamp>-<random>`) and never changes an existing one. Updating a channel publishes a new numbered prerelease into it; the confirmation lists the older releases that will be pruned after a successful publish.

`/releases` opens: manage a channel (show versions, update from a branch, roll back), list all test releases, or clean up outdated ones. `/recover` lists saved builds whose verified artifacts can be published again.

The command list lives in `src/commands.ts` and feeds the palette, `/help` and aliases (`/manager` → `/releases`, `/resume` and `/retry-publish` → `/recover`).

## Commands

For an existing release channel, DevKit derives the version base from that channel before inspecting stable releases. If the GitHub CLI returns no compatible tags, it reads the source branch's `pubspec.yaml` rather than failing early.

`/build` starts a guided sequence: branch, local build or test release, confirmation. For scripts use `/build --branch latest --local --yes` or `/build --branch <name> --mode new --yes`. `/clean` asks for confirmation unless `--dry-run` or `--yes` is supplied. `/status`, `/branches`, `/releases`, `/history`, `/logs`, `/run`, `/doctor`, and `/project` call `tools/cavey-devkit-engine.ps1` with live output.

Other text (`git status`, `flutter --version`, `Get-ChildItem`) runs in a PowerShell child process. `cd` is handled by DevKit so the working directory persists between executions. **Other PowerShell variables/functions do not persist**; for prompts, REPLs or full interactive programs use `/terminal`, which opens a real PowerShell in Windows Terminal or a separate console window.

`/agent` opens installed Claude Code, if available. Cavey DevKit is not itself Claude Code or an AI agent and uses Cavey branding.

## Checks

```powershell
cd tools\devkit
npm install
npm run typecheck
npm test
cd ..\..
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test-cavey-devkit.ps1
```

Windows PowerShell 5.1 source files include a UTF-8 BOM. Run the parser/smoke-test script before shipping a revision to catch encoding regressions. The launcher preserves noninteractive usage: `powershell -File .\tools\cavey-devkit.ps1 status` calls the headless engine. The UI always uses the new React frontend without arguments.

Dependencies: `@claude-code-kit/ui` 0.4.0 and `@claude-code-kit/ink-renderer` 0.4.0, MIT license. Initial dependency installation needs internet.

## Build progress and manifests

Stage events (`@@CAVEY_STAGE|…`) stream from the engine during the build and are drawn on the build's transcript entry, then removed from the visible output. `/logs` keeps the detailed build output and `/history` the run status. Each build writes a recoverable manifest to `%LOCALAPPDATA%\CaveyDevKit\builds\<run-id>\run.json` with the source commit, version, channel, artifact paths and SHA-256 checksums.

## Release Manager · history, updates and rollback

- `/releases` → Manage a channel opens the channel selector: show versions,
  update from a branch, or roll back to an older release.
- `/releases --channel <channel>` prints the published versions.
- `/rollback --channel <channel> --to <tag> --yes` restores an earlier version by
  marking **newer** releases as GitHub drafts. Their tags and assets remain stored,
  and old binaries are **not** republished under a false newer version number.
  Existing installations already on a newer embedded APP_VERSION may require
  manual reinstallation to downgrade; rollback does not force a client downgrade.
- New test channels remain distinct from existing channels. Channel updates
  publish a new version, then keep three most recent visible test releases;
  other releases are removed only after the new release succeeds.

## Build cache, recovery and updates

- Builds reuse a persistent detached worktree keyed by **exact source commit SHA
  and Flutter version**. This safely reuses Flutter's generated build data for
  repeated builds of an unchanged revision without mixing branches or toolchains.
  `/build --branch <branch> --fresh --local --yes` forces a clean one-off worktree.
- `/cache` lists cached worktrees; `/cache prune` prompts before removing them.
  Cached worktrees remain on disk until manually pruned. Monitor free disk
  space and prune old worktrees periodically.
- `/recover` lists saved runs. `/resume --id <run-id> --yes` checks both
  artifacts' SHA-256 checksums and retries **publication only**. It refuses
  already-published tags or corrupted artifacts. Incomplete compilation still
  requires rebuilding (with the source cache available).
- `/update` fetches `feat/keivi-devkit-20261117` and fast-forwards the dedicated
  `devkit-live`/DevKit source branch if clean. Divergence and uncommitted changes
  block the operation. On a successful update, the launcher reinstalls changed
  dependencies as needed and restarts the terminal automatically (exit code 42).
