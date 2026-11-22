[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ModFolder,
    [string]$Version,
    [string]$Channel,
    [Alias("force-update")]
    [switch]$ForceUpdate,
    [Alias("dry-run")]
    [switch]$DryRun,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$modRoot  = Join-Path $repoRoot $ModFolder
$ue4ssSrc = Join-Path $modRoot "ue4ss"

if (-not (Test-Path $ue4ssSrc)) {
    throw "Missing 'ue4ss' directory inside '$modRoot'"
}

if (-not $DryRun -and -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI ('gh') is required to publish releases. Install it from https://github.com and run 'gh auth login'."
}

$modDirs = Get-ChildItem -Path (Join-Path $ue4ssSrc "Mods") -Directory
if ($modDirs.Count -ne 1) {
    throw "Expected exactly 1 mod folder inside '$ue4ssSrc\Mods', found $($modDirs.Count)"
}
$modName = $modDirs.Name

# Read version.json
$versionFile = Join-Path $modRoot "version.json"
$verData = if (Test-Path $versionFile) { Get-Content $versionFile -Raw | ConvertFrom-Json } else { $null }

if (-not $Version) {
    $Version = if ($verData -and $verData.version) { [string]$verData.version } else { "1.0.0" }
}
if (-not $Channel) {
    $Channel = if ($verData -and $verData.channel) { [string]$verData.channel } else { "stable" }
}

$fullVersion = if ($Channel -and $Channel.ToLower() -ne "stable") { "$Version-$Channel" } else { $Version }
$tagName     = "$modName-v$fullVersion"
$zipPath     = Join-Path $repoRoot "archives\$tagName.zip"

if (-not $SkipBuild) {
    if ($DryRun) {
        Write-Host "[DRY-RUN] Would run build-mod.ps1 -ModFolder '$ModFolder' -Version '$Version' -Channel '$Channel'" -ForegroundColor DarkCyan
    } else {
        $buildScript = Join-Path $PSScriptRoot "build-mod.ps1"
        & $buildScript -ModFolder $ModFolder -Version $Version -Channel $Channel
    }
}

if (-not $DryRun -and -not (Test-Path $zipPath)) {
    throw "Release archive not found at '$zipPath'. Run build-mod.ps1 first or omit -SkipBuild."
}

# Extract latest changelog block from README.md for release notes
$notes = "Release $tagName"
$readmePath = Join-Path $modRoot "README.md"
if (Test-Path $readmePath) {
    $readmeText = Get-Content $readmePath -Raw
    $m = [regex]::Match($readmeText, '(?s)<!-- CHANGELOG:START -->\s*(.*?)\s*<!-- CHANGELOG:END -->')
    if ($m.Success) {
        $notes = $m.Groups.Value.Trim()
    }
}

Push-Location $repoRoot
try {
    # Check local and remote tags
    git fetch --tags --quiet 2>$null
    $localTag  = git tag -l $tagName
    $remoteTag = git ls-remote --tags origin "refs/tags/$tagName" 2>$null

    $releaseExists = $false
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        gh release view $tagName *> $null
        if ($LASTEXITCODE -eq 0) { $releaseExists = $true }
    }

    if (($localTag -or $remoteTag -or $releaseExists) -and -not $ForceUpdate) {
        Write-Error "Tag or release '$tagName' already exists. Pass -ForceUpdate (or --force-update) to overwrite it."
        exit 1
    }

    if ($DryRun) {
        Write-Host "`n================ [DRY-RUN RELEASE PREVIEW] ================" -ForegroundColor Cyan
        Write-Host "Mod Folder   : $ModFolder"
        Write-Host "Tag Name     : $tagName"
        Write-Host "Release Title: $modName v$fullVersion"
        Write-Host "Prerelease   : $($Channel.ToLower() -ne 'stable')"
        Write-Host "Asset Path   : $zipPath (Exists: $(Test-Path $zipPath))"
        Write-Host "Tag Exists   : local=$([bool]$localTag), remote=$([bool]$remoteTag), release=$releaseExists (ForceUpdate=$ForceUpdate)"
        Write-Host "--- Release Notes ---" -ForegroundColor DarkGray
        Write-Host $notes
        Write-Host "===========================================================`n" -ForegroundColor Cyan
        return
    }

    if ($ForceUpdate) {
        if ($releaseExists) {
            Write-Host "Deleting existing GitHub release '$tagName'..." -ForegroundColor Yellow
            gh release delete $tagName --yes --cleanup-tag
        } elseif ($remoteTag -or $localTag) {
            Write-Host "Removing existing tag '$tagName'..." -ForegroundColor Yellow
            if ($localTag) { git tag -d $tagName *> $null }
            if ($remoteTag) { git push origin ":refs/tags/$tagName" *> $null }
        }
    }

    # Create annotated tag on current HEAD and push
    git tag -a $tagName -m "Release $tagName"
    git push origin $tagName

    $ghArgs = @("release", "create", $tagName, $zipPath, "--title", "$modName v$fullVersion", "--notes", $notes)
    if ($Channel.ToLower() -ne "stable") {
        $ghArgs += "--prerelease"
    }

    & gh @ghArgs
    if ($LASTEXITCODE -ne 0) {
        throw "gh release create failed with exit code $LASTEXITCODE"
    }

    Write-Host "Published release '$tagName' with asset '$zipPath'" -ForegroundColor Green
} finally {
    Pop-Location
}
