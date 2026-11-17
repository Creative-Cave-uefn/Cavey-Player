# Cavey DevKit terminal UI for Windows PowerShell 5.1.
# Inspired by the compact boxed layout, command palette and status line of terminal-based coding tools.
# Everything is rendered in the local Windows console; no Node.js or webview is required.

$script:CaveyCommandCatalog = @(
    [pscustomobject]@{ name='/build';     description='Собрать тестовую версию из выбранной ветки' },
    [pscustomobject]@{ name='/branches';  description='Ветки GitHub и последние коммиты' },
    [pscustomobject]@{ name='/terminal';  description='Открыть настоящую интерактивную PowerShell-сессию' },
    [pscustomobject]@{ name='/project';   description='Просмотр или смена проекта на компьютере' },
    [pscustomobject]@{ name='/releases';  description='Тестовые релизы Cavey Player' },
    [pscustomobject]@{ name='/clean';     description='Очистка устаревших тестовых релизов' },
    [pscustomobject]@{ name='/history';   description='История локальных сборок' },
    [pscustomobject]@{ name='/logs';      description='Логи последней сборки' },
    [pscustomobject]@{ name='/run';       description='Запустить последнюю собранную версию' },
    [pscustomobject]@{ name='/status';    description='Состояние проекта и GitHub' },
    [pscustomobject]@{ name='/doctor';    description='Проверить инструменты разработки' },
    [pscustomobject]@{ name='/agent';     description='Открыть Claude Code, если установлен' },
    [pscustomobject]@{ name='/clear';     description='Перерисовать интерфейс DevKit' },
    [pscustomobject]@{ name='/help';      description='Все команды и опции' },
    [pscustomobject]@{ name='/quit';      description='Завершить DevKit' }
)
$script:CaveyInputHistory = New-Object System.Collections.ArrayList
$script:CaveyPromptRows = 10

function Get-CaveyWidth {
    try {
        $width = [Console]::WindowWidth
        if ($width -gt 0) { return [Math]::Max(22,[Math]::Min(96,$width-5)) }
    } catch {}
    return 76
}

function Write-CaveyBannerRow([string]$text, [ConsoleColor]$color, [int]$width) {
    $inner = [Math]::Max(18,$width-4)
    if ($text.Length -gt $inner) { $text = $text.Substring(0,$inner) }
    Write-Host ('  │ ' + $text.PadRight($inner) + ' │') -ForegroundColor $color
}

function Show-CaveyBanner {
    try { [Console]::Title = 'Cavey DevKit | Terminal workspace' } catch {}
    Clear-Host
    $width = Get-CaveyWidth
    $inner = $width - 2
    Write-Host ''
    Write-Host ('  ╭' + ('─' * $inner) + '╮') -ForegroundColor DarkGray
    Write-CaveyBannerRow '  ◆  C A V E Y   D E V K I T' DarkYellow $width
    Write-CaveyBannerRow '     Development workspace  ·  Windows' Gray $width
    Write-Host ('  ├' + ('─' * $inner) + '┤') -ForegroundColor DarkGray
    Write-CaveyBannerRow '     A local CLI for builds, GitHub branches and tools' White $width
    Write-CaveyBannerRow '     Type / for actions or enter PowerShell commands directly' Gray $width
    Write-Host ('  ╰' + ('─' * $inner) + '╯') -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  QUICK ACTIONS' -ForegroundColor DarkYellow
    Write-Host '  /build      Build from branch       /branches   Available branches' -ForegroundColor Gray
    Write-Host '  /terminal   Interactive shell       /project    Workspace folder' -ForegroundColor Gray
    Write-Host '  /help       All commands            /quit       Exit DevKit' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  ─────────────────────────────────────────────────────────' -ForegroundColor DarkGray
    Write-Host ('  WORKSPACE  ' + $script:Root) -ForegroundColor DarkGray
    Write-Host '  Ctrl+J  shell     Ctrl+L  clear     Tab  complete     ↑↓  history / selection' -ForegroundColor DarkGray
    Write-Host ''
}

