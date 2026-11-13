# Windows PowerShell 5.1+. Local Android runner setup, no Bash or Python.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root

if (-not (Test-Path 'android/app/src/main/AndroidManifest.xml')) {
    flutter create --platforms=android --org app.cavey --project-name cave_player .
    if ($LASTEXITCODE -ne 0) { throw 'flutter create failed' }
}

$manifest = Join-Path $root 'android/app/src/main/AndroidManifest.xml'
[xml]$doc = Get-Content -Raw -Encoding UTF8 $manifest
$ns = 'http://schemas.android.com/apk/res/android'
$app = $doc.SelectSingleNode('/manifest/application')
if ($null -eq $app) { throw 'AndroidManifest is missing application' }

function AndroidAttr($node, [string]$key, [string]$value) {
    $node.SetAttribute($key, $ns, $value)
}
function AddChild($parent, [string]$elementName, [string]$key, [string]$value) {
    $child = $doc.CreateElement($elementName)
    AndroidAttr $child $key $value
    [void]$parent.AppendChild($child)
    return $child
}

$rootElement = $doc.DocumentElement
$permissions = @(
    'android.permission.INTERNET',
    'android.permission.REQUEST_INSTALL_PACKAGES',
    'android.permission.WAKE_LOCK',
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
    'android.permission.POST_NOTIFICATIONS'
)
foreach ($permission in $permissions) {
    $found = $false
    foreach ($existing in @($rootElement.SelectNodes('uses-permission'))) {
        if ($existing.GetAttribute('name', $ns) -eq $permission) { $found = $true; break }
    }
    if (-not $found) { [void](AddChild $rootElement 'uses-permission' 'name' $permission) }
}

AndroidAttr $app 'label' 'Cavey Player'
AndroidAttr $app 'icon' '@mipmap/ic_launcher'
AndroidAttr $app 'usesCleartextTraffic' 'true'
AndroidAttr $app 'extractNativeLibs' 'true'

$provider = $null
foreach ($item in @($app.SelectNodes('provider'))) {
    if ($item.GetAttribute('name', $ns) -eq 'androidx.core.content.FileProvider') { $provider = $item; break }
}
if ($null -eq $provider) {
    $provider = AddChild $app 'provider' 'name' 'androidx.core.content.FileProvider'
    AndroidAttr $provider 'authorities' ('$' + '{applicationId}.fileprovider')
    AndroidAttr $provider 'exported' 'false'
    AndroidAttr $provider 'grantUriPermissions' 'true'
    $meta = AddChild $provider 'meta-data' 'name' 'android.support.FILE_PROVIDER_PATHS'
    AndroidAttr $meta 'resource' '@xml/file_paths'
}

$service = $null
foreach ($item in @($app.SelectNodes('service'))) {
    if ($item.GetAttribute('name', $ns) -eq 'com.ryanheise.audioservice.AudioService') { $service = $item; break }
}
if ($null -eq $service) {
    $service = AddChild $app 'service' 'name' 'com.ryanheise.audioservice.AudioService'
    AndroidAttr $service 'foregroundServiceType' 'mediaPlayback'
    AndroidAttr $service 'exported' 'true'
    $filter = $doc.CreateElement('intent-filter')
    [void]$service.AppendChild($filter)
    [void](AddChild $filter 'action' 'name' 'android.media.browse.MediaBrowserService')
    $receiver = AddChild $app 'receiver' 'name' 'com.ryanheise.audioservice.MediaButtonReceiver'
    AndroidAttr $receiver 'exported' 'true'
    $filter = $doc.CreateElement('intent-filter')
    [void]$receiver.AppendChild($filter)
    [void](AddChild $filter 'action' 'name' 'android.intent.action.MEDIA_BUTTON')
}

