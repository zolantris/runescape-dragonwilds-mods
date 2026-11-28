[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ModFolder,
    [string]$InputPath,
    [string]$OutputPath,
    [string]$RepoUrl,
    [string]$Branch = "main",
    [switch]$IncludeChangelog,
    [switch]$NoRepoBanner,
    [switch]$Copy,
    [switch]$PassThru
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$modRoot  = Join-Path $repoRoot $ModFolder

if (-not (Test-Path -LiteralPath $modRoot -PathType Container)) {
    throw "Mod folder not found: '$modRoot'"
}

if ([string]::IsNullOrWhiteSpace($InputPath)) {
    $InputPath = Join-Path $modRoot "README.md"
}
if (-not (Test-Path -LiteralPath $InputPath -PathType Leaf)) {
    throw "Input README not found: '$InputPath'"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $modRoot "nexus-description.bbcode"
}

# Resolve GitHub repo URL from git remote if not provided
if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
    try {
        $originUrl = (& git -C $repoRoot remote get-url origin 2>$null | Select-Object -First 1)
        if (-not [string]::IsNullOrWhiteSpace($originUrl)) {
            $originUrl = $originUrl.Trim()
            if ($originUrl -match '^git@github\.com:([^/]+/[^/]+?)(?:\.git)?$') {
                $RepoUrl = "https://github.com/$($Matches[1])"
            } elseif ($originUrl -match '^https?://github\.com/([^/]+/[^/]+?)(?:\.git)?/?$') {
                $RepoUrl = "https://github.com/$($Matches[1])"
            }
        }
    } catch { }
}
if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
    $RepoUrl = "https://github.com/zolantris/runescape-dragonwilds-mods"
}
$RepoUrl = $RepoUrl.TrimEnd('/')

$rawBaseUrl = $RepoUrl -replace '^https?://github\.com/', 'https://raw.githubusercontent.com/'
$inputDir   = Split-Path -Parent (Resolve-Path -LiteralPath $InputPath).Path

function Resolve-RepoUrl {
    param(
        [string]$Href,
        [switch]$IsImage
    )
    if ([string]::IsNullOrWhiteSpace($Href)) { return $Href }
    $trimmed = $Href.Trim()

    # Already absolute URL or anchor
    if ($trimmed -match '^(https?://|mailto:|#)') {
        return $trimmed
    }

    # Separate optional #anchor
    $anchor = ""
    if ($trimmed -match '^([^#]+)(#.*)$') {
        $trimmed = $Matches[1]
        $anchor  = $Matches[2]
    }

    $isDirLink = $trimmed.EndsWith("/")
    $combined  = [System.IO.Path]::GetFullPath((Join-Path $inputDir $trimmed))
    $rootFull  = [System.IO.Path]::GetFullPath($repoRoot).TrimEnd('\', '/')

    if ($combined.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $combined.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
        if ($IsImage) {
            return "$rawBaseUrl/$Branch/$rel"
        }
        $kind = if ($isDirLink -or (Test-Path -LiteralPath $combined -PathType Container)) { "tree" } else { "blob" }
        return "$RepoUrl/$kind/$Branch/$rel$anchor"
    }

    return $Href
}

function Convert-InlineMarkdown {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }

    $s = $Text

    # 1. Images: ![alt](url) -> [img]resolved_url[/img]
    $s = [regex]::Replace($s, '!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)', {
        param($m)
        $url = Resolve-RepoUrl -Href $m.Groups[2].Value -IsImage
        return "[img]$url[/img]"
    })

    # 2. Links: [label](url) -> [url=resolved_url]label[/url]
    $s = [regex]::Replace($s, '\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)', {
        param($m)
        $label = $m.Groups[1].Value -replace '`([^`]+)`', '$1'
        $url   = Resolve-RepoUrl -Href $m.Groups[2].Value
        # If label is identical to URL, still wrap cleanly
        return "[url=$url]$label[/url]"
    })

    # 3. Protect [url=...] and [img]...[/img] from italic/underscore replacements
    $placeholders = New-Object System.Collections.Generic.List[string]
    $s = [regex]::Replace($s, '\[(?:url=[^\]]+|img)\].*?\[/(?:url|img)\]', {
        param($m)
        $idx = $placeholders.Count
        $placeholders.Add($m.Value)
        return "`u{E000}PH$idx`u{E001}"
    })

    # 4. Inline code: strip backticks cleanly (Nexus [code] breaks inline flow)
    $s = [regex]::Replace($s, '`([^`]+)`', '$1')

    # 5. Bold + Italic: ***text*** -> [b][i]text[/i][/b]
    $s = [regex]::Replace($s, '\*\*\*([^\*]+?)\*\*\*', '[b][i]$1[/i][/b]')

    # 6. Bold: **text** -> [b]text[/b]
    $s = [regex]::Replace($s, '\*\*([^\*]+?)\*\*', '[b]$1[/b]')

    # 7. Italic: *text* -> [i]text[/i]
    $s = [regex]::Replace($s, '(?<!\*)\*([^\*\r\n]+?)\*(?!\*)', '[i]$1[/i]')

    # 8. Italic with underscores (only at word boundaries so DA_Spell_Primary_Air_04 is untouched)
    $s = [regex]::Replace($s, '(?<![A-Za-z0-9_])_([^_\r\n]+?)_(?![A-Za-z0-9_])', '[i]$1[/i]')

    # 9. Strikethrough: ~~text~~ -> [s]text[/s]
    $s = [regex]::Replace($s, '~~([^~]+?)~~', '[s]$1[/s]')

    # 10. Restore protected tags
    for ($i = 0; $i -lt $placeholders.Count; $i++) {
        $s = $s.Replace("`u{E000}PH$i`u{E001}", $placeholders[$i])
    }

    return $s
}