function Get-CaveySuggestions([string]$line) {
    if (-not $line.StartsWith('/')) { return @() }
    $prefix = ($line -split '\s+',2)[0]
    return @($script:CaveyCommandCatalog | Where-Object {
        $_.name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 4)
}

function Set-CaveyTuiRow([int]$row, [string]$message, [ConsoleColor]$color) {
    $width = [Math]::Max(12,[Console]::WindowWidth-1)
    if ($row -lt 0 -or $row -ge [Console]::BufferHeight) { return }
    [Console]::SetCursorPosition(0,$row)
    [Console]::Write(' ' * $width)
    [Console]::SetCursorPosition(0,$row)
    if ($message.Length -gt $width) { $message = $message.Substring(0,$width) }
    $previous = [Console]::ForegroundColor
    try {
        [Console]::ForegroundColor = $color
        [Console]::Write($message)
    } finally {
        [Console]::ForegroundColor = $previous
    }
}

function Render-CaveyPrompt([int]$top, [string]$line, [int]$selected, [int]$cursor) {
    $suggestions = @(Get-CaveySuggestions $line)
    for ($i = 0; $i -lt 4; $i++) {
        if ($i -lt $suggestions.Count) {
            $item = $suggestions[$i]
            $marker = if ($i -eq $selected) { '  ❯ ' } else { '    ' }
            $details = ('{0,-14} {1}' -f $item.name, $item.description)
            $color = if ($i -eq $selected) { [ConsoleColor]::DarkYellow } else { [ConsoleColor]::Gray }
            Set-CaveyTuiRow ($top+$i) ($marker+$details) $color
        } elseif ($line.StartsWith('/') -or $i -ne 0) {
            Set-CaveyTuiRow ($top+$i) '' DarkGray
        } else {
            Set-CaveyTuiRow ($top+$i) '  ·  Команды PowerShell выполняются прямо здесь' DarkGray
        }
    }
    $width = [Math]::Max(20,[Math]::Min(100,[Console]::WindowWidth-5))
    $rule = '─' * ($width-2)
    Set-CaveyTuiRow ($top+4) ('  ╭' + $rule + '╮') DarkGray
    $maxView = [Math]::Max(1,$width-8)
    $start = [Math]::Max(0,$cursor-$maxView+1)
    $available = [Math]::Max(0,$line.Length-$start)
    $view = if ($available -gt 0) { $line.Substring($start,[Math]::Min($maxView,$available)) } else { '' }
    $prompt = '  │ ❯ ' + $view.PadRight($maxView) + ' │'
    Set-CaveyTuiRow ($top+5) $prompt DarkYellow
    Set-CaveyTuiRow ($top+6) ('  ╰' + $rule + '╯') DarkGray
    $footer = if ($line.StartsWith('/')) {
        '  Tab  дополнить    ↑↓  выбор    Enter  запустить    Esc  очистить'
    } else {
        '  /  команды   ·   Ctrl+J  терминал   ·   Enter  выполнить'
    }
    Set-CaveyTuiRow ($top+7) $footer DarkGray
    Set-CaveyTuiRow ($top+8) ('  LOCAL  ·  ' + $script:Root) DarkGray
    Set-CaveyTuiRow ($top+9) '' DarkGray
    $column = [Math]::Min([Console]::WindowWidth-2,6+$cursor-$start)
    [Console]::SetCursorPosition($column,$top+5)
}

function Read-CaveyCommand {
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        return (Read-Host '  ❯')
    }
    try {
        if ([Console]::WindowWidth -lt 46 -or [Console]::WindowHeight -lt 17) {
            return (Read-Host '  ❯')
        }
    } catch { return (Read-Host '  ❯') }
    for ($i = 0; $i -lt $script:CaveyPromptRows; $i++) { Write-Host '' }
    $top = [Console]::CursorTop-$script:CaveyPromptRows
    $line = ''
    $cursor = 0
    $selected = 0
    $historyIndex = $script:CaveyInputHistory.Count
    while ($true) {
        try {
            Render-CaveyPrompt $top $line $selected $cursor
            $key = [Console]::ReadKey($true)
        } catch {
            try { [Console]::SetCursorPosition(0,[Math]::Max(0,$top+$script:CaveyPromptRows)) } catch {}
            return (Read-Host '  ❯')
        }
        if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq [ConsoleKey]::J) {
            $line = '/terminal'
            $cursor = $line.Length
            break
        }
        if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq [ConsoleKey]::L) {
            $line = '/clear'
            $cursor = $line.Length
            break
        }
        if (($key.Modifiers -band [ConsoleModifiers]::Control) -and $key.Key -eq [ConsoleKey]::C) {
            $line = '/quit'
            $cursor = $line.Length
            break
        }
        if ($key.Key -eq [ConsoleKey]::Enter) {
            $suggestions = @(Get-CaveySuggestions $line)
            if ($suggestions.Count -gt 0 -and $line -notmatch '\s' -and
                ($line -eq '/' -or $suggestions.Count -eq 1)) {
                $line = $suggestions[[Math]::Min($selected,$suggestions.Count-1)].name
            }
            break
        }
        if ($key.Key -eq [ConsoleKey]::Escape) {
            $line=''; $cursor=0; $selected=0
            continue
        }
        if ($key.Key -eq [ConsoleKey]::Backspace) {
            if ($cursor -gt 0) {
                $line=$line.Remove($cursor-1,1); $cursor--
            }
            $selected=0
            continue
        }
        if ($key.Key -eq [ConsoleKey]::Delete) {
            if ($cursor -lt $line.Length) { $line=$line.Remove($cursor,1) }
            continue
        }
        if ($key.Key -eq [ConsoleKey]::LeftArrow) {
            $cursor=[Math]::Max(0,$cursor-1); continue
        }
        if ($key.Key -eq [ConsoleKey]::RightArrow) {
            $cursor=[Math]::Min($line.Length,$cursor+1); continue
        }
        if ($key.Key -eq [ConsoleKey]::Home) { $cursor=0; continue }
        if ($key.Key -eq [ConsoleKey]::End) { $cursor=$line.Length; continue }
        if ($key.Key -eq [ConsoleKey]::Tab) {
            $suggestions = @(Get-CaveySuggestions $line)
            if ($suggestions.Count -gt 0) {
                $line = $suggestions[[Math]::Min($selected,$suggestions.Count-1)].name+' '
                $cursor=$line.Length
            }
            continue
        }
        if ($key.Key -eq [ConsoleKey]::UpArrow -or $key.Key -eq [ConsoleKey]::DownArrow) {
            $suggestions = @(Get-CaveySuggestions $line)
            if ($suggestions.Count -gt 0) {
                if ($key.Key -eq [ConsoleKey]::DownArrow) { $selected=($selected+1) % $suggestions.Count }
                else { $selected=($selected+$suggestions.Count-1) % $suggestions.Count }
            } elseif ($script:CaveyInputHistory.Count -gt 0) {
                if ($key.Key -eq [ConsoleKey]::UpArrow) { $historyIndex=[Math]::Max(0,$historyIndex-1) }
                else { $historyIndex=[Math]::Min($script:CaveyInputHistory.Count,$historyIndex+1) }
                $line=if ($historyIndex -eq $script:CaveyInputHistory.Count) {
                    ''
                } else {
                    [string]$script:CaveyInputHistory[$historyIndex]
                }
                $cursor=$line.Length
            }
            continue
        }
        if (-not [char]::IsControl($key.KeyChar)) {
            $line=$line.Insert($cursor,[string]$key.KeyChar)
            $cursor++
            $selected=0
        }
    }
    for ($i=0;$i -lt $script:CaveyPromptRows;$i++) { Set-CaveyTuiRow ($top+$i) '' Gray }
    [Console]::SetCursorPosition(0,$top)
    if ($line.Trim()) {
        Write-Host ('  ❯ '+$line) -ForegroundColor DarkYellow
        [void]$script:CaveyInputHistory.Add($line)
        if ($script:CaveyInputHistory.Count -gt 200) { $script:CaveyInputHistory.RemoveAt(0) }
    }
    [Console]::SetCursorPosition(0,$top+$script:CaveyPromptRows)
    return $line
}