$clientId = $env:GOOGLE_ANDROID_CLIENT_ID
if (-not [string]::IsNullOrWhiteSpace($clientId)) {
    $scheme = 'com.googleusercontent.apps.' + $clientId.Replace('.apps.googleusercontent.com', '')
    $activity = $app.SelectSingleNode('activity')
    if ($null -eq $activity) { throw 'AndroidManifest has no MainActivity' }
    $found = $false
    foreach ($item in @($activity.SelectNodes('intent-filter/data'))) {
        if ($item.GetAttribute('scheme', $ns) -eq $scheme) { $found = $true; break }
    }
    if (-not $found) {
        $filter = $doc.CreateElement('intent-filter')
        [void]$activity.AppendChild($filter)
        [void](AddChild $filter 'action' 'name' 'android.intent.action.VIEW')
        foreach ($category in @('android.intent.category.DEFAULT', 'android.intent.category.BROWSABLE')) {
            [void](AddChild $filter 'category' 'name' $category)
        }
        [void](AddChild $filter 'data' 'scheme' $scheme)
        $meta = AddChild $activity 'meta-data' 'name' 'flutter_deeply_linking_enabled'
        AndroidAttr $meta 'value' 'false'
    }
}
$doc.Save($manifest)

$src = 'android/app/src/main/kotlin/app/cavey/cave_player'
New-Item -ItemType Directory -Path $src -Force | Out-Null
Remove-Item 'android/app/src/main/java/app/cavey/cave_player/MainActivity.java' -ErrorAction SilentlyContinue
Copy-Item 'tool/android/MainActivity.kt' (Join-Path $src 'MainActivity.kt') -Force
New-Item -ItemType Directory -Path 'android/app/src/main/res/xml' -Force | Out-Null
Copy-Item 'tool/android/file_paths.xml' 'android/app/src/main/res/xml/file_paths.xml' -Force
$gradleInit = Join-Path $HOME '.gradle/init.d'
New-Item -ItemType Directory -Path $gradleInit -Force | Out-Null
Copy-Item 'tool/android/signing.init.gradle' (Join-Path $gradleInit 'cavey-signing.gradle') -Force

$gradleKts = 'android/app/build.gradle.kts'
$gradleGroovy = 'android/app/build.gradle'
$gradle = if (Test-Path $gradleKts) { $gradleKts } elseif (Test-Path $gradleGroovy) { $gradleGroovy } else { throw 'Gradle app configuration missing' }
$artifact = 'dev.ffmpegkit-maintained:yt-dlp-android:2.0.2'
$text = Get-Content $gradle -Raw -Encoding UTF8
if (-not $text.Contains($artifact)) {
    $nl = [Environment]::NewLine
    if ($gradle.EndsWith('.kts')) {
        $text += $nl + '// Android YouTube audio backend' + $nl + 'dependencies {' + $nl +
            ('    implementation("{0}")' -f $artifact) + $nl + '}' + $nl
    } else {
        $text += $nl + '// Android YouTube audio backend' + $nl + 'dependencies {' + $nl +
            ("    implementation '{0}'" -f $artifact) + $nl + '}' + $nl
    }
    [System.IO.File]::WriteAllText((Join-Path $root $gradle), $text)
}

# High-quality launcher icons using Windows' built-in System.Drawing.
$iconPath = Join-Path $root 'assets/icon.png'
if (Test-Path $iconPath) {
    Add-Type -AssemblyName System.Drawing
    $srcImage = [System.Drawing.Image]::FromFile($iconPath)
    try {
        $sizes = @{ mdpi = 48; hdpi = 72; xhdpi = 96; xxhdpi = 144; xxxhdpi = 192 }
        foreach ($density in $sizes.Keys) {
            $n = $sizes[$density]
            $out = Join-Path $root ("android/app/src/main/res/mipmap-" + $density)
            New-Item -ItemType Directory -Path $out -Force | Out-Null
            $bmp = New-Object System.Drawing.Bitmap($n, $n)
            try {
                $graphics = [System.Drawing.Graphics]::FromImage($bmp)
                try {
                    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphics.DrawImage($srcImage, 0, 0, $n, $n)
                } finally { $graphics.Dispose() }
                $bmp.Save((Join-Path $out 'ic_launcher.png'), [System.Drawing.Imaging.ImageFormat]::Png)
            } finally { $bmp.Dispose() }
        }
    } finally { $srcImage.Dispose() }
}

flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }
Write-Host 'Android runner ready (local Windows setup)' -ForegroundColor Green