function Split-MarkdownTableRow {
    param([string]$Line)
    $trimmed = $Line.Trim()
    if ($trimmed.StartsWith('|')) { $trimmed = $trimmed.Substring(1) }
    if ($trimmed.EndsWith('|'))   { $trimmed = $trimmed.Substring(0, $trimmed.Length - 1) }
    return @($trimmed -split '\|' | ForEach-Object { $_.Trim() })
}

function Convert-TableToBBCode {
    param([string[]]$TableLines)
    if ($TableLines.Count -lt 2) { return @() }

    $headers = Split-MarkdownTableRow $TableLines[0]
    $rows    = New-Object System.Collections.Generic.List[object]

    for ($r = 2; $r -lt $TableLines.Count; $r++) {
        $cells = Split-MarkdownTableRow $TableLines[$r]
        if ($cells.Count -gt 0) {
            $rows.Add($cells)
        }
    }

    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("[list]")

    foreach ($cells in $rows) {
        $colCount = $cells.Count
        if ($colCount -eq 2) {
            $c0 = Convert-InlineMarkdown $cells[0]
            $c1 = Convert-InlineMarkdown $cells[1]
            # Avoid double-bolding if cell already starts with [b]
            if ($c0 -notmatch '^\[b\].*\[/b\]$') { $c0 = "[b]$c0[/b]" }
            $out.Add("[*]$c0 — $c1[/*]")
        } elseif ($colCount -ge 3) {
            $first = Convert-InlineMarkdown $cells[0]
            if ($first -notmatch '^\[b\].*\[/b\]$') { $first = "[b]$first[/b]" }

            # Check if last column is a summary/description
            $lastHeader = if ($headers.Count -ge $colCount) { $headers[$colCount - 1] } else { "" }
            $hasSummary = ($lastHeader -match '^(Summary|Description|Purpose|Notes)$')

            if ($hasSummary -and $colCount -ge 4) {
                $metaParts = New-Object System.Collections.Generic.List[string]
                for ($c = 1; $c -lt ($colCount - 1); $c++) {
                    $val = Convert-InlineMarkdown $cells[$c]
                    if ([string]::IsNullOrWhiteSpace($val) -or $val -eq "—" -or $val -eq "-") { continue }
                    $hdr = if ($c -lt $headers.Count) { $headers[$c] } else { "" }
                    if ($c -eq 1 -and $hdr -match 'Name|Title') {
                        # Swap display name to lead, keep ID in meta
                        $idClean = Convert-InlineMarkdown $cells[0]
                        $metaParts.Insert(0, "ID: $idClean")
                        $first = "[b]$val[/b]"
                    } elseif (-not [string]::IsNullOrWhiteSpace($hdr)) {
                        $metaParts.Add("${hdr}: $val")
                    } else {
                        $metaParts.Add($val)
                    }
                }
                $summary = Convert-InlineMarkdown $cells[$colCount - 1]
                $metaStr = if ($metaParts.Count -gt 0) { " ($($metaParts -join ' | '))" } else { "" }
                $out.Add("[*]$first$metaStr — $summary[/*]")
            } else {
                $parts = New-Object System.Collections.Generic.List[string]
                for ($c = 1; $c -lt $colCount; $c++) {
                    $val = Convert-InlineMarkdown $cells[$c]
                    if ([string]::IsNullOrWhiteSpace($val)) { continue }
                    $hdr = if ($c -lt $headers.Count) { $headers[$c] } else { "" }
                    if ($c -eq 1) {
                        $parts.Add($val)
                    } elseif (-not [string]::IsNullOrWhiteSpace($hdr)) {
                        $parts.Add("${hdr}: $val")
                    } else {
                        $parts.Add($val)
                    }
                }
                $out.Add("[*]$first $($parts -join '  |  ')[/*]")
            }
        }
    }

    $out.Add("[/list]")
    return $out.ToArray()
}

