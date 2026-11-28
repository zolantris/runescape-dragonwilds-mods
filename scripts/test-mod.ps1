param(
    [Parameter(Position = 0)]
    [string]$ModFolder = "arcane-wilds",
    [string]$LuaExe = "",
    [switch]$NoCoverage,
    [switch]$CoverageDetails,
    [double]$MinCoverage = -1,
    [string]$LcovPath = "",
    [string]$CoverageMarkdownPath = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$modRoot  = Join-Path $repoRoot $ModFolder

if (-not (Test-Path -LiteralPath $modRoot -PathType Container)) {
    throw "Mod folder not found: '$modRoot'"
}

Write-Host "=== Testing $ModFolder ===" -ForegroundColor Cyan

# 1. Validate all JSON files under the mod folder (syntax + required top-level structure)
#    Player-editable config files support JSONC (//, /* ... */, trailing commas) matching json.lua;
#    metadata and schema files are validated as strict JSON.
function ConvertFrom-JsoncText {
    param([string]$Text)

    # Pass 1: strip // and /* ... */ comments outside string literals
    $sb = [System.Text.StringBuilder]::new($Text.Length)
    $i = 0
    $n = $Text.Length
    $inStr = $false
    while ($i -lt $n) {
        $ch = $Text[$i]
        if ($inStr) {
            [void]$sb.Append($ch)
            if ($ch -eq '\' -and ($i + 1) -lt $n) {
                [void]$sb.Append($Text[$i + 1])
                $i += 2
                continue
            }
            if ($ch -eq '"') { $inStr = $false }
            $i++
        } else {
            if ($ch -eq '"') {
                $inStr = $true
                [void]$sb.Append($ch)
                $i++
            } elseif ($ch -eq '/' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '/') {
                $i += 2
                while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
            } elseif ($ch -eq '/' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '*') {
                $endIdx = $Text.IndexOf("*/", $i + 2, [System.StringComparison]::Ordinal)
                if ($endIdx -lt 0) {
                    throw "Unterminated block comment in JSONC"
                }
                for ($k = $i; $k -lt ($endIdx + 2); $k++) {
                    if ($Text[$k] -eq "`n") { [void]$sb.Append("`n") }
                }
                $i = $endIdx + 2
            } else {
                [void]$sb.Append($ch)
                $i++
            }
        }
    }

    # Pass 2: remove trailing commas before } or ] outside string literals
    $noComments = $sb.ToString()
    $sb2 = [System.Text.StringBuilder]::new($noComments.Length)
    $i = 0
    $n = $noComments.Length
    $inStr = $false
    while ($i -lt $n) {
        $ch = $noComments[$i]
        if ($inStr) {
            [void]$sb2.Append($ch)
            if ($ch -eq '\' -and ($i + 1) -lt $n) {
                [void]$sb2.Append($noComments[$i + 1])
                $i += 2
                continue
            }
            if ($ch -eq '"') { $inStr = $false }
            $i++
        } else {
            if ($ch -eq '"') {
                $inStr = $true
                [void]$sb2.Append($ch)
                $i++
            } elseif ($ch -eq ',') {
                $j = $i + 1
                while ($j -lt $n -and ($noComments[$j] -eq ' ' -or $noComments[$j] -eq "`t" -or $noComments[$j] -eq "`r" -or $noComments[$j] -eq "`n")) {
                    $j++
                }
                if ($j -lt $n -and ($noComments[$j] -eq '}' -or $noComments[$j] -eq ']')) {
                    $i++
                    continue
                }
                [void]$sb2.Append($ch)
                $i++
            } else {
                [void]$sb2.Append($ch)
                $i++
            }
        }
    }
    return $sb2.ToString()
}

$jsoncConfigNames = @("custom_spells.json", "combo_rules.json", "combo_rules_examples.json")

$jsonFiles = @(Get-ChildItem -Path $modRoot -Filter "*.json" -Recurse -File | Where-Object {
    $_.FullName -notmatch '\\Intermediate\\' -and $_.FullName -notmatch '\\Saved\\'
})

$jsonErrors = 0
foreach ($jf in $jsonFiles) {
    $rel = $jf.FullName.Substring($repoRoot.Length).TrimStart('\')
    $isJsonc = $jsoncConfigNames -contains $jf.Name.ToLowerInvariant()
    try {
        $raw = Get-Content -LiteralPath $jf.FullName -Raw
        if ($isJsonc) {
            $raw = ConvertFrom-JsoncText -Text $raw
        }
        $obj = $raw | ConvertFrom-Json
        if ($jf.Name -ieq "custom_spells.json") {
            if (-not $obj.PSObject.Properties.Match("spells").Count) {
                throw "missing top-level 'spells' object"
            }
            if (-not $obj.PSObject.Properties.Match("schemaVersion").Count -or ([int]$obj.schemaVersion -lt 1)) {
                throw "missing integer 'schemaVersion' >= 1"
            }
        } elseif ($jf.Name -ieq "combo_rules.json" -or $jf.Name -ieq "combo_rules_examples.json") {
            if (-not $obj.PSObject.Properties.Match("rules").Count) {
                throw "missing top-level 'rules' array"
            }
            if (-not $obj.PSObject.Properties.Match("schemaVersion").Count -or ([int]$obj.schemaVersion -lt 1)) {
                throw "missing integer 'schemaVersion' >= 1"
            }
        }
        $tag = if ($isJsonc) { "JSONC OK" } else { "JSON OK " }
        Write-Host "  $tag $rel" -ForegroundColor Green
    } catch {
        $jsonErrors++
        Write-Host "  JSON ERR $rel : $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($jsonErrors -gt 0) {
    throw "$jsonErrors JSON validation error(s) found."
}

# 2. Run Lua unit & regression test suite if <mod>/tests/run_tests.lua exists
$luaTestEntry = Join-Path $modRoot "tests\run_tests.lua"
if (-not (Test-Path -LiteralPath $luaTestEntry -PathType Leaf)) {
    Write-Host "No Lua test runner found at '$luaTestEntry' (JSON validation passed)." -ForegroundColor Yellow
    return
}

function Find-LuaRuntime {
    param([string]$ExplicitPath)
    if ($ExplicitPath -and (Test-Path -LiteralPath $ExplicitPath -PathType Leaf)) {
        return $ExplicitPath
    }
    foreach ($candidate in @("lua54", "lua5.4", "lua", "luajit")) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    $localCandidates = @(
        (Join-Path $repoRoot ".tools\lua\lua54.exe"),
        (Join-Path $repoRoot ".tools\lua\lua.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Lua\bin\lua.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Lua\bin\lua54.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Lua\lua54.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Lua\lua.exe"),
        "C:\Program Files\Lua\bin\lua.exe",
        "C:\Program Files\Lua\lua54.exe",
        "C:\Program Files\Lua\lua.exe",
        "C:\Program Files (x86)\Lua\5.4\lua54.exe"
    )
    foreach ($p in $localCandidates) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) {
            return $p
        }
    }
    return $null
}

$resolvedLua = Find-LuaRuntime -ExplicitPath $LuaExe
if (-not $resolvedLua) {
    Write-Host ""
    Write-Host "Lua 5.4 runtime not found on PATH." -ForegroundColor Yellow
    Write-Host "Install Lua 5.4 once via:" -ForegroundColor Yellow
    Write-Host "  winget install DEVCOM.Lua" -ForegroundColor White
    Write-Host "Or pass -LuaExe <path-to-lua54.exe>." -ForegroundColor Yellow
    throw "Cannot execute Lua unit tests without a Lua interpreter."
}

$luaArgs = @($luaTestEntry)
if ($NoCoverage) { $luaArgs += "--no-coverage" }
if ($CoverageDetails) { $luaArgs += "--coverage-details" }
if ($MinCoverage -ge 0) { $luaArgs += @("--min-coverage", $MinCoverage.ToString([System.Globalization.CultureInfo]::InvariantCulture)) }
if ($LcovPath) { $luaArgs += @("--lcov", $LcovPath) }
if ($CoverageMarkdownPath) { $luaArgs += @("--coverage-markdown", $CoverageMarkdownPath) }

Write-Host "`nRunning Lua tests via: $resolvedLua" -ForegroundColor Cyan
& $resolvedLua @luaArgs
if ($LASTEXITCODE -ne 0) {
    throw "Lua test suite failed (Exit Code: $LASTEXITCODE)."
}
Write-Host "All tests passed for $ModFolder!" -ForegroundColor Green
