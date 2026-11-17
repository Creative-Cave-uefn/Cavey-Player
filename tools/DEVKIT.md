# Cavey DevKit · Windows terminal workspace

Cavey DevKit is a **local** PowerShell 5.1 console. No npm/Bun/Node dependency is required. The UI follows a compact boxed terminal layout and command palette from the supplied Workbench CLI visual reference; no reference branding or agent backend is bundled.

## Install / update

Open PowerShell **inside the Cavey-Player repository**:

```powershell
git fetch origin
git switch feat/keivi-devkit-20261117
git pull --ff-only origin feat/keivi-devkit-20261117

# One-time setup: creates Desktop and Start Menu shortcuts
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\install-devkit-shortcuts.ps1

# Or launch directly without installing shortcuts
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\cavey-devkit.ps1
```

**Cavey DevKit** shortcut opens the visual command palette. **Cavey DevKit Terminal** shortcut opens a real, interactive Windows PowerShell session in the project directory.

## Keyboard and commands

| Action | Command / shortcut |
| --- | --- |
| Interactive shell within DevKit | `Ctrl+J` or `/terminal` |
| Return from child PowerShell session | `exit` |
| Run PowerShell directly | `git status`, `dir`, `cd`, `flutter --version` |
| DevKit commands | `/` or `/help` |
| Autocomplete | `Tab` |
| Navigate suggestions/history | `↑` and `↓` |
| Edit input | `←`, `→`, `Home`, `End`, `Backspace`, `Delete` |
| Redraw | `Ctrl+L` or `/clear` |
| Change project folder | `/project C:\path\to\repo` |
| Launch installed Claude Code | `/agent` |
| Quit | `/quit` |

Commands without `/` run in the DevKit PowerShell runspace, so `cd` remains effective while DevKit is open. `/terminal` starts a nested PowerShell process supporting real interactive programs; use `exit` to return to DevKit.

## Build and development

Existing `/branches`, `/build`, `/releases`, `/clean`, `/history`, `/logs`, `/run` and `/doctor` commands are retained. Run `powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test-cavey-devkit.ps1` to validate PowerShell syntax and smoke-test CLI help.

## Notes

- Shortcuts use the local checkout, create no service, and require no administrator permissions.
- The shell executes only user-entered commands.
- For best rendering, use Windows Terminal or a UTF-8-capable console. Redirected input/output falls back to a normal prompt.
- If you move the repository, rerun the shortcut installer.
- `/agent` starts an already installed Claude Code CLI. DevKit itself does not incorporate the referenced project's AI functionality.
