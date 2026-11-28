param(
    [Parameter(Position = 0)]
    [string]$ModFolder = "arcane-wilds",
    [switch]$Deployed,
    [string]$GameDir = "",
    [switch]$Sandbox,
    [switch]$CleanSandbox,
    [string]$UserDir = "",
    [switch]$SeedMockCatalog,
    [switch]$SmokeTest,
    [int]$Port = 47821,
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$modRoot  = Join-Path $repoRoot $ModFolder

if (-not (Test-Path -LiteralPath $modRoot -PathType Container)) {
    throw "Mod folder not found: '$modRoot'"
}

$modsParent = Join-Path $modRoot "ue4ss\Mods"
$innerDirs  = @(Get-ChildItem -LiteralPath $modsParent -Directory)
if ($innerDirs.Count -ne 1) {
    throw "Expected 1 mod directory under '$modsParent', found $($innerDirs.Count)."
}
$modName      = $innerDirs[0].Name
$repoModDir   = $innerDirs[0].FullName
$serverScript = Join-Path $repoModDir "editor\server.ps1"

if (-not (Test-Path -LiteralPath $serverScript -PathType Leaf)) {
    throw "Editor server script not found at '$serverScript'."
}

# Resolve target mod directory (repo by default, or deployed game folder with -Deployed)
$targetModDir = $repoModDir
if ($Deployed) {
    $resolvedGameDir = if (-not [string]::IsNullOrWhiteSpace($GameDir)) {
        $GameDir
    } elseif ($env:RSDW_GAME_DIR) {
        $env:RSDW_GAME_DIR
    } else {
        "C:\steam\steamapps\common\RSDragonwilds"
    }
    $gameSub = if (Test-Path -LiteralPath (Join-Path $resolvedGameDir "RSDragonwilds\Binaries\Win64")) {
        Join-Path $resolvedGameDir "RSDragonwilds"
    } else {
        $resolvedGameDir
    }
    $targetModDir = Join-Path $gameSub "Binaries\Win64\ue4ss\Mods\$modName"
    if (-not (Test-Path -LiteralPath $targetModDir -PathType Container)) {
        throw "Deployed mod folder not found at '$targetModDir'."
    }
}

# Resolve user profile directory
$useSandbox = $Sandbox -or $CleanSandbox -or $SmokeTest
$resolvedUserDir = $UserDir
if ([string]::IsNullOrWhiteSpace($resolvedUserDir)) {
    if ($SmokeTest) {
        $resolvedUserDir = Join-Path $env:TEMP ("rsdw-editor-smoke-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
    } elseif ($useSandbox) {
        $resolvedUserDir = Join-Path $env:TEMP "rsdw-editor-sandbox\$modName"
        if ($CleanSandbox -and (Test-Path -LiteralPath $resolvedUserDir)) {
            Remove-Item -LiteralPath $resolvedUserDir -Recurse -Force
            Write-Host "Cleaned sandbox user dir: $resolvedUserDir" -ForegroundColor Yellow
        }
    } elseif ($env:ARCANE_WILDS_USER_DIR) {
        $resolvedUserDir = $env:ARCANE_WILDS_USER_DIR
    } elseif ($env:LOCALAPPDATA) {
        $resolvedUserDir = Join-Path $env:LOCALAPPDATA $modName
    } else {
        $resolvedUserDir = Join-Path $env:TEMP "rsdw-editor-user\$modName"
    }
}

if (-not (Test-Path -LiteralPath $resolvedUserDir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $resolvedUserDir | Out-Null
}

function Write-MockDetectedCatalog {
    param([string]$OutPath)
    $mock = [ordered]@{
        '$schema'     = "./schemas/detected_catalog.schema.json"
        schemaVersion = 1
        format        = "arcane-wilds.detected_catalog"
        modVersion    = "standalone-mock"
        generatedAt   = [DateTime]::UtcNow.ToString("o")
        categories    = @("Air", "Air_Wand", "AncientMagicks", "Earth", "Earth_Wand", "Fire", "Fire_Wand", "Water", "Water_Wand")
        spells        = @(
            [ordered]@{ shortName = "DA_Spell_Primary_Air_01"; fullName = "/Game/Spells/Combat/Air/DA_Spell_Primary_Air_01"; category = "Air"; stepIndex = 0; montage = "AM_Spell_Primary_Air_01"; aliases = @("bolt"); isModded = $false; isSpecial = $false },
            [ordered]@{ shortName = "DA_Spell_Primary_Air_02"; fullName = "/Game/Spells/Combat/Air/DA_Spell_Primary_Air_02"; category = "Air"; stepIndex = 1; montage = "AM_Spell_Primary_Air_02"; aliases = @("gust"); isModded = $false; isSpecial = $false },
            [ordered]@{ shortName = "DA_Spell_Primary_Air_03"; fullName = "/Game/Spells/Combat/Air/DA_Spell_Primary_Air_03"; category = "Air"; stepIndex = 2; montage = "AM_Spell_Primary_Air_03"; aliases = @("vortex"); isModded = $false; isSpecial = $false },
            [ordered]@{ shortName = "DA_Spell_Primary_Air_04"; fullName = "/Game/Spells/Combat/Air/DA_Spell_Primary_Air_04"; category = "Air"; stepIndex = 3; montage = "AM_Spell_Primary_Air_04"; aliases = @("slam", "ground_smash"); isModded = $false; isSpecial = $false },
            [ordered]@{ shortName = "DA_Spell_Primary_Fire_01"; fullName = "/Game/Spells/Combat/Fire/DA_Spell_Primary_Fire_01"; category = "Fire"; stepIndex = 0; montage = "AM_Spell_Primary_Fire_01"; aliases = @("bolt", "bolt_1"); isModded = $false; isSpecial = $false },
            [ordered]@{ shortName = "DA_Spell_Primary_Fire_02"; fullName = "/Game/Spells/Combat/Fire/DA_Spell_Primary_Fire_02"; category = "Fire"; stepIndex = 1; montage = "AM_Spell_Primary_Fire_02"; aliases = @("bolt_2"); isModded = $false; isSpecial = $false },
            [ordered]@{ shortName = "DA_Spell_Primary_Fire_03"; fullName = "/Game/Spells/Combat/Fire/DA_Spell_Primary_Fire_03"; category = "Fire"; stepIndex = 2; montage = "AM_Spell_Primary_Fire_03"; aliases = @("burst"); isModded = $false; isSpecial = $false },
            [ordered]@{ shortName = "DA_Spell_Primary_Fire_04"; fullName = "/Game/Spells/Combat/Fire/DA_Spell_Primary_Fire_04"; category = "Fire"; stepIndex = 3; montage = "AM_Spell_Primary_Fire_04"; aliases = @("explosion", "meteor", "volcano"); isModded = $false; isSpecial = $false },
            [ordered]@{ shortName = "DA_Spell_Primary_Water_01"; fullName = "/Game/Spells/Combat/Water/DA_Spell_Primary_Water_01"; category = "Water"; stepIndex = 0; montage = "AM_Spell_Primary_Water_01"; aliases = @("bolt"); isModded = $false; isSpecial = $false },
            [ordered]@{ shortName = "DA_Spell_Primary_Water_02"; fullName = "/Game/Spells/Combat/Water/DA_Spell_Primary_Water_02"; category = "Water"; stepIndex = 1; montage = "AM_Spell_Primary_Water_02"; aliases = @("waterfall"); isModded = $false; isSpecial = $false },
            [ordered]@{ shortName = "DA_Spell_Primary_Water_03"; fullName = "/Game/Spells/Combat/Water/DA_Spell_Primary_Water_03"; category = "Water"; stepIndex = 2; montage = "AM_Spell_Primary_Water_03"; aliases = @("wave"); isModded = $false; isSpecial = $false },
            [ordered]@{ shortName = "DA_Spell_Primary_Water_04"; fullName = "/Game/Spells/Combat/Water/DA_Spell_Primary_Water_04"; category = "Water"; stepIndex = 3; montage = "AM_Spell_Primary_Water_04"; aliases = @("tsunami"); isModded = $false; isSpecial = $false },
            [ordered]@{ shortName = "DA_Spell_Primary_Earth_01"; fullName = "/Game/Spells/Combat/Earth/DA_Spell_Primary_Earth_01"; category = "Earth"; stepIndex = 0; montage = "AM_Spell_Primary_Earth_01"; aliases = @("bolt"); isModded = $false; isSpecial = $false },
            [ordered]@{ shortName = "DA_Spell_Primary_Earth_02"; fullName = "/Game/Spells/Combat/Earth/DA_Spell_Primary_Earth_02"; category = "Earth"; stepIndex = 1; montage = "AM_Spell_Primary_Earth_02"; aliases = @("spike"); isModded = $false; isSpecial = $false },
            [ordered]@{ shortName = "DA_Spell_Primary_Earth_03"; fullName = "/Game/Spells/Combat/Earth/DA_Spell_Primary_Earth_03"; category = "Earth"; stepIndex = 2; montage = "AM_Spell_Primary_Earth_03"; aliases = @("shatter"); isModded = $false; isSpecial = $false },
            [ordered]@{ shortName = "DA_Spell_Primary_Earth_04"; fullName = "/Game/Spells/Combat/Earth/DA_Spell_Primary_Earth_04"; category = "Earth"; stepIndex = 3; montage = "AM_Spell_Primary_Earth_04"; aliases = @("boulder"); isModded = $false; isSpecial = $false },
            [ordered]@{ shortName = "DA_ZamorakStaff_Special"; fullName = "/Game/Spells/Specials/DA_ZamorakStaff_Special"; category = "Special_ZamorakStaff"; stepIndex = 0; montage = $null; aliases = @(); isModded = $false; isSpecial = $true },
            [ordered]@{ shortName = "HAM_IceBarrage"; fullName = "/Game/Mods/HydraAncientMagicks/HAM_IceBarrage"; category = "AncientMagicks"; stepIndex = 0; montage = $null; aliases = @("ice_barrage"); isModded = $true; isSpecial = $false },
            [ordered]@{ shortName = "HAM_BloodBarrage"; fullName = "/Game/Mods/HydraAncientMagicks/HAM_BloodBarrage"; category = "AncientMagicks"; stepIndex = 0; montage = $null; aliases = @("blood_barrage"); isModded = $true; isSpecial = $false }
        )
        vfx           = @(
            [ordered]@{ shortName = "NS_Windstep_Launch"; path = "/Game/Art/VFX/Library/Spells/Windstep/NS_Windstep_Launch.NS_Windstep_Launch"; kind = "niagara"; aliases = @("windstep") },
            [ordered]@{ shortName = "NS_Lightning_Strike"; path = "/Game/Art/VFX/Library/Weather/NS_Lightning_Strike.NS_Lightning_Strike"; kind = "niagara"; aliases = @("lightning") },
            [ordered]@{ shortName = "NS_Fire_Explosion"; path = "/Game/Art/VFX/Library/Spells/Fire/NS_Fire_Explosion.NS_Fire_Explosion"; kind = "niagara"; aliases = @("fire_explosion") },
            [ordered]@{ shortName = "NS_Water_Surge"; path = "/Game/Art/VFX/Library/Spells/Water/NS_Water_Surge.NS_Water_Surge"; kind = "niagara"; aliases = @("water_surge") },
            [ordered]@{ shortName = "NS_Earth_Shatter"; path = "/Game/Art/VFX/Library/Spells/Earth/NS_Earth_Shatter.NS_Earth_Shatter"; kind = "niagara"; aliases = @("earth_shatter") }
        )
        sfx           = @(
            [ordered]@{ shortName = "SC_Lightning_Strike"; path = "/Game/Audio/Spells/SC_Lightning_Strike.SC_Lightning_Strike"; kind = "sound"; aliases = @("lightning", "thunder") },
            [ordered]@{ shortName = "SC_Fire_Explosion"; path = "/Game/Audio/Spells/SC_Fire_Explosion.SC_Fire_Explosion"; kind = "sound"; aliases = @("fire_boom") },
            [ordered]@{ shortName = "SC_Air_Gust"; path = "/Game/Audio/Spells/SC_Air_Gust.SC_Air_Gust"; kind = "sound"; aliases = @("whoosh") },
            [ordered]@{ shortName = "SC_Water_Splash"; path = "/Game/Audio/Spells/SC_Water_Splash.SC_Water_Splash"; kind = "sound"; aliases = @("splash") }
        )
        montages      = @(
            [ordered]@{ shortName = "AM_Spell_Primary_Air_01"; path = "/Game/Art/Animation/Spells/AM_Spell_Primary_Air_01.AM_Spell_Primary_Air_01" },
            [ordered]@{ shortName = "AM_Spell_Primary_Air_04"; path = "/Game/Art/Animation/Spells/AM_Spell_Primary_Air_04.AM_Spell_Primary_Air_04" },
            [ordered]@{ shortName = "AM_Spell_Primary_Fire_04"; path = "/Game/Art/Animation/Spells/AM_Spell_Primary_Fire_04.AM_Spell_Primary_Fire_04" },
            [ordered]@{ shortName = "AM_PlayerM_Attack_2H_Greatsword_Secondary"; path = "/Game/Art/Animation/PlayerM/Greatsword/AM_PlayerM_Attack_2H_Greatsword_Secondary.AM_PlayerM_Attack_2H_Greatsword_Secondary" },
            [ordered]@{ shortName = "AM_AI_HitReact_Heavy"; path = "/Game/Art/Animation/AI/AM_AI_HitReact_Heavy.AM_AI_HitReact_Heavy" }
        )
    }
    $json = $mock | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($OutPath, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

$catalogOverride = ""
if ($SeedMockCatalog -or $SmokeTest) {
    $catalogOverride = Join-Path $resolvedUserDir "_mock_detected_catalog.json"
    Write-MockDetectedCatalog -OutPath $catalogOverride
    Write-Host "Seeded mock detected catalog: $catalogOverride" -ForegroundColor Cyan
}

if ($SmokeTest) {
    Write-Host "=== Running Headless Web GUI Smoke Test ($modName) ===" -ForegroundColor Cyan
    $testPort = if ($Port -ne 47821) { $Port } else { 47892 }
    $serverOutLog = Join-Path $resolvedUserDir "_smoke_server_out.log"
    $serverErrLog = Join-Path $resolvedUserDir "_smoke_server_err.log"

    Write-Host "  [1/8] Starting editor server on http://127.0.0.1:$testPort ..." -ForegroundColor DarkGray
    $proc = Start-Process powershell.exe -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $serverScript,
        "-ModDir", $targetModDir,
        "-UserDir", $resolvedUserDir,
        "-CatalogPath", $catalogOverride,
        "-Port", [string]$testPort,
        "-NoBrowser"
    ) -PassThru -WindowStyle Hidden -RedirectStandardOutput $serverOutLog -RedirectStandardError $serverErrLog

    try {
        $baseUrl = "http://127.0.0.1:$testPort"
        $ready = $false
        for ($i = 0; $i -lt 30; $i++) {
            if ($proc.HasExited) {
                $errText = if (Test-Path -LiteralPath $serverErrLog) { [System.IO.File]::ReadAllText($serverErrLog).Trim() } else { "" }
                $outText = if (Test-Path -LiteralPath $serverOutLog) { [System.IO.File]::ReadAllText($serverOutLog).Trim() } else { "" }
                $details = (@($errText, $outText) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
                throw "Editor server exited early (code $($proc.ExitCode)).`n$details"
            }
            try {
                $st = Invoke-RestMethod "$baseUrl/api/status" -TimeoutSec 2
                if ($st.ok) { $ready = $true; break }
            } catch {
                Start-Sleep -Milliseconds 150
            }
        }
        if (-not $ready) {
            $errText = if (Test-Path -LiteralPath $serverErrLog) { [System.IO.File]::ReadAllText($serverErrLog).Trim() } else { "" }
            throw "Editor server did not become ready on $baseUrl within timeout.`n$errText"
        }
        Write-Host "  PASS [1/8] GET /api/status (server ready)" -ForegroundColor Green

        $htmlRes = Invoke-WebRequest -UseBasicParsing "$baseUrl/" -TimeoutSec 5
        if ($htmlRes.StatusCode -ne 200) { throw "GET / returned $($htmlRes.StatusCode)" }
        Write-Host "  PASS [2/8] GET / (HTML 200)" -ForegroundColor Green

        $cat = Invoke-RestMethod "$baseUrl/api/catalog" -TimeoutSec 5
        if ($cat.spells.Count -lt 1 -or $cat.vfx.Count -lt 1 -or $cat.sfx.Count -lt 1) {
            throw "Catalog missing expected spells/vfx/sfx entries."
        }
        Write-Host "  PASS [3/8] GET /api/catalog ($($cat.spells.Count) spells, $($cat.vfx.Count) VFX, $($cat.sfx.Count) SFX, $($cat.montages.Count) montages)" -ForegroundColor Green

        $defs = Invoke-RestMethod "$baseUrl/api/defaults" -TimeoutSec 5
        if (-not $defs.ok) { throw "GET /api/defaults failed." }
        Write-Host "  PASS [4/8] GET /api/defaults" -ForegroundColor Green

        # Save user spells, user combos, user quickcast, and export JSON
        $spPayload = '{"schemaVersion":1,"format":"arcane-wilds.user_spells","disabledDefaults":["FlamesOfZamorak"],"spells":{"SmokeSpell":{"enabled":true,"category":"Air","speed":1.5}}}'
        $spSave = Invoke-RestMethod -Method Put -Uri "$baseUrl/api/user/spells" -Body $spPayload -ContentType "application/json" -TimeoutSec 5
        if (-not $spSave.ok -or -not (Test-Path -LiteralPath (Join-Path $resolvedUserDir "user_spells.json"))) {
            throw "PUT /api/user/spells did not write user_spells.json"
        }
        Write-Host "  PASS [5/8] PUT /api/user/spells -> user_spells.json" -ForegroundColor Green

        $cbPayload = '{"schemaVersion":1,"format":"arcane-wilds.user_combos","disableAllDefaults":false,"disabledDefaultIds":["default.fire_to_air"],"rules":[{"name":"SmokeCombo","enabled":true,"weight":5,"stages":[{"category":"Air","spells":["bolt"],"speed":2.0}]}]}'
        $cbSave = Invoke-RestMethod -Method Put -Uri "$baseUrl/api/user/combos" -Body $cbPayload -ContentType "application/json" -TimeoutSec 5
        if (-not $cbSave.ok -or -not (Test-Path -LiteralPath (Join-Path $resolvedUserDir "user_combos.json"))) {
            throw "PUT /api/user/combos did not write user_combos.json"
        }
        Write-Host "  PASS [6/8] PUT /api/user/combos -> user_combos.json" -ForegroundColor Green

        $qcPayload = '{"schemaVersion":1,"format":"arcane-wilds.user_quick_cast","overrideDefaults":true,"bindings":[{"enabled":true,"modifier":"BLOCK","keys":["1","GP_X"],"target":"SmokeSpell"}]}'
        $qcSave = Invoke-RestMethod -Method Put -Uri "$baseUrl/api/user/quickcast" -Body $qcPayload -ContentType "application/json" -TimeoutSec 5
        if (-not $qcSave.ok -or -not (Test-Path -LiteralPath (Join-Path $resolvedUserDir "user_quick_cast.json"))) {
            throw "PUT /api/user/quickcast did not write user_quick_cast.json"
        }
        $qcDel = Invoke-RestMethod -Method Delete -Uri "$baseUrl/api/user/quickcast" -TimeoutSec 5
        if (-not $qcDel.ok) { throw "DELETE /api/user/quickcast failed" }
        Write-Host "  PASS [7/8] PUT & DELETE /api/user/quickcast -> user_quick_cast.json" -ForegroundColor Green

        $expBody = @{ filename = "smoke-bundle.json"; openExplorer = $false; content = '{"schemaVersion":1,"format":"arcane-wilds.bundle","spells":{},"rules":[]}' } | ConvertTo-Json
        $expRes = Invoke-RestMethod -Method Post -Uri "$baseUrl/api/export" -Body $expBody -ContentType "application/json" -TimeoutSec 5
        if (-not $expRes.ok -or -not (Test-Path -LiteralPath $expRes.path)) {
            throw "POST /api/export did not write exported file"
        }
        Write-Host "  PASS [8/8] POST /api/export -> exports\smoke-bundle.json" -ForegroundColor Green

        Write-Host "Web GUI Smoke Test PASSED!" -ForegroundColor Green
    } finally {
        if ($proc -and -not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $resolvedUserDir) {
            Remove-Item -LiteralPath $resolvedUserDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return
}

# Interactive standalone launch
$srvParams = @{
    ModDir  = $targetModDir
    UserDir = $resolvedUserDir
    Port    = $Port
}
if ($catalogOverride -ne "") { $srvParams["CatalogPath"] = $catalogOverride }
if ($NoBrowser) { $srvParams["NoBrowser"] = $true }

& $serverScript @srvParams
