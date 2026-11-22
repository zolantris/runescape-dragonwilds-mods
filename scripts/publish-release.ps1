[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ModFolder,
    [string]$Version,
    [string]$Channel,
    [switch]$ForceUpdate,
    [switch]$DryRun,
    [switch]$SkipBuild,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = "Stop"

if ($ExtraArgs) {
    foreach ($arg in $ExtraArgs) {
        switch ($arg.ToLower()) {
            "--force-update" { $ForceUpdate = $true }
            "-force-update"  { $ForceUpdate = $true }
            "--dry-run"      { $DryRun = $true }
            "-dry-run"       { $DryRun = $true }
            "--skip-build"   { $SkipBuild = $true }
            default          { throw "Unknown argument: '$arg'" }
        }
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$modRoot  = Join-Path $repoRoot $ModFolder
$ue4ssSrc = Join-Path $modRoot "ue4ss"

if (-not (Test-Path $ue4ssSrc)) {
    throw "Missing 'ue4ss' directory inside '$modRoot'"
}

if (-not $DryRun -and -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI ('gh') is required to publish releases. Install it from https://cli.github.com/ and run 'gh auth login'."
}

$modDirs = Get-ChildItem -Path (Join-Path $ue4ssSrc "Mods") -Directory
if ($modDirs.Count -ne 1) {
    throw "Expected exactly 1 mod folder inside '$ue4ssSrc\Mods', found $($modDirs.Count)"
}
$modName = $modDirs.Name

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

function Parse-SemVer([string]$verStr) {
    $clean = $verStr -replace '^v', ''
    $m = [regex]::Match($clean, '^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$')
    if ($m.Success) {
        $pre = $m.Groups.Item(4).Value
        return [PSCustomObject]@{
            Major      = [int]$m.Groups.Item(1).Value
            Minor      = [int]$m.Groups.Item(2).Value
            Patch      = [int]$m.Groups.Item(3).Value
            PreRelease = $pre
            IsStable   = [string]::IsNullOrEmpty($pre)
        }
    }
    return $null
}

function Compare-SemVer($a, $b) {
    if ($a.Major -ne $b.Major) { return $a.Major.CompareTo($b.Major) }
    if ($a.Minor -ne $b.Minor) { return $a.Minor.CompareTo($b.Minor) }
    if ($a.Patch -ne $b.Patch) { return $a.Patch.CompareTo($b.Patch) }
    if ($a.IsStable -and -not $b.IsStable) { return 1 }
    if (-not $a.IsStable -and $b.IsStable) { return -1 }
    return [string]::Compare($a.PreRelease, $b.PreRelease, $true)
}

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

# Extract ONLY the current version's delta block from README.md
$notes = "Release $tagName"
$readmePath = Join-Path $modRoot "README.md"
if (Test-Path $readmePath) {
    $readmeText = Get-Content $readmePath -Raw
    $escapedVer = [regex]::Escape($fullVersion)
    $m = [regex]::Match($readmeText, "(?s)(### v$escapedVer\b.*?)(?=\r?\n### v|\r?\n<!-- CHANGELOG:END -->)")
    if ($m.Success) {
        $notes = $m.Groups.Item(1).Value.Trim()
    }
}

Push-Location $repoRoot
$notesFile = Join-Path $env:TEMP "gh-release-notes-$tagName.md"
try {
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

    # Find closest lower semver tag (handles 0 prior tags gracefully)
    $prevTag = $null
    $targetSemVer = Parse-SemVer $fullVersion
    $allTags = @(git tag -l "$modName-v*" 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($targetSemVer -and $allTags.Count -gt 0) {
        $lowerTags = @()
        foreach ($t in $allTags) {
            $tVerStr = $t.Substring("$modName-v".Length)
            $tSemVer = Parse-SemVer $tVerStr
            if ($tSemVer -and (Compare-SemVer $tSemVer $targetSemVer) -lt 0) {
                $lowerTags += [PSCustomObject]@{ Tag = $t; SemVer = $tSemVer }
            }
        }
        if ($lowerTags.Count -gt 0) {
            $sorted = @($lowerTags | Sort-Object { $_.SemVer.Major }, { $_.SemVer.Minor }, { $_.SemVer.Patch }, { $_.SemVer.IsStable }, { $_.SemVer.PreRelease })
            $prevTag = ($sorted | Select-Object -Last 1).Tag
        }
    }

    # Check if README.md or version.json was updated during build so working tree stays clean
    $relReadme  = "$ModFolder/README.md"
    $relVersion = "$ModFolder/version.json"
    $dirtyReleaseFiles = @(git status --porcelain -- $relReadme $relVersion 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($DryRun) {
        Write-Host "`n================ [DRY-RUN RELEASE PREVIEW] ================" -ForegroundColor Cyan
        Write-Host "Mod Folder   : $ModFolder"
        Write-Host "Tag Name     : $tagName"
        Write-Host "Previous Tag : $(if ($prevTag) { $prevTag } else { '<none - initial release>' })"
        Write-Host "Release Title: $modName v$fullVersion"
        Write-Host "Prerelease   : $($Channel.ToLower() -ne 'stable')"
        Write-Host "Asset Path   : $zipPath (Exists: $(Test-Path $zipPath))"
        Write-Host "Tag Exists   : local=$([bool]$localTag), remote=$([bool]$remoteTag), release=$releaseExists (ForceUpdate=$ForceUpdate)"
        Write-Host "Dirty Meta   : $($dirtyReleaseFiles.Count) file(s) would be auto-committed before tagging"
        Write-Host "--- Folder-Scoped Delta Notes (+ GitHub --generate-notes) ---" -ForegroundColor DarkGray
        Write-Host $notes
        Write-Host "===========================================================`n" -ForegroundColor Cyan
        return
    }

    # Commit & push updated README.md / version.json before creating the release tag
    if ($dirtyReleaseFiles.Count -gt 0) {
        Write-Host "Committing updated release metadata ($relReadme)..." -ForegroundColor Cyan
        git add -- $relReadme $relVersion 2>$null
        git commit -m "chore(release): update $ModFolder README for v$fullVersion"
        git push
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

    git tag -a $tagName -m "Release $tagName"
    git push origin $tagName

    Set-Content -Path $notesFile -Value $notes -Encoding UTF8

    $ghArgs = @("release", "create", $tagName, $zipPath, "--title", "$modName v$fullVersion", "--notes-file", $notesFile, "--generate-notes")
    if ($prevTag) {
        $ghArgs += @("--notes-start-tag", $prevTag)
    }
    if ($Channel.ToLower() -ne "stable") {
        $ghArgs += "--prerelease"
    }

    & gh @ghArgs
    if ($LASTEXITCODE -ne 0) {
        throw "gh release create failed with exit code $LASTEXITCODE"
    }

    Write-Host "Published release '$tagName' (delta from $(if ($prevTag) { $prevTag } else { 'initial release' }))" -ForegroundColor Green
} finally {
    if (Test-Path $notesFile) { Remove-Item $notesFile -Force -ErrorAction SilentlyContinue }
    Pop-Location
}
