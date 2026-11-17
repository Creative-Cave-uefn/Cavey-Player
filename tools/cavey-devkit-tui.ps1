# Cavey DevKit original terminal user interface.
# No third-party TUI source or branding is bundled.
$script:CaveyCommandCatalog = @(
    [pscustomobject]@{ name='/build';     description='Выбрать ветку, собрать и опубликовать тестовую версию' },
    [pscustomobject]@{ name='/branches';  description='Актуальные ветки GitHub по дате коммита' },
    [pscustomobject]@{ name='/releases';  description='Список тестовых обновлений Cavey Player' },
    [pscustomobject]@{ name='/clean';     description='Найти и удалить устаревшие тестовые релизы' },
    [pscustomobject]@{ name='/history';   description='История сборок на этом компьютере' },
    [pscustomobject]@{ name='/logs';      description='Последние строки журнала сборки' },
    [pscustomobject]@{ name='/run';       description='Запустить последний собранный плеер' },
    [pscustomobject]@{ name='/status';    description='Статус репозитория и локальной сборки' },
    [pscustomobject]@{ name='/doctor';    description='Проверить инструменты для Windows-сборки' },
    [pscustomobject]@{ name='/project';   description='Показать или изменить папку исходников' },
    [pscustomobject]@{ name='/agent';     description='Открыть установленный Claude Code отдельно' },
    [pscustomobject]@{ name='/help';      description='Все команды и параметры' },
    [pscustomobject]@{ name='/quit';      description='Закрыть Cavey DevKit' }
)
$script:CaveyInputHistory = New-Object System.Collections.ArrayList

function Show-CaveyBanner {
    Clear-Host
    Write-Host ''
    Write-Host '   CAVEY DEVKIT  v0.2' -ForegroundColor Cyan
    Write-Host '   Terminal workspace  /  Cavey Player' -ForegroundColor DarkGray
    Write-Host ('   ' + $script:Root) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   / для команд   Tab — дополнить   ↑↓ — выбор   /help — помощь' -ForegroundColor Gray
    try {
        if (-not [Console]::IsOutputRedirected) {
            $target = [Console]::WindowTop + [Console]::WindowHeight - 11
            $space = [Math]::Max(0, [Math]::Min(40, $target - [Console]::CursorTop))
            for ($i = 0; $i -lt $space; $i++) { Write-Host '' }
        }
    } catch {}
}

