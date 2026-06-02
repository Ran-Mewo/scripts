# =============================================
# OpenSteam + Luatools Plugin + Millennium Installer
# =============================================

$SelfUrl = 'https://raw.githubusercontent.com/Ran-Mewo/scripts/refs/heads/main/opensteam-install.ps1'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argv = if ($PSCommandPath) {
        @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath) + $args
    } else {
        @('-NoProfile','-ExecutionPolicy','Bypass','-Command',"irm $SelfUrl | iex")
    }
    Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argv
    exit
}

$OpenSteamRepo = "OpenSteam001/OpenSteamTool"
$LtPluginRepos = @('madoiscool/ltsteamplugin','piqseu/ltsteamplugin')
$MillenniumUrls = @(
    'https://clemdotla.github.io/millennium-installer-ps1/millennium.ps1'
)
$SteamDefault  = "C:\Program Files (x86)\Steam"
$Tmp           = $env:TEMP

function Write-Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[OK] $m"      -ForegroundColor Green }
function Write-Warn($m) { Write-Host "[!]  $m"      -ForegroundColor Yellow }
function Write-Err($m)  { Write-Host "[X]  $m"      -ForegroundColor Red }

function Stop-Steam {
    $procs = Get-Process steam -ErrorAction SilentlyContinue
    if (-not $procs) { Write-Ok "Steam is not running."; return }
    Write-Warn "Closing Steam..."
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Get-Process steam -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Ok "Steam closed."
}

function Find-SteamPath {
    $candidates = @(
        (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction SilentlyContinue).InstallPath
        (Get-ItemProperty 'HKCU:\Software\Valve\Steam'             -ErrorAction SilentlyContinue).SteamPath
        $SteamDefault
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    if (-not $candidates) { Write-Err "Steam not found."; exit 1 }
    $candidates[0]
}

function Get-LatestReleaseTag($repo) {
    $r = Invoke-WebRequest -Uri "https://github.com/$repo/releases/latest" `
        -UseBasicParsing -MaximumRedirection 0 -ErrorAction SilentlyContinue
    ($r.Headers.Location -split '/')[-1]
}

function Get-LatestZipUrl($repo, $pattern) {
    $tag  = Get-LatestReleaseTag $repo
    $page = Invoke-WebRequest -Uri "https://github.com/$repo/releases/expanded_assets/$tag" -UseBasicParsing
    $href = $page.Links.href | Where-Object { $_ -match $pattern } | Select-Object -First 1
    if (-not $href) { Write-Err "No asset matching '$pattern' in ${repo}@${tag}"; exit 1 }
    "https://github.com$href"
}

function Resolve-LatestPlugin($repos) {
    # Pick the repo whose latest release tag has the highest [version].
    $best = $repos | ForEach-Object {
        $tag = Get-LatestReleaseTag $_
        [pscustomobject]@{ Repo = $_; Tag = $tag; Version = [version]($tag -replace '^v','') }
    } | Sort-Object Version -Descending | Select-Object -First 1
    Write-Ok "Latest plugin: $($best.Repo) @ $($best.Tag)"
    "https://github.com/$($best.Repo)/releases/download/$($best.Tag)/ltsteamplugin.zip"
}

function Get-File($url, $dest) {
    Write-Host "Downloading $url" -ForegroundColor DarkGray
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
}

function Expand-Into($zip, $dest) {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Expand-Archive -Path $zip -DestinationPath $dest -Force
}

function New-DirSymlink($link, $target) {
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    if (Test-Path $link) {
        $item = Get-Item $link -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Write-Ok "Symlink already exists: $link"; return
        }
        Write-Warn "Migrating existing folder into link target..."
        Get-ChildItem $link -Force | Move-Item -Destination $target -Force -ErrorAction SilentlyContinue
        Remove-Item $link -Recurse -Force
    }
    cmd.exe /c "mklink /d `"$link`" `"$target`"" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Err "mklink failed for $link"; exit 1 }
    Write-Ok "Linked: $link -> $target"
}

