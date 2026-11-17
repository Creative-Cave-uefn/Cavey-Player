# Cavey DevKit - noninteractive build and GitHub command engine.
# PowerShell 5.1; invoked by tools/devkit/src/runner.ts.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$script:RepoFallback = Split-Path -Parent $PSScriptRoot
$script:SourceRepo = 'Creative-Cave-uefn/Cavey-Player'
$script:ReleaseRepo = 'Creative-Cave-uefn/cave-player-releases'
$script:DataHome = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'CaveyDevKit' } else { Join-Path $HOME '.cavey-devkit' }
$script:HistoryFile = Join-Path $script:DataHome 'history.jsonl'
$script:ConfigFile = Join-Path $script:DataHome 'config.json'
$script:Root = $script:RepoFallback
if (Test-Path -LiteralPath $script:ConfigFile) {
    try {
        $configured = (Get-Content -LiteralPath $script:ConfigFile -Raw | ConvertFrom-Json).projectRoot
        if ($configured -and (Test-Path -LiteralPath $configured)) { $script:Root = $configured }
    } catch {}
}
# Installed copies use their own compatible build engine instead of a different branch's tools.
$script:BuildScript = Join-Path $PSScriptRoot 'local-test-build.ps1'
if (-not (Test-Path $script:BuildScript)) {
    $script:BuildScript = Join-Path $script:Root 'tools\local-test-build.ps1'
}
$script:Interactive = $false
Set-Location $script:Root

