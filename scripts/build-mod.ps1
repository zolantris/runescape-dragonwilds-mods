param(
    [Parameter(Mandatory = $true)]
    [string]$ModFolder,
    [string]$Version,
    [string]$Channel,
    [ValidateSet("", "patch", "minor", "major")]
    [string]$Bump = "",
    [switch]$SkipChangelog
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$modRoot  = Join-Path $repoRoot $ModFolder
$ue4ssSrc = Join-Path $modRoot "ue4ss"

if (-not (Test-Path $ue4ssSrc)) {
    throw "Missing 'ue4ss' directory inside '$modRoot'"
}

$modDirs = Get-ChildItem -Path (Join-Path $ue4ssSrc "Mods") -Directory
if ($modDirs.Count -ne 1) {
    throw "Expected exactly 1 mod folder inside '$ue4ssSrc\Mods', found $($modDirs.Count)"
}
$modName = $modDirs.Name

# Read version.json at the mod folder root
$versionFile = Join-Path $modRoot "version.json"
$verData = if (Test-Path $versionFile) {
    Get-Content $versionFile -Raw | ConvertFrom-Json
} else {
    [PSCustomObject]@{ version = "1.0.0"; channel = "stable" }
}

if (-not $Version) {
    $Version = if ($verData.version) { [string]$verData.version } else { "1.0.0" }
}
if (-not $Channel) {
    $Channel = if ($verData.channel) { [string]$verData.channel } else { "stable" }
}

# Optional semantic version bump (updates version.json in place)
if ($Bump) {
    $nums = $Version -split '\.'
    $maj = if ($nums.Count -ge 1) { [int]$nums[0] } else { 1 }
    $min = if ($nums.Count -ge 2) { [int]$nums[1] } else { 0 }
    $pat = if ($nums.Count -ge 3) { [int]$nums[2] } else { 0 }
    switch ($Bump) {
        "major" { $maj++; $min = 0; $pat = 0 }
        "minor" { $min++; $pat = 0 }
        "patch" { $pat++ }
    }
    $Version = "$maj.$min.$pat"
    $verData.version = $Version
    $verData.channel = $Channel
    $verData | ConvertTo-Json -Depth 5 | Set-Content -Path $versionFile -Encoding UTF8
}

$fullVersion = if ($Channel -and $Channel.ToLower() -ne "stable") { "$Version-$Channel" } else { $Version }

# Invoke standalone changelog generator before staging README.md
if (-not $SkipChangelog) {
    $changelogScript = Join-Path $PSScriptRoot "update-changelog.ps1"
    if (Test-Path $changelogScript) {
        & $changelogScript -ModFolder $ModFolder -Version $fullVersion
    } else {
        Write-Warning "Changelog script not found at '$changelogScript'; skipping changelog update."
    }
}

$stageRoot = Join-Path $env:TEMP "rsdw-build-$modName"
if (Test-Path $stageRoot) { Remove-Item $stageRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null

Copy-Item -Path $ue4ssSrc -Destination $stageRoot -Recurse
$stagedModDir = Join-Path $stageRoot "ue4ss\Mods\$modName"

# Strip local snapshots, logs, and runtime layout overrides from release archive
Get-ChildItem -Path $stageRoot -Recurse -Include "snapshots","*.log","panel_layouts.lua" |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# Sync version into staged modmenu.json (updates top-level version and/or nested mod.version if present)
$stagedMenu = Join-Path $stagedModDir "modmenu.json"
if (Test-Path $stagedMenu) {
    $menuObj = Get-Content $stagedMenu -Raw | ConvertFrom-Json
    $updatedMenuVersion = $false

    if ($menuObj.PSObject.Properties.Match("version").Count -gt 0) {
        $menuObj.version = $fullVersion
        $updatedMenuVersion = $true
    }
    if ($menuObj.PSObject.Properties.Match("mod").Count -gt 0 -and $menuObj.mod) {
        $menuObj.mod.version = $fullVersion
        $updatedMenuVersion = $true
    }
    if (-not $updatedMenuVersion) {
        $menuObj | Add-Member -NotePropertyName "version" -NotePropertyValue $fullVersion
    }

    $menuObj | ConvertTo-Json -Depth 10 | Set-Content -Path $stagedMenu -Encoding UTF8
}

# Sync VERSION / MOD_VERSION constant into staged Scripts/main.lua
$stagedMain = Join-Path $stagedModDir "Scripts\main.lua"
if (Test-Path $stagedMain) {
    $luaText = Get-Content $stagedMain -Raw
    $luaText = $luaText -replace '(local\s+(?:MOD_)?VERSION\s*=\s*")[^"]*(")', "`${1}$fullVersion`${2}"
    Set-Content -Path $stagedMain -Value $luaText -Encoding UTF8 -NoNewline
}

# Copy updated top-level README.md into staged mod folder
$readme = Join-Path $modRoot "README.md"
if (Test-Path $readme) {
    Copy-Item -Path $readme -Destination (Join-Path $stagedModDir "README.md") -Force
}

$archivesDir = Join-Path $repoRoot "archives"
New-Item -ItemType Directory -Force -Path $archivesDir | Out-Null
$zipPath = Join-Path $archivesDir "$modName-v$fullVersion.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

Compress-Archive -Path (Join-Path $stageRoot "ue4ss") -DestinationPath $zipPath
Remove-Item $stageRoot -Recurse -Force

Write-Host "Built: $zipPath (version: $fullVersion)" -ForegroundColor Green
