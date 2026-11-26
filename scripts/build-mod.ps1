param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ModFolder,
    [string]$Version,
    [string]$Channel,
    [ValidateSet("", "patch", "minor", "major")]
    [string]$Bump = "",
    [string]$EngineDir = "C:\Program Files\Epic Games\UE_5.6",
    [switch]$SkipChangelog,
    [switch]$SkipPak,
    [switch]$ForceRebuildPak
)

$ErrorActionPreference     = "Stop"
$ProgressPreference        = "SilentlyContinue"
$global:ProgressPreference = "SilentlyContinue"
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

# Optional UE Blueprint .pak pipeline when <ModFolder>/pak.json is present
$pakConfigPath = Join-Path $modRoot "pak.json"
$builtPakFiles = @()
$pakInstallFolder = "~mods"

if (-not $SkipPak -and (Test-Path $pakConfigPath)) {
    $pakCfg = Get-Content $pakConfigPath -Raw | ConvertFrom-Json
    $pakName          = if ($pakCfg.pakName) { [string]$pakCfg.pakName } else { "${modName}_P" }
    $contentSubPath   = if ($pakCfg.contentSubPath) { [string]$pakCfg.contentSubPath } else { "Mods/$modName" }
    $pakInstallFolder = if ($pakCfg.installFolder) { [string]$pakCfg.installFolder } else { "~mods" }
    $ueProjectRel     = if ($pakCfg.ueProject) { [string]$pakCfg.ueProject } else { "unreal-engine/RSDragonwilds/RSDragonwilds.uproject" }
    $editorTarget     = if ($pakCfg.editorTarget) { [string]$pakCfg.editorTarget } else { "RSDragonwildsEditor" }
    $genCommandlet    = if ($pakCfg.generatorCommandlet) { [string]$pakCfg.generatorCommandlet } else { $null }
    $syncScriptRel    = if ($pakCfg.syncStubsScript) { [string]$pakCfg.syncStubsScript } else { "scripts/sync-ue-damage-stubs.ps1" }

    $uprojectPath = Join-Path $repoRoot ($ueProjectRel -replace '/', '\')
    $projectDir   = Split-Path -Parent $uprojectPath
    $buildBat     = Join-Path $EngineDir "Engine\Build\BatchFiles\Build.bat"
    $runUAT       = Join-Path $EngineDir "Engine\Build\BatchFiles\RunUAT.bat"
    $ueCmd        = Join-Path $EngineDir "Engine\Binaries\Win64\UnrealEditor-Cmd.exe"
    $syncScript   = Join-Path $repoRoot ($syncScriptRel -replace '/', '\')
    $chunkId      = if ($pakCfg.chunkId) { [int]$pakCfg.chunkId } else { 101 }

    if (-not (Test-Path $uprojectPath)) { throw "Missing UE project configured in pak.json: $uprojectPath" }
    if (-not (Test-Path $buildBat))     { throw "Missing UE Build.bat at '$buildBat'. Pass -EngineDir or -SkipPak." }
    if (-not (Test-Path $runUAT))       { throw "Missing UE RunUAT.bat at '$runUAT'." }
    if (-not (Test-Path $ueCmd))        { throw "Missing UnrealEditor-Cmd.exe at '$ueCmd'." }

    Write-Host "=== Building UE 5.6 IoStore Blueprint Pak ($pakName) for $modName ===" -ForegroundColor Cyan

    # 1. Sync minimal Dominion damage stubs from gitignored UHTHeaderDump/ if needed
    $dominionStubDir = Join-Path $projectDir "Source\Dominion"
    if (($ForceRebuildPak -or -not (Test-Path $dominionStubDir)) -and (Test-Path $syncScript)) {
        Write-Host "[Pak 1/4] Syncing minimal Dominion interface stubs from UHTHeaderDump..." -ForegroundColor Yellow
        & $syncScript
    }

    # 2. Compile Editor target (fast incremental build once compiled)
    Write-Host "[Pak 2/4] Building $editorTarget (Win64 Development)..." -ForegroundColor Yellow
    & $buildBat $editorTarget Win64 Development "$uprojectPath" -WaitMutex -FromMsBuild
    if ($LASTEXITCODE -ne 0) {
        throw "UE Editor build failed (Exit Code: $LASTEXITCODE)."
    }

    # 3. Auto-generate Blueprint asset + PrimaryAssetLabel (Chunk $chunkId) via Editor commandlet
    $modContentDisk = Join-Path $projectDir ("Content\" + ($contentSubPath -replace '/', '\'))
    $palFile        = Join-Path $modContentDisk "PAL_ArcaneWildsDamageBridge.uasset"
    $hasUassets     = (Test-Path $modContentDisk) -and ((Get-ChildItem -Path $modContentDisk -Filter "*.uasset" -Recurse -ErrorAction SilentlyContinue).Count -gt 0) -and (Test-Path $palFile)
    if ($genCommandlet -and ($ForceRebuildPak -or -not $hasUassets)) {
        Write-Host "[Pak 3/4] Generating Blueprint & PrimaryAssetLabel via -run=$genCommandlet..." -ForegroundColor Yellow
        & $ueCmd "$uprojectPath" "-run=$genCommandlet" -unattended -nop4 -stdout -NoLogTimes
        if ($LASTEXITCODE -ne 0) {
            throw "Blueprint generator commandlet '$genCommandlet' failed (Exit Code: $LASTEXITCODE)."
        }
    }

    # 4. Cook & stage Chunk $chunkId as UE 5.6 IoStore (.pak + .utoc + .ucas) via RunUAT BuildCookRun
    $pakStageDir = Join-Path $env:TEMP "rsdw-pak-$modName"
    $uatStageDir = Join-Path $pakStageDir "UATStaged"
    if (Test-Path $pakStageDir) { Remove-Item $pakStageDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $uatStageDir | Out-Null

    $shippingExe = Join-Path $projectDir "Binaries\Win64\RSDragonwilds-Win64-Shipping.exe"
    $needsShippingBuild = $ForceRebuildPak -or -not (Test-Path $shippingExe)
    $uatArgs = @(
        "BuildCookRun",
        "-project=`"$uprojectPath`"",
        "-platform=Win64",
        "-clientconfig=Shipping",
        "-cook",
        "-stage",
        "-pak",
        "-iostore",
        "-nocompile",
        "-nocompileuat",
        "-nodebuginfo",
        "-nop4",
        "-unattended",
        "-utf8output",
        "-CookDir=/Game/$contentSubPath",
        "-stagingdirectory=`"$uatStageDir`""
    )
    if ($needsShippingBuild) {
        $uatArgs += "-build"
        Write-Host "[Pak 4/4] Building Shipping stub + cooking IoStore Chunk $chunkId ($pakName.pak/.utoc/.ucas)..." -ForegroundColor Yellow
    } else {
        $uatArgs += "-skipbuild"
        Write-Host "[Pak 4/4] Cooking & packaging IoStore Chunk $chunkId ($pakName.pak/.utoc/.ucas)..." -ForegroundColor Yellow
    }

    & $runUAT @uatArgs
    if ($LASTEXITCODE -ne 0) {
        throw "UE BuildCookRun IoStore packaging failed (Exit Code: $LASTEXITCODE)."
    }

    $stagedPaksDir = Join-Path $uatStageDir "Windows\RSDragonwilds\Content\Paks"
    $chunkBase     = "pakchunk$chunkId-Windows"
    $requiredExts  = @(".pak", ".utoc", ".ucas")
    foreach ($ext in $requiredExts) {
        $srcChunkFile = Join-Path $stagedPaksDir ($chunkBase + $ext)
        if (-not (Test-Path $srcChunkFile)) {
            $avail = (Get-ChildItem -Path $stagedPaksDir -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ", "
            throw "Expected IoStore chunk file '$srcChunkFile' not found. Available in staged Paks: [$avail]"
        }
        $dstModPakFile = Join-Path $pakStageDir ($pakName + $ext)
        Copy-Item -Path $srcChunkFile -Destination $dstModPakFile -Force
        $builtPakFiles += $dstModPakFile
    }

    Write-Host "Built IoStore Blueprint container: $pakName.{pak,utoc,ucas}" -ForegroundColor Green
}

# Also collect any pre-built .pak/.utoc/.ucas placed in <ModFolder>/paks/
$staticPaksDir = Join-Path $modRoot "paks"
if (-not $SkipPak -and (Test-Path $staticPaksDir)) {
    $builtPakFiles += @(Get-ChildItem -Path $staticPaksDir -File | Where-Object { $_.Extension -in ".pak", ".utoc", ".ucas" } | ForEach-Object { $_.FullName })
}

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

$hasPak = ($builtPakFiles.Count -gt 0)
if ($hasPak) {
    # Vortex Combo / Root Folder layout:
    #   RSDragonwilds/Binaries/Win64/ue4ss/Mods/<ModName>/...
    #   RSDragonwilds/Content/Paks/<installFolder>/*.pak
    $win64Dest = Join-Path $stageRoot "RSDragonwilds\Binaries\Win64"
    $paksDest  = Join-Path $stageRoot "RSDragonwilds\Content\Paks\$pakInstallFolder"
    New-Item -ItemType Directory -Force -Path $win64Dest, $paksDest | Out-Null

    Copy-Item -Path $ue4ssSrc -Destination $win64Dest -Recurse
    foreach ($pf in $builtPakFiles) {
        Copy-Item -Path $pf -Destination $paksDest -Force
    }
    $stagedModDir = Join-Path $win64Dest "ue4ss\Mods\$modName"
    $archiveInputPath = Join-Path $stageRoot "RSDragonwilds"
} else {
    # Pure UE4SS Mod layout: ue4ss/Mods/<ModName>/...
    Copy-Item -Path $ue4ssSrc -Destination $stageRoot -Recurse
    $stagedModDir = Join-Path $stageRoot "ue4ss\Mods\$modName"
    $archiveInputPath = Join-Path $stageRoot "ue4ss"
}

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

Compress-Archive -Path $archiveInputPath -DestinationPath $zipPath
Remove-Item $stageRoot -Recurse -Force
$pakStageCleanup = Join-Path $env:TEMP "rsdw-pak-$modName"
if (Test-Path $pakStageCleanup) { Remove-Item $pakStageCleanup -Recurse -Force -ErrorAction SilentlyContinue }

$layoutNote = if ($hasPak) { "Combo UE4SS + Pak ($pakInstallFolder)" } else { "UE4SS only" }
Write-Host "Built: $zipPath (version: $fullVersion, layout: $layoutNote)" -ForegroundColor Green
