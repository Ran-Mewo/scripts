# =============================================
# OpenSteam + Luatools Plugin + Millennium Installer
# - OpenSteamTool sourced from mirrored repos (highest version wins)
# - LuaTools installs as a Millennium .star plugin from the latest GitHub release
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
$LtPluginRepo   = 'Ran-Mewo/ltsteamplugin'
$OnlineFixRepo  = 'Ran-Mewo/OnlineFix'
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

function Resolve-LatestPlugin {
    $best = Get-LatestReleaseInfo $LtPluginRepo
    Write-Ok "Latest LuaTools plugin: $($best.Repo) @ $($best.Tag)"
    "https://github.com/$($best.Repo)/releases/latest/download/luatools.star"
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

function Install-OnlineFix($steamPath) {
    # Download the latest OnlineFix.dll next to OpenSteamTool.dll (Steam root),
    # then ensure opensteamtool.toml injects it for the -onlinefix command line.
    $best = Get-LatestReleaseInfo $OnlineFixRepo
    Write-Ok "Latest OnlineFix: $($best.Repo) @ $($best.Tag)"
    Get-File (Get-LatestZipUrl $best.Repo $best.Tag 'OnlineFix\.dll$') (Join-Path $steamPath 'OnlineFix.dll')
    Write-Ok "OnlineFix.dll downloaded."

    # Append an [[inject]] table only if one for OnlineFix.dll isn't already present;
    # we only ever add to the file so any other values the user has are left intact.
    $tomlPath = Join-Path $steamPath 'opensteamtool.toml'
    $block = @(
        '[[inject]]'
        'path = "OnlineFix.dll"'
        'when_cmdline = "-onlinefix"'
    ) -join "`r`n"
    $utf8 = New-Object System.Text.UTF8Encoding $false   # no BOM (TOML parsers can choke on it)

    if (Test-Path $tomlPath) {
        $existing = Get-Content $tomlPath -Raw -Encoding UTF8
        if ($existing -match '(?im)^\s*path\s*=\s*"OnlineFix\.dll"\s*$') {
            Write-Ok "opensteamtool.toml already injects OnlineFix.dll."
            return
        }
        $trimmed = $existing.TrimEnd()
        $content = if ($trimmed.Length) { "$trimmed`r`n`r`n$block`r`n" } else { "$block`r`n" }
        [System.IO.File]::WriteAllText($tomlPath, $content, $utf8)
        Write-Ok "Added OnlineFix inject block to opensteamtool.toml."
    } else {
        [System.IO.File]::WriteAllText($tomlPath, "$block`r`n", $utf8)
        Write-Ok "Created opensteamtool.toml with OnlineFix inject block."
    }
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

    Write-Step "Installing OnlineFix"
    Install-OnlineFix $SteamPath

    Write-Step "Linking config\stplug-in -> config\lua"
    $cfg = Join-Path $SteamPath 'config'
    New-Item -ItemType Directory -Force -Path $cfg | Out-Null
    New-DirSymlink (Join-Path $cfg 'stplug-in') (Join-Path $cfg 'lua')

    Write-Step "Installing LuaTools Millennium plugin"
    $ltStar = Join-Path $Tmp 'luatools.star'
    $pluginsRoot = Join-Path $SteamPath 'millennium\plugins'
    New-Item -ItemType Directory -Force -Path $pluginsRoot | Out-Null

    foreach ($legacyName in @('luatools', 'ltsteamplugin')) {
        $legacyPath = Join-Path $pluginsRoot $legacyName
        if (Test-Path $legacyPath) {
            Write-Warn "Removing existing $legacyName folder..."
            Remove-Item $legacyPath -Recurse -Force
        }
    }

    Get-File (Resolve-LatestPlugin) $ltStar
    Copy-Item $ltStar (Join-Path $pluginsRoot 'luatools.star') -Force
    Remove-Item $ltStar -Force -ErrorAction SilentlyContinue
    Write-Ok "LuaTools plugin installed."

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
