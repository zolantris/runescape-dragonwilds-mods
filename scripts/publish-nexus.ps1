[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ModFolder,
    [string]$Version,
    [string]$Channel,
    [ValidateSet("", "main", "optional", "miscellaneous")]
    [string]$Category = "",
    [string]$ApiKey,
    [string]$NotesFile,
    [string]$ArchivePath,
    [string]$UploadId,
    [switch]$SkipBuild,
    [switch]$DryRun,
    [switch]$NoArchiveOld,
    [switch]$NoUpdateModVersion,
    [switch]$NoSyncDescription,
    [switch]$NoSyncChangelog,
    [switch]$DescriptionOnly,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"

if ($ExtraArgs) {
    foreach ($arg in $ExtraArgs) {
        switch ($arg.ToLowerInvariant()) {
            "--dry-run"               { $DryRun = $true }
            "-dry-run"                { $DryRun = $true }
            "--skip-build"            { $SkipBuild = $true }
            "--no-archive-old"        { $NoArchiveOld = $true }
            "--no-update-mod-version" { $NoUpdateModVersion = $true }
            default                   { throw "Unknown argument: '$arg'" }
        }
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$modRoot  = Join-Path $repoRoot $ModFolder
$ue4ssSrc = Join-Path $modRoot "ue4ss"

if (-not (Test-Path -LiteralPath $modRoot -PathType Container)) {
    throw "Mod folder not found: '$modRoot'"
}
if (-not (Test-Path -LiteralPath $ue4ssSrc -PathType Container)) {
    throw "Missing 'ue4ss' directory inside '$modRoot'"
}

$modDirs = @(Get-ChildItem -LiteralPath (Join-Path $ue4ssSrc "Mods") -Directory)
if ($modDirs.Count -ne 1) {
    throw "Expected exactly 1 mod folder inside '$ue4ssSrc\Mods', found $($modDirs.Count)"
}
$modName = $modDirs[0].Name

# Read <mod>/nexus.json
$nexusConfigPath = Join-Path $modRoot "nexus.json"
if (-not (Test-Path -LiteralPath $nexusConfigPath -PathType Leaf)) {
    throw "Missing Nexus Mods configuration at '$nexusConfigPath'. Create it with gameDomain, modId, and fileId."
}

$nexusCfg = Get-Content -LiteralPath $nexusConfigPath -Raw | ConvertFrom-Json

$gameDomain  = if ($nexusCfg.gameDomain) { [string]$nexusCfg.gameDomain } else { "" }
$modId       = if ($null -ne $nexusCfg.modId) { [int]$nexusCfg.modId } else { 0 }
$uniqueModId = if ($null -ne $nexusCfg.uniqueModId) { [string]$nexusCfg.uniqueModId } else { "" }
$fileId      = if ($null -ne $nexusCfg.fileId) { [int]$nexusCfg.fileId } else { 0 }
$apiBaseUrl = if ($nexusCfg.apiBaseUrl) { ([string]$nexusCfg.apiBaseUrl).TrimEnd('/') } else { "https://api.nexusmods.com/v3" }

if ([string]::IsNullOrWhiteSpace($gameDomain)) {
    throw "Invalid '$nexusConfigPath': 'gameDomain' is required."
}
if (-not $DryRun) {
    if ($modId -le 0) {
        throw "Invalid '$nexusConfigPath': 'modId' must be a positive integer (currently $modId)."
    }
    if ($fileId -le 0) {
        throw "Invalid '$nexusConfigPath': 'fileId' must be a positive integer (currently $fileId)."
    }
}

if ([string]::IsNullOrWhiteSpace($Category)) {
    $Category = if ($nexusCfg.category) { ([string]$nexusCfg.category).ToLowerInvariant() } else { "main" }
}
if ($Category -notin @("main", "optional", "miscellaneous")) {
    throw "Invalid category '$Category'. Expected one of: main, optional, miscellaneous."
}

$archiveExisting = if ($NoArchiveOld) {
    $false
} elseif ($null -ne $nexusCfg.archiveExistingVersion) {
    [bool]$nexusCfg.archiveExistingVersion
} else {
    $true
}

$updateModVersion = if ($NoUpdateModVersion) {
    $false
} elseif ($null -ne $nexusCfg.updateModVersion) {
    [bool]$nexusCfg.updateModVersion
} else {
    $true
}

# Resolve API key (never stored in nexus.json)
$resolvedApiKey = if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
    $ApiKey.Trim()
} elseif (-not [string]::IsNullOrWhiteSpace($env:NEXUSMODS_API_KEY)) {
    $env:NEXUSMODS_API_KEY.Trim()
} else {
    $null
}

if (-not $DryRun -and [string]::IsNullOrWhiteSpace($resolvedApiKey)) {
    throw "Nexus Mods API key is required. Set `$env:NEXUSMODS_API_KEY or pass -ApiKey '<key>'."
}

# Read <mod>/version.json
$versionFile = Join-Path $modRoot "version.json"
$verData = if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
    Get-Content -LiteralPath $versionFile -Raw | ConvertFrom-Json
} else {
    $null
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = if ($verData -and $verData.version) { [string]$verData.version } else { "1.0.0" }
}
if ([string]::IsNullOrWhiteSpace($Channel)) {
    $Channel = if ($verData -and $verData.channel) { [string]$verData.channel } else { "stable" }
}

$fullVersion = if ($Channel -and $Channel.ToLowerInvariant() -ne "stable") { "$Version-$Channel" } else { $Version }
$tagName     = "$modName-v$fullVersion"
$zipPath     = if (-not [string]::IsNullOrWhiteSpace($ArchivePath)) {
    $ArchivePath
} else {
    Join-Path $repoRoot "archives\$tagName.zip"
}

$reuseUpload = -not [string]::IsNullOrWhiteSpace($UploadId)

# Optionally update changelog and build archive
if (-not $SkipBuild -and -not $reuseUpload -and -not $DescriptionOnly) {
    $changelogScript = Join-Path $PSScriptRoot "update-changelog.ps1"
    if ($DryRun) {
        Write-Host "[DRY-RUN] Would run update-changelog.ps1 -ModFolder '$ModFolder' -Version '$fullVersion'" -ForegroundColor DarkCyan
        Write-Host "[DRY-RUN] Would run build-mod.ps1 -ModFolder '$ModFolder' -Version '$Version' -Channel '$Channel'" -ForegroundColor DarkCyan
    } else {
        if (Test-Path -LiteralPath $changelogScript -PathType Leaf) {
            & $changelogScript -ModFolder $ModFolder -Version $fullVersion
        }
        $buildScript = Join-Path $PSScriptRoot "build-mod.ps1"
        & $buildScript -ModFolder $ModFolder -Version $Version -Channel $Channel
    }
}

$zipExists = Test-Path -LiteralPath $zipPath -PathType Leaf
if (-not $DryRun -and -not $reuseUpload -and -not $DescriptionOnly -and -not $zipExists) {
    throw "Release archive not found at '$zipPath'. Run build-mod.ps1 first or omit -SkipBuild."
}

$zipSize = if ($zipExists) { (Get-Item -LiteralPath $zipPath).Length } else { 0 }
$zipFileName = Split-Path -Leaf $zipPath

# Resolve changelog notes
$notes = "Release $modName v$fullVersion"
if (-not [string]::IsNullOrWhiteSpace($NotesFile)) {
    if (-not (Test-Path -LiteralPath $NotesFile -PathType Leaf)) {
        throw "Notes file not found: '$NotesFile'"
    }
    $notes = (Get-Content -LiteralPath $NotesFile -Raw).Trim()
} else {
    $readmePath = Join-Path $modRoot "README.md"
    if (Test-Path -LiteralPath $readmePath -PathType Leaf) {
        $readmeText = Get-Content -LiteralPath $readmePath -Raw
        $escapedVer = [regex]::Escape($fullVersion)
        $m = [regex]::Match($readmeText, "(?s)(### v$escapedVer\b.*?)(?=\r?\n### v|\r?\n<!-- CHANGELOG:END -->)")
        if ($m.Success) {
            $notes = $m.Groups.Item(1).Value.Trim()
        }
    }
}

$modPageUrl = "https://www.nexusmods.com/$gameDomain/mods/$modId"
$nexusDescScript = Join-Path $PSScriptRoot "export-nexus-description.ps1"
$nexusDescPath   = Join-Path $modRoot "nexus-description.bbcode"

if (Test-Path -LiteralPath $nexusDescScript -PathType Leaf) {
    if ($DryRun) {
        Write-Host "[DRY-RUN] Would regenerate Nexus BBCode description at '$nexusDescPath'" -ForegroundColor DarkCyan
    } else {
        & $nexusDescScript -ModFolder $ModFolder -OutputPath $nexusDescPath
    }
}

if ($DryRun) {
    $placeholderWarn = ($modId -le 0 -or $fileId -le 0)
    Write-Host "`n================ [DRY-RUN NEXUS MODS PREVIEW] ================" -ForegroundColor Cyan
    Write-Host "Mod Folder         : $ModFolder ($modName)"
    Write-Host "Game Domain        : $gameDomain"
    Write-Host "Mod ID / File ID   : $modId / $fileId$(if ($placeholderWarn) { '  [PLACEHOLDER - set real IDs in nexus.json before publishing]' })"
    Write-Host "Mod Page URL       : $modPageUrl"
    Write-Host "Version            : $fullVersion (channel: $Channel)"
    Write-Host "Category           : $Category"
    Write-Host "Archive Existing   : $archiveExisting"
    Write-Host "Update Mod Version : $updateModVersion"
    Write-Host "API Key            : $(if ($resolvedApiKey) { '<set>' } else { '<not set - required for live publish>' })"
    Write-Host "Archive Path       : $zipPath (Exists: $zipExists, Size: $([math]::Round($zipSize / 1KB, 1)) KB)"
    Write-Host "--- Changelog Notes ---" -ForegroundColor DarkGray
    Write-Host $notes
    Write-Host "==============================================================`n" -ForegroundColor Cyan
    return
}

$apiHeaders = @{
    "apikey"     = $resolvedApiKey
    "Accept"     = "application/json"
    "User-Agent" = "runescape-dragonwilds-mods-cli/1.0"
}

if (-not $DescriptionOnly) {
    if ($reuseUpload) {
        $uploadId = $UploadId.Trim()
        Write-Host "Reusing finalized Nexus Mods upload '$uploadId' (skipping steps 1-3)..." -ForegroundColor Cyan
    } else {
        Write-Host "Uploading '$zipFileName' ($([math]::Round($zipSize / 1KB, 1)) KB) for $modName v$fullVersion to Nexus Mods..." -ForegroundColor Cyan

        # Step 1: Create upload session
        Write-Host "[1/4] Creating Nexus Mods upload session..." -ForegroundColor Yellow
        $createUploadBody = @{
            size_bytes = [int64]$zipSize
            filename   = $zipFileName
        } | ConvertTo-Json -Depth 4

        $uploadResp = Invoke-RestMethod `
            -Uri "$apiBaseUrl/uploads" `
            -Method Post `
            -Headers $apiHeaders `
            -ContentType "application/json" `
            -Body $createUploadBody

        $uploadData   = if ($uploadResp.data) { $uploadResp.data } else { $uploadResp }
        $uploadId     = [string]$uploadData.id
        $presignedUrl = [string]$uploadData.presigned_url

        if ([string]::IsNullOrWhiteSpace($uploadId) -or [string]::IsNullOrWhiteSpace($presignedUrl)) {
            throw "Unexpected response from Nexus Mods POST /uploads (missing 'id' or 'presigned_url')."
        }

        # Step 2: Upload archive binary to presigned URL
        Write-Host "[2/4] Uploading archive binary to cloud storage..." -ForegroundColor Yellow
        $putHeaders = @{
            "Content-Disposition" = "attachment; filename=`"$zipFileName`""
        }
        Invoke-RestMethod `
            -Uri $presignedUrl `
            -Method Put `
            -Headers $putHeaders `
            -InFile $zipPath `
            -ContentType "application/octet-stream" | Out-Null

        # Step 3: Finalize upload
        Write-Host "[3/4] Finalizing upload '$uploadId'..." -ForegroundColor Yellow
        Invoke-RestMethod `
            -Uri "$apiBaseUrl/uploads/$uploadId/finalise" `
            -Method Post `
            -Headers $apiHeaders | Out-Null
    }

    # Step 4: Create new mod file version
    Write-Host "[4/4] Publishing version '$fullVersion' to mod file #$fileId..." -ForegroundColor Yellow
    $versionPayload = @{
        upload_id             = $uploadId
        name                  = "$modName v$fullVersion"
        version               = $fullVersion
        file_category         = $Category
        archive_existing_file = $archiveExisting
        update_mod_version    = $updateModVersion
    }
    if (-not [string]::IsNullOrWhiteSpace($notes)) {
        # Nexus Mods file descriptions have a 255-character limit; strip markdown links and truncate cleanly
        $fileDesc = [regex]::Replace($notes, '\[([^\]]+)\]\([^\)]+\)', '$1')
        $fileDesc = [regex]::Replace($fileDesc, '[*_`#]+', '')
        $fileDesc = [regex]::Replace($fileDesc, '(\r?\n){2,}', "`n").Trim()
        if ($fileDesc.Length -gt 255) {
            $fileDesc = $fileDesc.Substring(0, 252).TrimEnd() + "..."
        }
        $versionPayload["description"] = $fileDesc
    }

    $versionResp = Invoke-RestMethod `
        -Uri "$apiBaseUrl/mod-files/$fileId/versions" `
        -Method Post `
        -Headers $apiHeaders `
        -ContentType "application/json" `
        -Body ($versionPayload | ConvertTo-Json -Depth 4)

    $versionData = if ($versionResp.data) { $versionResp.data } else { $versionResp }
    $newVersionId = if ($versionData.id) { [string]$versionData.id } else { "<created>" }

    Write-Host "Published $modName v$fullVersion to Nexus Mods (version ID: $newVersionId)" -ForegroundColor Green
}

# Sync Full description (BBCode) from README.md via PATCH /v3/mods/{uniqueModId}
if (-not $NoSyncDescription -and -not [string]::IsNullOrWhiteSpace($uniqueModId) -and (Test-Path -LiteralPath $nexusDescPath -PathType Leaf)) {
    $bbcodeDesc = (Get-Content -LiteralPath $nexusDescPath -Raw).Trim()
    if (-not [string]::IsNullOrWhiteSpace($bbcodeDesc)) {
        Write-Host "Syncing full mod description (BBCode) to Nexus Mods (mod UID $uniqueModId)..." -ForegroundColor Yellow
        $modPatchBody = @{
            description = $bbcodeDesc
        } | ConvertTo-Json -Depth 4
        Invoke-RestMethod `
            -Uri "$apiBaseUrl/mods/$uniqueModId" `
            -Method Patch `
            -Headers $apiHeaders `
            -ContentType "application/json" `
            -Body $modPatchBody | Out-Null
        Write-Host "Synced full mod description from README.md." -ForegroundColor Green
    }
}

