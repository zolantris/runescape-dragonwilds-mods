param(
    [Parameter(Position = 0)]
    [string]$ModFolder = "arcane-wilds",
    [string]$LuaExe = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$modRoot  = Join-Path $repoRoot $ModFolder

if (-not (Test-Path -LiteralPath $modRoot -PathType Container)) {
    throw "Mod folder not found: '$modRoot'"
}

Write-Host "=== Testing $ModFolder ===" -ForegroundColor Cyan

# 1. Validate all JSON files under the mod folder (syntax + required top-level structure)
$jsonFiles = @(Get-ChildItem -Path $modRoot -Filter "*.json" -Recurse -File | Where-Object {
    $_.FullName -notmatch '\\Intermediate\\' -and $_.FullName -notmatch '\\Saved\\'
})

$jsonErrors = 0
foreach ($jf in $jsonFiles) {
    $rel = $jf.FullName.Substring($repoRoot.Length).TrimStart('\')
    try {
        $obj = Get-Content -LiteralPath $jf.FullName -Raw | ConvertFrom-Json
        if ($jf.Name -ieq "custom_spells.json") {
            if (-not $obj.PSObject.Properties.Match("spells").Count) {
                throw "missing top-level 'spells' object"
            }
        } elseif ($jf.Name -ieq "combo_rules.json" -or $jf.Name -ieq "combo_rules_examples.json") {
            if (-not $obj.PSObject.Properties.Match("rules").Count) {
                throw "missing top-level 'rules' array"
            }
        }
        Write-Host "  JSON OK  $rel" -ForegroundColor Green
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

Write-Host "`nRunning Lua tests via: $resolvedLua" -ForegroundColor Cyan
& $resolvedLua $luaTestEntry
if ($LASTEXITCODE -ne 0) {
    throw "Lua test suite failed (Exit Code: $LASTEXITCODE)."
}
Write-Host "All tests passed for $ModFolder!" -ForegroundColor Green
