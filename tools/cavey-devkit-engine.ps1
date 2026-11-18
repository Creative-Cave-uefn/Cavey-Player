# Cavey DevKit - noninteractive build and GitHub command engine.
# PowerShell 5.1; invoked by tools/devkit/src/runner.ts.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$script:RepoFallback = Split-Path -Parent $PSScriptRoot
$script:SourceRepo = 'Creative-Cave-uefn/Cavey-Player'
$script:ReleaseRepo = 'Creative-Cave-uefn/Cavey-Player-Releases'
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
    if ($null -eq $arguments -or $arguments.Count -lt 2) { return '' }
    for ($i = 0; $i -lt $arguments.Count - 1; $i++) {
        if ($arguments[$i] -eq $key) { return $arguments[$i + 1] }
    }
    return ''
}
function Flag([string[]]$arguments, [string]$key) { return ($null -ne $arguments -and $arguments -contains $key) }
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
function Cached-Worktree([string]$source, [string]$folder, [bool]$fresh) {
    if ($fresh) {
        $tree = Create-BuildWorktree $source $folder
        $tree | Add-Member -NotePropertyName cached -NotePropertyValue $false
        return $tree
    }
    $cache = Cache-Location $source
    $dest = $cache.path
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    if (Test-Path -LiteralPath $dest -PathType Container) {
        $actual = Git @('-C',$dest,'rev-parse','HEAD')
        if ($actual -ne $cache.sha) {
            Fail "Cached worktree does not match selected commit. Use /cache prune then retry: $dest"
        }
        Git @('-C',$dest,'reset','--hard',$cache.sha) | Out-Null
        Hint "Reusing build cache: $dest"
    } else {
        Git @('worktree','add','--detach',$dest,$cache.sha) | Out-Null
        Hint "Created build cache: $dest"
    }
    return [pscustomobject]@{path=$dest;sha=$cache.sha;cached=$true}
}
function Cache-Manager([string[]]$tokens) {
    $root = Join-Path $script:DataHome 'source-cache'
    $paths = @(if (Test-Path -LiteralPath $root) {
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue
    })
    if ($tokens -contains 'prune') {
        if (-not (Ask "Remove $($paths.Count) cached source worktrees?" (Flag $tokens '--yes'))) { return }
        foreach ($item in $paths) {
            Git @('worktree','remove','--force',$item.FullName) | Out-Null
        }
        Git @('worktree','prune') | Out-Null
        Say '  Build cache cleared.' Green
        return
    }
    Heading "Source build cache · $($paths.Count) worktree(s)"
    foreach ($item in $paths) { Say "  $($item.Name) · $($item.LastWriteTime)" }
    Hint 'Cache is keyed by source commit and Flutter version. Use /cache prune to reclaim space.'
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
        if ([string]::IsNullOrWhiteSpace($current)) { Fail 'Detached HEAD; select a branch.' }
        return $current
    }
    if ($requested -and $requested -ne 'latest') {
        # Explicit choices from the React wizard never depend on array indexes.
        $ref = "refs/remotes/origin/$requested"
        $resolved = Git @('rev-parse','--verify',$ref)
        if ($resolved -notmatch '^[0-9a-fA-F]{40,64}$') { Fail "Branch $requested was not found." }
        return $requested
    }
    $branches = @(Get-Branches)
    if ($branches.Count -eq 0) { Fail 'No remote origin branches found. Run git fetch origin.' }
    if ($requested -eq 'latest' -or (-not $requested -and -not $script:Interactive)) {
        $latest = @($branches | Where-Object {
            $null -ne $_ -and $_.branch -and $_.branch -ne 'main' -and
            $_.branch -ne 'beta' -and $_.branch -notlike 'feat/keivi-devkit-*'
        })
        if ($latest.Count -eq 0) { Fail 'No experimental branches found.' }
        $candidate = $latest | Select-Object -First 1
        Hint "Latest by commit date: $($candidate.branch), $($candidate.sha)"
        return [string]$candidate.branch
    }
    $choices = @($branches | Where-Object { $null -ne $_ -and $_.branch } | Select-Object -First 50)
    if ($choices.Count -eq 0) { Fail 'No selectable branches were found.' }
    $labels = @($choices | ForEach-Object { "$($_.branch) · $($_.sha) · $($_.date)" })
    $index = Pick 'Select a GitHub branch' $labels
    if ($null -eq $index -or $index -lt 0 -or $index -ge $choices.Count) { Fail 'Invalid branch choice.' }
    return [string]$choices[$index].branch
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
function Source-BaseVersion([string]$source) {
    # Use the source branch version rather than a potentially stale checkout.
    $ref = "refs/remotes/origin/$($source):pubspec.yaml"
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
function Trim-ChannelReleases([string]$channel, [int]$keep = 3) {
    # Never remove stable releases. Keep three newest published test releases,
    # so Release Manager has rollback targets after an update.
    $prefix = 'test-' + (Slug $channel) + '-v'
    $versions = @(Test-Releases | Where-Object {
        ([string]$_.tagName).StartsWith($prefix,[StringComparison]::Ordinal)
    } | Sort-Object publishedAt -Descending)
    foreach ($old in @($versions | Select-Object -Skip $keep)) {
        try {
            Remove-TestRelease $old.tagName
            Hint "Pruned old test release: $($old.tagName)"
        } catch {
            Say "  ! Could not prune $($old.tagName): $_" Yellow
        }
    }
}
function Publish-Manifest([object]$record) {
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
        # The previous create may have succeeded before the network disconnected.
        # Do not overwrite potentially different remote assets silently.
        Fail "Tag $tag is already published. Check GitHub Releases before retrying."
    }
    Stage 'publish' 'running' 'Uploading release assets'
    $notes = @(
        'Cavey DevKit', "Source: $script:SourceRepo",
        "Branch: $($record.source)", "Commit: $($record.sha)",
        "Update channel: $($record.channel)", "Version: $($record.version)"
    ) -join [Environment]::NewLine
    $publishArgs = @('release','create',$tag) + $files + @(
        '--repo',$script:ReleaseRepo,'--prerelease',
        '--title',"Test: $($record.channel) · $($record.version)",
        '--notes',$notes
    )
    Gh $publishArgs | Out-Null
    $record.status = 'published'
    $script:CurrentManifest = $record
    Save-BuildState
    Stage 'publish' 'done' 'Release uploaded'
    Say "  ✓ https://github.com/$script:ReleaseRepo/releases/tag/$tag" Green
    if ($record.mode -eq 'update') { Trim-ChannelReleases ([string]$record.channel) 3 }
}
function Recovery([string[]]$tokens) {
    $records = @(Build-Records)
    $target = Option $tokens '--id'
    if (-not $target) {
        Heading "Recovery · $($records.Count) saved run(s)"
        foreach ($record in @($records | Select-Object -First 12)) {
            Say "  $($record.id) · $($record.status) · $($record.source) · $($record.channel)"
        }
        Hint 'Use /resume --id <id> to republish verified artifacts without rebuilding.'
        Hint 'Interrupted compiling runs require a new build (the source cache is retained).'
        return
    }
    $record = @($records | Where-Object { $_.id -ceq $target } | Select-Object -First 1)
    if ($record.Count -eq 0) { Fail "Unknown build run: $target" }
    if (-not (Ask "Republish saved run $target?" (Flag $tokens '--yes'))) { return }
    $script:CurrentManifest = $record[0]
    $script:CurrentManifest.stages = @{}
    try {
        Publish-Manifest $record[0]
    } catch {
        if ($record[0].status -ne 'published') {
            $record[0].status = 'publish_failed'
            Save-BuildState
        }
        throw
    } finally {
        $script:CurrentManifest = $null
    }
}
function Release-Manager([string[]]$tokens) {
    $channel = Option $tokens '--channel'
    $all = @(All-TestReleases | Sort-Object publishedAt -Descending)
    if ($channel) {
        $prefix = 'test-' + (Slug $channel) + '-v'
        $all = @($all | Where-Object { ([string]$_.tagName).StartsWith($prefix,[StringComparison]::Ordinal) })
        Heading "Channel: $channel · $($all.Count) published release(s)"
        foreach ($release in $all) {
            Say "  $($release.tagName) · $($release.publishedAt) $(if ($release.isDraft) { '[DRAFT]' } else { '[ACTIVE]' })"
        }
        Hint 'Use /rollback --channel <name> --to <tag> to restore a previous version.'
        return
    }
    Heading 'Release Manager · test channels'
    $seen = @{}
    foreach ($release in $all) {
        $name = Release-Channel $release
        $id = Slug $name
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $count = @($all | Where-Object {
            ([string]$_.tagName).StartsWith(('test-' + $id + '-v'),[StringComparison]::Ordinal)
        }).Count
        Say "  $name · $count version(s) · latest: $($release.tagName)"
    }
    Hint 'Select a channel from /build → Update, or run /manager --channel <name>.'
}
function Rollback-Release([string[]]$tokens) {
    $channel = Option $tokens '--channel'
    $to = Option $tokens '--to'
    if (-not $channel -or -not $to) {
        Fail 'Usage: /rollback --channel <name> --to <test-release-tag> --yes'
    }
    $prefix = 'test-' + (Slug $channel) + '-v'
    $existing = @(Test-Releases | Where-Object {
        -not $_.isDraft -and
        ([string]$_.tagName).StartsWith($prefix,[StringComparison]::Ordinal)
    } | Sort-Object publishedAt -Descending)
    $found = @($existing | Where-Object { $_.tagName -ceq $to })
    if ($found.Count -ne 1) { Fail 'Rollback target must be an active prerelease in the selected channel.' }
    $newer = @($existing | Where-Object { [string]$_.publishedAt -gt [string]$found[0].publishedAt })
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
    Stage 'publish' 'running' 'Restoring previous release'
    foreach ($release in $newer) {
        Gh @('release','edit',$release.tagName,'--repo',$script:ReleaseRepo,'--draft') | Out-Null
        Hint "  Hidden as draft: $($release.tagName)"
    }
    Stage 'publish' 'done' 'Previous release restored'
    Say "  ✓ Active release restored: https://github.com/$script:ReleaseRepo/releases/tag/$to" Green
}
function DevKit-Update {
    # Only fast-forward the DevKit's OWN checkout. Never update the app source.
    $ownRepo = $script:RepoFallback
    $current = Native 'git' @('-C',$ownRepo,'branch','--show-current')
    if ($current -notin @('devkit-live','feat/keivi-devkit-20261117')) {
        Fail "Self-update disabled on branch $current. Use a dedicated DevKit worktree."
    }
    $dirty = Native 'git' @('-C',$ownRepo,'status','--porcelain')
    if ($dirty) { Fail 'DevKit has uncommitted changes. Self-update will not overwrite them.' }
    $before = Native 'git' @('-C',$ownRepo,'rev-parse','HEAD')
    Heading 'Checking for DevKit updates'
    Native 'git' @('-C',$ownRepo,'fetch','origin','feat/keivi-devkit-20261117') | Out-Null
    $upstream = Native 'git' @('-C',$ownRepo,'rev-parse','FETCH_HEAD')
    if ($before -eq $upstream) { Say '  DevKit is already up to date.' Green; return }
    $base = Native 'git' @('-C',$ownRepo,'merge-base',$before,$upstream)
    if ($base -ne $before) { Fail 'DevKit branch has diverged. Update cancelled; local commits are preserved.' }
    Native 'git' @('-C',$ownRepo,'merge','--ff-only',$upstream) | Out-Null
    Say "  Updated DevKit: $before → $upstream" Green
    Write-Host '@@CAVEY_RESTART|updated'
}
function Build([string[]]$tokens) {
    Check-Repo
    $source = Select-Source (Option $tokens '--branch')
    $mode = Option $tokens '--mode'
    $local = Flag $tokens '--local'
    $fresh = Flag $tokens '--fresh'
    if (-not $mode) {
        if ($local -or -not $script:Interactive) { $mode = 'new' }
        else { $mode = @('new','update')[(Pick 'Publication mode' @('New independent build','Update existing test channel'))] }
    }
    if (@('new','update') -notcontains $mode) { Fail 'Invalid mode; use new/update.' }
    if ($mode -eq 'update' -and $local) { Fail 'Update mode requires publication. Do not use --local.' }
    if ($mode -eq 'update') {
        $releases = @(Test-Releases | Sort-Object publishedAt -Descending)
        if ($releases.Count -eq 0) { Fail 'No test releases available to update.' }
        $specified = Option $tokens '--channel'
        if ($specified) {
            $expected = Slug $specified
            $pattern = '^test-' + [regex]::Escape($expected) + '-v\d'
            $matches = @($releases | Where-Object { $_.tagName -match $pattern })
            if ($matches.Count -eq 0) { Fail "Channel $specified was not found." }
            $channel = Release-Channel ($matches | Select-Object -First 1)
        } else {
            if (-not $script:Interactive) { Fail 'For --mode update, specify --channel.' }
            $slots = @(); $seen = @{}
            foreach ($release in $releases) {
                $name = Release-Channel $release; $id = Slug $name
                if ($seen.ContainsKey($id)) { continue }
                $seen[$id] = $true
                $slots += [pscustomobject]@{channel=$name;tag=$release.tagName}
            }
            $labels = @($slots | ForEach-Object { "$($_.channel) · $($_.tag)" })
            $index = Pick 'Select test channel to update' $labels
            if ($null -eq $index -or $index -lt 0 -or $index -ge $slots.Count) { Fail 'Invalid channel choice.' }
            $channel = $slots[$index].channel
        }
    } else {
        $channel = Option $tokens '--channel'
        if ($local) {
            if (-not $channel) { $channel = New-ReleaseChannel $source @() }
        } else {
            $published = @(All-TestReleases)
            if (-not $channel) { $channel = New-ReleaseChannel $source $published }
            if (Test-ChannelExists $channel $published) {
                Fail "Channel $channel already exists. Choose Update existing build."
            }
        }
    }
    Heading 'Build plan'
    Say "  Source: origin/$source"
    Say "  Channel: $channel"
    Say "  Mode: $mode · $(if ($local) { 'local only' } else { 'publish to GitHub Releases' })"
    Say "  Source cache: $(if ($fresh) { 'disabled (--fresh)' } else { 'enabled, keyed by commit and Flutter version' })"
    if (-not (Ask 'Prepare source and build?' (Flag $tokens '--yes'))) { return }
    $base = if ($local) { Source-BaseVersion $source } else { Stable-Base $mode $channel $source }
    $existing = if ($local) { @() } else { @(All-TestReleases) }
    $number = Next-BuildNumber $base $channel $existing
    $version = "$base.$number"
    $tag = 'test-' + (Slug $channel) + '-v' + $version
    $id = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6)
    $folder = Join-Path (Join-Path $script:DataHome 'builds') $id
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $start = Get-Date
    $status = 'building'; $sha = ''; $worktree = $null; $cached = $false
    $script:CurrentManifest = @{
        id=$id; manifestPath=(Join-Path $folder 'run.json')
        folder=$folder; status='building'; stages=@{}
        source=$source; sha=''; mode=$mode; channel=$channel
        version=$version; tag=$tag; local=$local
        artifacts=@(); startedUtc=[DateTime]::UtcNow.ToString('o')
        updatedUtc=[DateTime]::UtcNow.ToString('o')
    }
    Save-BuildState
    try {
        Stage 'source' 'running' 'Prepare source checkout'
        $tree = Cached-Worktree $source $folder $fresh
        $worktree = $tree.path
        $sha = $tree.sha
        $cached = [bool]$tree.cached
        $script:CurrentManifest.sha = $sha
        Stage 'source' 'done' 'Source checkout ready'
        $buildArgs = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$script:BuildScript,
            '-ProjectRoot',$worktree,'-SourceBranch',$source,'-NoPublish',
            '-BuildChannel',$channel,'-Version',$version
        )
        if (Flag $tokens '--skip-checks') { $buildArgs += '-SkipChecks' }
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
            }
            if (-not $cached) {
                try { Git @('worktree','remove','--force',$worktree) | Out-Null }
                catch { Say "  ! Could not clean temporary worktree: $_" Yellow }
            }
        }
        if ($null -ne $script:CurrentManifest) {
            $script:CurrentManifest.status = $status
            Save-BuildState
            $script:CurrentManifest = $null
        }
        $script:CurrentStage = ''
        Add-History ([pscustomobject]@{
            time=(Get-Date).ToUniversalTime().ToString('o')
            mode=$mode; sourceBranch=$source; channel=$channel; sha=$sha
            version=$version; status=$status; folder=$folder; id=$id
            seconds=[math]::Round(((Get-Date)-$start).TotalSeconds,1)
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
        '/build                        Guided build: branch, type, confirmation'
        '/build --branch <name> --local --yes'
        '/build --branch <name> --mode new --yes'
        '/build --branch <name> --mode update --channel <name> --yes'
        '/build --branch <name> --fresh --yes   (no source cache)'
        '/releases [--channel <name>]  Test channels and their versions'
        '/rollback --channel <name> --to <tag> --yes'
        '/clean [--dry-run] [--keep N] [--yes]'
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
        'selftest-version' {
            $fixtures = @(
                [pscustomobject]@{ tagName = 'v0.3.1'; isPrerelease = $false; publishedAt = '2026-11-10' },
                [pscustomobject]@{ tagName = 'v0.4.0'; isPrerelease = $false; publishedAt = '2026-11-13' },
                [pscustomobject]@{ tagName = 'test-claude-dj-v2-review-fixes-v0.4.0.11451'; isPrerelease = $true; publishedAt = '2026-11-16' },
                [pscustomobject]@{ tagName = 'test-claude-dj-v2-review-fixes-v0.4.0.11422'; isPrerelease = $true; publishedAt = '2026-11-15' }
            )
            if ((Version-BaseFromReleases $fixtures 'new' '') -cne '0.4.0') {
                Fail 'Stable release version selection regression.'
            }
            if ((Version-BaseFromReleases $fixtures 'update' 'claude/dj-v2-review-fixes') -cne '0.4.0') {
                Fail 'Existing release channel version selection regression.'
            }
            $channelOnly = @($fixtures | Where-Object { $_.isPrerelease })
            if ((Version-BaseFromReleases $channelOnly 'update' 'claude/dj-v2-review-fixes') -cne '0.4.0') {
                Fail 'Release channel update requires a stable release (regression).'
            }
            $missing = @(Version-BaseFromReleases @() 'new' '')
            if ($missing.Count -ne 0 -and $missing[0]) {
                Fail 'No releases should produce no base version.'
            }
            Say 'PASS stable and test channel version selection' Green
        }
        'selftest-new-channel' {
            $existing = @([pscustomobject]@{
                tagName = 'test-devkit-dj-engine-20261117-172954-v0.4.0.11800'
            })
            $newChannel = New-ReleaseChannel 'dj-engine' $existing
            if ($newChannel -notmatch '^devkit/dj-engine/\d{8}-\d{6}-\d{3}-[0-9a-f]{10}$') {
                Fail "Generated new channel has unexpected format: $newChannel"
            }
            if (-not (Test-ChannelExists 'devkit/dj-engine/20261117-172954' $existing)) {
                Fail 'Existing test channel was not detected.'
            }
            if (Test-ChannelExists $newChannel $existing) {
                Fail 'Generated new channel collides with an existing release.'
            }
            Say 'PASS new build channel is distinct from existing channels' Green
        }
        'selftest-selection' {
            $empty = @()
            $demo = @('build','--branch','main','--mode','new','--yes')
            if ((Option $empty '--branch') -ne '') { Fail 'Empty argument list should return an empty option.' }
            if (Flag $empty '--yes') { Fail 'Empty argument list must not indicate confirmation.' }
            if ((Option $demo '--branch') -cne 'main' -or (Option $demo '--mode') -cne 'new' -or
                -not (Flag $demo '--yes')) { Fail 'Build argument parsing regression.' }
            $english = [pscustomobject]@{ name = 'Test: dj · 0.4.0'; tagName = 'test-dj-v0.4.0' }
            $legacy = [pscustomobject]@{ name = 'Тест: wave · 0.4.0'; tagName = 'test-wave-v0.4.0' }
            if ((Release-Channel $english) -cne 'dj' -or (Release-Channel $legacy) -cne 'wave') {
                Fail 'Release channel parsing regression.'
            }
            Say 'PASS build arguments and release-channel guards' Green
            # This is a read-only check of the branch validation path used by /build.
            $remote = @(Get-Branches $false | Select-Object -First 1)
            if ($remote.Count -gt 0 -and $remote[0].branch) {
                $validated = Select-Source ([string]$remote[0].branch)
                if ($validated -cne $remote[0].branch) { Fail 'Explicit branch resolution regression.' }
            }
            Say 'PASS explicit branch validation' Green
        }
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
        'selftest-workflow' {
            $fixtures = @(
                [pscustomobject]@{tagName='test-dj-v0.4.0.90000';publishedAt='2026-11-15'},
                [pscustomobject]@{tagName='test-dj-v0.4.0.90001';publishedAt='2026-11-16'}
            )
            $next = Next-BuildNumber '0.4.0' 'dj' $fixtures
            if ($next -le 90001) { Fail 'Build number must exceed an existing channel version.' }
            $temporary = Join-Path $env:TEMP ("cavey-workflow-test-" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $temporary | Out-Null
            try {
                $entries = @()
                foreach ($name in @('CavePlayer-Setup.exe','CavePlayer-portable.zip')) {
                    $p = Join-Path $temporary $name
                    Set-Content -LiteralPath $p -Value $name -Encoding Ascii
                    $entries += @{path=$p;sha256=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}
                }
                $record = @{artifacts=$entries}
                $found = @(Verify-Artifacts $record)
                if ($found.Count -ne 2) { Fail 'Artifact verification count regression.' }
                Set-Content -LiteralPath $entries[0].path -Value 'tampered' -Encoding Ascii
                $checksumRejected = $false
                try { Verify-Artifacts $record | Out-Null } catch { $checksumRejected = $true }
                if (-not $checksumRejected) { Fail 'Corrupted build artifact passed SHA-256 verification.' }
                Say 'PASS build numbering, artifact verification and corruption detection' Green
            } finally {
                Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
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
            if (Option $tokens '--channel') { Release-Manager $tokens; return }
            $releases = @(Test-Releases | Sort-Object publishedAt -Descending)
            Heading "Test releases · $($releases.Count)"
            foreach ($r in $releases) { Say "  $($r.tagName) · $($r.publishedAt)" }
        }
        'clean' { Clean $tokens }
        'build' { Build $tokens }
        'cache' { Cache-Manager $tokens }
        'manager' { Release-Manager $tokens }
        'rollback' { Rollback-Release $tokens }
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
try {
    Dispatch @($args)
} catch {
    $errorRecord = $_
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
