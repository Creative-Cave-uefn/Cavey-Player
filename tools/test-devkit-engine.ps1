# Cavey DevKit engine tests. Dot-sources the engine as a library and calls
# its functions directly: no network, GitHub account, Flutter or Windows build.
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test-devkit-engine.ps1
[CmdletBinding()]
param([string]$Only = '')
$ErrorActionPreference = 'Stop'
$previousLibrary = $env:CAVEY_DEVKIT_LIBRARY
$env:CAVEY_DEVKIT_LIBRARY = '1'
try { . (Join-Path $PSScriptRoot 'cavey-devkit-engine.ps1') } finally { $env:CAVEY_DEVKIT_LIBRARY = $previousLibrary }
if (-not $env:TEMP) { $env:TEMP = [IO.Path]::GetTempPath() }

$script:Failures = 0
$script:Passed = 0
function Run-Test([string]$name, [scriptblock]$body) {
    if ($Only -and $name -notlike "*$Only*") { return }
    # Tests may point DataHome/ConfigFile at temporary folders; restore them.
    $saved = @{ DataHome = $script:DataHome; ConfigFile = $script:ConfigFile; Root = $script:Root }
    try {
        & $body | Out-Null
        $script:Passed++
        Write-Host "ok   $name" -ForegroundColor Green
    } catch {
        $script:Failures++
        Write-Host "FAIL $name : $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        $script:DataHome = $saved.DataHome; $script:ConfigFile = $saved.ConfigFile; $script:Root = $saved.Root
        $script:ExpectedFailure = $false
    }
}

