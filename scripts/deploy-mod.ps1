[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ModFolder,
    [string]$GameDir = $(if ($env:RSDW_GAME_DIR) { $env:RSDW_GAME_DIR } else { "C:\steam\steamapps\common\RSDragonwilds" }),
    [string]$ArchivePath,
    [string]$Version,
    [string]$Channel,
    [switch]$Wipe
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = Split-Path -Parent $PSScriptRoot
$modRoot  = Join-Path $repoRoot $ModFolder
$ue4ssSrc = Join-Path $modRoot "ue4ss"

if (-not (Test-Path $ue4ssSrc)) {
    throw "Missing 'ue4ss' directory inside '$modRoot'"
}

$modDirs = @(Get-ChildItem -Path (Join-Path $ue4ssSrc "Mods") -Directory)
if ($modDirs.Count -ne 1) {
    throw "Expected exactly 1 mod folder inside '$ue4ssSrc\Mods', found $($modDirs.Count)"
}
$modName = $modDirs[0].Name
if ([string]::IsNullOrWhiteSpace($modName) -or $modName -match '[\\/:*?"<>|]' -or $modName -eq "." -or $modName -eq "..") {
    throw "Invalid mod folder name '$modName'."
}

function Resolve-GameInstall {
    param([string]$InputPath)

    if ([string]::IsNullOrWhiteSpace($InputPath)) {
        throw "Game directory path is empty. Pass -GameDir <path> or set `$env:RSDW_GAME_DIR."
    }

    $trimmed = $InputPath.TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $trimmed -PathType Container)) {
        throw "Game directory not found at '$trimmed'. Pass -GameDir <path> (or set `$env:RSDW_GAME_DIR), or pass -SkipDeploy when building."
    }

    $resolved = (Resolve-Path -LiteralPath $trimmed).Path.TrimEnd('\')

    # Accept either <Steam>\common\RSDragonwilds or <Steam>\common\RSDragonwilds\RSDragonwilds
    $candidateSub = Join-Path $resolved "RSDragonwilds"
    if (Test-Path -LiteralPath (Join-Path $candidateSub "Binaries\Win64") -PathType Container) {
        $gameRoot   = $resolved
        $gameSubDir = $candidateSub
    } elseif ((Split-Path -Leaf $resolved) -ieq "RSDragonwilds" -and (Test-Path -LiteralPath (Join-Path $resolved "Binaries\Win64") -PathType Container)) {
        $gameRoot   = Split-Path -Parent $resolved
        $gameSubDir = $resolved
    } else {
        throw "Directory '$resolved' does not look like a valid RuneScape: Dragonwilds installation (missing 'RSDragonwilds\Binaries\Win64'). Pass -GameDir <path>."
    }

    $win64Dir = Join-Path $gameSubDir "Binaries\Win64"
    $paksDir  = Join-Path $gameSubDir "Content\Paks"
    if (-not (Test-Path -LiteralPath $paksDir -PathType Container)) {
        throw "Expected Paks directory not found at '$paksDir'. Refusing to modify an unrecognized game directory."
    }

    return [PSCustomObject]@{
        GameRoot     = $gameRoot
        GameSubDir   = $gameSubDir
        Win64Dir     = $win64Dir
        Ue4ssDir     = Join-Path $win64Dir "ue4ss"
        Ue4ssModsDir = Join-Path $win64Dir "ue4ss\Mods"
        PaksDir      = $paksDir
    }
}