# Read source markdown as UTF-8
$rawMd = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8

# Optionally strip Changelog section
if (-not $IncludeChangelog) {
    $rawMd = [regex]::Replace($rawMd, '(?s)\r?\n##\s+Changelog\b.*$', '')
    $rawMd = [regex]::Replace($rawMd, '(?s)<!--\s*CHANGELOG:START\s*-->.*?<!--\s*CHANGELOG:END\s*-->', '')
}

$lines = $rawMd -split "\r?\n"
$out   = New-Object System.Collections.Generic.List[string]

$inCodeBlock   = $false
$codeLines     = New-Object System.Collections.Generic.List[string]
$inList        = $false
$listOrdered   = $false
$currentItem   = $null
$bannerAdded   = $NoRepoBanner.IsPresent

$relReadmeUrl = "$RepoUrl/blob/$Branch/$ModFolder/README.md"
$repoMainUrl  = "$RepoUrl/tree/$Branch"
$repoBanner   = "Please see the GitHub repo's [url=$relReadmeUrl]README[/url] for the latest information. The main GitHub repo can be found [url=$repoMainUrl]here[/url]."

function Flush-List {
    if ($script:inList) {
        if ($null -ne $script:currentItem) {
            $out.Add("[*]$($script:currentItem)[/*]")
            $script:currentItem = $null
        }
        $out.Add("[/list]")
        $script:inList = $false
    }
}

