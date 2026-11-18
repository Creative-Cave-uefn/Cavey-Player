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
- **Queue.** Commands typed while something runs wait their turn and are listed under the spinner (`⎿ queued: …`). Esc interrupts the current run and drops the queue.
- **Build card.** A finished build shows what it produced (files and sizes, the release link when published) with clickable actions: Run, Open folder, Copy link, Build again. `/rebuild` repeats the last build — a build that created a new channel is repeated as an update of that channel — and `/open` opens the latest build folder.
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

`/build` asks for a branch (with last commit time, author and the channel that already carries it), then the build type: local, new test release, or update a DevKit channel (the branch's own DevKit channel is suggested first; CI channels cannot be updated). A new test release asks for a channel name (default: the last part of the branch, made unique) and creates `devkit/<name>`; it never changes an existing channel. Scripts that pass no `--channel` still get a unique `devkit/<source>/<timestamp>-<random>`. Updating a channel publishes a new numbered prerelease into it; the confirmation lists the older releases that will be pruned after a successful publish.

`/releases` opens: manage a channel (show versions, update from a branch, roll back), list all test releases, or clean up outdated ones. `/recover` lists saved builds whose verified artifacts can be published again.

The command list lives in `src/commands.ts` and feeds the palette, `/help` and aliases. The palette shows 8 core commands (`/build`, `/rebuild`, `/releases`, `/recover`, `/run`, `/logs`, `/doctor`, `/help`); the rest appear as you type. Aliases: `/manager` → `/releases`, `/resume` and `/retry-publish` → `/recover`.

## Commands

For an existing release channel, DevKit derives the version base from that channel before inspecting stable releases. If the GitHub CLI returns no compatible tags, it reads the source branch's `pubspec.yaml` rather than failing early.

`/build` starts a guided sequence: branch, local build or test release, confirmation. For scripts use `/build --branch latest --local --yes` or `/build --branch <name> --mode new --yes`. `/clean` asks for confirmation unless `--dry-run` or `--yes` is supplied. `/status`, `/branches`, `/releases`, `/history`, `/logs`, `/run`, `/doctor`, and `/project` call `tools/cavey-devkit-engine.ps1` with live output.

Other text (`git status`, `flutter --version`, `Get-ChildItem`) runs in a PowerShell child process. `cd` is handled by DevKit so the working directory persists between executions. **Other PowerShell variables/functions do not persist**; for prompts, REPLs or full interactive programs use `/terminal`, which opens a real PowerShell in Windows Terminal or a separate console window.

`/agent` opens installed Claude Code, if available. Cavey DevKit is not itself Claude Code or an AI agent and uses Cavey branding.

## Checks

```powershell
cd tools\devkit
npm ci
npm run typecheck
npm test
cd ..\..
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test-cavey-devkit.ps1
```

`package-lock.json` is committed: the launcher and CI install with `npm ci`, so every machine runs the same package versions. Change dependencies with `npm install <pkg>` and commit the updated lockfile.

**Screen tests.** `python3 tools/devkit/test/ui/ui_snapshots.py` (Linux or macOS, `pip install pyte`) runs the real UI in a pseudo-terminal against a throwaway Git repository, with PowerShell and `gh` replaced by the doubles in `test/ui/fakes`. It checks the palette, the build wizard (including going back), a failing build's collapsed output, the release manager, a 80×24 terminal and exit, and fails on overlapping or cut-off boxes. CI runs it on every DevKit push and uploads the screens as the `devkit-ui-screens` artifact.

Windows PowerShell 5.1 source files include a UTF-8 BOM. Run the parser/smoke-test script before shipping a revision to catch encoding regressions. The launcher preserves noninteractive usage: `powershell -File .\tools\cavey-devkit.ps1 status` calls the headless engine. The UI always uses the new React frontend without arguments.

Dependencies: `@claude-code-kit/ui` 0.4.0 and `@claude-code-kit/ink-renderer` 0.4.0, MIT license. Initial dependency installation needs internet.

## Build progress and manifests

Stage events (`@@CAVEY_STAGE|…`) stream from the engine during the build and are drawn on the build's transcript entry, then removed from the visible output. `/logs` keeps the detailed build output and `/history` the run status. Each build writes a recoverable manifest to `%LOCALAPPDATA%\CaveyDevKit\builds\<run-id>\run.json` with the source commit, version, channel, artifact paths and SHA-256 checksums.

## What gets built

- **Working copy.** "Working copy" at the top of the branch list (or `/build --working-tree --local --yes`) builds the project folder as it is now, uncommitted and untracked files included (`.gitignore` respected). DevKit snapshots it with a private Git index, so your index, stash and branch are untouched. Such builds are never published.
- **Build script.** DevKit runs the branch's own `tools/local-test-build.ps1` when it supports the DevKit parameters, so a branch that changes its build is built the way it expects; otherwise it uses DevKit's copy. The transcript says which one ran, and `run.json` records it (`buildScript`).
- **Faster builds.** "Build faster" in a local confirmation (or `--skip-checks`) skips `flutter analyze` and `flutter test`.
- **Tool versions.** Flutter, Git and Inno Setup versions go into `run.json` (`tools`). A Flutter version other than `flutterVersion` in `tools/devkit.config.json` is flagged in the build plan and in `/doctor`.
- **Code signing.** `/sign <certificate-thumbprint>` signs `cave_player.exe`, the downloader and the installer with `signtool` (Windows SDK) and a certificate from the Windows store; a published build stops if the installer signature is not valid. `/sign off` turns it off.
- **Secrets.** Publishing stops if the release notes contain the value of an environment variable that looks secret (`*SECRET*`, `*TOKEN*`, `*PASSWORD*`, …); a warning appears if `build-log.txt` contains one.

## Launch check before publishing

After packaging, DevKit unpacks the portable ZIP and runs `cave_player.exe --smoke-test=<run folder>\smoke.json`. The app (`lib/core/smoke_test.dart`) loads the native player libraries, renders one frame, writes its `APP_VERSION` and `BUILD_CHANNEL` and exits before the single-instance check, without touching user data. The build is published only if the report matches the planned version and channel. Branches older than this feature are not launched (the Verify stage shows "skipped"); `--skip-smoke` skips the check on purpose.

## Release notes and announcements

- Release notes start with an optional note for testers (`--message`, or "Yes, with a note for testers" in the confirmation), then the changes: for a channel update, commits since the commit recorded in the channel's previous release; for a new channel, what the branch adds on top of `main` (up to 30). The metadata block keeps a `Commit:` line that the next update reads. The player shows these notes in Settings → Updates.
- `/notify <discord-webhook-url>` posts every published build to Discord (channel, version, note, up to 10 changes, link). `/notify test` sends a test message, `/notify off` stops. The webhook is stored only in `%LOCALAPPDATA%\CaveyDevKit\config.json`; a failed post never fails the publication.

## Channels and retention

- **DevKit channels** are always named `devkit/…` (tags `test-devkit-…`). A name given with `--channel` is prefixed automatically. Only these channels can be updated or rolled back.
- **CI channels** (`test-<branch>-v…`) belong to GitHub Actions, which replaces them on every push to the branch and deletes them with the branch. DevKit shows them read-only; CI never deletes `devkit-*` releases.
- One retention rule everywhere: a DevKit channel keeps **3** active versions (rollback targets), a CI channel keeps 1. It is `$script:KeepPerChannel` in the engine, `KEEP_PER_CHANNEL` in `wizard.ts` and `TestBuildAdmin.devKitKeep` in the player; change all three together. `/clean` and the player's "delete old test builds" follow it unless `--keep` is given.
- Order inside a channel follows the build number in the tag, not the publication time (drafting resets it).

## Release Manager · history, updates and rollback

- `/releases` → Manage a channel: show versions, update from a branch, roll back, or undo a rollback.
- `/releases --channel <channel>` prints active and hidden versions.
- `/rollback --channel <channel> --to <tag> --yes` restores an earlier version by marking **newer** releases as GitHub drafts. Their tags and assets remain stored, and old binaries are **not** republished under a false newer version number. Installations already on a newer APP_VERSION are not downgraded.
- `/rollforward --channel <channel> --yes` makes the releases hidden by a rollback active again.
- Hidden releases are kept by `/clean` (add `--drafts` to delete them) and removed automatically after the next successful update of that channel. The update confirmation lists every release it will prune.

## Build cache, recovery and updates

- Builds reuse a persistent detached worktree keyed by **exact source commit SHA
  and Flutter version**. This safely reuses Flutter's generated build data for
  repeated builds of an unchanged revision without mixing branches or toolchains.
  `/build --branch <branch> --fresh --local --yes` forces a clean one-off worktree.
- A cached worktree is marked complete (`<cache>.ok`) only after a build in it
  finishes. A build killed mid-compile leaves no marker, and the next build of
  that commit recreates the worktree instead of reusing half-written output.
- `/cache` lists cached worktrees and whether they are ready; `/cache prune`
  prompts before removing them. Monitor free disk space and prune periodically.
- Only one build or release change runs at a time: a second DevKit window gets
  "Another DevKit window is building…". The lock (`build.lock`) is released by
  the OS if DevKit crashes.
- `/recover` lists saved runs. `/recover --id <run-id> --yes` checks both
  artifacts' SHA-256 checksums and retries **publication only**. If an earlier
  upload was interrupted and the tag already exists, DevKit compares the files on
  GitHub (name, size, SHA-256 when GitHub reports it): identical files are simply
  marked published; otherwise it stops and `--replace` deletes that release and
  uploads again. Incomplete compilation still requires rebuilding.
- Published builds must contain `Cavey-Downloader.exe`; without it the build
  stops before publishing. Its source and SHA-256 are written to `run.json` and
  to the release notes.
- `/update` fetches `feat/keivi-devkit-20261117` and fast-forwards the dedicated
  `devkit-live`/DevKit source branch if clean. Divergence and uncommitted changes
  block the operation. On a successful update, the launcher reinstalls changed
  dependencies as needed and restarts the terminal automatically (exit code 42).
