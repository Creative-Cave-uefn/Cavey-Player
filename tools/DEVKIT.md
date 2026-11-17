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

## UI design

The command palette appears **above** the input. Moving the mouse highlights an entry and clicking it executes the command. Arrow keys also change the highlighted entry, Tab completes the command and Enter executes it. The revised header keeps title, workspace path and live state aligned in a compact border. Build output remains scrollable with a fixed bottom input and status bar.

## Keyboard

| Keys | Action |
| --- | --- |
| `/` | Command palette with autocomplete |
| `Tab`, `↑` / `↓` | Complete command / navigate suggestions or history |
| `PgUp`, `PgDn` | Scroll output |
| `Ctrl+F` | Search history |
| `Ctrl+C` | Stop current operation |
| `Ctrl+J` | Open PowerShell in a Windows Terminal tab or window |
| `/clear` | Clear visible transcript |
| `/quit` | Exit |

## Interactive menus

The minimal Cavey DevKit layout uses a compact unboxed header, subdued status bar and a pinned input inspired by the Claude Code console. English is used for interface labels, statuses and instructions; only descriptions of command and selection options remain Russian. The command palette and all build/publish wizard choices use the same keyboard-and-mouse component. Slash-command suggestions, branch selection, build mode (local / new test release / update an existing channel), release-channel selection and publish confirmations appear **above** the pinned input. Hover highlights a choice and clicking selects it; `↑↓` navigates, `Enter` selects, `Esc` cancels, and typing filters long lists. `PgUp/PgDn` and the mouse wheel page through a long menu.

The `/build` wizard has **two separate publication actions**:
- **New test release** allocates a unique channel (`devkit/<source>/<timestamp>-<random>`). It never changes an existing channel. If `--mode new --channel <name>` is supplied and the channel exists, the command refuses to overwrite it and directs the user to Update.
- **Update channel** lists previously published test-release channels, accepts the selected channel and publishes a new numbered prerelease into that same channel. Older builds are removed only **after** the replacement is published successfully.
- **Local build** packages the selected source without publishing.

The branch/release selector shows up to 12 rows on sufficiently tall terminals. Wheel scrolling is active only while the mouse is over selectable rows, not the bottom hints/input or status area. The transcript scrolls under the pointer only while the mouse is over its output area; PgUp/PgDn still work anywhere.

The `/build` wizard refreshes remote refs from `origin` before displaying branches. Confirmation is mandatory before build or publication. The Release Manager also has an explicit rollback confirmation.

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

## Build Center · interactive steps and progress

The pinned Build Center shows Source → Prepare → Checks → Compile → Package → Publish.
Stage updates stream during Flutter compilation. The final transcript and `/logs` retain
the detailed build output, while `/history` records a run status. Each build writes a
recoverable manifest to `%LOCALAPPDATA%\CaveyDevKit\builds\<run-id>\run.json`.
It contains the source commit, version, channel, artifact paths and SHA-256 checksums.
The UI removes internal stage control markers from the visible transcript.

## Release Manager · history, updates and rollback

- `/manager` opens an interactive channel selector. Choose View versions,
  Update channel (select source branch), or Rollback (select an older release).
- `/manager --channel <channel>` prints the published versions.
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