function Test-IsUnderDirectory {
    param(
        [string]$CandidatePath,
        [string]$BaseDirectory
    )
    $fullBase = [System.IO.Path]::GetFullPath($BaseDirectory).TrimEnd('\') + '\'
    $fullCand = [System.IO.Path]::GetFullPath($CandidatePath)
    return $fullCand.StartsWith($fullBase, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-IsSafeModPakPath {
    param(
        [string]$FullPath,
        [string]$PaksDir
    )
    if (-not (Test-IsUnderDirectory -CandidatePath $FullPath -BaseDirectory $PaksDir)) {
        return $false
    }
    $ext = [System.IO.Path]::GetExtension($FullPath).ToLowerInvariant()
    if ($ext -notin @(".pak", ".utoc", ".ucas", ".sig")) {
        return $false
    }
    $leaf = [System.IO.Path]::GetFileName($FullPath)
    # Never allow touching shipping base-game pak files
    if ($leaf -imatch '^(RSDragonwilds-Windows|pakchunk\d+)') {
        return $false
    }
    return $true
}

function Remove-ModFileSafe {
    param([string]$PathToRemove)

    if (-not (Test-Path -LiteralPath $PathToRemove)) {
        return $false
    }

    if ($PSCmdlet.ShouldProcess($PathToRemove, "Remove")) {
        try {
            Remove-Item -LiteralPath $PathToRemove -Recurse -Force
            return $true
        } catch {
            $runningGame = Get-Process -Name "RSDragonwilds*" -ErrorAction SilentlyContinue
            $hint = if ($runningGame) {
                " RuneScape: Dragonwilds appears to be running - close the game and retry."
            } else {
                " Ensure the game or another process is not locking this file, then retry."
            }
            throw "Failed to remove '$PathToRemove': $($_.Exception.Message).$hint"
        }
    }
    return $false
}

$game = Resolve-GameInstall -InputPath $GameDir
$deployedModDir = Join-Path $game.Ue4ssModsDir $modName

# Read mod version metadata (for resolving default archive path)
$versionFile = Join-Path $modRoot "version.json"
$verData = if (Test-Path -LiteralPath $versionFile) {
    Get-Content -LiteralPath $versionFile -Raw | ConvertFrom-Json
} else {
    $null
}
if (-not $Version) {
    $Version = if ($verData -and $verData.version) { [string]$verData.version } else { "1.0.0" }
}
if (-not $Channel) {
    $Channel = if ($verData -and $verData.channel) { [string]$verData.channel } else { "stable" }
}
$fullVersion = if ($Channel -and $Channel.ToLower() -ne "stable") { "$Version-$Channel" } else { $Version }

# Validate archive BEFORE wiping anything when deploying
$resolvedArchive = $null
$archiveLayout   = $null
$archiveEntries  = @()
$archivePakPaths = New-Object System.Collections.Generic.List[string]

if (-not $Wipe) {
    if ($ArchivePath) {
        $candidateArchive = if ([System.IO.Path]::IsPathRooted($ArchivePath)) {
            $ArchivePath
        } else {
            Join-Path $repoRoot $ArchivePath
        }
        if (-not (Test-Path -LiteralPath $candidateArchive -PathType Leaf)) {
            throw "Archive not found at '$candidateArchive'."
        }
        $resolvedArchive = (Resolve-Path -LiteralPath $candidateArchive).Path
    } else {
        $defaultArchive = Join-Path $repoRoot "archives\$modName-v$fullVersion.zip"
        if (-not (Test-Path -LiteralPath $defaultArchive -PathType Leaf)) {
            throw "Archive not found at '$defaultArchive'. Run '.\scripts\build-mod.ps1 -ModFolder $ModFolder' first or pass -ArchivePath."
        }
        $resolvedArchive = (Resolve-Path -LiteralPath $defaultArchive).Path
    }

    $zipInspect = [System.IO.Compression.ZipFile]::OpenRead($resolvedArchive)
    try {
        $fileEntries = @($zipInspect.Entries | Where-Object { -not $_.FullName.EndsWith("/") -and -not $_.FullName.EndsWith("\") })
        if ($fileEntries.Count -eq 0) {
            throw "Archive '$resolvedArchive' contains no files."
        }

        $hasRootLayout  = $false
        $hasUe4ssLayout = $false
        foreach ($entry in $fileEntries) {
            $norm = ($entry.FullName -replace '\\', '/').TrimStart('/')
            if ($norm -match '(^|/)\.\.(/|$)' -or [System.IO.Path]::IsPathRooted($entry.FullName)) {
                throw "Unsafe path inside archive '$resolvedArchive': '$($entry.FullName)'."
            }
            if ($norm.StartsWith("RSDragonwilds/", [System.StringComparison]::OrdinalIgnoreCase)) {
                $hasRootLayout = $true
            } elseif ($norm.StartsWith("ue4ss/", [System.StringComparison]::OrdinalIgnoreCase)) {
                $hasUe4ssLayout = $true
            } else {
                throw "Unrecognized archive entry '$norm' in '$resolvedArchive' (expected 'RSDragonwilds/...' or 'ue4ss/...')."
            }

            if ($norm -imatch '^RSDragonwilds/Content/Paks/(.+)$') {
                $pakRel = $Matches[1] -replace '/', '\'
                $archivePakPaths.Add((Join-Path $game.PaksDir $pakRel))
            }
            $archiveEntries += $norm
        }

        if ($hasRootLayout -and $hasUe4ssLayout) {
            throw "Archive '$resolvedArchive' mixes 'RSDragonwilds/' and top-level 'ue4ss/' paths."
        }
        $archiveLayout = if ($hasRootLayout) { "Combo" } else { "UE4SS" }
    } finally {
        $zipInspect.Dispose()
    }
}

# Collect all mod-owned pak files to wipe (current pak.json + static paks/ + archive paks + previous deploy manifest)
$pakCandidates = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)

$pakInstallFolders = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
[void]$pakInstallFolders.Add("~mods")

$pakBaseNames = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
[void]$pakBaseNames.Add("${modName}_P")

$pakConfigPath = Join-Path $modRoot "pak.json"
if (Test-Path -LiteralPath $pakConfigPath -PathType Leaf) {
    $pakCfg = Get-Content -LiteralPath $pakConfigPath -Raw | ConvertFrom-Json
    if ($pakCfg.pakName) {
        [void]$pakBaseNames.Add([string]$pakCfg.pakName)
    }
    if ($pakCfg.installFolder) {
        [void]$pakInstallFolders.Add(([string]$pakCfg.installFolder).Trim('\', '/'))
    }
    if ($pakCfg.PSObject.Properties.Match("legacyPakNames").Count -gt 0 -and $pakCfg.legacyPakNames) {
        foreach ($legacy in $pakCfg.legacyPakNames) {
            if (-not [string]::IsNullOrWhiteSpace($legacy)) {
                [void]$pakBaseNames.Add([string]$legacy)
            }
        }
    }
}

foreach ($folder in $pakInstallFolders) {
    $targetPakDir = if ([string]::IsNullOrWhiteSpace($folder)) { $game.PaksDir } else { Join-Path $game.PaksDir ($folder -replace '/', '\') }
    foreach ($baseName in $pakBaseNames) {
        foreach ($ext in @(".pak", ".utoc", ".ucas", ".sig")) {
            [void]$pakCandidates.Add((Join-Path $targetPakDir "$baseName$ext"))
        }
    }
}

$staticPaksDir = Join-Path $modRoot "paks"
if (Test-Path -LiteralPath $staticPaksDir -PathType Container) {
    foreach ($f in (Get-ChildItem -LiteralPath $staticPaksDir -File | Where-Object { $_.Extension -in ".pak", ".utoc", ".ucas", ".sig" })) {
        foreach ($folder in $pakInstallFolders) {
            $targetPakDir = if ([string]::IsNullOrWhiteSpace($folder)) { $game.PaksDir } else { Join-Path $game.PaksDir ($folder -replace '/', '\') }
            [void]$pakCandidates.Add((Join-Path $targetPakDir $f.Name))
        }
    }
}

foreach ($ap in $archivePakPaths) {
    [void]$pakCandidates.Add($ap)
}

# Load previous deploy manifest (gitignored under archives/.deploy-state/) to catch renamed/removed paks or files
$manifestDir  = Join-Path $repoRoot "archives\.deploy-state"
$manifestPath = Join-Path $manifestDir "$modName.json"
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try {
        $prevManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($prevManifest -and $prevManifest.files) {
            foreach ($relFile in $prevManifest.files) {
                if ([string]::IsNullOrWhiteSpace($relFile)) { continue }
                $normRel = ($relFile -replace '/', '\').TrimStart('\')
                $fullPrev = [System.IO.Path]::GetFullPath((Join-Path $game.GameRoot $normRel))
                if (Test-IsSafeModPakPath -FullPath $fullPrev -PaksDir $game.PaksDir) {
                    [void]$pakCandidates.Add($fullPrev)
                }
            }
        }
    } catch {
        Write-Warning "Could not parse previous deploy manifest '$manifestPath'; continuing with config-based wipe."
    }
}

# --- Step 1: Clean wipe of ONLY this mod ---
$actionLabel = if ($Wipe) { "Wiping" } else { "Cleaning previous install of" }
Write-Host "=== $actionLabel $modName in '$($game.GameRoot)' ===" -ForegroundColor Cyan

$wipedItems = New-Object System.Collections.Generic.List[string]

if (Test-Path -LiteralPath $deployedModDir) {
    if (-not (Test-IsUnderDirectory -CandidatePath $deployedModDir -BaseDirectory $game.Ue4ssModsDir)) {
        throw "Refusing to delete unexpected path '$deployedModDir'."
    }
    if (Remove-ModFileSafe -PathToRemove $deployedModDir) {
        $wipedItems.Add($deployedModDir)
        Write-Host "  Removed mod folder: $deployedModDir" -ForegroundColor Yellow
    }
}

foreach ($pakPath in ($pakCandidates | Sort-Object)) {
    if (-not (Test-IsSafeModPakPath -FullPath $pakPath -PaksDir $game.PaksDir)) {
        continue
    }
    if (Test-Path -LiteralPath $pakPath -PathType Leaf) {
        if (Remove-ModFileSafe -PathToRemove $pakPath) {
            $wipedItems.Add($pakPath)
            Write-Host "  Removed pak file  : $pakPath" -ForegroundColor Yellow
        }
    }
}

if ($Wipe) {
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        if ($PSCmdlet.ShouldProcess($manifestPath, "Remove deploy manifest")) {
            Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
        }
    }
    if ($WhatIfPreference) {
        Write-Host "WhatIf complete for $modName; no files were removed." -ForegroundColor DarkCyan
    } elseif ($wipedItems.Count -eq 0) {
        Write-Host "Nothing to wipe: '$modName' was not present in '$($game.GameRoot)'." -ForegroundColor DarkGray
    } else {
        Write-Host "Wiped $modName ($($wipedItems.Count) target(s) removed). Other mods and game files were untouched." -ForegroundColor Green
    }
    return
}

# --- Step 2: Deploy fresh from archive ---
if (-not (Test-Path -LiteralPath $game.Ue4ssDir -PathType Container)) {
    Write-Warning "UE4SS directory '$($game.Ue4ssDir)' does not exist yet (creating it, make sure UE4SS is installed in '$($game.Win64Dir)')."
}

$extractRoot = if ($archiveLayout -eq "Combo") { $game.GameRoot } else { $game.Win64Dir }
$deployedRelFiles = New-Object System.Collections.Generic.List[string]
$deployedPakFiles = New-Object System.Collections.Generic.List[string]
$deployedModFileCount = 0

Write-Host "=== Deploying $(Split-Path -Leaf $resolvedArchive) ($archiveLayout layout) ===" -ForegroundColor Cyan

$zip = [System.IO.Compression.ZipFile]::OpenRead($resolvedArchive)
try {
    foreach ($entry in $zip.Entries) {
        if ($entry.FullName.EndsWith("/") -or $entry.FullName.EndsWith("\")) {
            continue
        }
        $normEntry = ($entry.FullName -replace '\\', '/').TrimStart('/')
        $destPath  = [System.IO.Path]::GetFullPath((Join-Path $extractRoot ($normEntry -replace '/', '\')))

        if (-not (Test-IsUnderDirectory -CandidatePath $destPath -BaseDirectory $game.GameRoot)) {
            throw "Refusing to extract '$normEntry' outside game directory '$($game.GameRoot)'."
        }

        if ($PSCmdlet.ShouldProcess($destPath, "Extract $normEntry")) {
            $parentDir = Split-Path -Parent $destPath
            if (-not (Test-Path -LiteralPath $parentDir -PathType Container)) {
                New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
            }
            try {
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destPath, $true)
            } catch {
                $runningGame = Get-Process -Name "RSDragonwilds*" -ErrorAction SilentlyContinue
                $hint = if ($runningGame) {
                    " RuneScape: Dragonwilds appears to be running - close the game and retry."
                } else {
                    " Ensure no process is locking the destination file, then retry."
                }
                throw "Failed to extract '$destPath': $($_.Exception.Message).$hint"
            }
        }

        $relFromGameRoot = $destPath.Substring($game.GameRoot.Length).TrimStart('\') -replace '\\', '/'
        $deployedRelFiles.Add($relFromGameRoot)
        if (Test-IsUnderDirectory -CandidatePath $destPath -BaseDirectory $game.PaksDir) {
            $deployedPakFiles.Add($destPath)
        } else {
            $deployedModFileCount++
        }
    }
} finally {
    $zip.Dispose()
}

# Save fresh deploy manifest so future wipes/deploys catch any renamed or removed files
if ($PSCmdlet.ShouldProcess($manifestPath, "Write deploy manifest")) {
    New-Item -ItemType Directory -Force -Path $manifestDir | Out-Null
    $manifestObj = [PSCustomObject]@{
        modName    = $modName
        modFolder  = $ModFolder
        version    = $fullVersion
        archive    = (Split-Path -Leaf $resolvedArchive)
        gameRoot   = $game.GameRoot
        layout     = $archiveLayout
        deployedAt = (Get-Date -Format "o")
        files      = [string[]]$deployedRelFiles.ToArray()
    }
    $manifestObj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
}

$pakSummary = if ($deployedPakFiles.Count -gt 0) {
    $pakNames = ($deployedPakFiles | ForEach-Object { Split-Path -Leaf $_ }) -join ", "
    "$($deployedPakFiles.Count) pak file(s) [$pakNames]"
} else {
    "no pak files"
}
Write-Host "Deployed $modName to '$($game.GameRoot)' ($deployedModFileCount mod file(s), $pakSummary)" -ForegroundColor Green