Run-Test 'version' {
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
    Hint 'stable and test channel version selection'
}
Run-Test 'new-channel' {
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
    Hint 'new build channel is distinct from existing channels'
}
Run-Test 'selection' {
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
    Hint 'build arguments and release-channel guards'
    # This is a read-only check of the branch validation path used by /build.
    $remote = @(Get-Branches $false | Select-Object -First 1)
    if ($remote.Count -gt 0 -and $remote[0].branch) {
        $validated = Select-Source ([string]$remote[0].branch)
        if ($validated -cne $remote[0].branch) { Fail 'Explicit branch resolution regression.' }
    }
    Hint 'explicit branch validation'
}
Run-Test 'branches' {
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
    Hint 'malformed branch refs are skipped'
    # Reproduce the real for-each-ref path without network access.
    $actual = @(Get-Branches $false)
    Hint "local Git refs parsed: $($actual.Count) branch(es)"
}
Run-Test 'native' {
    # Offline smoke test: both wrappers must resolve an executable, not recurse.
    $gitVersion = Git @('--version')
    if ($gitVersion -notmatch '^git version ') { Fail "Unexpected Git version output: $gitVersion" }
    Hint "native Git executable: $gitVersion"
    if (Has 'gh') {
        $ghVersion = Gh @('version')
        if ($ghVersion -notmatch '^gh version ') { Fail "Unexpected GitHub CLI output: $ghVersion" }
        Hint "native GitHub CLI executable"
    } else {
        Hint 'GitHub CLI is not installed; skipping optional gh check.'
    }
}
Run-Test 'workflow' {
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
        Hint 'build numbering, artifact verification and corruption detection'
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Run-Test 'retention' {
    if (-not (Is-DevKitChannel 'devkit/dj/20261118-1')) { Fail 'DevKit channel not detected.' }
    if (Is-DevKitChannel 'claude/dj-v2-review-fixes') { Fail 'CI channel detected as DevKit.' }
    if ((DevKit-ChannelName 'dj') -cne 'devkit/dj') { Fail 'Custom channel was not namespaced.' }
    if ((DevKit-ChannelName 'devkit/dj') -cne 'devkit/dj') { Fail 'Namespaced channel was changed.' }
    # Un-drafting resets publishedAt: order must follow the build number.
    $releases = @(
        [pscustomobject]@{ tagName = 'test-devkit-dj-v0.4.0.900'; publishedAt = '2026-11-18T10:00:00Z' },
        [pscustomobject]@{ tagName = 'test-devkit-dj-v0.4.0.1200'; publishedAt = '2026-11-17T10:00:00Z' },
        [pscustomobject]@{ tagName = 'test-devkit-dj-v0.4.0.1000'; publishedAt = $null }
    )
    $order = @(Sort-Newest $releases | ForEach-Object { $_.tagName })
    if (($order -join ',') -cne 'test-devkit-dj-v0.4.0.1200,test-devkit-dj-v0.4.0.1000,test-devkit-dj-v0.4.0.900') {
        Fail "Release order regression: $($order -join ',')"
    }
    Hint 'DevKit channels, naming and build-number ordering'
    $sha = 'a' * 64
    $record = [pscustomobject]@{ artifacts = @(
        [pscustomobject]@{ name = 'CavePlayer-Setup.exe'; size = 10; sha256 = $sha },
        [pscustomobject]@{ name = 'CavePlayer-portable.zip'; size = 20; sha256 = $sha }) }
    $complete = [pscustomobject]@{ assets = @(
        [pscustomobject]@{ name = 'CavePlayer-Setup.exe'; size = 10; state = 'uploaded'; digest = "sha256:$sha" },
        [pscustomobject]@{ name = 'CavePlayer-portable.zip'; size = 20; state = 'uploaded' }) }
    if (Compare-RemoteAssets $complete $record) { Fail 'Complete release reported as incomplete.' }
    $partial = [pscustomobject]@{ assets = @($complete.assets[0]) }
    if ((Compare-RemoteAssets $partial $record) -notmatch 'portable.zip is missing') { Fail 'Missing asset not detected.' }
    $resized = [pscustomobject]@{ assets = @($complete.assets[0], [pscustomobject]@{ name = 'CavePlayer-portable.zip'; size = 5; state = 'uploaded' }) }
    if ((Compare-RemoteAssets $resized $record) -notmatch 'different size') { Fail 'Size mismatch not detected.' }
    $other = [pscustomobject]@{ assets = @([pscustomobject]@{ name = 'CavePlayer-Setup.exe'; size = 10; state = 'uploaded'; digest = ('sha256:' + 'b' * 64) }, $complete.assets[1]) }
    if ((Compare-RemoteAssets $other $record) -notmatch 'SHA-256') { Fail 'Digest mismatch not detected.' }
    Hint 'interrupted publication reconciliation'
}
Run-Test 'smoke' {
    $good = [pscustomobject]@{ version = '0.4.0.12'; channel = 'devkit/dj'; mediaKit = $true; frame = $true }
    if (Smoke-Problem $good '0.4.0.12' 'devkit/dj') { Fail 'A good smoke report was rejected.' }
    if ((Smoke-Problem $good '0.4.0.13' 'devkit/dj') -notmatch 'version') { Fail 'Version mismatch not detected.' }
    if ((Smoke-Problem $good '0.4.0.12' 'devkit/x') -notmatch 'channel') { Fail 'Channel mismatch not detected.' }
    $noMedia = [pscustomobject]@{ version = '0.4.0.12'; channel = 'devkit/dj'; mediaKit = $false; frame = $false }
    if ((Smoke-Problem $noMedia '0.4.0.12' 'devkit/dj') -notmatch 'native player') { Fail 'Missing media libraries not detected.' }
    $crashed = [pscustomobject]@{ error = 'boom' }
    if ((Smoke-Problem $crashed '0.4.0.12' 'devkit/dj') -notmatch 'boom') { Fail 'App error not reported.' }
    Hint 'smoke test report validation'
}
Run-Test 'notes' {
    $record = [pscustomobject]@{
        message = 'Check the new mixer'; source = 'feature/dj'; sha = 'abcdef1234567890'
        channel = 'devkit/dj'; version = '0.4.0.12'; downloader = $null
        changes = [pscustomobject]@{ title = 'Changes since test-devkit-dj-v0.4.0.11'; more = $false
            items = @('Fix crossfade (abc1234)', 'Faster waveform (def5678)') }
    }
    $notes = Release-Notes $record
    if (-not $notes.StartsWith('Check the new mixer')) { Fail 'The tester note must come first.' }
    if ($notes -notmatch '(?m)^- Fix crossfade \(abc1234\)$') { Fail 'Changelog missing from notes.' }
    if ($notes -notmatch '(?m)^Commit: abcdef1234567890$') { Fail 'Commit line must stay parseable.' }
    $discord = Discord-Message $record 'https://example.test/r'
    if ($discord -notmatch '^\*\*Cavey test build\*\* `devkit/dj` · 0\.4\.0\.12' -or $discord -notmatch '• Faster waveform') {
        Fail "Unexpected Discord message: $discord"
    }
    $record.changes.items = @(1..400 | ForEach-Object { 'A very long change description number ' + $_ })
    if ((Discord-Message $record 'https://example.test/r').Length -gt 2000) { Fail 'Discord message exceeds the limit.' }
    if (-not (Test-DiscordWebhook 'https://discord.com/api/webhooks/123/abc_DEF-1')) { Fail 'Valid webhook rejected.' }
    if (Test-DiscordWebhook 'https://evil.example/api/webhooks/123/abc') { Fail 'Foreign URL accepted as webhook.' }
    Hint 'release notes and Discord message'
    $script:DataHome = Join-Path ([IO.Path]::GetTempPath()) ('cavey-config-test-' + [guid]::NewGuid().ToString('N'))
    $script:ConfigFile = Join-Path $script:DataHome 'config.json'
    try {
        Write-Config @{ projectRoot = 'C:\src\cavey' }
        Write-Config @{ discordWebhook = 'https://discord.com/api/webhooks/1/x' }
        $config = Read-Config
        if ($config['projectRoot'] -ne 'C:\src\cavey' -or -not $config['discordWebhook']) { Fail 'Settings were not merged.' }
        Write-Config @{ discordWebhook = $null }
        if ((Read-Config).Contains('discordWebhook')) { Fail 'Setting was not removed.' }
        Hint 'settings merge'
    } finally { Remove-Item -LiteralPath $script:DataHome -Recurse -Force -ErrorAction SilentlyContinue }
}
Run-Test 'lock' {
    $script:DataHome = Join-Path ([IO.Path]::GetTempPath()) ('cavey-lock-test-' + [guid]::NewGuid().ToString('N'))
    try {
        $first = Enter-ReleaseLock
        $blocked = $false
        try { $second = Enter-ReleaseLock; $second.Dispose() } catch { $blocked = $_.Exception.Message -match 'Another DevKit window' }
        $first.Dispose()
        if (-not $blocked) { Fail 'A second build lock was granted while the first was held.' }
        $again = Enter-ReleaseLock
        $again.Dispose()
        Hint 'build lock is exclusive and released'
    } finally {
        Remove-Item -LiteralPath $script:DataHome -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test 'secrets' {
    $env:CAVEY_TEST_CLIENT_SECRET = 's3cr3t-value-123'
    try {
        if (@(Find-Secrets 'release notes without secrets').Count) { Fail 'False positive.' }
        $found = @(Find-Secrets 'oops s3cr3t-value-123 leaked')
        if ($found -notcontains 'CAVEY_TEST_CLIENT_SECRET') { Fail 'Secret value not detected.' }
    } finally { Remove-Item Env:CAVEY_TEST_CLIENT_SECRET -ErrorAction SilentlyContinue }
}
Run-Test 'flutter-version' {
    if (Flutter-Mismatch 'Flutter 3.27.4 • channel stable • https://github.com/flutter/flutter.git') { Fail 'Matching version flagged.' }
    if (-not (Flutter-Mismatch 'Flutter 3.29.0 • channel stable')) { Fail 'Different version not flagged.' }
}
Run-Test 'build-script-selection' {
    $tree = Join-Path ([IO.Path]::GetTempPath()) ('cavey-script-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path (Join-Path $tree 'tools') | Out-Null
    try {
        $own = Join-Path $tree 'tools\local-test-build.ps1'
        Set-Content -LiteralPath $own -Value 'param([string]$ProjectRoot, [string]$Version)' -Encoding UTF8
        if ((Select-BuildScript $tree).origin -ne 'devkit') { Fail 'An old branch script was chosen.' }
        Set-Content -LiteralPath $own -Encoding UTF8 -Value ('param([string]$ProjectRoot, [string]$BuildChannel, [string]$SourceBranch, ' +
            '[switch]$NoPublish, [string]$Version, [switch]$RequireDownloader, [string]$SignThumbprint)')
        $selected = Select-BuildScript $tree
        if ($selected.origin -ne 'branch' -or $selected.path -ne $own) { Fail "A compatible branch script was not chosen: $($selected.origin)" }
        if (@(Build-ScriptParameters $own) -notcontains 'SignThumbprint') { Fail 'Parameters were not read.' }
    } finally { Remove-Item -LiteralPath $tree -Recurse -Force -ErrorAction SilentlyContinue }
}
Run-Test 'working-copy-snapshot' {
    $repo = Join-Path ([IO.Path]::GetTempPath()) ('cavey-snapshot-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    $here = Get-Location
    try {
        Set-Location $repo
        Git @('init','-q') | Out-Null
        Git @('-c','user.name=t','-c','user.email=t@e','commit','-q','--allow-empty','-m','base') | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'tracked.txt') -Value 'changed' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $repo '.gitignore') -Value 'ignored.txt' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $repo 'ignored.txt') -Value 'x' -Encoding Ascii
        $before = Git @('status','--porcelain')
        $env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@e'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@e'
        $sha = Snapshot-WorkingTree $repo
        $files = @((Git @('ls-tree','--name-only',$sha)) -split "\r?\n")
        if ($files -notcontains 'tracked.txt' -or $files -notcontains '.gitignore') { Fail "Snapshot is missing files: $($files -join ',')" }
        if ($files -contains 'ignored.txt') { Fail 'Ignored files must not be snapshotted.' }
        if ((Git @('status','--porcelain')) -ne $before) { Fail "The user's index or working tree changed." }
    } finally {
        foreach ($name in 'GIT_AUTHOR_NAME','GIT_AUTHOR_EMAIL','GIT_COMMITTER_NAME','GIT_COMMITTER_EMAIL') { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
        Set-Location $here
        Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Run-Test 'android-support' {
    $tree = Join-Path ([IO.Path]::GetTempPath()) ('cavey-android-test-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Force -Path $tree | Out-Null
        if (@(Android-Support $tree).Count -ne 3) { Fail 'A tree without Android files was accepted.' }
        foreach ($file in 'lib\mobile_main.dart','tool\setup_android.sh','tool\android\signing.init.gradle') {
            $path = Join-Path $tree $file
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
            Set-Content -LiteralPath $path -Value '' -Encoding Ascii
        }
        $missing = @(Android-Support $tree)
        if ($missing.Count) { Fail "Complete Android tree rejected: $($missing -join ', ')" }
    } finally { Remove-Item -LiteralPath $tree -Recurse -Force -ErrorAction SilentlyContinue }
    # CI runners have a real SDK: hide every place DevKit looks for one.
    $saved = @{}
    foreach ($name in 'ANDROID_HOME','ANDROID_SDK_ROOT','LOCALAPPDATA') { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        $nowhere = Join-Path ([IO.Path]::GetTempPath()) ('no-such-android-sdk-' + [guid]::NewGuid().ToString('N'))
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $nowhere) }
        if (Android-Sdk) { Fail "An SDK was found where there is none: $(Android-Sdk)" }
        if (Find-AndroidTool 'apksigner') { Fail 'A tool was found without an SDK.' }
    } finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
}

Run-Test 'release-age' {
    $old = [pscustomobject]@{ publishedAt = [DateTime]::UtcNow.AddDays(-20).ToString('o') }
    $new = [pscustomobject]@{ publishedAt = [DateTime]::UtcNow.AddHours(-3) }
    $draft = [pscustomobject]@{ publishedAt = $null }
    if ((Release-Age $old) -lt 19.9) { Fail 'Age of an old release is wrong.' }
    if ((Release-Age $new) -gt 1) { Fail 'A recent release looks old.' }
    if ((Release-Age $draft) -ne 0) { Fail 'Drafts must not count as stale.' }
}

Run-Test 'actions-log' {
    $script:DataHome = Join-Path ([IO.Path]::GetTempPath()) ('devkit-actions-' + [guid]::NewGuid().ToString('N'))
    if ((Read-Actions).Count -ne 0) { Fail 'A missing journal must read as empty.' }
    Log-Action 'publish' 'test-demo-v1.0.0.1 · demo'
    Log-Action 'delete' 'test-demo-v1.0.0.0'
    $entries = @(Read-Actions)
    if ($entries.Count -ne 2) { Fail "Expected 2 journal entries, got $($entries.Count)." }
    if ($entries[0].action -cne 'publish' -or $entries[1].detail -cne 'test-demo-v1.0.0.0') { Fail 'Journal entries came back in the wrong order.' }
    if ((Read-Actions 1)[0].action -cne 'delete') { Fail 'The limit must keep the newest entries.' }
}

Run-Test 'self-update-keeps-local-changes' {
    $base = Join-Path ([IO.Path]::GetTempPath()) ('devkit-update-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    $script:DataHome = Join-Path $base 'data'
    $who = @('-c','user.name=t','-c','user.email=t@example.com')
    function G([string]$dir, [string[]]$arguments) { Native 'git' (@('-C',$dir) + $who + $arguments) | Out-Null }
    $origin = Join-Path $base 'origin.git'
    Native 'git' @('init','--bare','--initial-branch=devkit',$origin) | Out-Null
    $mine = Join-Path $base 'mine'
    $other = Join-Path $base 'other'
    Native 'git' @('clone','-q',$origin,$mine) | Out-Null
    Set-Content -LiteralPath (Join-Path $mine 'a.txt') -Value 'a1'
    Set-Content -LiteralPath (Join-Path $mine 'b.txt') -Value 'b1'
    G $mine @('add','-A'); G $mine @('commit','-q','-m','first'); G $mine @('push','-q','origin','devkit')
    Native 'git' @('clone','-q',$origin,$other) | Out-Null
    Set-Content -LiteralPath (Join-Path $other 'a.txt') -Value 'a2'
    G $other @('commit','-q','-am','change a'); G $other @('push','-q','origin','devkit')
    $script:RepoFallback = $mine
    $script:Shared | Add-Member -NotePropertyName devkitBranch -NotePropertyValue 'devkit' -Force
    # A local edit in another file survives the update.
    Set-Content -LiteralPath (Join-Path $mine 'b.txt') -Value 'b-local'
    DevKit-Update | Out-Null
    if ((Get-Content -LiteralPath (Join-Path $mine 'a.txt')).Trim() -cne 'a2') { Fail 'The update was not applied.' }
    if ((Get-Content -LiteralPath (Join-Path $mine 'b.txt')).Trim() -cne 'b-local') { Fail 'The local edit was lost.' }
    # A local edit that conflicts leaves a clean checkout and the edit in the stash.
    Set-Content -LiteralPath (Join-Path $other 'a.txt') -Value 'a3'
    G $other @('commit','-q','-am','change a again'); G $other @('push','-q','origin','devkit')
    Set-Content -LiteralPath (Join-Path $mine 'a.txt') -Value 'a-local'
    DevKit-Update | Out-Null
    if ((Get-Content -LiteralPath (Join-Path $mine 'a.txt')).Trim() -cne 'a3') { Fail 'A conflicting update must leave the new version in place.' }
    if (Native 'git' @('-C',$mine,'status','--porcelain','--untracked-files=no')) { Fail 'The checkout must be clean after a conflict.' }
    if (-not (Native 'git' @('-C',$mine,'stash','list'))) { Fail 'The conflicting edit must stay in the stash.' }
}

Write-Host ''
if ($script:Failures) {
    Write-Host "$($script:Failures) engine test(s) failed, $($script:Passed) passed." -ForegroundColor Red
    exit 1
}
Write-Host "PASS all $($script:Passed) engine tests" -ForegroundColor Green
