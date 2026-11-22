param(
    [Parameter(Mandatory = $true)]
    [string]$ModFolder,
    [string]$Version,
    [int]$MaxCommits = 30
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$modRoot  = Join-Path $repoRoot $ModFolder

if (-not (Test-Path $modRoot)) {
    throw "Mod folder '$modRoot' does not exist."
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

$readmePath = Join-Path $modRoot "README.md"
if (-not (Test-Path $readmePath)) {
    throw "Missing README.md at '$readmePath'"
}

$commits = @()
Push-Location $repoRoot
try {
    $gitAvailable = Get-Command git -ErrorAction SilentlyContinue
    if ($gitAvailable -and (Test-Path (Join-Path $repoRoot ".git"))) {
        $rawLog = git log -n $MaxCommits --pretty=format:"%ad|%h|%s" --date=short -- $ModFolder 2>$null
        if ($LASTEXITCODE -eq 0 -and $rawLog) {
            foreach ($entry in $rawLog) {
                $parts = $entry -split '\|', 3
                if ($parts.Count -eq 3) {
                    $date = $parts[0].Trim()
                    $hash = $parts[1].Trim()
                    $msg  = $parts[2].Trim()
                    if ($msg -notmatch '^(chore\(release\)|docs: update changelog)') {
                        $commits += "- **$date** - $msg (``$hash``)"
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

$changelogBlock = @(
    "<!-- CHANGELOG:START -->"
    "### v$Version"
    ""
) + $commits + @(
    "<!-- CHANGELOG:END -->"
)
$replacement = ($changelogBlock -join "`n")

$readmeText = Get-Content $readmePath -Raw

# Update version inside top H1 heading: e.g. # Ultra-Wide Menu Alignment (`UltraWideMenuAlignment` v1.3.3)
$readmeText = [regex]::Replace(
    $readmeText,
    '(?m)^(#\s+.+?`[^`]+`\s+v)[^\)\r\n]+(\))',
    "`${1}$Version`${2}",
    1
)

# Update or append changelog block
$pattern = '(?s)<!-- CHANGELOG:START -->.*?<!-- CHANGELOG:END -->'
if ($readmeText -match $pattern) {
    $updatedText = [regex]::Replace($readmeText, $pattern, $replacement)
} else {
    $updatedText = $readmeText.TrimEnd() + "`n`n## Changelog`n`n" + $replacement + "`n"
}

Set-Content -Path $readmePath -Value $updatedText -Encoding UTF8 -NoNewline
Write-Host "Updated README title & changelog in '$readmePath' (v$Version, $($commits.Count) entries)" -ForegroundColor Cyan