function Say([string]$message, [ConsoleColor]$color = [ConsoleColor]::Gray) { Write-Host $message -ForegroundColor $color }
function Heading([string]$message) { Write-Host ''; Say "  $message" Cyan }
function Hint([string]$message) { Say "  $message" DarkGray }
function Fail([string]$message) { throw $message }
function Resolve-NativeCommand([string]$name) {
    # PowerShell commands are case-insensitive: the Git/Gh helper functions MUST NOT
    # shadow the native git.exe/gh.exe applications. Resolve applications only.
    $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command) { Fail "Executable not found on PATH: $name" }
    return $command.Source
}
function Native([string]$exe, [string[]]$arguments) {
    $path = Resolve-NativeCommand $exe
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $code = $null
    $output = ''
    try {
        $output = & $path @arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $old
    }
    if ($code -ne 0) { Fail "$exe $($arguments -join ' '): $($output.Trim())" }
    return $output.Trim()
}
function Git([string[]]$arguments) { Native 'git' $arguments }
function Gh([string[]]$arguments) { Native 'gh' $arguments }
function Has([string]$name) {
    # A same-named helper function is not proof that the external CLI exists.
    return [bool](Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1)
}
function Option([string[]]$arguments, [string]$key) {
    for ($i = 0; $i -lt $arguments.Count - 1; $i++) {
        if ($arguments[$i] -eq $key) { return $arguments[$i + 1] }
    }
    return ''
}
function Flag([string[]]$arguments, [string]$key) { return ($arguments -contains $key) }
function Ask([string]$prompt, [bool]$approved = $false) {
    if ($approved) { return $true }
    if (-not $script:Interactive) { Fail "$prompt : add --yes to confirm." }
    return ((Read-Host "$prompt [y/N]") -match '^(y|yes|д|да)$')
}
function Pick([string]$prompt, [array]$values) {
    if ($values.Count -eq 0) { Fail 'No options available.' }
    Heading $prompt
    for ($i = 0; $i -lt $values.Count; $i++) { Say ("  {0,2}. {1}" -f ($i+1),$values[$i]) }
    $choice = Read-Host '  Number [1]'
    if (-not $choice) { return 0 }
    $index = 0
    if (-not [int]::TryParse($choice,[ref]$index) -or $index -lt 1 -or $index -gt $values.Count) {
        Fail 'Invalid option number.'
    }
    return ($index - 1)
}
function Add-History([object]$record) {
    New-Item -ItemType Directory -Force -Path $script:DataHome | Out-Null
    Add-Content -Path $script:HistoryFile -Encoding UTF8 -Value ($record | ConvertTo-Json -Compress -Depth 5)
}
function History {
    if (-not (Test-Path $script:HistoryFile)) { return @() }
    return @(Get-Content $script:HistoryFile | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}
function Project([string[]]$tokens) {
    if ($tokens.Count -lt 2) {
        Heading 'Current project'
        Say "  $script:Root"
        Hint 'To change: /project C:\path\to\cavey'
        return
    }
    $newPath = ($tokens[1..($tokens.Count - 1)] -join ' ').Trim('"').Trim("'")
    if (-not (Test-Path -LiteralPath $newPath -PathType Container)) { Fail "Directory not found: $newPath" }
    $resolved = (Resolve-Path -LiteralPath $newPath).Path
    if (-not (Test-Path -LiteralPath (Join-Path $resolved 'tools\local-test-build.ps1'))) {
        Fail 'The selected directory is not a Cavey Player source checkout.'
    }
    $origin = Native 'git' @('-C',$resolved,'remote','get-url','origin')
    if ($origin -notmatch '(?i)Creative-Cave-uefn/Cavey-Player(\.git)?$') {
        Fail "This is not the Cavey Player repository: $origin"
    }
    New-Item -ItemType Directory -Force -Path $script:DataHome | Out-Null
    @{ projectRoot = $resolved } | ConvertTo-Json | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8
    $script:Root = $resolved
    Set-Location $script:Root
    Say "  Project saved: $script:Root" Green
}
function Check-Repo {
    $origin = Git @('remote','get-url','origin')
    if ($origin -notmatch '(?i)Creative-Cave-uefn/Cavey-Player(\.git)?$') {
        Fail "Incorrect Git origin: $origin"
    }
}
function Check-Clean {
    $changes = Git @('status','--porcelain','--untracked-files=no')
    if ($changes) { Fail ('Commit or stash changes before switching branches: ' + [Environment]::NewLine + $changes) }
}
function Parse-RemoteBranchRefs([string]$text) {
    # The full ref name is unambiguous; short refs can be unexpected or empty.
    # Ignore malformed lines rather than calling Substring on a short value.
    $prefix = 'refs/remotes/origin/'
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in ($text -split "\r?\n")) {
        $columns = $row.Trim().Split('|')
        if ($columns.Count -ne 3) { continue }
        $fullRef = $columns[0].Trim()
        if (-not $fullRef.StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
        if ($fullRef.Length -le $prefix.Length) { continue }
        $branch = $fullRef.Substring($prefix.Length)
        if ($branch -eq 'HEAD') { continue }
        $date = $columns[1].Trim()
        $sha = $columns[2].Trim()
        if ($sha -notmatch '^[0-9a-fA-F]{4,64}$') { continue }
        if ($date -notmatch '^\d{4}-\d{2}-\d{2}$') { $date = 'unknown' }
        [void]$list.Add([pscustomobject]@{ branch = $branch; date = $date; sha = $sha })
    }
    return $list.ToArray()
}
function Get-Branches([bool]$refresh = $true) {
    Check-Repo
    if ($refresh) { Git @('fetch','origin','--prune') | Out-Null }
    $format = '%(refname)|%(committerdate:short)|%(objectname:short)'
    $refs = Git @('for-each-ref','--sort=-committerdate',"--format=$format",'refs/remotes/origin/')
    return @(Parse-RemoteBranchRefs $refs)
}
function Select-Source([string]$requested) {
    if ($requested -eq 'current') {
        $current = Git @('branch','--show-current')
        if (-not $current) { Fail 'Detached HEAD; select a branch.' }
        return $current
    }
    $branches = @(Get-Branches)
    if ($requested -eq 'latest' -or (-not $requested -and -not $script:Interactive)) {
        $latest = @($branches | Where-Object { $_.branch -ne 'main' -and $_.branch -ne 'beta' -and $_.branch -notlike 'feat/keivi-devkit-*' })
        if ($latest.Count -eq 0) { Fail 'No experimental branches found.' }
        Hint "Latest by commit date: $($latest[0].branch), $($latest[0].sha)"
        return $latest[0].branch
    }
    if ($requested) {
        if (@($branches | Where-Object { $_.branch -ceq $requested }).Count -eq 0) { Fail "Branch $requested was not found." }
        return $requested
    }
    $choices = @($branches | Select-Object -First 50)
    $labels = @($choices | ForEach-Object { "$($_.branch) · $($_.sha) · $($_.date)" })
    return $choices[(Pick 'Select a GitHub branch' $labels)].branch
}
function Create-BuildWorktree([string]$source, [string]$folder) {
    $remoteSha = Git @('rev-parse',"refs/remotes/origin/$source")
    $worktree = Join-Path $folder 'source'
    Git @('worktree','add','--detach',$worktree,$remoteSha) | Out-Null
    $head = Git @('-C',$worktree,'rev-parse','HEAD')
    if ($head -ne $remoteSha) { Fail "Selected commit does not match GitHub: $head != $remoteSha" }
    return [pscustomobject]@{ path = $worktree; sha = $head }
}
function Slug([string]$channel) {
    $slug = ($channel.ToLower() -replace '[^a-z0-9]+','-').Trim('-')
    if (-not $slug) { Fail 'Empty release channel.' }
    return $slug
}
function Test-Releases {
    if (-not (Has 'gh')) { Fail 'GitHub CLI is not installed. Install gh and run gh auth login.' }
    $json = Gh @('release','list','--repo',$script:ReleaseRepo,'--limit','500','--json','tagName,name,isPrerelease,publishedAt')
    $releases = @($json | ConvertFrom-Json)
    return @($releases | Where-Object { $_.isPrerelease -and $_.tagName -match '^test-[a-z0-9-]+-v\d+(\.\d+)+$' })
}
function Release-Channel([object]$release) {
    if ($release.name -match '^(?:Тест|Test):\s*(.+?)\s*·') { return $Matches[1] }
    if ($release.tagName -match '^test-(.+)-v\d') { return $Matches[1] }
    Fail "Cannot determine release channel: $($release.tagName)"
}
function Stable-Base {
    $json = Gh @('release','list','--repo',$script:ReleaseRepo,'--limit','250','--json','tagName,isPrerelease')
    $all = @($json | ConvertFrom-Json)
    $stable = @($all | Where-Object { -not $_.isPrerelease -and $_.tagName -match '^v\d+\.\d+\.\d+$' } |
        Sort-Object { [version]($_.tagName.Substring(1)) } -Descending)
    if ($stable.Count -eq 0) { Fail 'No stable releases found. Cannot determine a base version.' }
    return $stable[0].tagName.Substring(1)
}
function Remove-TestRelease([string]$tag) {
    if ($tag -notmatch '^test-[a-z0-9-]+-v\d+(\.\d+)+$') { Fail "Deletion prohibited: $tag" }
    $check = Gh @('release','view',$tag,'--repo',$script:ReleaseRepo,'--json','tagName,isPrerelease') | ConvertFrom-Json
    if ($check.tagName -cne $tag -or -not $check.isPrerelease) { Fail "Invalid release: $tag" }
    Gh @('release','delete',$tag,'--repo',$script:ReleaseRepo,'--cleanup-tag','--yes') | Out-Null
}
function Clean([string[]]$tokens) {
    $keep = 1
    $keepText = Option $tokens '--keep'
    if ($keepText -and (-not [int]::TryParse($keepText,[ref]$keep) -or $keep -lt 1)) {
        Fail '--keep must be an integer of at least 1.'
    }
    $items = @(Test-Releases)
    $channel = Option $tokens '--channel'
    if ($channel) {
        $prefix = 'test-' + (Slug $channel) + '-v'
        $items = @($items | Where-Object { $_.tagName.StartsWith($prefix) })
    }
    $remove = @()
    foreach ($group in ($items | Group-Object { $_.tagName -replace '-v\d+(\.\d+)+$','' })) {
        $sorted = @($group.Group | Sort-Object publishedAt -Descending)
        if ($sorted.Count -gt $keep) { $remove += @($sorted | Select-Object -Skip $keep) }
    }
    if ($remove.Count -eq 0) { Say '  No outdated test releases.' Green; return }
    Heading "Releases eligible for deletion: $($remove.Count)"
    $remove | ForEach-Object { Hint "$($_.tagName) · $($_.publishedAt)" }
    Hint "Stable, beta, Android and iOS releases are protected. Keep $keep per channel."
    if (Flag $tokens '--dry-run') { return }
    if (-not (Ask 'Delete the listed test releases?' (Flag $tokens '--yes'))) { return }
    $success = 0
    foreach ($release in $remove) {
        try { Remove-TestRelease $release.tagName; $success++; Say "  ✓ $($release.tagName)" Green }
        catch { Say "  ✗ $($release.tagName): $_" Red }
    }
    Say "  Removed $success of $($remove.Count)." Cyan
    if ($success -ne $remove.Count) { Fail 'Some test releases could not be removed.' }
}
function Build([string[]]$tokens) {
    Check-Repo
    $source = Select-Source (Option $tokens '--branch')
    $mode = Option $tokens '--mode'
    $local = Flag $tokens '--local'
    if (-not $mode) {
        if ($local -or -not $script:Interactive) { $mode = 'new' }
        else { $mode = @('new','update')[(Pick 'Publication mode' @('New independent build', 'Update existing test channel'))] }
    }
    if (@('new','update') -notcontains $mode) { Fail 'Invalid mode; use new/update.' }
    if ($mode -eq 'update') {
        $releases = @(Test-Releases | Sort-Object publishedAt -Descending)
        if ($releases.Count -eq 0) { Fail 'No test releases available to update.' }
        $specified = Option $tokens '--channel'
        if ($specified) {
            $expected = Slug $specified
            $match = @($releases | Where-Object { $_.tagName -match ('^test-' + [regex]::Escape($expected) + '-v\d') })
            if ($match.Count -eq 0) { Fail "Channel $specified was not found." }
            $channel = Release-Channel $match[0]
        } else {
            if (-not $script:Interactive) { Fail 'For --mode update, specify --channel.' }
            $slots = @(); $seen = @{}
            foreach ($release in $releases) {
                $name = Release-Channel $release; $id = Slug $name
                if ($seen.ContainsKey($id)) { continue }
                $seen[$id] = $true
                $slots += [pscustomobject]@{ channel = $name; tag = $release.tagName }
            }
            $labels = @($slots | ForEach-Object { "$($_.channel) · $($_.tag)" })
            $channel = $slots[(Pick 'Select test channel to update' $labels)].channel
        }
    } else {
        $channel = Option $tokens '--channel'
        if (-not $channel) { $channel = 'devkit/' + $source + '/' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') }
        if (-not $local) {
            $prefix = 'test-' + (Slug $channel) + '-v'
            if (@(Test-Releases | Where-Object { $_.tagName.StartsWith($prefix) }).Count -gt 0) {
                Fail "Channel $channel already exists. Use --mode update."
            }
        }
    }
    Heading 'Local build plan'
    Say "  Source: origin/$source"
    Say "  Channel: $channel"
    Say "  Mode: $mode · $(if ($local) { 'local only' } else { 'publish to GitHub Releases' })"
    if (-not (Ask 'Create a temporary worktree and build?' (Flag $tokens '--yes'))) { return }
    $base = if ($local) { '0.4.0' } else { Stable-Base }
    $seconds = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1794182400)
    if ($seconds -lt 1) { $seconds = 1 }
    $version = "$base.$seconds"
    $prefix = 'test-' + (Slug $channel) + '-v'
    if (-not $local) {
        $existing = @(Test-Releases | Where-Object { $_.tagName.StartsWith($prefix) })
        while (@($existing | Where-Object { $_.tagName -eq "$prefix$version" }).Count -gt 0) {
            $seconds++; $version = "$base.$seconds"
        }
    }
    $id = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
    $folder = Join-Path (Join-Path $script:DataHome 'builds') $id
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $start = Get-Date; $status = 'failed'; $sha = ''
    $worktree = $null
    $buildLog = ''
    $publishError = $null
    try {
        $tree = Create-BuildWorktree $source $folder
        $worktree = $tree.path
        $sha = $tree.sha
        $buildArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$script:BuildScript,'-ProjectRoot',$worktree,'-SourceBranch',$source,'-NoPublish','-BuildChannel',$channel,'-Version',$version)
        if (Flag $tokens '--skip-checks') { $buildArgs += '-SkipChecks' }
        Heading "Windows build $version · $($sha.Substring(0,8))"
        & powershell @buildArgs
        if ($LASTEXITCODE -ne 0) { Fail "Build failed with exit code $LASTEXITCODE." }
        $artifacts = @()
        foreach ($file in @('CavePlayer-Setup.exe','CavePlayer-portable.zip')) {
            $srcFile = Join-Path (Join-Path $worktree 'dist') $file
            if (-not (Test-Path $srcFile) -or (Get-Item $srcFile).Length -eq 0) { Fail "Missing $file." }
            $target = Join-Path $folder $file
            Copy-Item -LiteralPath $srcFile -Destination $target
            $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLower()
            $artifacts += [pscustomobject]@{ path = $target; name = $file; sha256 = $hash; size = (Get-Item $target).Length }
            Hint "$file · SHA-256 $hash"
        }
        $status = 'built'
        if (-not $local) {
            $tag = "$prefix$version"
            Heading 'Publication preview'
            Say "  $script:ReleaseRepo / $tag"
            Say "  Source branch: $source ($sha)"
            $notes = @("Cavey DevKit", "Source: $script:SourceRepo", "Branch: $source", "Commit: $sha", "Update channel: $channel", "Version: $version") -join [Environment]::NewLine
            if (Ask 'Publish built artifacts?' (Flag $tokens '--yes')) {
                $publishArgs = @('release','create',$tag) + @($artifacts | ForEach-Object { $_.path }) + @('--repo',$script:ReleaseRepo,'--prerelease','--title',"Test: $channel · $version",'--notes',$notes)
                Gh $publishArgs | Out-Null
                $status = 'published'
                Say "  ✓ https://github.com/$script:ReleaseRepo/releases/tag/$tag" Green
                if ($mode -eq 'update') {
                    # Preserve previous working builds unless replacement is fully published.
                    $old = @(Test-Releases | Where-Object { $_.tagName.StartsWith($prefix) -and $_.tagName -ne $tag })
                    foreach ($release in $old) {
                        try { Remove-TestRelease $release.tagName; Hint "Old release removed: $($release.tagName)" }
                        catch { Say "  ! Could not delete $($release.tagName): $_" Yellow }
                    }
                }
            }
        }
    } finally {
        if ($worktree) {
            $buildLog = Join-Path $worktree 'build-log.txt'
            if (Test-Path $buildLog) {
                try { Copy-Item -LiteralPath $buildLog -Destination (Join-Path $folder 'build-log.txt') -Force } catch {}
            }
            # Remove the temporary checkout but preserve packaged build artifacts.
            try { Git @('worktree','remove','--force',$worktree) | Out-Null }
            catch { Say "  ! Could not clean temporary worktree $worktree : $_" Yellow }
        }
        Add-History ([pscustomobject]@{
            time = (Get-Date).ToUniversalTime().ToString('o')
            mode = $mode; sourceBranch = $source; channel = $channel; sha = $sha
            version = $version; status = $status; folder = $folder
            seconds = [math]::Round(((Get-Date) - $start).TotalSeconds,1)
        })
    }
    Say "  ✓ $status · $folder" Green
}
function Status {
    Check-Repo
    Heading 'Cavey DevKit / Cavey Player'
    Say "  Repository: $script:SourceRepo"
    Say "  Branch: $(Git @('branch','--show-current'))"
    Say "  Commit: $(Git @('rev-parse','--short','HEAD'))"
    $dirty = Git @('status','--porcelain','--untracked-files=no')
    Say "  Working tree: $(if ($dirty) { 'modified' } else { 'clean' })"
    $records = @(History)
    if ($records.Count) { Say "  Last build: $($records[-1].version) / $($records[-1].status)" }
    if (Has 'gh') {
        try { Gh @('auth','status') | Out-Null; Say '  GitHub: authenticated' Green }
        catch { Say '  GitHub: run gh auth login' Yellow }
    }
}
function Doctor {
    Heading 'Environment check'
    foreach ($name in @('git','gh','flutter','powershell')) {
        if (Has $name) { Say "  ✓ $name" Green } else { Say "  ✗ $name" Red }
    }
    $possible = @(
        "$([Environment]::GetFolderPath('ProgramFilesX86'))\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    )
    if (@($possible | Where-Object { Test-Path $_ }).Count) { Say '  ✓ Inno Setup 6' Green }
    else { Say '  ✗ Inno Setup 6' Red }
    if (Has 'flutter') {
        try { Say "  $((Native 'flutter' @('--version') -split [char]10)[0])" }
        catch { Say "  ! $($_.Exception.Message)" Yellow }
    }
    try { Check-Repo; Say '  ✓ Git origin' Green } catch { Say "  ✗ $_" Red }
    if (Has 'gh') {
        try { Gh @('auth','status') | Out-Null; Say '  ✓ GitHub authentication' Green }
        catch { Say '  ✗ Run gh auth login' Yellow }
    }
    Hint 'Windows build requires Flutter 3.27.4 and Visual Studio 2022 C++ Build Tools.'
}
function Help {
    Heading 'Cavey DevKit · Commands'
    @(
        '/status                       Статус проекта'
        '/branches                     Ветки по дате последнего коммита'
        '/build                        Интерактивный выбор ветки/публикации'
        '/build --branch latest --mode new --yes'
        '/build --branch <branch> --mode update --channel <channel>'
        '/build --branch <branch> --local --yes'
        '/releases                     Тестовые релизы'
        '/clean                        Очистка старых тестовых релизов'
        '/clean --dry-run               Просмотр без удаления'
        '/history                      История локальных сборок'
        '/logs                         Последний лог сборки'
        '/run --latest                 Последняя успешная локальная сборка'
        '/doctor                       Диагностика'
        '/project [folder]               Папка проекта; сохраняется между запусками'
        '/quit                         Выход'
    ) | ForEach-Object { Say "  $_" }
}
function Dispatch([string[]]$tokens) {
    if ($tokens.Count -eq 0) { Help; return }
    $command = $tokens[0].TrimStart('/').ToLower()
    switch ($command) {
        'selftest-branches' {
            # Fixture-based, offline regression check for a malformed/non-origin ref.
            $sample = @(
                'refs/remotes/origin/main|2026-11-17|abcdef123456',
                'refs/remotes/origin/feat/deep/path|2026-11-16|123abc456789',
                'origin|2026-11-17|abcdef123456',
                'refs/remotes/upstream/other|2026-11-17|abcdef123456',
                'refs/remotes/origin/HEAD|2026-11-17|abcdef123456',
                'refs/remotes/origin/|2026-11-17|abcdef123456',
                'refs/remotes/origin/broken|bad-date|bad-sha',
                ''
            ) -join [Environment]::NewLine
            $parsed = @(Parse-RemoteBranchRefs $sample)
            if ($parsed.Count -ne 2 -or $parsed[0].branch -cne 'main' -or
                $parsed[1].branch -cne 'feat/deep/path') {
                Fail "Branch parser regression: expected 2 valid branches, found $($parsed.Count)."
            }
            Say 'PASS malformed branch refs are skipped' Green
            # Reproduce the real for-each-ref path without network access.
            $actual = @(Get-Branches $false)
            Say "PASS local Git refs parsed: $($actual.Count) branch(es)" Green
        }
        'selftest-native' {
            # Offline smoke test: both wrappers must resolve an executable, not recurse.
            $gitVersion = Git @('--version')
            if ($gitVersion -notmatch '^git version ') { Fail "Unexpected Git version output: $gitVersion" }
            Say "PASS native Git executable: $gitVersion" Green
            if (Has 'gh') {
                $ghVersion = Gh @('version')
                if ($ghVersion -notmatch '^gh version ') { Fail "Unexpected GitHub CLI output: $ghVersion" }
                Say "PASS native GitHub CLI executable" Green
            } else {
                Hint 'GitHub CLI is not installed; skipping optional gh check.'
            }
        }
        'help' { Help }
        'status' { Status }
        'doctor' { Doctor }
        'project' { Project $tokens }
        'branches' {
            $branches = @(Get-Branches)
            Heading "GitHub branches · $($branches.Count)"
            foreach ($b in $branches) { Say ("  {0,-52} {1}  {2}" -f $b.branch,$b.date,$b.sha) }
        }
        'releases' {
            $releases = @(Test-Releases | Sort-Object publishedAt -Descending)
            Heading "Test releases · $($releases.Count)"
            foreach ($r in $releases) { Say "  $($r.tagName) · $($r.publishedAt)" }
        }
        'clean' { Clean $tokens }
        'build' { Build $tokens }
        'history' {
            Heading 'Local builds'
            foreach ($record in @(History | Select-Object -Last 20)) {
                Say "  $($record.time) · $($record.status) · $($record.version) · $($record.sourceBranch)"
            }
        }
        'logs' {
            $path = Join-Path $script:Root 'build-log.txt'
            $records = @(History)
            if ($records.Count) {
                $last = Join-Path $records[-1].folder 'build-log.txt'
                if (Test-Path $last) { $path = $last }
            }
            if (-not (Test-Path $path)) { Fail 'No logs available.' }
            if (Flag $tokens '--follow') { Get-Content $path -Wait -Tail 80 } else { Get-Content $path -Tail 100 }
        }
        'run' {
            $available = @(History | Where-Object { $_.status -eq 'built' -or $_.status -eq 'published' })
            if ($available.Count -eq 0) { Fail 'No successful local builds. Run /build.' }
            $record = $available[-1]
            $zip = Join-Path $record.folder 'CavePlayer-portable.zip'
            if (-not (Test-Path $zip)) { Fail "Latest build file is missing: $zip" }
            $target = Join-Path $record.folder 'run'
            $exe = Join-Path $target 'cave_player.exe'
            if (-not (Test-Path $exe)) {
                New-Item -ItemType Directory -Force -Path $target | Out-Null
                Heading 'Extracting latest successful build'
                Expand-Archive -LiteralPath $zip -DestinationPath $target -Force
            }
            if (-not (Test-Path $exe)) { Fail "Portable archive is missing cave_player.exe: $zip" }
            Start-Process -FilePath $exe -WorkingDirectory $target
            Say "  ✓ Cavey $($record.version) · $($record.sourceBranch) · $($record.sha.Substring(0,8))" Green
        }
        default { Fail "Unknown command: $command. Use /help." }
    }
}
try { Dispatch @($args) }
catch { Write-Error $_.Exception.Message; exit 1 }
