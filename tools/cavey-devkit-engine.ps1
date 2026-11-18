# Cavey DevKit - noninteractive build and GitHub command engine.
# PowerShell 5.1; invoked by tools/devkit/src/runner.ts.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$script:RepoFallback = Split-Path -Parent $PSScriptRoot
# Shared settings for the engine, the terminal UI and local-test-build.ps1.
$script:Shared = [pscustomobject]@{
    sourceRepo = 'Creative-Cave-uefn/Cavey-Player'; releaseRepo = 'Creative-Cave-uefn/Cavey-Player-Releases'
    devkitBranch = 'devkit'; keepPerChannel = 3; flutterVersion = '3.27.4'; useBranchBuildScript = $true
}
$sharedFile = Join-Path $PSScriptRoot 'devkit.config.json'
if (Test-Path -LiteralPath $sharedFile) {
    $loaded = Get-Content -LiteralPath $sharedFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($property in $loaded.PSObject.Properties) { $script:Shared.($property.Name) = $property.Value }
}
$script:SourceRepo = [string]$script:Shared.sourceRepo
$script:ReleaseRepo = [string]$script:Shared.releaseRepo
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
# One retention rule for DevKit channels everywhere (engine, /clean, player).
# GitHub Actions owns test-<branch>-v* channels and keeps one build per branch;
# DevKit channels always start with devkit/ so CI never deletes them.
$script:KeepPerChannel = [int]$script:Shared.keepPerChannel
$script:DevKitSlugPrefix = 'devkit-'
Set-Location $script:Root

