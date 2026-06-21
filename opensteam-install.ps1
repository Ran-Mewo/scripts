# =============================================
# OpenSteam + Luatools Plugin + Millennium Installer
# - OpenSteamTool & ltsteamplugin sourced from mirrored repos (highest version wins)
# - Enables the luatools plugin in Millennium and skips its first-load disclaimer
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

$OpenSteamRepos = @('OpenSteam001/OpenSteamTool','Ran-Mewo/OpenSteamTool')
$LtPluginRepos  = @('madoiscool/ltsteamplugin','piqseu/ltsteamplugin')
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

function Get-LatestZipUrl($repo, $tag, $pattern) {
    $page = Invoke-WebRequest -Uri "https://github.com/$repo/releases/expanded_assets/$tag" -UseBasicParsing
    $href = $page.Links.href | Where-Object { $_ -match $pattern } | Select-Object -First 1
    if (-not $href) { Write-Err "No asset matching '$pattern' in ${repo}@${tag}"; exit 1 }
    "https://github.com$href"
}

function Get-LatestReleaseInfo($repo) {
    # Use the releases atom feed (not the rate-limited API) for the newest release's tag + date.
    $feed = Invoke-WebRequest -Uri "https://github.com/$repo/releases.atom" -UseBasicParsing
    $xml  = [xml]$feed.Content
    $entry = @($xml.feed.entry)[0]
    if (-not $entry) { Write-Err "No releases found for $repo"; exit 1 }
    [pscustomobject]@{
        Repo = $repo
        Tag  = ($entry.id -split '/')[-1]   # e.g. .../1.4.8 -> 1.4.8
        Date = [datetime]$entry.updated
    }
}

function Resolve-LatestRepo($repos) {
    # Pick the repo whose latest release is the most recently published (by date, not version).
    $best = $repos | ForEach-Object { Get-LatestReleaseInfo $_ } |
        Sort-Object Date -Descending | Select-Object -First 1
    $best
}

function Resolve-LatestPlugin($repos) {
    $best = Resolve-LatestRepo $repos
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

function Find-PluginRoot($dir) {
    # Some release zips put the plugin files at the root; others nest them one (or more)
    # levels deep inside a wrapper folder. Locate the folder that actually holds the plugin
    # by finding its plugin.json manifest and returning that directory.
    $manifest = Get-ChildItem -Path $dir -Filter 'plugin.json' -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } | Select-Object -First 1
    if ($manifest) { return $manifest.Directory.FullName }
    # Fallback: if the zip wrapped everything in a single subfolder, descend into it.
    $entries = @(Get-ChildItem -Path $dir -Force)
    if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) { return $entries[0].FullName }
    $dir
}

function Expand-Plugin($zip, $dest) {
    # Extract to a staging dir, normalize away any wrapper folder, then copy the real
    # plugin contents into $dest so the layout is always luatools\plugin.json, luatools\public\...
    $stage = Join-Path $Tmp ('ltstage-' + [IO.Path]::GetFileNameWithoutExtension($zip))
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $stage -Force
    $root = Find-PluginRoot $stage
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Get-ChildItem -Path $root -Force | Move-Item -Destination $dest -Force
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
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

function Enable-Plugin($steamPath, $pluginName) {
    # Millennium tracks enabled plugins in millennium\config\config.json under plugins.enabledPlugins.
    $cfgDir  = Join-Path $steamPath 'millennium\config'
    $cfgPath = Join-Path $cfgDir 'config.json'
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null

    if (Test-Path $cfgPath) {
        $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        $cfg = [pscustomobject]@{}
    }
    if (-not $cfg.PSObject.Properties['plugins']) {
        $cfg | Add-Member -NotePropertyName plugins -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not $cfg.plugins.PSObject.Properties['enabledPlugins']) {
        $cfg.plugins | Add-Member -NotePropertyName enabledPlugins -NotePropertyValue @() -Force
    }

    $enabled = @($cfg.plugins.enabledPlugins)
    if ($enabled -contains $pluginName) {
        Write-Ok "Plugin '$pluginName' already enabled."
        return
    }
    $cfg.plugins.enabledPlugins = @($enabled + $pluginName)
    $cfg | ConvertTo-Json -Depth 20 | Set-Content $cfgPath -Encoding UTF8
    Write-Ok "Enabled plugin '$pluginName' in Millennium config."
}

function Disable-LuatoolsDisclaimer($pluginDir) {
    # luatools shows a one-time "type I Understand" modal gated on a localStorage flag.
    # Pre-seed the flag inside its frontend bundle so the modal never appears.
    $jsPath = Join-Path $pluginDir 'public\luatools.js'
    if (-not (Test-Path $jsPath)) { Write-Warn "luatools.js not found, skipping disclaimer bypass."; return }
    $key    = 'luatools millennium disclaimer accepted'
    $marker = '/* opensteam-install: disclaimer pre-accepted */'
    $js     = Get-Content $jsPath -Raw -Encoding UTF8
    if ($js.Contains($marker)) { Write-Ok "Disclaimer bypass already present."; return }
    $seed = "try{localStorage.setItem(`"$key`",`"1`");}catch(e){} $marker`r`n"
    Set-Content $jsPath -Value ($seed + $js) -Encoding UTF8
    Write-Ok "Pre-accepted luatools disclaimer."
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

    $hasMillennium = Test-Millennium $SteamPath

    Write-Step "Installing OpenSteamTool"
    $openBest = Resolve-LatestRepo $OpenSteamRepos
    Write-Ok "Latest OpenSteamTool: $($openBest.Repo) @ $($openBest.Tag)"
    $openZip = Join-Path $Tmp 'opensteamtool.zip'
    Get-File (Get-LatestZipUrl $openBest.Repo $openBest.Tag 'Release\.zip$') $openZip
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
    Expand-Plugin $ltZip $pluginDir
    Remove-Item $ltZip -Force -ErrorAction SilentlyContinue
    Disable-LuatoolsDisclaimer $pluginDir

    Write-Step "Installing Millennium"
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

    Write-Step "Enabling luatools plugin"
    Enable-Plugin $SteamPath 'luatools'

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