function Get-CaveySuggestions([string]$line) {
    if (-not $line.StartsWith('/')) { return @() }
    $prefix = ($line -split '\s+',2)[0]
    return @($script:CaveyCommandCatalog | Where-Object {
        $_.name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 5)
}

function Set-CaveyTuiRow([int]$row, [string]$message, [ConsoleColor]$color) {
    $width = [Math]::Max(10, [Console]::WindowWidth - 1)
    [Console]::SetCursorPosition(0, $row)
    [Console]::Write((' ' * $width))
    [Console]::SetCursorPosition(0, $row)
    $actual = $message
    if ($actual.Length -gt $width) { $actual = $actual.Substring(0,$width) }
    $original = [Console]::ForegroundColor
    try {
        [Console]::ForegroundColor = $color
        [Console]::Write($actual)
    } finally {
        [Console]::ForegroundColor = $original
    }
}

function Render-CaveyPrompt([int]$top, [string]$line, [int]$selected) {
    $suggestions = @(Get-CaveySuggestions $line)
    $width = [Math]::Max(10,[Console]::WindowWidth - 1)
    for ($i = 0; $i -lt 5; $i++) {
        if ($i -lt $suggestions.Count) {
            $item = $suggestions[$i]
            $marker = if ($i -eq $selected) { '  > ' } else { '    ' }
            $desc = ('{0,-17} {1}' -f $item.name, $item.description)
            Set-CaveyTuiRow ($top+$i) ($marker+$desc) $(if ($i -eq $selected) { [ConsoleColor]::Cyan } else { [ConsoleColor]::DarkGray })
        } else {
            Set-CaveyTuiRow ($top+$i) '' DarkGray
        }
    }
    $border = ('─' * [Math]::Max(8,[Math]::Min($width,105)))
    Set-CaveyTuiRow ($top+5) ('  '+$border) DarkGray
    $visible = $line
    if ($visible.Length -gt ($width - 6)) { $visible = $visible.Substring($visible.Length - ($width - 6)) }
    Set-CaveyTuiRow ($top+6) ('  > '+$visible) Cyan
    Set-CaveyTuiRow ($top+7) ('  '+$border) DarkGray
    $footer = if ($line.StartsWith('/')) {
        '  Tab — дополнить     ↑↓ — команда     Enter — выполнить     Esc — очистить'
    } else {
        '  LOCAL BUILD     GitHub branches     /help — команды     /agent — Claude CLI'
    }
    Set-CaveyTuiRow ($top+8) $footer DarkGray
    $column = [Math]::Min($width-1, 4+$visible.Length)
    [Console]::SetCursorPosition($column,$top+6)
}

function Read-CaveyCommand {
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        return (Read-Host '  >')
    }
    try {
        $test = [Console]::WindowWidth
        if ($test -lt 45 -or [Console]::WindowHeight -lt 15) { return (Read-Host '  >') }
    } catch { return (Read-Host '  >') }
    # Reserve redraw space. This does not spawn a second console window.
    for ($i = 0; $i -lt 9; $i++) { Write-Host '' }
    $top = [Console]::CursorTop - 9
    $line = ''
    $selected = 0
    $historyIndex = $script:CaveyInputHistory.Count
    while ($true) {
        try {
            Render-CaveyPrompt $top $line $selected
            $key = [Console]::ReadKey($true)
        } catch {
            [Console]::SetCursorPosition(0,[Math]::Max(0,$top+9))
            return (Read-Host '  >')
        }
        if ($key.Key -eq [ConsoleKey]::Enter) {
            $suggestions = @(Get-CaveySuggestions $line)
            if ($suggestions.Count -gt 0 -and $line -notmatch '\s' -and
                ($line -eq '/' -or $suggestions.Count -eq 1)) {
                $line = $suggestions[$selected].name
            }
            for ($i = 0; $i -lt 9; $i++) { Set-CaveyTuiRow ($top+$i) '' Gray }
            [Console]::SetCursorPosition(0,$top)
            if ($line.Trim()) {
                Write-Host ('  > '+$line) -ForegroundColor Cyan
                [void]$script:CaveyInputHistory.Add($line)
            }
            [Console]::SetCursorPosition(0,$top+9)
            return $line
        }
        if ($key.Key -eq [ConsoleKey]::Escape) {
            $line = ''; $selected = 0; continue
        }
        if ($key.Modifiers -band [ConsoleModifiers]::Control -and $key.Key -eq [ConsoleKey]::C) {
            [Console]::SetCursorPosition(0,$top+9)
            return '/quit'
        }
        if ($key.Key -eq [ConsoleKey]::Backspace) {
            if ($line.Length -gt 0) { $line = $line.Substring(0,$line.Length-1) }
            $selected = 0
            continue
        }
        if ($key.Key -eq [ConsoleKey]::Tab) {
            $suggestions = @(Get-CaveySuggestions $line)
            if ($suggestions.Count -gt 0) { $line = $suggestions[$selected].name + ' ' }
            continue
        }
        if ($key.Key -eq [ConsoleKey]::DownArrow -or $key.Key -eq [ConsoleKey]::UpArrow) {
            $suggestions = @(Get-CaveySuggestions $line)
            if ($suggestions.Count -gt 0) {
                if ($key.Key -eq [ConsoleKey]::DownArrow) { $selected = ($selected+1) % $suggestions.Count }
                else { $selected = ($selected+$suggestions.Count-1) % $suggestions.Count }
            } elseif ($script:CaveyInputHistory.Count -gt 0) {
                if ($key.Key -eq [ConsoleKey]::UpArrow) { $historyIndex = [Math]::Max(0,$historyIndex-1) }
                else { $historyIndex = [Math]::Min($script:CaveyInputHistory.Count,$historyIndex+1) }
                $line = if ($historyIndex -eq $script:CaveyInputHistory.Count) { '' } else { [string]$script:CaveyInputHistory[$historyIndex] }
            }
            continue
        }
        if (-not [char]::IsControl($key.KeyChar)) {
            $line += [string]$key.KeyChar
            $selected = 0
        }
    }
}
