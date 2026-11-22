param(
    [Parameter(Mandatory = $true)]
    [string]$ModFolder,
    [string]$Version,
    [int]$MaxCommits = 50
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$modRoot  = Join-Path $repoRoot $ModFolder
$ue4ssSrc = Join-Path $modRoot "ue4ss"

if (-not (Test-Path $modRoot)) {
    throw "Mod folder '$modRoot' does not exist."
}

$modName = $ModFolder
if (Test-Path (Join-Path $ue4ssSrc "Mods")) {
    $modDirs = Get-ChildItem -Path (Join-Path $ue4ssSrc "Mods") -Directory
    if ($modDirs.Count -eq 1) { $modName = $modDirs.Name }
}

$versionFile = Join-Path $modRoot "version.json"
if (-not $Version) {
    if (Test-Path $versionFile) {
        $verData = Get-Content $versionFile -Raw | ConvertFrom-Json
        $v = if ($verData.version) { [string]$verData.version } else { "1.0.0" }
        $c = if ($verData.channel) { [string]$verData.channel } else { "stable" }
        $Version = if ($c.ToLower() -ne "stable") { "$v-$c" } else { $v }
    } else {
        $Version = "1.0.0"
    }
}

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

function Resolve-RepoWebUrl {
    $remoteUrl = (git remote get-url origin 2>$null)
    if ([string]::IsNullOrWhiteSpace($remoteUrl)) { return $null }
    $remoteUrl = $remoteUrl.Trim()
    if ($remoteUrl -match '^git@([^:]+):(.+?)(?:\.git)?$') {
        return "https://$($Matches[1])/$($Matches[2])"
    }
    if ($remoteUrl -match '^https?://(.+?)(?:\.git)?$') {
        return "https://$($Matches[1])"
    }
    return $null
}

$readmePath = Join-Path $modRoot "README.md"
if (-not (Test-Path $readmePath)) {
    throw "Missing README.md at '$readmePath'"
}

$commits = @()
$prevTag = $null
$repoWebUrl = $null

Push-Location $repoRoot
try {
    $gitAvailable = Get-Command git -ErrorAction SilentlyContinue
    if ($gitAvailable -and (Test-Path (Join-Path $repoRoot ".git"))) {
        $repoWebUrl = Resolve-RepoWebUrl

        # Resolve active local branch (fallback to 'main' if detached HEAD)
        $baseRef = (git rev-parse --abbrev-ref HEAD 2>$null)
        if ([string]::IsNullOrWhiteSpace($baseRef) -or $baseRef.Trim() -eq "HEAD") {
            $baseRef = "main"
        } else {
            $baseRef = $baseRef.Trim()
        }

        $targetSemVer = Parse-SemVer $Version
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

        $rangeSpec = if ($prevTag) { "$prevTag..$baseRef" } else { $baseRef }
        $rawLog = @(git log $rangeSpec -n $MaxCommits --pretty=format:"%ad|%h|%H|%s" --date=short 2>$null)
        if ($LASTEXITCODE -eq 0 -and $rawLog.Count -gt 0) {
            foreach ($entry in $rawLog) {
                if ([string]::IsNullOrWhiteSpace($entry)) { continue }
                $parts = $entry.Split('|', 4)
                if ($parts.Length -eq 4) {
                    $date     = ($parts | Select-Object -Index 0).Trim()
                    $shortSha = ($parts | Select-Object -Index 1).Trim()
                    $fullSha  = ($parts | Select-Object -Index 2).Trim()
                    $msg      = ($parts | Select-Object -Index 3).Trim()
                    if ($msg -notmatch '^(chore\(release\)|docs: update changelog)') {
                        if ($repoWebUrl) {
                            $commits += "- **$date** - $msg ([$shortSha]($repoWebUrl/commit/$fullSha))"
                        } else {
                            $commits += "- **$date** - $msg ($shortSha)"
                        }
                    }
                }
            }
        }
    }
} finally {
    Pop-Location
}

if ($commits.Count -eq 0) {
    $commits = @("- **$(Get-Date -Format 'yyyy-MM-dd')** - Release v$Version")
}

if ($prevTag) {
    if ($repoWebUrl) {
        $compareNote = "`n_Changes since [$prevTag]($repoWebUrl/releases/tag/$prevTag)_`n"
    } else {
        $compareNote = "`n_Changes since $prevTag_`n"
    }
} else {
    $compareNote = ""
}

$newSection = (@("### v$Version$compareNote", "") + $commits) -join "`n"

$readmeText = Get-Content $readmePath -Raw
$readmeText = [regex]::Replace(
    $readmeText,
    '(?m)^(#\s+.+?`[^`]+`\s+v)[^\)\r\n]+(\))',
    "`${1}$Version`${2}",
    1
)

$pattern = '(?s)<!-- CHANGELOG:START -->\s*(.*?)\s*<!-- CHANGELOG:END -->'
$bodyMatch = [regex]::Match($readmeText, $pattern)
if ($bodyMatch.Success) {
    $existingBody = $bodyMatch.Groups.Item(1).Value.Trim()
    $escapedVer = [regex]::Escape($Version)
    $secPattern = "(?s)### v$escapedVer\b.*?(?=\r?\n### v|\z)"
    if ($existingBody -match $secPattern) {
        $mergedBody = [regex]::Replace($existingBody, $secPattern, $newSection, 1).Trim()
    } elseif ($existingBody) {
        $mergedBody = "$newSection`n`n$existingBody"
    } else {
        $mergedBody = $newSection
    }
    $replacement = "<!-- CHANGELOG:START -->`n$mergedBody`n<!-- CHANGELOG:END -->"
    $updatedText = [regex]::Replace($readmeText, $pattern, $replacement, 1)
} else {
    $replacement = "<!-- CHANGELOG:START -->`n$newSection`n<!-- CHANGELOG:END -->"
    $updatedText = $readmeText.TrimEnd() + "`n`n## Changelog`n`n" + $replacement + "`n"
}

Set-Content -Path $readmePath -Value $updatedText -Encoding UTF8 -NoNewline
$fromLabel = if ($prevTag) { "since $prevTag" } else { "initial release" }
Write-Host "Updated README changelog in '$readmePath' (v$Version, $($commits.Count) entries, $fromLabel)" -ForegroundColor Cyan