function Set-PluginFastDownload($pluginDir) {
    $cfgPath = Join-Path $pluginDir 'backend\data\settings.json'
    if (-not (Test-Path $cfgPath)) { Write-Warn "settings.json not found, skipping fastDownload."; return }
    $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfg.values.general.fastDownload = $true
    $cfg | ConvertTo-Json -Depth 10 | Set-Content $cfgPath -Encoding UTF8
    Write-Ok "Enabled fastDownload in plugin settings."
}

function Test-Millennium($steamPath) {
    (Test-Path (Join-Path $steamPath 'millennium.dll')) -or
    (Test-Path (Join-Path $steamPath 'millennium'))
}

function Install-Millennium($steamPath) {
    foreach ($url in $MillenniumUrls) {
        try {
            $code = Invoke-RestMethod $url -TimeoutSec 30
            if ($code) {
                Invoke-Expression "& { $code } -NoLog -DontStart -SteamPath '$steamPath'"
                return
            }
        } catch { Write-Warn "Millennium source failed: $url" }
    }
    throw "Could not fetch the Millennium installer."
}

# ==================== MAIN ====================

try {
    Write-Host "=== OpenSteam + Luatools + Millennium Installer ===" -ForegroundColor Magenta

    Write-Step "Stopping Steam"
    Stop-Steam

    Write-Step "Locating Steam"
    $SteamPath = Find-SteamPath
    Write-Ok "Steam: $SteamPath"

    Write-Step "Installing OpenSteamTool"
    $openZip = Join-Path $Tmp 'opensteamtool.zip'
    Get-File (Get-LatestZipUrl $OpenSteamRepo 'Release\.zip$') $openZip
    Expand-Into $openZip $SteamPath
    Remove-Item $openZip -Force -ErrorAction SilentlyContinue
    Write-Ok "OpenSteamTool extracted to Steam."

    Write-Step "Linking config\stplug-in -> config\lua"
    $cfg = Join-Path $SteamPath 'config'
    New-Item -ItemType Directory -Force -Path $cfg | Out-Null
    New-DirSymlink (Join-Path $cfg 'stplug-in') (Join-Path $cfg 'lua')

    Write-Step "Installing ltsteamplugin (luatools)"
    $ltZip       = Join-Path $Tmp 'ltsteamplugin.zip'
    $pluginsRoot = if (Test-Path (Join-Path $SteamPath 'plugins')) { Join-Path $SteamPath 'plugins' } else { Join-Path $SteamPath 'millennium\plugins' }
    $pluginDir   = Join-Path $pluginsRoot 'luatools'
    if (Test-Path $pluginDir) {
        Write-Warn "Removing existing luatools folder..."
        Remove-Item $pluginDir -Recurse -Force
    }
    Get-File (Resolve-LatestPlugin $LtPluginRepos) $ltZip
    Expand-Into $ltZip $pluginDir
    Remove-Item $ltZip -Force -ErrorAction SilentlyContinue
    Set-PluginFastDownload $pluginDir

    Write-Step "Installing Millennium"
    $hasMillennium = Test-Millennium $SteamPath
    $doInstall     = $true
    if ($hasMillennium) {
        $reply = Read-Host "Millennium is already installed. Update it? [y/N]"
        $doInstall = $reply -match '^[Yy]'
    }
    if ($doInstall) {
        Install-Millennium $SteamPath
        Write-Ok (@{ $true = "Millennium updated."; $false = "Millennium installed." }[$hasMillennium])
    } else {
        Write-Ok "Skipping Millennium."
    }

    Write-Host "`nAll done. Steam patched at: $SteamPath" -ForegroundColor Magenta
}
catch {
    Write-Err $_.Exception.Message
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
}
finally {
    Write-Host "`nPress any key to exit..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}