$i = 0
while ($i -lt $lines.Count) {
    $line = $lines[$i]

    # Fenced code blocks
    if ($line -match '^\s*```') {
        if (-not $inCodeBlock) {
            Flush-List
            $inCodeBlock = $true
            $codeLines.Clear()
        } else {
            $inCodeBlock = $false
            $out.Add("[code]")
            foreach ($cl in $codeLines) { $out.Add($cl) }
            $out.Add("[/code]")
        }
        $i++
        continue
    }

    if ($inCodeBlock) {
        $codeLines.Add($line)
        $i++
        continue
    }

    # Skip HTML comments
    if ($line -match '^\s*<!--.*-->\s*$') {
        $i++
        continue
    }

    # Markdown Table detection (header row + separator row)
    if ($line -match '^\s*\|.+\|\s*$' -and ($i + 1) -lt $lines.Count -and $lines[$i + 1] -match '^\s*\|[\s:\-\|]+\|\s*$') {
        Flush-List
        $tableLines = New-Object System.Collections.Generic.List[string]
        while ($i -lt $lines.Count -and $lines[$i] -match '^\s*\|.+\|\s*$') {
            $tableLines.Add($lines[$i])
            $i++
        }
        foreach ($tl in (Convert-TableToBBCode $tableLines.ToArray())) {
            $out.Add($tl)
        }
        continue
    }

    # Horizontal rule
    if ($line -match '^\s*(?:---+|\*\*\*+|___+)\s*$') {
        Flush-List
        $out.Add("[line]")
        if (-not $bannerAdded) {
            $out.Add($repoBanner)
            $out.Add("")
            $bannerAdded = $true
        }
        $i++
        continue
    }

    # Headings
    if ($line -match '^(#{1,6})\s+(.+?)\s*$') {
        Flush-List
        $level = $Matches[1].Length
        $text  = Convert-InlineMarkdown $Matches[2]
        switch ($level) {
            1 { $out.Add("[size=5][b]$text[/b][/size]") }
            2 { $out.Add("[size=4][b]$text[/b][/size]") }
            default { $out.Add("[b]$text[/b]") }
        }
        $i++
        continue
    }

    # Blockquote
    if ($line -match '^\s*>\s?(.*)$') {
        Flush-List
        $quoteLines = New-Object System.Collections.Generic.List[string]
        while ($i -lt $lines.Count -and $lines[$i] -match '^\s*>\s?(.*)$') {
            $quoteLines.Add((Convert-InlineMarkdown $Matches[1]))
            $i++
        }
        $out.Add("[quote]$($quoteLines -join "`n")[/quote]")
        continue
    }

    # Nested list item (indented 2+ spaces)
    if ($inList -and $line -match '^\s{2,}(?:[\*\-]|\d+\.)\s+(.+)$') {
        $subText = Convert-InlineMarkdown $Matches[1]
        if ($null -ne $currentItem) {
            $currentItem += "`n• $subText"
        } else {
            $currentItem = "• $subText"
        }
        $i++
        continue
    }

    # Top-level unordered list item
    if ($line -match '^[\*\-]\s+(.+)$') {
        $itemText = Convert-InlineMarkdown $Matches[1]
        if ($inList -and $listOrdered) {
            Flush-List
        }
        if (-not $inList) {
            $out.Add("[list]")
            $inList      = $true
            $listOrdered = $false
        } elseif ($null -ne $currentItem) {
            $out.Add("[*]$currentItem[/*]")
        }
        $currentItem = $itemText
        $i++
        continue
    }

    # Top-level ordered list item
    if ($line -match '^\d+\.\s+(.+)$') {
        $itemText = Convert-InlineMarkdown $Matches[1]
        if ($inList -and -not $listOrdered) {
            Flush-List
        }
        if (-not $inList) {
            $out.Add("[list=1]")
            $inList      = $true
            $listOrdered = $true
        } elseif ($null -ne $currentItem) {
            $out.Add("[*]$currentItem[/*]")
        }
        $currentItem = $itemText
        $i++
        continue
    }

    # Blank line
    if ([string]::IsNullOrWhiteSpace($line)) {
        Flush-List
        if ($out.Count -gt 0 -and $out[$out.Count - 1] -ne "") {
            $out.Add("")
        }
        $i++
        continue
    }

    # Regular paragraph line
    Flush-List
    $out.Add((Convert-InlineMarkdown $line))
    $i++
}

Flush-List

# Trim trailing blank lines
while ($out.Count -gt 0 -and $out[$out.Count - 1] -eq "") {
    $out.RemoveAt($out.Count - 1)
}

$bbcode = ($out -join "`n") + "`n"

# Write UTF-8 without BOM
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$outDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
[System.IO.File]::WriteAllText($OutputPath, $bbcode, $utf8NoBom)

Write-Host "Generated Nexus Mods BBCode description: $OutputPath" -ForegroundColor Green

if ($Copy) {
    try {
        Set-Clipboard -Value $bbcode
        Write-Host "Copied BBCode to clipboard." -ForegroundColor Cyan
    } catch {
        Write-Warning "Could not copy to clipboard: $($_.Exception.Message)"
    }
}

if ($PassThru) {
    return $bbcode
}