# Sync version changelog to Nexus Mods Changelogs tab via POST /v3/mods/{uniqueModId}/changelogs
if (-not $NoSyncChangelog -and -not [string]::IsNullOrWhiteSpace($uniqueModId) -and -not [string]::IsNullOrWhiteSpace($notes)) {
    $cleanChangelog = [regex]::Replace($notes, '\[([^\]]+)\]\([^\)]+\)', '$1')
    $cleanChangelog = [regex]::Replace($cleanChangelog, '(?m)^###\s+v[^\r\n]+\r?\n?', '')
    $cleanChangelog = [regex]::Replace($cleanChangelog, '[*_`]+', '').Trim()

    if (-not [string]::IsNullOrWhiteSpace($cleanChangelog)) {
        $alreadyHasVersion = $false
        try {
            $existingLogs = Invoke-RestMethod `
                -Uri "$apiBaseUrl/mods/$uniqueModId/changelogs" `
                -Method Get `
                -Headers $apiHeaders
            $logItems = if ($existingLogs.data) { @($existingLogs.data) } else { @($existingLogs) }
            foreach ($entry in $logItems) {
                if ($entry.version -eq $fullVersion) {
                    $alreadyHasVersion = $true
                    break
                }
            }
        } catch {
            Write-Warning "Could not check existing Nexus changelogs: $_"
        }

        if ($alreadyHasVersion) {
            Write-Host "Nexus Mods changelog for v$fullVersion already exists; skipping to avoid duplicates." -ForegroundColor DarkGray
        } else {
            Write-Host "Posting changelog for v$fullVersion to Nexus Mods Changelogs tab..." -ForegroundColor Yellow
            $changelogBody = @{
                version   = $fullVersion
                changelog = $cleanChangelog
            } | ConvertTo-Json -Depth 4
            Invoke-RestMethod `
                -Uri "$apiBaseUrl/mods/$uniqueModId/changelogs" `
                -Method Post `
                -Headers $apiHeaders `
                -ContentType "application/json" `
                -Body $changelogBody | Out-Null
            Write-Host "Posted changelog for v$fullVersion to Nexus Mods." -ForegroundColor Green
        }
    }
}

Write-Host "Mod Page: $modPageUrl" -ForegroundColor Green