function Say([string]$message, [ConsoleColor]$color = [ConsoleColor]::Gray) { Write-Host $message -ForegroundColor $color }
function Heading([string]$message) { Write-Host ''; Say "  $message" Cyan }
function Hint([string]$message) { Say "  $message" DarkGray }
function Fail([string]$message) { $script:ExpectedFailure = $true; throw $message }
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
    if ($null -eq $arguments -or $arguments.Count -lt 2) { return '' }
    for ($i = 0; $i -lt $arguments.Count - 1; $i++) {
        if ($arguments[$i] -eq $key) { return $arguments[$i + 1] }
    }
    return ''
}
function Flag([string[]]$arguments, [string]$key) { return ($null -ne $arguments -and $arguments -contains $key) }
function Ask([string]$prompt, [bool]$approved = $false) {
    # The engine never prompts: the terminal UI confirms first and passes --yes.
    if ($approved) { return $true }
    Fail "$prompt : add --yes to confirm."
}
function Write-Json([object]$value) {
    # One JSON document on stdout for the terminal UI; arrays stay arrays.
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $value -Depth 6 -Compress))
}
function Iso-Time([object]$value) {
    # Windows PowerShell keeps JSON dates as text; PowerShell 7 parses them.
    if ($null -eq $value) { return $null }
    if ($value -is [DateTime]) { return $value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    return [string]$value
}
function Add-History([object]$record) {
    New-Item -ItemType Directory -Force -Path $script:DataHome | Out-Null
    Add-Content -Path $script:HistoryFile -Encoding UTF8 -Value ($record | ConvertTo-Json -Compress -Depth 5)
}
function History {
    if (-not (Test-Path $script:HistoryFile)) { return @() }
    return @(Get-Content $script:HistoryFile | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}
# Workflow events are consumed by the React Build Center; the same events
# remain legible in terminal logs when the engine is invoked headlessly.
$script:CurrentManifest = $null
$script:CurrentStage = ''
function Save-BuildState {
    if ($null -eq $script:CurrentManifest) { return }
    $path = [string]$script:CurrentManifest.manifestPath
    $tmp = "$path.tmp"
    $script:CurrentManifest.updatedUtc = [DateTime]::UtcNow.ToString('o')
    $script:CurrentManifest | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
}
function Stage([string]$name, [string]$state, [string]$label) {
    Write-Host "@@CAVEY_STAGE|$name|$state|$label"
    if ($null -ne $script:CurrentManifest) {
        $script:CurrentStage = $name
        $script:CurrentManifest.stages[$name] = @{
            state = $state; label = $label; updatedUtc = [DateTime]::UtcNow.ToString('o')
        }
        Save-BuildState
    }
}
function Enter-ReleaseLock {
    # One build or release change at a time across all DevKit windows.
    # The OS releases the handle if the process dies, so a lock never goes stale.
    New-Item -ItemType Directory -Force -Path $script:DataHome | Out-Null
    $path = Join-Path $script:DataHome 'build.lock'
    try {
        $stream = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
        Fail 'Another DevKit window is building or changing releases. Wait for it to finish, then retry.'
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes("pid=$PID started=$([DateTime]::UtcNow.ToString('o'))")
    $stream.SetLength(0); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
    return $stream
}
function Build-Records {
    $root = Join-Path $script:DataHome 'builds'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $records = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter 'run.json' -Recurse -File -ErrorAction SilentlyContinue)) {
        try {
            $record = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($record -and $record.id -and $record.folder) { $records += $record }
        } catch { Hint "Skipping corrupt build manifest: $($file.FullName)" }
    }
    return @($records | Sort-Object updatedUtc -Descending)
}
function Verify-Artifacts([object]$record) {
    if ($null -eq $record -or -not $record.artifacts -or @($record.artifacts).Count -ne 2) {
        Fail 'This run has no complete artifact manifest. Rebuild is required.'
    }
    $validated = @()
    foreach ($artifact in @($record.artifacts)) {
        $file = [string]$artifact.path
        $expected = [string]$artifact.sha256
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
            $expected -notmatch '^[a-fA-F0-9]{64}$') {
            Fail "Build artifact is missing or has no checksum: $file"
        }
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        if ($actual -ine $expected) { Fail "Build artifact checksum mismatch: $file" }
        $validated += $file
    }
    return $validated
}
function Cache-Location([string]$source) {
    $sha = Git @('rev-parse',"refs/remotes/origin/$source")
    if ($sha -notmatch '^[a-fA-F0-9]{40,64}$') { Fail 'Invalid remote commit SHA.' }
    $versionText = Native 'flutter' @('--version')
    $version = ($versionText -split "\r?\n")[0]
    $hashBytes = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($version))
    $fingerprint = ([BitConverter]::ToString($hashBytes)).Replace('-','').Substring(0,8).ToLowerInvariant()
    return [pscustomobject]@{
        sha=$sha; path=(Join-Path (Join-Path $script:DataHome 'source-cache') ($sha.Substring(0,12) + '-' + $fingerprint))
    }
}
function Remove-CachedWorktree([string]$path) {
    try { Git @('worktree','remove','--force',$path) | Out-Null } catch {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop }
    }
    try { Git @('worktree','prune') | Out-Null } catch {}
    Remove-Item -LiteralPath "$path.ok" -Force -ErrorAction SilentlyContinue
}
function Cached-Worktree([string]$source, [string]$folder, [bool]$fresh) {
    if ($fresh) {
        $tree = Create-BuildWorktree $source $folder
        $tree | Add-Member -NotePropertyName cached -NotePropertyValue $false
        $tree | Add-Member -NotePropertyName marker -NotePropertyValue ''
        return $tree
    }
    $cache = Cache-Location $source
    $dest = $cache.path
    # "<cache>.ok" exists only after a build in this worktree finished. A build
    # killed mid-compile leaves no marker, and its half-written build/ folder
    # must not be reused.
    $marker = "$dest.ok"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    if (Test-Path -LiteralPath $dest -PathType Container) {
        $actual = ''
        try { $actual = Git @('-C',$dest,'rev-parse','HEAD') } catch {}
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) {
            Hint 'The previous build in this cache did not finish; recreating it.'
            Remove-CachedWorktree $dest
        } elseif ($actual -ne $cache.sha) {
            Hint 'Cached worktree does not match the selected commit; recreating it.'
            Remove-CachedWorktree $dest
        }
    }
    if (Test-Path -LiteralPath $dest -PathType Container) {
        Git @('-C',$dest,'reset','--hard',$cache.sha) | Out-Null
        Hint "Reusing build cache: $dest"
    } else {
        Git @('worktree','add','--detach',$dest,$cache.sha) | Out-Null
        Hint "Created build cache: $dest"
    }
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{path=$dest;sha=$cache.sha;cached=$true;marker=$marker}
}
function Cache-Manager([string[]]$tokens) {
    $root = Join-Path $script:DataHome 'source-cache'
    $paths = @(if (Test-Path -LiteralPath $root) {
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue
    })
    if ($tokens -contains 'prune') {
        if (-not (Ask "Remove $($paths.Count) cached source worktrees?" (Flag $tokens '--yes'))) { return }
        $lock = Enter-ReleaseLock
        try {
            $failed = 0
            foreach ($item in $paths) {
                try { Remove-CachedWorktree $item.FullName }
                catch { $failed++; Say "  ✗ $($item.Name): $_" Red }
            }
        } finally { $lock.Dispose() }
        if ($failed) { Fail "$failed cached worktree(s) could not be removed." }
        Say '  Build cache cleared.' Green
        return
    }
    Heading "Source build cache · $($paths.Count) worktree(s)"
    foreach ($item in $paths) {
        $state = if (Test-Path -LiteralPath "$($item.FullName).ok") { 'ready' } else { 'incomplete, rebuilt on next use' }
        Say "  $($item.Name) · $state · $($item.LastWriteTime)"
    }
    Hint 'Cache is keyed by source commit and Flutter version. Use /cache prune to reclaim space.'
}
function Read-Config {
    $config = [ordered]@{}
    if (Test-Path -LiteralPath $script:ConfigFile) {
        try {
            $saved = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($property in $saved.PSObject.Properties) { $config[$property.Name] = $property.Value }
        } catch { Hint "Ignoring unreadable settings: $script:ConfigFile" }
    }
    return $config
}
function Write-Config([hashtable]$changes) {
    # Merge: /project and /notify each own one key and must not erase the other.
    $config = Read-Config
    foreach ($key in $changes.Keys) {
        if ($null -eq $changes[$key]) { $config.Remove($key) } else { $config[$key] = $changes[$key] }
    }
    New-Item -ItemType Directory -Force -Path $script:DataHome | Out-Null
    $config | ConvertTo-Json | Set-Content -LiteralPath $script:ConfigFile -Encoding UTF8
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
    Write-Config @{ projectRoot = $resolved }
    $script:Root = $resolved
    Set-Location $script:Root
    Say "  Project saved: $script:Root" Green
}
function Check-Repo {
    # CAVEY_DEVKIT_ANY_ORIGIN=1 is used only by the UI screen tests, whose
    # throwaway repository has a local origin.
    if ($env:CAVEY_DEVKIT_ANY_ORIGIN -eq '1') { return }
    $origin = Git @('remote','get-url','origin')
    if ($origin -notmatch ('(?i)' + [regex]::Escape($script:SourceRepo) + '(\.git)?$')) {
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
    # Columns: ref | committer date | short sha [| author]
    $prefix = 'refs/remotes/origin/'
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in ($text -split "\r?\n")) {
        $columns = $row.Trim().Split('|')
        if ($columns.Count -lt 3) { continue }
        $fullRef = $columns[0].Trim()
        if (-not $fullRef.StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
        if ($fullRef.Length -le $prefix.Length) { continue }
        $branch = $fullRef.Substring($prefix.Length)
        if ($branch -eq 'HEAD') { continue }
        $date = $columns[1].Trim()
        $sha = $columns[2].Trim()
        if ($sha -notmatch '^[0-9a-fA-F]{4,64}$') { continue }
        if ($date -notmatch '^\d{4}-\d{2}-\d{2}') { $date = 'unknown' }
        $author = if ($columns.Count -gt 3) { ($columns[3..($columns.Count - 1)] -join '|').Trim() } else { '' }
        [void]$list.Add([pscustomobject]@{ branch = $branch; date = $date; sha = $sha; author = $author })
    }
    return $list.ToArray()
}
function Get-Branches([bool]$refresh = $true) {
    Check-Repo
    if ($refresh) { Git @('fetch','origin','--prune') | Out-Null }
    $format = '%(refname)|%(committerdate:iso-strict)|%(objectname:short)|%(authorname)'
    $refs = Git @('for-each-ref','--sort=-committerdate',"--format=$format",'refs/remotes/origin/')
    return @(Parse-RemoteBranchRefs $refs)
}
function Select-Source([string]$requested) {
    if ($requested -eq 'current') {
        $current = Git @('branch','--show-current')
        if ([string]::IsNullOrWhiteSpace($current)) { Fail 'Detached HEAD; select a branch.' }
        return $current
    }
    if ($requested -and $requested -ne 'latest') {
        # Explicit choices from the React wizard never depend on array indexes.
        $ref = "refs/remotes/origin/$requested"
        $resolved = ''
        try { $resolved = Git @('rev-parse','--verify','--quiet',$ref) } catch {}
        if ($resolved -notmatch '^[0-9a-fA-F]{40,64}$') { Fail "Branch $requested was not found on origin. Run /branches to see what exists." }
        return $requested
    }
    $branches = @(Get-Branches)
    if ($branches.Count -eq 0) { Fail 'No remote origin branches found. Run git fetch origin.' }
    # No branch or "latest": the most recently changed experimental branch.
    $latest = @($branches | Where-Object {
        $null -ne $_ -and $_.branch -and $_.branch -ne 'main' -and $_.branch -ne 'beta' -and
        $_.branch -ne [string]$script:Shared.devkitBranch -and $_.branch -notlike 'feat/keivi-devkit-*'
    })
    if ($latest.Count -eq 0) { Fail 'No experimental branches found.' }
    $candidate = $latest | Select-Object -First 1
    Hint "Latest by commit date: $($candidate.branch), $($candidate.sha)"
    return [string]$candidate.branch
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
function Is-DevKitChannel([string]$channel) {
    if ([string]::IsNullOrWhiteSpace($channel)) { return $false }
    return (Slug $channel).StartsWith($script:DevKitSlugPrefix, [StringComparison]::Ordinal)
}
function DevKit-ChannelName([string]$channel) {
    # User-supplied names are namespaced so CI cleanup can never match them.
    if (Is-DevKitChannel $channel) { return $channel }
    return 'devkit/' + $channel.Trim().Trim('/')
}
function Release-Build([object]$release) {
    # Build order comes from the version in the tag, not publishedAt:
    # drafting and un-drafting a release resets its publication time.
    $match = [regex]::Match([string]$release.tagName, '-v(\d+(?:\.\d+){1,3})$')
    if ($match.Success) { try { return [version]$match.Groups[1].Value } catch {} }
    return [version]'0.0'
}
function Sort-Newest([object[]]$releases) {
    return @(@($releases | Where-Object { $null -ne $_ }) | Sort-Object `
        @{ Expression = { Release-Build $_ }; Descending = $true },
        @{ Expression = { [string]$_.publishedAt }; Descending = $true })
}
function Channel-Prefix([string]$channel) { return 'test-' + (Slug $channel) + '-v' }
function Test-ChannelExists([string]$channel, [object[]]$releases) {
    $prefix = 'test-' + (Slug $channel) + '-v'
    foreach ($release in @($releases)) {
        if ($null -ne $release -and $null -ne $release.tagName -and
            ([string]$release.tagName).StartsWith($prefix, [StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}
function New-ReleaseChannel([string]$source, [object[]]$existing) {
    # A new build must not silently replace an earlier test channel.
    # Millisecond timestamp + GUID suffix also distinguishes rapid retries.
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $token = [guid]::NewGuid().ToString('N').Substring(0, 10)
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
        $channel = "devkit/$source/$stamp-$token"
        if (-not (Test-ChannelExists $channel $existing)) { return $channel }
    }
    Fail 'Could not allocate a unique test channel. Please retry.'
}
function All-TestReleases {
    if (-not (Has 'gh')) { Fail 'GitHub CLI is not installed. Install gh and run gh auth login.' }
    $json = Gh @('release','list','--repo',$script:ReleaseRepo,
        '--limit','500','--json','tagName,name,isPrerelease,isDraft,publishedAt')
    $releases = @($json | ConvertFrom-Json)
    return @($releases | Where-Object {
        $_.isPrerelease -and $_.tagName -match '^test-[a-z0-9-]+-v\d+(\.\d+)+$'
    })
}
function Test-Releases {
    return @(All-TestReleases | Where-Object { -not $_.isDraft })
}
function Release-Channel([object]$release) {
    if ($null -eq $release) { Fail 'Cannot determine release channel from a null release.' }
    $byName = [regex]::Match([string]$release.name, '^(?:Тест|Test):\s*(.+?)\s*·')
    if ($byName.Success) { return $byName.Groups[1].Value }
    $byTag = [regex]::Match([string]$release.tagName, '^test-(.+)-v\d')
    if ($byTag.Success) { return $byTag.Groups[1].Value }
    Fail "Cannot determine release channel: $($release.tagName)"
}
function Version-BaseFromReleases([object[]]$releases, [string]$mode, [string]$channel) {
    # Updating an existing test channel must work even when the GitHub CLI
    # doesn't return stable releases. Preserve that channel's version base.
    if ($mode -eq 'update' -and -not [string]::IsNullOrWhiteSpace($channel)) {
        $slug = Slug $channel
        $pattern = '^test-' + [regex]::Escape($slug) + '-v(\d+\.\d+\.\d+)\.\d+$'
        $existing = @($releases | Where-Object {
            $null -ne $_ -and [string]$_.tagName -match $pattern
        } | Sort-Object publishedAt -Descending)
        foreach ($record in $existing) {
            $match = [regex]::Match([string]$record.tagName, $pattern)
            if ($match.Success) { return $match.Groups[1].Value }
        }
    }
    $stable = @($releases | Where-Object {
        $null -ne $_ -and -not $_.isDraft -and $_.isPrerelease -ne $true -and
        [string]$_.tagName -match '^v\d+\.\d+\.\d+$'
    } | Sort-Object { [version](([string]$_.tagName).Substring(1)) } -Descending)
    if ($stable.Count -gt 0) {
        $best = $stable | Select-Object -First 1
        return ([string]$best.tagName).Substring(1)
    }
    return ''
}
function Source-BaseVersion([string]$source, [string]$revision = '') {
    # Use the source branch version rather than a potentially stale checkout.
    $ref = if ($revision) { "$($revision):pubspec.yaml" } else { "refs/remotes/origin/$($source):pubspec.yaml" }
    $yaml = Git @('show', $ref)
    $match = [regex]::Match($yaml, '(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?\s*$')
    if (-not $match.Success) {
        Fail "Cannot determine version from $ref. Check pubspec.yaml."
    }
    return $match.Groups[1].Value
}
function Stable-Base([string]$mode, [string]$channel, [string]$source) {
    $json = Gh @('release','list','--repo',$script:ReleaseRepo,'--limit','500',
        '--json','tagName,isPrerelease,publishedAt')
    if ([string]::IsNullOrWhiteSpace($json)) { Fail 'GitHub CLI returned an empty release list.' }
    $releases = @($json | ConvertFrom-Json)
    $version = Version-BaseFromReleases $releases $mode $channel
    if (-not [string]::IsNullOrWhiteSpace($version)) { return $version }
    $version = Source-BaseVersion $source
    Hint "No usable release version found; using pubspec.yaml from origin/$source : $version"
    return $version
}
function Remove-TestRelease([string]$tag) {
    if ($tag -notmatch '^test-[a-z0-9-]+-v\d+(\.\d+)+$') { Fail "Deletion prohibited: $tag" }
    $check = Gh @('release','view',$tag,'--repo',$script:ReleaseRepo,'--json','tagName,isPrerelease') | ConvertFrom-Json
    if ($check.tagName -cne $tag -or -not $check.isPrerelease) { Fail "Invalid release: $tag" }
    Gh @('release','delete',$tag,'--repo',$script:ReleaseRepo,'--cleanup-tag','--yes') | Out-Null
}
function Release-Age([object]$release) {
    # Days since publication; drafts and unknown dates count as new.
    $published = $release.publishedAt
    if (-not $published) { return 0 }
    $at = if ($published -is [DateTime]) { $published } else {
        $parsed = [DateTime]::MinValue
        if (-not [DateTime]::TryParse([string]$published, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return 0 }
        $parsed
    }
    return ([DateTime]::UtcNow - $at.ToUniversalTime()).TotalDays
}
function Clean([string[]]$tokens) {
    # Default retention: DevKit channels keep $script:KeepPerChannel versions for
    # rollback; CI channels keep one (CI replaces them on every push anyway).
    $explicitKeep = 0
    $keepText = Option $tokens '--keep'
    if ($keepText -and (-not [int]::TryParse($keepText,[ref]$explicitKeep) -or $explicitKeep -lt 1)) {
        Fail '--keep must be an integer of at least 1.'
    }
    $withDrafts = Flag $tokens '--drafts'
    $staleDays = 0
    $staleText = Option $tokens '--stale'
    if ($staleText -and (-not [int]::TryParse($staleText,[ref]$staleDays) -or $staleDays -lt 1)) {
        Fail '--stale must be a number of days, at least 1.'
    }
    $all = @(All-TestReleases)
    $channel = Option $tokens '--channel'
    if ($channel) {
        $prefix = Channel-Prefix $channel
        $all = @($all | Where-Object { ([string]$_.tagName).StartsWith($prefix,[StringComparison]::Ordinal) })
    }
    $remove = @()
    foreach ($group in ($all | Group-Object { $_.tagName -replace '-v\d+(\.\d+)+$','' })) {
        $slug = ([string]$group.Name).Substring(5)
        $keep = if ($explicitKeep) { $explicitKeep }
                elseif ($slug.StartsWith($script:DevKitSlugPrefix,[StringComparison]::Ordinal)) { $script:KeepPerChannel }
                else { 1 }
        $active = @(Sort-Newest @($group.Group | Where-Object { -not $_.isDraft }))
        $devkitChannel = $slug.StartsWith($script:DevKitSlugPrefix,[StringComparison]::Ordinal)
        if ($staleDays -and $devkitChannel -and $active.Count -and (Release-Age $active[0]) -gt $staleDays) {
            # A DevKit channel nobody updated for $staleDays days goes away entirely.
            $remove += @($group.Group)
            continue
        }
        if ($active.Count -gt $keep) { $remove += @($active | Select-Object -Skip $keep) }
        if ($withDrafts) { $remove += @($group.Group | Where-Object { $_.isDraft }) }
    }
    $hiddenDrafts = @($all | Where-Object { $_.isDraft }).Count
    if ($remove.Count -eq 0) {
        Say '  No outdated test releases.' Green
        if ($hiddenDrafts -and -not $withDrafts) { Hint "$hiddenDrafts release(s) hidden by rollback are kept; add --drafts to delete them." }
        return
    }
    Heading "Releases eligible for deletion: $($remove.Count)"
    $remove | ForEach-Object { Hint "$($_.tagName)$(if ($_.isDraft) { ' [hidden by rollback]' })" }
    Hint "Stable, beta, Android and iOS releases are protected. DevKit channels keep $($script:KeepPerChannel), CI channels keep 1$(if ($explicitKeep) { "; overridden: keep $explicitKeep" })."
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
function Next-BuildNumber([string]$base, [string]$channel, [object[]]$releases) {
    $epoch = [DateTimeOffset]::new(2026,11,9,0,0,0,[TimeSpan]::Zero).ToUnixTimeSeconds()
    $number = [int][Math]::Floor(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $epoch) / 60)
    if ($number -lt 1) { $number = 1 }
    $prefix = 'test-' + (Slug $channel) + '-v'
    $pattern = '^' + [regex]::Escape($prefix + $base + '.') + '(\d+)$'
    foreach ($release in @($releases)) {
        if ($null -eq $release) { continue }
        $match = [regex]::Match([string]$release.tagName, $pattern)
        if ($match.Success) {
            $parsed = 0
            if ([int]::TryParse($match.Groups[1].Value,[ref]$parsed) -and $parsed -ge $number) {
                $number = $parsed + 1
            }
        }
    }
    return $number
}
function Trim-ChannelReleases([string]$channel, [int]$keep = $script:KeepPerChannel) {
    # Runs only after a successful publish. Never touches stable releases.
    # Keeps the newest $keep active versions as rollback targets; releases
    # hidden by an earlier rollback are obsolete once a newer build is live.
    $prefix = Channel-Prefix $channel
    $channelReleases = @(All-TestReleases | Where-Object {
        ([string]$_.tagName).StartsWith($prefix,[StringComparison]::Ordinal)
    })
    $active = @(Sort-Newest @($channelReleases | Where-Object { -not $_.isDraft }))
    $obsolete = @($active | Select-Object -Skip $keep) + @($channelReleases | Where-Object { $_.isDraft })
    foreach ($old in $obsolete) {
        try {
            Remove-TestRelease $old.tagName
            Hint "Pruned old test release: $($old.tagName)"
        } catch {
            Say "  ! Could not prune $($old.tagName): $_" Yellow
        }
    }
}
function Previous-ChannelRelease([string]$channel) {
    # Newest active release of the channel and the commit recorded in its notes.
    $prefix = Channel-Prefix $channel
    $members = @(Sort-Newest @(Test-Releases | Where-Object { ([string]$_.tagName).StartsWith($prefix,[StringComparison]::Ordinal) }))
    if ($members.Count -eq 0) { return $null }
    try {
        $body = (Gh @('release','view',$members[0].tagName,'--repo',$script:ReleaseRepo,'--json','body') | ConvertFrom-Json).body
    } catch { return $null }
    $match = [regex]::Match([string]$body, '(?m)^Commit:\s*([0-9a-fA-F]{7,40})\s*$')
    if (-not $match.Success) { return $null }
    return [pscustomobject]@{ tag = [string]$members[0].tagName; sha = $match.Groups[1].Value }
}
function Change-Log([string]$source, [string]$sha, [string]$mode, [string]$channel, [bool]$local) {
    # What testers get compared with the previous build of this channel; for a
    # new channel, what the branch adds on top of main.
    $since = ''; $title = ''
    if ($mode -eq 'update' -and -not $local) {
        $previous = Previous-ChannelRelease $channel
        if ($previous) {
            try {
                Git @('merge-base','--is-ancestor',$previous.sha,$sha) | Out-Null
                $since = $previous.sha; $title = "Changes since $($previous.tag)"
            } catch { Hint "The previous build's commit $($previous.sha) is not in this branch; listing branch changes instead." }
        }
    }
    if (-not $since -and $source -ne 'main') {
        try { Git @('rev-parse','--verify','refs/remotes/origin/main') | Out-Null; $since = 'refs/remotes/origin/main'; $title = "Changes on $source" } catch {}
    }
    $range = if ($since) { "$since..$sha" } else { $sha }
    $limit = 30
    $lines = @()
    try {
        $text = Git @('log','--no-merges',"--max-count=$($limit + 1)",'--format=%s (%h)',$range)
        $lines = @($text -split "\r?\n" | Where-Object { $_.Trim() })
    } catch {}
    if (-not $title) { $title = 'Recent changes' }
    $more = $lines.Count -gt $limit
    return [pscustomobject]@{ title = $title; items = @($lines | Select-Object -First $limit); more = $more }
}
function Release-Notes([object]$record) {
    # The player shows these notes to testers, so the human part comes first.
    # The "Commit:" line is parsed by the next update to build its changelog.
    $lines = @()
    if ($record.message) { $lines += [string]$record.message; $lines += '' }
    if ($record.changes -and @($record.changes.items).Count) {
        $lines += [string]$record.changes.title
        $lines += @($record.changes.items | ForEach-Object { "- $_" })
        if ($record.changes.more) { $lines += '- …' }
        $lines += ''
    }
    $lines += @('---', 'Cavey DevKit', "Source: $script:SourceRepo",
        "Branch: $($record.source)", "Commit: $($record.sha)",
        "Update channel: $($record.channel)", "Version: $($record.version)")
    if ($record.downloader -and $record.downloader.sha256) {
        $lines += "Downloader: $($record.downloader.source) · SHA-256 $($record.downloader.sha256)"
    }
    return ($lines -join "`n")
}
function Discord-Message([object]$record, [string]$url) {
    $lines = @("**Cavey test build** ``$($record.channel)`` · $($record.version)")
    if ($record.message) { $lines += [string]$record.message }
    $items = @(if ($record.changes) { @($record.changes.items) })
    if ($items.Count) {
        $lines += @($items | Select-Object -First 10 | ForEach-Object { "• $_" })
        if ($items.Count -gt 10 -or $record.changes.more) { $lines += '• …' }
    }
    $lines += "Branch ``$($record.source)`` · $(([string]$record.sha).Substring(0, [Math]::Min(8, ([string]$record.sha).Length)))"
    $lines += $url
    $text = $lines -join "`n"
    if ($text.Length -gt 1900) { $text = $text.Substring(0, 1890) + "…`n" + $url }
    return $text
}
function Test-DiscordWebhook([string]$url) {
    return $url -match '^https://(?:canary\.|ptb\.)?(?:discord|discordapp)\.com/api/webhooks/\d+/[\w-]+$'
}
function Send-Discord([string]$text) {
    $webhook = [string](Read-Config)['discordWebhook']
    if (-not $webhook) { return $false }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $body = [Text.Encoding]::UTF8.GetBytes((@{ content = $text; allowed_mentions = @{ parse = @() } } | ConvertTo-Json -Compress -Depth 4))
    Invoke-RestMethod -Uri $webhook -Method Post -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 20 | Out-Null
    return $true
}
function Announce([object]$record, [string]$url) {
    # A failed announcement never fails the publication.
    try {
        if (Send-Discord (Discord-Message $record $url)) { Hint 'Announced in Discord.' }
    } catch { Say "  ! Discord announcement failed: $($_.Exception.Message)" Yellow }
}
function Notify-Settings([string[]]$tokens) {
    $value = if ($tokens.Count -ge 2) { [string]$tokens[1] } else { '' }
    if ($value -eq 'off') { Write-Config @{ discordWebhook = $null }; Say '  Discord announcements turned off.' Green; return }
    if ($value -eq 'test') {
        if (Send-Discord '**Cavey DevKit** · test message: announcements for new test builds will appear here.') { Say '  ✓ Test message sent.' Green }
        else { Fail 'No Discord webhook is set. Use /notify <webhook-url>.' }
        return
    }
    if ($value) {
        if (-not (Test-DiscordWebhook $value)) { Fail 'That is not a Discord webhook URL (https://discord.com/api/webhooks/<id>/<token>).' }
        Write-Config @{ discordWebhook = $value }
        Say '  Discord announcements on: every published test build is posted to this webhook.' Green
        Hint 'Send a test message with /notify test.'
        return
    }
    $webhook = [string](Read-Config)['discordWebhook']
    Heading 'Discord announcements'
    if ($webhook) { Say "  On · $($webhook -replace '/[\w-]+$', '/••••••')" } else { Say '  Off' }
    Hint 'Set: /notify <webhook-url> · Test: /notify test · Disable: /notify off'
}
function Compare-RemoteAssets([object]$remote, [object]$record) {
    # Pure comparison so it can be self-tested: does the release on GitHub
    # carry exactly the verified files of this run?
    $assets = @($remote.assets | Where-Object { $null -ne $_ })
    foreach ($artifact in @($record.artifacts)) {
        $name = if ($artifact.name) { [string]$artifact.name } else { Split-Path -Leaf ([string]$artifact.path) }
        $size = if ($artifact.size) { [int64]$artifact.size } else { (Get-Item -LiteralPath ([string]$artifact.path)).Length }
        $asset = @($assets | Where-Object { $_.name -ceq $name } | Select-Object -First 1)
        if ($asset.Count -eq 0) { return "$name is missing" }
        if ($asset[0].state -and $asset[0].state -ne 'uploaded') { return "$name upload did not finish" }
        if ([int64]$asset[0].size -ne $size) { return "$name has a different size" }
        $digest = [string]$asset[0].digest
        if ($digest -match '^sha256:([0-9a-fA-F]{64})$' -and $Matches[1] -ine [string]$artifact.sha256) {
            return "$name has a different SHA-256"
        }
    }
    return ''
}
function Publish-Manifest([object]$record, [bool]$replace = $false) {
    if ($record.local) { Fail 'Local-only builds cannot be published.' }
    if ($record.status -eq 'published') {
        Hint "Already published: $($record.tag)"
        return
    }
    if ([string]$record.status -notin @('built','publish_failed')) {
        Fail "Run status is $($record.status). Build artifacts are not ready for publishing."
    }
    $files = @(Verify-Artifacts $record)
    $tag = [string]$record.tag
    if ($tag -notmatch '^test-[a-z0-9-]+-v\d+\.\d+\.\d+\.\d+$') {
        Fail "Invalid test-release tag in manifest: $tag"
    }
    $already = @(All-TestReleases | Where-Object { $_.tagName -ceq $tag })
    if ($already.Count -gt 0) {
        # An interrupted upload leaves the tag behind (gh creates a draft,
        # uploads, then publishes). Reconcile instead of refusing forever.
        $remote = Gh @('release','view',$tag,'--repo',$script:ReleaseRepo,'--json','tagName,isDraft,isPrerelease,assets') | ConvertFrom-Json
        $problem = Compare-RemoteAssets $remote $record
        if (-not $problem) {
            if ($remote.isDraft) {
                Gh @('release','edit',$tag,'--repo',$script:ReleaseRepo,'--draft=false','--prerelease') | Out-Null
            }
            Hint 'GitHub already has this release with the same files; marking it as published.'
        } elseif (-not $replace) {
            Fail ("Tag $tag already exists on GitHub, but $problem. " +
                "Run /recover --id $($record.id) --replace --yes to delete that release and upload again.")
        } else {
            Hint "Replacing the incomplete release: $problem."
            Remove-TestRelease $tag
            $problem = 'replaced'
        }
        if (-not $problem) {
            $record.status = 'published'
            $script:CurrentManifest = $record
            Save-BuildState
            Stage 'publish' 'done' 'Release already on GitHub'
            Say "  ✓ https://github.com/$script:ReleaseRepo/releases/tag/$tag" Green
            if ($record.mode -eq 'update') { Trim-ChannelReleases ([string]$record.channel) }
            return
        }
    }
    Stage 'publish' 'running' 'Uploading release assets'
    $notesText = Release-Notes $record
    $leaked = @(Find-Secrets ($notesText + "`n" + [string]$record.channel))
    if ($leaked.Count) { Fail "The release notes contain the value of $($leaked -join ', '). Not publishing." }
    $publishArgs = @('release','create',$tag) + $files + @(
        '--repo',$script:ReleaseRepo,'--prerelease',
        '--title',"Test: $($record.channel) · $($record.version)",
        '--notes',$notesText
    )
    Gh $publishArgs | Out-Null
    $record.status = 'published'
    $script:CurrentManifest = $record
    Save-BuildState
    Stage 'publish' 'done' 'Release uploaded'
    $url = "https://github.com/$script:ReleaseRepo/releases/tag/$tag"
    Say "  ✓ $url" Green
    Announce $record $url
    if ($record.mode -eq 'update') { Trim-ChannelReleases ([string]$record.channel) }
}
function Recovery([string[]]$tokens) {
    $records = @(Build-Records)
    $target = Option $tokens '--id'
    if (-not $target) {
        Heading "Recovery · $($records.Count) saved run(s)"
        foreach ($record in @($records | Select-Object -First 12)) {
            Say "  $($record.id) · $($record.status) · $($record.source) · $($record.channel)"
        }
        Hint 'Use /recover --id <id> to publish verified artifacts without rebuilding.'
        Hint 'Interrupted compiling runs require a new build.'
        return
    }
    $record = @($records | Where-Object { $_.id -ceq $target } | Select-Object -First 1)
    if ($record.Count -eq 0) { Fail "Unknown build run: $target" }
    $replace = Flag $tokens '--replace'
    $question = if ($replace) { "Replace the release on GitHub and republish $target?" } else { "Republish saved run $target?" }
    if (-not (Ask $question (Flag $tokens '--yes'))) { return }
    $lock = Enter-ReleaseLock
    $script:CurrentManifest = $record[0]
    $script:CurrentManifest.stages = @{}
    try {
        Publish-Manifest $record[0] $replace
        Emit-Result $record[0]
    } catch {
        if ($record[0].status -ne 'published') {
            $record[0].status = 'publish_failed'
            Save-BuildState
        }
        throw
    } finally {
        $script:CurrentManifest = $null
        $lock.Dispose()
    }
}
function Release-Manager([string[]]$tokens) {
    $channel = Option $tokens '--channel'
    $all = @(Sort-Newest @(All-TestReleases))
    if ($channel) {
        $prefix = Channel-Prefix $channel
        $all = @($all | Where-Object { ([string]$_.tagName).StartsWith($prefix,[StringComparison]::Ordinal) })
        Heading "Channel: $channel · $($all.Count) release(s)"
        foreach ($release in $all) {
            $state = if ($release.isDraft) { 'hidden by rollback' } else { 'active' }
            Say "  $($release.tagName) · $state$(if ($release.publishedAt) { ' · ' + $release.publishedAt })"
        }
        if (Is-DevKitChannel $channel) {
            Hint "Keeps $($script:KeepPerChannel) active versions. /rollback restores an older one; /rollforward undoes a rollback."
        } else {
            Hint 'This channel belongs to GitHub Actions builds of a branch: CI replaces it on every push.'
        }
        return
    }
    Heading 'Release Manager · test channels'
    $seen = @{}
    foreach ($release in $all) {
        $name = Release-Channel $release
        $id = Slug $name
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $members = @($all | Where-Object { ([string]$_.tagName).StartsWith(('test-' + $id + '-v'),[StringComparison]::Ordinal) })
        $hidden = @($members | Where-Object { $_.isDraft }).Count
        $owner = if (Is-DevKitChannel $name) { 'DevKit' } else { 'CI' }
        Say "  $name · $owner · $($members.Count - $hidden) active$(if ($hidden) { ", $hidden hidden" }) · latest: $($release.tagName)"
    }
    Hint 'Use /releases --channel <name> for details.'
}
function Rollback-Release([string[]]$tokens) {
    $channel = Option $tokens '--channel'
    $to = Option $tokens '--to'
    if (-not $channel -or -not $to) {
        Fail 'Usage: /rollback --channel <name> --to <test-release-tag> --yes'
    }
    $prefix = Channel-Prefix $channel
    $existing = @(Sort-Newest @(Test-Releases | Where-Object {
        ([string]$_.tagName).StartsWith($prefix,[StringComparison]::Ordinal)
    }))
    $found = @($existing | Where-Object { $_.tagName -ceq $to })
    if ($found.Count -ne 1) { Fail 'Rollback target must be an active prerelease in the selected channel.' }
    $target = Release-Build $found[0]
    $newer = @($existing | Where-Object { (Release-Build $_) -gt $target })
    if ($newer.Count -eq 0) { Fail 'The selected release is already the newest in its channel.' }
    Heading 'Rollback preview'
    Say "  Channel: $channel"
    Say "  Restore: $to"
    Say "  Newer releases to hide as drafts: $($newer.Count)"
    foreach ($release in $newer) { Hint "  $($release.tagName)" }
    if (-not (Ask 'Hide newer releases as drafts and restore selected version?' (Flag $tokens '--yes'))) { return }
    # IMPORTANT: do NOT re-upload old binaries under a newer version tag:
    # their embedded APP_VERSION would disagree with the release version,
    # causing broken auto-updates. Drafting newer releases restores the
    # old version without deleting assets or falsifying its version number.
    $lock = Enter-ReleaseLock
    try {
        Stage 'publish' 'running' 'Restoring previous release'
        foreach ($release in $newer) {
            Gh @('release','edit',$release.tagName,'--repo',$script:ReleaseRepo,'--draft=true') | Out-Null
            Hint "  Hidden as draft: $($release.tagName)"
        }
        Stage 'publish' 'done' 'Previous release restored'
    } finally { $lock.Dispose() }
    Say "  ✓ Active release restored: https://github.com/$script:ReleaseRepo/releases/tag/$to" Green
    Hint "Undo with /rollforward --channel $channel"
}
function Rollforward-Release([string[]]$tokens) {
    $channel = Option $tokens '--channel'
    if (-not $channel) { Fail 'Usage: /rollforward --channel <name> --yes' }
    $prefix = Channel-Prefix $channel
    $hidden = @(Sort-Newest @(All-TestReleases | Where-Object {
        $_.isDraft -and ([string]$_.tagName).StartsWith($prefix,[StringComparison]::Ordinal)
    }))
    if ($hidden.Count -eq 0) { Fail "Channel $channel has no releases hidden by a rollback." }
    Heading 'Undo rollback'
    Say "  Channel: $channel"
    Say "  Releases to show again: $($hidden.Count)"
    foreach ($release in $hidden) { Hint "  $($release.tagName)" }
    if (-not (Ask 'Publish the hidden releases again?' (Flag $tokens '--yes'))) { return }
    $lock = Enter-ReleaseLock
    try {
        Stage 'publish' 'running' 'Showing hidden releases'
        # Oldest first, so the newest build ends up with the latest publication time.
        [array]::Reverse($hidden)
        foreach ($release in $hidden) {
            Gh @('release','edit',$release.tagName,'--repo',$script:ReleaseRepo,'--draft=false','--prerelease') | Out-Null
            Hint "  Active again: $($release.tagName)"
        }
        Stage 'publish' 'done' 'Rollback undone'
    } finally { $lock.Dispose() }
    Say "  ✓ Newest active release: $($hidden[-1].tagName)" Green
}
function DevKit-Update {
    # Only fast-forward the DevKit's OWN checkout. Never update the app source.
    $ownRepo = $script:RepoFallback
    $updateBranch = [string]$script:Shared.devkitBranch
    $current = Native 'git' @('-C',$ownRepo,'branch','--show-current')
    # devkit-live: a dedicated local worktree; feat/keivi-devkit-*: where DevKit lived before.
    if ($current -ne $updateBranch -and $current -ne 'devkit-live' -and $current -notlike 'feat/keivi-devkit-*') {
        Fail "Self-update is disabled on branch $current. Run DevKit from a checkout of '$updateBranch'."
    }
    # Only tracked files matter: a fast-forward never touches untracked ones unless the update adds the same path,
    # and git refuses that on its own.
    $dirty = @((Native 'git' @('-C',$ownRepo,'status','--porcelain','--untracked-files=no')) -split "\r?\n" | Where-Object { $_.Trim() })
    if ($dirty.Count) {
        Say '  Changed files in the DevKit checkout:' Yellow
        $dirty | Select-Object -First 8 | ForEach-Object { Hint "    $_" }
        if ($dirty.Count -gt 8) { Hint "    … and $($dirty.Count - 8) more" }
        Hint "  Commit them, or discard with: git -C `"$ownRepo`" checkout -- ."
        Hint '  If every file differs only by line endings: git config core.autocrlf false, then discard.'
        Fail 'DevKit has uncommitted changes. Self-update will not overwrite them.'
    }
    $before = Native 'git' @('-C',$ownRepo,'rev-parse','HEAD')
    Heading "Checking for DevKit updates on $updateBranch"
    Native 'git' @('-C',$ownRepo,'fetch','origin',$updateBranch) | Out-Null
    $upstream = Native 'git' @('-C',$ownRepo,'rev-parse','FETCH_HEAD')
    if ($before -eq $upstream) { Say '  DevKit is already up to date.' Green; return }
    $base = Native 'git' @('-C',$ownRepo,'merge-base',$before,$upstream)
    if ($base -ne $before) { Fail 'DevKit branch has diverged. Update cancelled; local commits are preserved.' }
    $news = @((Native 'git' @('-C',$ownRepo,'log','--no-merges','--max-count=15','--format=%s',"$before..$upstream")) -split "\r?\n" |
        Where-Object { $_.Trim() })
    Native 'git' @('-C',$ownRepo,'merge','--ff-only',$upstream) | Out-Null
    Say "  Updated DevKit: $($before.Substring(0,8)) → $($upstream.Substring(0,8))" Green
    if ($news.Count) {
        Heading "What's new"
        $news | ForEach-Object { Say "  · $_" }
    }
    Write-Host '@@CAVEY_RESTART|updated'
}
function Smoke-Problem([object]$result, [string]$version, [string]$channel) {
    # Pure check of the report written by `cave_player.exe --smoke-test=<file>`.
    if ($null -eq $result) { return 'no report' }
    if ($result.error) { return "the app reported an error: $($result.error)" }
    if ($result.mediaKit -ne $true) { return 'the native player libraries did not load' }
    if ($result.frame -ne $true) { return 'the first frame was not rendered' }
    if ([string]$result.version -cne $version) { return "it reports version '$($result.version)' instead of '$version'" }
    if ([string]$result.channel -cne $channel) { return "it reports channel '$($result.channel)' instead of '$channel'" }
    return ''
}
function Test-BuildRuns([string]$zip, [string]$folder, [string]$version, [string]$channel, [string]$sourceTree) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceTree 'lib\core\smoke_test.dart') -PathType Leaf)) {
        Stage 'verify' 'skipped' 'Branch predates the smoke test'
        Say '  ! This branch has no --smoke-test support; the build was not launched before publishing.' Yellow
        return
    }
    Stage 'verify' 'running' 'Launch the build'
    $target = Join-Path $folder 'smoke'
    $report = Join-Path $folder 'smoke.json'
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $report -Force -ErrorAction SilentlyContinue
    Expand-Archive -LiteralPath $zip -DestinationPath $target -Force
    $exe = Join-Path $target 'cave_player.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { Fail 'The portable archive has no cave_player.exe.' }
    $process = Start-Process -FilePath $exe -ArgumentList ('--smoke-test="' + $report + '"') `
        -WorkingDirectory $target -PassThru -WindowStyle Minimized
    if (-not $process.WaitForExit(90000)) {
        try { $process.Kill() } catch {}
        Fail 'Smoke test failed: the build did not start within 90 seconds.'
    }
    if (-not (Test-Path -LiteralPath $report -PathType Leaf)) {
        Fail "Smoke test failed: the build exited with code $($process.ExitCode) before writing its report."
    }
    $problem = Smoke-Problem (Get-Content -LiteralPath $report -Raw -Encoding UTF8 | ConvertFrom-Json) $version $channel
    if ($problem) { Fail "Smoke test failed: $problem." }
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    Stage 'verify' 'done' "Started as $version"
    Hint "Smoke test passed: the build starts and reports $version · $channel"
}
function Snapshot-WorkingTree([string]$folder) {
    # Commit object of the working copy, untracked files included (.gitignore
    # respected), built with a private index: the user's index, stash and
    # branch are not touched.
    $index = Join-Path $folder 'snapshot.index'
    $previous = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $index
        Git @('read-tree','HEAD') | Out-Null
        Git @('add','--all') | Out-Null
        $tree = Git @('write-tree')
        $sha = Git @('commit-tree',$tree,'-p','HEAD','-m','Cavey DevKit working-copy snapshot')
    } finally {
        $env:GIT_INDEX_FILE = $previous
        Remove-Item -LiteralPath $index -Force -ErrorAction SilentlyContinue
    }
    if ($sha -notmatch '^[0-9a-fA-F]{40,64}$') { Fail 'Could not snapshot the working copy.' }
    return $sha
}
function Build-ScriptParameters([string]$path) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -or -not $ast.ParamBlock) { return @() }
    return @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
}
function Select-BuildScript([string]$worktree) {
    # Prefer the branch's own build script, so a branch that changes how it is
    # built (new defines, new steps) is built the way CI would build it. Fall
    # back to DevKit's copy when the branch's script predates the DevKit flags.
    $own = Join-Path $worktree 'tools\local-test-build.ps1'
    if ($script:Shared.useBranchBuildScript -and (Test-Path -LiteralPath $own -PathType Leaf)) {
        $needed = @('ProjectRoot','BuildChannel','SourceBranch','NoPublish','Version','RequireDownloader')
        $has = @(Build-ScriptParameters $own)
        $missing = @($needed | Where-Object { $has -notcontains $_ })
        if ($missing.Count -eq 0) { return [pscustomobject]@{ path = $own; origin = 'branch' } }
        Hint "The branch's build script lacks $($missing -join ', '); using DevKit's build script."
    }
    return [pscustomobject]@{ path = $script:BuildScript; origin = 'devkit' }
}
function Tool-Versions {
    $versions = [ordered]@{}
    try { $versions.flutter = ((Native 'flutter' @('--version')) -split "\r?\n")[0].Trim() } catch { $versions.flutter = 'unavailable' }
    try { $versions.git = Git @('--version') } catch {}
    foreach ($candidate in @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
            "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe")) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { $versions.innoSetup = (Get-Item -LiteralPath $candidate).VersionInfo.ProductVersion; break }
    }
    return $versions
}
function Flutter-Mismatch([string]$flutterLine) {
    $expected = [string]$script:Shared.flutterVersion
    if (-not $expected -or -not $flutterLine) { return '' }
    if ($flutterLine -match ('^Flutter ' + [regex]::Escape($expected) + '\b')) { return '' }
    return "This machine has '$flutterLine'; CI builds with Flutter $expected. The build may differ from CI."
}
function Find-Secrets([string]$text) {
    # Names of environment variables that look secret and whose values appear in $text.
    $found = @()
    if (-not $text) { return $found }
    foreach ($item in @(Get-ChildItem Env:)) {
        if ($item.Name -notmatch '(?i)(SECRET|TOKEN|PASSWORD|PASSWD|_ARL|API_?KEY|PRIVATE)') { continue }
        $value = [string]$item.Value
        if ($value.Length -lt 8) { continue }
        if ($text.Contains($value)) { $found += $item.Name }
    }
    return $found
}
function Find-SignTool {
    $command = Get-Command 'signtool.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (-not (Test-Path -LiteralPath $kits)) { return '' }
    $tool = Get-ChildItem -LiteralPath $kits -Recurse -Filter 'signtool.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName -Descending | Select-Object -First 1
    return $(if ($tool) { $tool.FullName } else { '' })
}
function Signing-Settings([string[]]$tokens) {
    $value = if ($tokens.Count -ge 2) { [string]$tokens[1] } else { '' }
    if ($value -eq 'off') { Write-Config @{ signThumbprint = $null }; Say '  Code signing turned off.' Green; return }
    if ($value) {
        $thumbprint = ($value -replace '\s', '').ToUpperInvariant()
        if ($thumbprint -notmatch '^[0-9A-F]{40}$') { Fail 'A certificate thumbprint is 40 hexadecimal characters.' }
        $certificate = Get-ChildItem -Path Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $thumbprint } | Select-Object -First 1
        if (-not $certificate) { Fail "No certificate with thumbprint $thumbprint in the Windows certificate store." }
        if (-not $certificate.HasPrivateKey) { Fail 'The certificate has no private key on this computer.' }
        Write-Config @{ signThumbprint = $thumbprint }
        Say "  Builds will be signed with: $($certificate.Subject)" Green
        if (-not (Find-SignTool)) { Say '  ! signtool.exe was not found; install the Windows SDK signing tools.' Yellow }
        return
    }
    $current = [string](Read-Config)['signThumbprint']
    Heading 'Code signing'
    if ($current) { Say "  On · certificate $current" } else { Say '  Off · SmartScreen warns testers about unsigned builds' }
    Hint 'Set: /sign <certificate-thumbprint> · Disable: /sign off'
}
function Android-Support([string]$tree) {
    # Which Android pieces this source has; empty "missing" means it can build an APK.
    $missing = @()
    foreach ($file in @('lib\mobile_main.dart', 'tool\setup_android.sh', 'tool\android\signing.init.gradle')) {
        if (-not (Test-Path -LiteralPath (Join-Path $tree $file) -PathType Leaf)) { $missing += ($file -replace '\\', '/') }
    }
    return $missing
}
function Find-Bash {
    foreach ($candidate in @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
            "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe")) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    $command = Get-Command 'bash' -CommandType Application -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notmatch '\\System32\\' } | Select-Object -First 1
    return $(if ($command) { $command.Source } else { '' })
}
function Android-Sdk {
    $candidates = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Android\Sdk') }
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath (Join-Path $path 'build-tools'))) { return $path }
    }
    return ''
}
function Find-AndroidTool([string]$name) {
    $sdk = Android-Sdk
    if (-not $sdk) { return '' }
    if ($name -eq 'adb') {
        $adb = Join-Path $sdk 'platform-tools\adb.exe'
        if (-not (Test-Path -LiteralPath $adb)) { $adb = Join-Path $sdk 'platform-tools/adb' }
        return $(if (Test-Path -LiteralPath $adb) { $adb } else { '' })
    }
    $tool = Get-ChildItem -LiteralPath (Join-Path $sdk 'build-tools') -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -eq $name } | Sort-Object FullName -Descending | Select-Object -First 1
    return $(if ($tool) { $tool.FullName } else { '' })
}
function Android-Prerequisites {
    $problems = @()
    if (-not (Has 'flutter')) { $problems += 'Flutter is not on PATH.' }
    if (-not (Has 'java')) { $problems += 'Java 17 is not on PATH (install Temurin 17).' }
    if (-not (Android-Sdk)) { $problems += 'Android SDK not found (set ANDROID_HOME or install Android Studio).' }
    if (-not (Find-Bash)) { $problems += 'bash was not found (install Git for Windows).' }
    if (-not (Get-Command 'python3','python' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        $problems += 'Python 3 is not on PATH (tool/setup_android.sh needs it).'
    }
    return $problems
}
function Android-KeySettings([string[]]$tokens) {
    $value = if ($tokens.Count -ge 2) { [string]$tokens[1] } else { '' }
    if ($value -eq 'off') { Write-Config @{ androidKeystore = $null; androidKeyAlias = $null }; Say '  APKs will use the debug key.' Green; return }
    if ($value) {
        if (-not (Test-Path -LiteralPath $value -PathType Leaf)) { Fail "Keystore not found: $value" }
        $alias = if ($tokens.Count -ge 3) { [string]$tokens[2] } else { 'cavey' }
        Write-Config @{ androidKeystore = (Resolve-Path -LiteralPath $value).Path; androidKeyAlias = $alias }
        Say "  APKs will be signed with $value (alias $alias)." Green
        Hint 'Passwords are read from CAVEY_KEYSTORE_PASSWORD (and CAVEY_KEY_PASSWORD if different); they are never stored.'
        return
    }
    $config = Read-Config
    Heading 'Android signing key'
    if ($config['androidKeystore']) { Say "  $($config['androidKeystore']) · alias $($config['androidKeyAlias'])" }
    else { Say '  Not set: APKs use the debug key and will not install over a release build.' }
    Hint 'Set: /android-key <path.jks> [alias] · Debug key: /android-key off'
}
function Build-Android([string[]]$tokens) {
    # Local APK, mirroring .github/workflows/android-apk.yml of the Android
    # branches. Never published: phones update from android-v* releases,
    # which only CI creates.
    Check-Repo
    if (-not (Flag $tokens '--local')) { Fail 'Android builds from DevKit stay on this computer; add --local. Phone releases come from CI.' }
    $source = Select-Source (Option $tokens '--branch')
    $problems = @(Android-Prerequisites)
    if ($problems.Count) { Fail ("Android build needs: " + ($problems -join ' ')) }
    $config = Read-Config
    $keystore = [string]$config['androidKeystore']
    if ($keystore -and -not $env:CAVEY_KEYSTORE_PASSWORD) { Fail 'Set CAVEY_KEYSTORE_PASSWORD for the Android signing key, or use /android-key off.' }
    Heading 'Android build plan'
    Say "  Source: origin/$source"
    Say "  Signing: $(if ($keystore) { $keystore } else { 'debug key (will not install over a release build)' })"
    if (-not (Ask 'Build the APK?' (Flag $tokens '--yes'))) { return }
    $lock = Enter-ReleaseLock
    $epoch = [DateTimeOffset]::new(2026,11,9,0,0,0,[TimeSpan]::Zero).ToUnixTimeSeconds()
    $number = [int][Math]::Max(1, [Math]::Floor(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $epoch) / 60))
    $version = "1.0.$number"
    $channel = DevKit-ChannelName ("android/" + (Slug $source))
    $id = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6)
    $folder = Join-Path (Join-Path $script:DataHome 'builds') $id
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $start = Get-Date
    $status = 'building'; $worktree = $null; $sha = ''
    $script:CurrentManifest = @{
        id=$id; manifestPath=(Join-Path $folder 'run.json'); folder=$folder; status='building'; stages=@{}
        source=$source; sha=''; mode='new'; channel=$channel; version=$version; tag=''; local=$true
        platform='android'; artifacts=@(); tools=(Tool-Versions)
        startedUtc=[DateTime]::UtcNow.ToString('o'); updatedUtc=[DateTime]::UtcNow.ToString('o')
    }
    Save-BuildState
    $saved = @{}
    foreach ($name in 'CAVEY_KEYSTORE','CAVEY_KEY_ALIAS','BUILD_CHANNEL') { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        Stage 'source' 'running' 'Prepare source checkout'
        $tree = Create-BuildWorktree $source $folder
        $worktree = $tree.path; $sha = $tree.sha; $script:CurrentManifest.sha = $sha
        $missing = @(Android-Support $worktree)
        if ($missing.Count) { Fail "Branch $source has no Android app (missing $($missing -join ', '))." }
        Stage 'source' 'done' 'Source checkout ready'
        Push-Location $worktree
        try {
            Stage 'prepare' 'running' 'Generate the Android project'
            & (Find-Bash) 'tool/setup_android.sh'
            if ($LASTEXITCODE -ne 0) { Fail "tool/setup_android.sh failed with exit code $LASTEXITCODE." }
            Stage 'prepare' 'done' 'Android project ready'
            if (Flag $tokens '--skip-checks') { Stage 'checks' 'skipped' 'Checks skipped on request' } else {
                Stage 'checks' 'running' 'Analyze mobile code'
                & (Resolve-NativeCommand 'flutter') analyze --no-fatal-infos --no-fatal-warnings lib/mobile_main.dart lib/mobile
                if ($LASTEXITCODE -ne 0) { Fail 'flutter analyze found errors in the mobile code.' }
                Stage 'checks' 'done' 'Analyze passed'
            }
            Stage 'compile' 'running' 'Build release APK'
            if ($keystore) { $env:CAVEY_KEYSTORE = $keystore; $env:CAVEY_KEY_ALIAS = [string]$config['androidKeyAlias'] }
            $defines = @("--dart-define=APP_VERSION=$version", "--dart-define=BUILD_CHANNEL=$channel")
            foreach ($name in 'GOOGLE_WEB_CLIENT_ID','GOOGLE_ANDROID_CLIENT_ID') {
                $value = [Environment]::GetEnvironmentVariable($name)
                if ($value) { $defines += "--dart-define=$name=$value" } else { Say "  ! $name is not set; Google sign-in will not work in this APK." Yellow }
            }
            & (Resolve-NativeCommand 'flutter') build apk --release --target lib/mobile_main.dart --build-name $version --build-number $number @defines
            if ($LASTEXITCODE -ne 0) { Fail "flutter build apk failed with exit code $LASTEXITCODE." }
            Stage 'compile' 'done' 'APK compiled'
        } finally { Pop-Location }
        Stage 'package' 'running' 'Collect the APK'
        $apk = Join-Path $worktree 'build\app\outputs\flutter-apk\app-release.apk'
        if (-not (Test-Path -LiteralPath $apk -PathType Leaf)) { Fail 'flutter build apk produced no app-release.apk.' }
        $dest = Join-Path $folder 'CaveyPlayer.apk'
        Copy-Item -LiteralPath $apk -Destination $dest -Force
        $hash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
        $script:CurrentManifest.artifacts = @(@{ path = $dest; name = 'CaveyPlayer.apk'; sha256 = $hash; size = (Get-Item $dest).Length })
        Stage 'package' 'done' 'APK ready'
        Stage 'verify' 'running' 'Check the APK signature'
        $apksigner = Find-AndroidTool 'apksigner'
        if ($apksigner) {
            $certs = (& $apksigner verify --print-certs $dest 2>&1 | Out-String)
            if ($LASTEXITCODE -ne 0) { Fail "apksigner rejected the APK: $($certs.Trim())" }
            $sha1 = [regex]::Match($certs, 'SHA-1 digest:\s*([0-9a-fA-F]+)').Groups[1].Value
            $script:CurrentManifest.signingSha1 = $sha1
            if ($certs -match 'Android Debug') {
                if ($keystore) { Fail 'The APK is signed with the debug key although a release key is configured.' }
                Say '  ! Signed with the debug key: it will not install over a release build.' Yellow
            }
            Stage 'verify' 'done' "Signature SHA-1 $sha1"
        } else { Stage 'verify' 'skipped' 'apksigner not found in the Android SDK' }
        Stage 'publish' 'skipped' 'Android builds from DevKit stay local'
        $status = 'built'
    } catch {
        $status = 'failed'
        if ($script:CurrentStage) { Stage $script:CurrentStage 'failed' $_.Exception.Message }
        throw
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        # setup_android.sh installs a Gradle init script into the user's ~/.gradle
        # (it forces minSdk 24 and release signing for every Android project);
        # remove it so other projects on this computer are not affected.
        Remove-Item -LiteralPath (Join-Path $HOME '.gradle\init.d\cavey-signing.gradle') -Force -ErrorAction SilentlyContinue
        if ($worktree) {
            try { Git @('worktree','remove','--force',$worktree) | Out-Null } catch { Say "  ! Could not clean temporary worktree: $_" Yellow }
        }
        if ($null -ne $script:CurrentManifest) {
            $script:CurrentManifest.status = $status
            Save-BuildState
            Emit-Result $script:CurrentManifest
            $script:CurrentManifest = $null
        }
        $script:CurrentStage = ''
        Add-History ([pscustomobject]@{
            time=(Get-Date).ToUniversalTime().ToString('o'); mode='android'; sourceBranch=$source; channel=$channel
            sha=$sha; version=$version; status=$status; folder=$folder; id=$id; platform='android'
            seconds=[math]::Round(((Get-Date)-$start).TotalSeconds,1)
        })
        $lock.Dispose()
    }
    Say "  ✓ $status · $folder" Green
}
function Install-Apk([string[]]$tokens) {
    $adb = Find-AndroidTool 'adb'
    if (-not $adb) { Fail 'adb was not found in the Android SDK (platform-tools).' }
    $record = @(History | Where-Object { $_.platform -eq 'android' -and $_.status -eq 'built' } | Select-Object -Last 1)
    if ($record.Count -eq 0) { Fail 'No Android build yet. Use /build and choose Android APK.' }
    $apk = Join-Path $record[0].folder 'CaveyPlayer.apk'
    if (-not (Test-Path -LiteralPath $apk)) { Fail "The APK is missing: $apk" }
    $devices = @((& $adb devices) -split "\r?\n" | Where-Object { $_ -match '\tdevice$' })
    if ($devices.Count -eq 0) { Fail 'No phone connected. Enable USB debugging and connect the phone (adb devices).' }
    Heading "Installing $($record[0].version) on $($devices.Count) device(s)"
    $output = & $adb install -r $apk 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or $output -notmatch 'Success') { Fail "adb install failed: $($output.Trim())" }
    Say "  ✓ Installed Cavey $($record[0].version)" Green
}
function Try-Release([string[]]$tokens) {
    # Run a published test build on this computer from DevKit's own folder.
    # It shares the installed Cavey's settings and library, so Cavey must be
    # closed first.
    $channel = Option $tokens '--channel'
    $tag = Option $tokens '--tag'
    if (-not $channel -and -not $tag) { Fail 'Usage: /try --channel <name> [--tag <test-release-tag>] --yes' }
    $candidates = @(Sort-Newest @(Test-Releases | Where-Object {
        ($tag -and $_.tagName -ceq $tag) -or (-not $tag -and ([string]$_.tagName).StartsWith((Channel-Prefix $channel),[StringComparison]::Ordinal))
    }))
    if ($candidates.Count -eq 0) { Fail 'No active test release matches.' }
    $release = $candidates[0]
    if (Get-Process -Name 'cave_player' -ErrorAction SilentlyContinue) {
        Fail 'Cavey is running. Close it first: the test build uses the same settings and library.'
    }
    if (-not (Ask "Download and start $($release.tagName)?" (Flag $tokens '--yes'))) { return }
    $root = Join-Path $script:DataHome 'try'
    $target = Join-Path $root $release.tagName
    $exe = Join-Path $target 'app\cave_player.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        New-Item -ItemType Directory -Force -Path $target | Out-Null
        Stage 'source' 'running' "Download $($release.tagName)"
        Gh @('release','download',$release.tagName,'--repo',$script:ReleaseRepo,'--pattern','CavePlayer-portable.zip','--dir',$target,'--clobber') | Out-Null
        $zip = Join-Path $target 'CavePlayer-portable.zip'
        if (-not (Test-Path -LiteralPath $zip)) { Fail 'The release has no CavePlayer-portable.zip.' }
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $target 'app') -Force
        Remove-Item -LiteralPath $zip -Force
        Stage 'source' 'done' 'Downloaded'
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { Fail 'The portable archive has no cave_player.exe.' }
    }
    # Keep the three most recent tried builds.
    @(Get-ChildItem -LiteralPath $root -Directory | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3) |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    (Get-Item -LiteralPath $target).LastWriteTime = Get-Date
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe)
    Say "  ✓ Started $($release.tagName)" Green
    Hint 'Start your installed Cavey again when you are done; it may update its settings from the newer build.'
}
function Emit-Result([object]$record) {
    # Machine-readable summary for the terminal UI's build card.
    if ($null -eq $record) { return }
    $artifacts = @(@($record.artifacts) | Where-Object { $null -ne $_ } | ForEach-Object {
        [ordered]@{ name = $(if ($_.name) { [string]$_.name } else { Split-Path -Leaf ([string]$_.path) }); size = [int64]$_.size }
    })
    $url = if ($record.status -eq 'published') { "https://github.com/$script:ReleaseRepo/releases/tag/$($record.tag)" } else { '' }
    $data = [ordered]@{
        id = [string]$record.id; status = [string]$record.status; folder = [string]$record.folder
        version = [string]$record.version; channel = [string]$record.channel; tag = [string]$record.tag
        local = [bool]$record.local; source = [string]$record.source; url = $url; artifacts = $artifacts
        platform = $(if ($record.platform) { [string]$record.platform } else { 'windows' })
    }
    Write-Host ('@@CAVEY_RESULT|' + ($data | ConvertTo-Json -Compress -Depth 4))
}
function Build([string[]]$tokens) {
    Check-Repo
    $workingTree = Flag $tokens '--working-tree'
    $local = Flag $tokens '--local'
    if ($workingTree) {
        # The working copy has no pushed commit, so it is never published.
        if (-not $local) { Fail 'Working-copy builds stay on this computer. Add --local, or commit and push to publish.' }
        $source = Git @('branch','--show-current')
        if (-not $source) { $source = 'detached' }
    } else {
        $source = Select-Source (Option $tokens '--branch')
    }
    $mode = Option $tokens '--mode'
    $fresh = Flag $tokens '--fresh'
    if (-not $mode) { $mode = 'new' }
    if (@('new','update') -notcontains $mode) { Fail 'Invalid mode; use new/update.' }
    if ($mode -eq 'update' -and $local) { Fail 'Update mode requires publication. Do not use --local.' }
    $channel = Option $tokens '--channel'
    if ($mode -eq 'update') {
        if (-not $channel) { Fail 'For --mode update, specify --channel.' }
        if (-not (Is-DevKitChannel $channel)) {
            Fail ("Channel $channel belongs to GitHub Actions builds of a branch; CI deletes its releases " +
                "on every push, so updates and rollbacks there would be lost. Create a DevKit channel with --mode new.")
        }
        $pattern = '^' + [regex]::Escape((Channel-Prefix $channel)) + '\d'
        $members = @(Sort-Newest @(Test-Releases | Where-Object { $_.tagName -match $pattern }))
        if ($members.Count -eq 0) { Fail "Channel $channel was not found." }
        $channel = Release-Channel $members[0]
    } else {
        if ($channel) { $channel = DevKit-ChannelName $channel }
        if ($local) {
            if (-not $channel) { $channel = New-ReleaseChannel $source @() }
        } else {
            $published = @(All-TestReleases)
            if (-not $channel) { $channel = New-ReleaseChannel $source $published }
            if (Test-ChannelExists $channel $published) {
                Fail "Channel $channel already exists. Use --mode update to publish into it."
            }
        }
    }
    Heading 'Build plan'
    Say "  Source: $(if ($workingTree) { "working copy of $source (uncommitted changes included)" } else { "origin/$source" })"
    Say "  Channel: $channel"
    Say "  Mode: $mode · $(if ($local) { 'local only' } else { 'publish to GitHub Releases' })"
    Say "  Source cache: $(if ($fresh) { 'disabled (--fresh)' } else { 'enabled, keyed by commit and Flutter version' })"
    if (-not (Ask 'Prepare source and build?' (Flag $tokens '--yes'))) { return }
    $lock = Enter-ReleaseLock
    $tools = Tool-Versions
    $mismatch = Flutter-Mismatch ([string]$tools.flutter)
    if ($mismatch) { Say "  ! $mismatch" Yellow }
    $id = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6)
    $folder = Join-Path (Join-Path $script:DataHome 'builds') $id
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $snapshot = if ($workingTree) { Snapshot-WorkingTree $folder } else { '' }
    $base = if ($workingTree) { Source-BaseVersion $source $snapshot }
            elseif ($local) { Source-BaseVersion $source } else { Stable-Base $mode $channel $source }
    $existing = if ($local) { @() } else { @(All-TestReleases) }
    $number = Next-BuildNumber $base $channel $existing
    $version = "$base.$number"
    $tag = 'test-' + (Slug $channel) + '-v' + $version
    $start = Get-Date
    $status = 'building'; $sha = ''; $worktree = $null; $cached = $false
    $script:CurrentManifest = @{
        id=$id; manifestPath=(Join-Path $folder 'run.json')
        folder=$folder; status='building'; stages=@{}
        source=$source; sha=''; mode=$mode; channel=$channel
        version=$version; tag=$tag; local=$local
        message=(Option $tokens '--message'); changes=$null; workingTree=$workingTree; tools=$tools
        artifacts=@(); startedUtc=[DateTime]::UtcNow.ToString('o')
        updatedUtc=[DateTime]::UtcNow.ToString('o')
    }
    Save-BuildState
    try {
        Stage 'source' 'running' 'Prepare source checkout'
        $tree = if ($workingTree) {
            $path = Join-Path $folder 'source'
            Git @('worktree','add','--detach',$path,$snapshot) | Out-Null
            [pscustomobject]@{ path = $path; sha = $snapshot; cached = $false; marker = '' }
        } else { Cached-Worktree $source $folder $fresh }
        $worktree = $tree.path
        $sha = $tree.sha
        $cached = [bool]$tree.cached
        $script:CurrentManifest.sha = $sha
        $changes = Change-Log $source $sha $mode $channel $local
        $script:CurrentManifest.changes = $changes
        if (@($changes.items).Count) {
            Heading $changes.title
            $changes.items | Select-Object -First 10 | ForEach-Object { Say "  · $_" }
            if (@($changes.items).Count -gt 10 -or $changes.more) { Hint '  … the full list goes into the release notes' }
        }
        Stage 'source' 'done' 'Source checkout ready'
        $selected = Select-BuildScript $worktree
        $script:CurrentManifest.buildScript = $selected.origin
        Hint "Build script: $(if ($selected.origin -eq 'branch') { "the branch's tools\local-test-build.ps1" } else { "DevKit's copy" })"
        $buildArgs = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$selected.path,
            '-ProjectRoot',$worktree,'-SourceBranch',$source,'-NoPublish',
            '-BuildChannel',$channel,'-Version',$version
        )
        if (Flag $tokens '--skip-checks') { $buildArgs += '-SkipChecks' }
        # A published build without the downloader cannot download tracks.
        if (-not $local) { $buildArgs += '-RequireDownloader' }
        $signThumbprint = [string](Read-Config)['signThumbprint']
        if ($signThumbprint) {
            if (@(Build-ScriptParameters $selected.path) -contains 'SignThumbprint') { $buildArgs += @('-SignThumbprint', $signThumbprint) }
            else { Say '  ! Code signing is on, but this build script cannot sign; the build will be unsigned.' Yellow; $signThumbprint = '' }
        }
        Heading "Windows build $version · $($sha.Substring(0,8))"
        $priorProgress = $env:CAVEY_DEVKIT_PROGRESS
        try {
            $env:CAVEY_DEVKIT_PROGRESS = '1'
            & powershell.exe @buildArgs
            $buildExitCode = $LASTEXITCODE
        } finally {
            $env:CAVEY_DEVKIT_PROGRESS = $priorProgress
        }
        if ($buildExitCode -ne 0) { Fail "Windows build failed with exit code $buildExitCode." }
        $artifacts = @()
        foreach ($name in @('CavePlayer-Setup.exe','CavePlayer-portable.zip')) {
            $sourceFile = Join-Path (Join-Path $worktree 'dist') $name
            if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf) -or
                (Get-Item -LiteralPath $sourceFile).Length -le 0) {
                Fail "Missing or empty build artifact: $name"
            }
            $dest = Join-Path $folder $name
            Copy-Item -LiteralPath $sourceFile -Destination $dest -Force
            $hash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
            $artifacts += @{path=$dest;name=$name;sha256=$hash;size=(Get-Item $dest).Length}
            Hint "$name · SHA-256 $hash"
        }
        if ($signThumbprint) {
            $signature = Get-AuthenticodeSignature -FilePath (Join-Path $folder 'CavePlayer-Setup.exe')
            if ($signature.Status -ne 'Valid') { Fail "The installer signature is $($signature.Status): $($signature.StatusMessage)" }
            Hint "Signed by $($signature.SignerCertificate.Subject)"
        }
        $downloaderInfo = Join-Path (Join-Path $worktree 'dist') 'downloader.json'
        if (Test-Path -LiteralPath $downloaderInfo -PathType Leaf) {
            $downloader = Get-Content -LiteralPath $downloaderInfo -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:CurrentManifest.downloader = $downloader
            if ($downloader.sha256) { Hint "Cavey-Downloader.exe · $($downloader.source) · SHA-256 $($downloader.sha256)" }
            else { Say '  ! This build has no Cavey-Downloader.exe; track downloads will not work.' Yellow }
        }
        if ($tree.marker) { Set-Content -LiteralPath $tree.marker -Value $sha -Encoding Ascii }
        if (Flag $tokens '--skip-smoke') {
            Stage 'verify' 'skipped' 'Smoke test skipped on request'
        } else {
            Test-BuildRuns (Join-Path $folder 'CavePlayer-portable.zip') $folder $version $channel $worktree
        }
        $status = 'built'
        $script:CurrentManifest.status = $status
        $script:CurrentManifest.artifacts = $artifacts
        Save-BuildState
        if (-not $local) {
            Heading 'Release publication'
            Say "  Repository: $script:ReleaseRepo"
            Say "  Tag: $tag"
            if (Ask 'Publish verified build artifacts?' (Flag $tokens '--yes')) {
                Publish-Manifest $script:CurrentManifest
                $status = 'published'
            } else {
                Stage 'publish' 'skipped' 'Publication deferred; use /resume'
            }
        } else {
            Stage 'publish' 'skipped' 'Local-only build'
        }
    } catch {
        $record = $_
        if ($status -eq 'built') { $status = 'publish_failed' } else { $status = 'failed' }
        $script:CurrentManifest.status = $status
        if ($script:CurrentStage) { Stage $script:CurrentStage 'failed' $record.Exception.Message }
        Save-BuildState
        throw
    } finally {
        if ($worktree) {
            $logPath = Join-Path $worktree 'build-log.txt'
            if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                try { Copy-Item -LiteralPath $logPath -Destination (Join-Path $folder 'build-log.txt') -Force } catch {}
                $leaked = @(Find-Secrets (Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue))
                if ($leaked.Count) { Say "  ! build-log.txt contains the value of $($leaked -join ', '); do not share this log." Yellow }
            }
            if (-not $cached) {
                try { Git @('worktree','remove','--force',$worktree) | Out-Null }
                catch { Say "  ! Could not clean temporary worktree: $_" Yellow }
            }
        }
        if ($null -ne $script:CurrentManifest) {
            $script:CurrentManifest.status = $status
            Save-BuildState
            Emit-Result $script:CurrentManifest
            $script:CurrentManifest = $null
        }
        $script:CurrentStage = ''
        Add-History ([pscustomobject]@{
            time=(Get-Date).ToUniversalTime().ToString('o')
            mode=$mode; sourceBranch=$source; channel=$channel; sha=$sha
            version=$version; status=$status; folder=$folder; id=$id
            seconds=[math]::Round(((Get-Date)-$start).TotalSeconds,1)
        })
        $lock.Dispose()
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
    $tools = Tool-Versions
    if ($tools.innoSetup) { Say "  ✓ Inno Setup $($tools.innoSetup)" Green } else { Say '  ✗ Inno Setup 6' Red }
    if ($tools.flutter -and $tools.flutter -ne 'unavailable') {
        $mismatch = Flutter-Mismatch ([string]$tools.flutter)
        if ($mismatch) { Say "  ! $mismatch" Yellow } else { Say "  ✓ $($tools.flutter)" Green }
    }
    try { Check-Repo; Say '  ✓ Git origin' Green } catch { Say "  ✗ $($_.Exception.Message)" Red }
    if (Has 'gh') {
        try { Gh @('auth','status') | Out-Null; Say '  ✓ GitHub authentication' Green }
        catch { Say '  ✗ Run gh auth login' Yellow }
    }
    $config = Read-Config
    if ($config['signThumbprint']) {
        if (Find-SignTool) { Say "  ✓ Code signing · certificate $($config['signThumbprint'])" Green }
        else { Say '  ✗ Code signing is on, but signtool.exe was not found (Windows SDK)' Red }
    } else { Hint 'Code signing is off (/sign <thumbprint>); SmartScreen warns about unsigned builds.' }
    if ($config['discordWebhook']) { Say '  ✓ Discord announcements' Green } else { Hint 'Discord announcements are off (/notify <webhook-url>).' }
    $cacheRoot = Join-Path $script:DataHome 'source-cache'
    $buildsRoot = Join-Path $script:DataHome 'builds'
    foreach ($place in @(@{ name = 'Build cache'; path = $cacheRoot }, @{ name = 'Saved builds'; path = $buildsRoot })) {
        if (Test-Path -LiteralPath $place.path) {
            $bytes = (Get-ChildItem -LiteralPath $place.path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            Hint ("{0}: {1:N1} GB · {2}" -f $place.name, ($bytes / 1GB), $place.path)
        }
    }
    Hint "Windows builds need Flutter $($script:Shared.flutterVersion) and Visual Studio 2022 C++ Build Tools."
}
function Help {
    Heading 'Cavey DevKit · Commands'
    @(
        '/build                        Guided build: branch, type, confirmation'
        '/build --branch <name> --local --yes'
        '/build --branch <name> --mode new --yes'
        '/build --branch <name> --mode update --channel <name> --yes'
        '/build --branch <name> --fresh --yes   (no source cache)'
        '/build ... --skip-smoke       Do not launch the build before publishing'
        '/build ... --message "<text>" Note for testers, shown first in the release notes'
        '/notify [<webhook-url>|test|off]   Announce published builds in Discord'
        '/build --working-tree --local --yes   Build uncommitted changes of the project folder'
        '/sign [<thumbprint>|off]      Sign builds with a code-signing certificate'
        '/build --android --branch <name> --local --yes   Android APK (local only)'
        '/install-apk                  Install the latest APK on a USB-connected phone'
        '/try --channel <name> --yes   Download and start a test build (close Cavey first)'
        '/clean --stale <days> --yes   Also delete DevKit channels idle for that long'
        '/android-key [<path.jks> [alias]|off]   Android signing key'
        '/releases [--channel <name>]  Test channels and their versions'
        '/rollback --channel <name> --to <tag> --yes'
        '/rollforward --channel <name> --yes   Undo a rollback'
        '/clean [--dry-run] [--keep N] [--drafts] [--yes]'
        '/recover --id <id> --replace --yes    Replace an incomplete release'
        '/recover                      Saved builds that can be published'
        '/resume --id <id> --yes       Publish a saved build without rebuilding'
        '/cache [prune --yes]          Source build cache'
        '/status   /branches   /history   /logs   /run   /doctor'
        '/project [folder]             Project folder, kept between launches'
        '/update                       Update DevKit and restart'
    ) | ForEach-Object { Say "  $_" }
}
function Dispatch([string[]]$tokens) {
    if ($tokens.Count -eq 0) { Help; return }
    $command = $tokens[0].TrimStart('/').ToLower()
    switch ($command) {
        'help' { Help }
        'status' { Status }
        'doctor' { Doctor }
        'project' { Project $tokens }
        'branches' {
            $branches = @(Get-Branches (-not (Flag $tokens '--cached')))
            if (Flag $tokens '--json') {
                Write-Json @($branches | ForEach-Object { [ordered]@{ name = $_.branch; date = $_.date; sha = $_.sha; author = $_.author } })
                return
            }
            Heading "GitHub branches · $($branches.Count)"
            foreach ($b in $branches) { Say ("  {0,-52} {1}  {2}" -f $b.branch,$b.date,$b.sha) }
        }
        'releases' {
            if (Flag $tokens '--json') {
                # Every test prerelease, hidden ones included, with the channel
                # already resolved so the UI never re-derives it.
                Write-Json @(All-TestReleases | ForEach-Object {
                    $channel = try { Release-Channel $_ } catch { '' }
                    [ordered]@{ tagName = [string]$_.tagName; name = [string]$_.name; isPrerelease = [bool]$_.isPrerelease
                        isDraft = [bool]$_.isDraft; publishedAt = (Iso-Time $_.publishedAt)
                        channel = $channel; devkit = (Is-DevKitChannel $channel) }
                })
                return
            }
            if (Option $tokens '--channel') { Release-Manager $tokens; return }
            $releases = @(Test-Releases | Sort-Object publishedAt -Descending)
            Heading "Test releases · $($releases.Count)"
            foreach ($r in $releases) { Say "  $($r.tagName) · $($r.publishedAt)" }
        }
        'clean' { Clean $tokens }
        'build' { if (Flag $tokens '--android') { Build-Android $tokens } else { Build $tokens } }
        'install-apk' { Install-Apk $tokens }
        'try' { Try-Release $tokens }
        'android-key' { Android-KeySettings $tokens }
        'cache' { Cache-Manager $tokens }
        'manager' { Release-Manager $tokens }
        'rollback' { Rollback-Release $tokens }
        'rollforward' { Rollforward-Release $tokens }
        'notify' { Notify-Settings $tokens }
        'sign' { Signing-Settings $tokens }
        'recover' { Recovery $tokens }
        'resume' { Recovery $tokens }
        'retry-publish' { Recovery $tokens }
        'update' { DevKit-Update }
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
# Tests dot-source this file with CAVEY_DEVKIT_LIBRARY=1 to call functions directly.
if ($env:CAVEY_DEVKIT_LIBRARY -eq '1') { return }
try {
    Dispatch @($args)
} catch {
    $errorRecord = $_
    if ($script:ExpectedFailure) {
        # A known problem with a clear message: no script location or stack trace.
        [Console]::Error.WriteLine('✗ ' + $errorRecord.Exception.Message)
        exit 1
    }
    $line = if ($errorRecord.InvocationInfo) { $errorRecord.InvocationInfo.ScriptLineNumber } else { 0 }
    $path = if ($errorRecord.InvocationInfo) { $errorRecord.InvocationInfo.ScriptName } else { '' }
    if (-not $path) { $path = $PSCommandPath }
    $location = if ($line -gt 0) { "$($path):$line" } else { [string]$path }
    $message = "DevKit engine error at $location : $($errorRecord.Exception.Message)"
    [Console]::Error.WriteLine($message)
    if ($errorRecord.ScriptStackTrace) {
        [Console]::Error.WriteLine($errorRecord.ScriptStackTrace)
    }
    exit 1
}
