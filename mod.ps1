param(
    [Parameter(Position = 0)]
    [string]$Command = "help",
    [Parameter(ValueFromRemainingArguments = $true)]
    [object[]]$RemainingArgs
)

$ErrorActionPreference = "Stop"
$repoRoot   = $PSScriptRoot
$scriptsDir = Join-Path $repoRoot "scripts"

function Get-RepoMods {
    $mods = @()
    foreach ($dir in (Get-ChildItem -LiteralPath $repoRoot -Directory | Sort-Object Name)) {
        $modsPath = Join-Path $dir.FullName "ue4ss\Mods"
        if (-not (Test-Path -LiteralPath $modsPath -PathType Container)) { continue }
        $inner = @(Get-ChildItem -LiteralPath $modsPath -Directory)
        if ($inner.Count -ne 1) { continue }

        $verFile = Join-Path $dir.FullName "version.json"
        $ver = "1.0.0"
        $chan = "stable"
        if (Test-Path -LiteralPath $verFile -PathType Leaf) {
            $vd = Get-Content -LiteralPath $verFile -Raw | ConvertFrom-Json
            if ($vd.version) { $ver = [string]$vd.version }
            if ($vd.channel) { $chan = [string]$vd.channel }
        }
        $fullVer = if ($chan.ToLower() -ne "stable") { "$ver-$chan" } else { $ver }

        $pakFile = Join-Path $dir.FullName "pak.json"
        $pakName = $null
        $pakInstallFolder = "~mods"
        if (Test-Path -LiteralPath $pakFile -PathType Leaf) {
            $pc = Get-Content -LiteralPath $pakFile -Raw | ConvertFrom-Json
            $pakName = if ($pc.pakName) { [string]$pc.pakName } else { "$($inner[0].Name)_P" }
            if ($pc.installFolder) { $pakInstallFolder = [string]$pc.installFolder }
        }

        $mods += [PSCustomObject]@{
            Folder           = $dir.Name
            ModName          = $inner[0].Name
            Version          = $fullVer
            PakName          = $pakName
            PakInstallFolder = $pakInstallFolder
        }
    }
    return $mods
}

function Resolve-ModFolderName {
    param([string]$InputMod)
    if ([string]::IsNullOrWhiteSpace($InputMod)) { return $null }
    $trimmed = $InputMod.Trim('\', '/')
    $mods = Get-RepoMods
    foreach ($m in $mods) {
        if ($m.Folder -ieq $trimmed -or $m.ModName -ieq $trimmed) {
            return $m.Folder
        }
    }
    return $trimmed
}

function Parse-CliArgs {
    param(
        [object[]]$RawArgs,
        [string[]]$SwitchNames,
        [string[]]$PassThroughFlags = @()
    )

    $switchSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $SwitchNames) { [void]$switchSet.Add($s) }

    $passSet = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $PassThroughFlags) { [void]$passSet.Add($p) }

    $named       = @{}
    $positional  = New-Object System.Collections.Generic.List[object]
    $passthrough = New-Object System.Collections.Generic.List[string]

    $i = 0
    while ($i -lt $RawArgs.Count) {
        $tok = $RawArgs[$i]
        if ($tok -is [string] -and $passSet.Contains($tok)) {
            $passthrough.Add($tok)
            $i++
            continue
        }

        if ($tok -is [string] -and $tok -match '^-([A-Za-z][A-Za-z0-9_-]*)(:?)$') {
            $paramName = $Matches[1]
            $hasColon  = ($Matches[2] -eq ":")

            if ($hasColon) {
                if (($i + 1) -ge $RawArgs.Count) {
                    throw "Missing value after '$tok'."
                }
                $named[$paramName] = $RawArgs[$i + 1]
                $i += 2
                continue
            }

            if ($switchSet.Contains($paramName)) {
                $named[$paramName] = $true
                $i++
                continue
            }

            if (($i + 1) -ge $RawArgs.Count) {
                throw "Missing value for parameter '-$paramName'."
            }
            $named[$paramName] = $RawArgs[$i + 1]
            $i += 2
            continue
        }

        $positional.Add($tok)
        $i++
    }

    return [PSCustomObject]@{
        Named       = $named
        Positional  = $positional.ToArray()
        PassThrough = $passthrough.ToArray()
    }
}

function Show-Help {
    Write-Host @"
RuneScape: Dragonwilds Mods CLI (.\mod.ps1)

Usage:
  .\mod.ps1 <command> [mod] [options]

Commands:
  build        <mod>   Build archive ONLY (does not touch game folder) (aliases: b, archive)
                       Options: -Bump <patch|minor|major>, -Version <ver>, -Channel <ch>,
                                -EngineDir <path>, -SkipPak, -ForceRebuildPak
  deploy       <mod>   Cleanly wipe old mod files & deploy built archive ONLY (alias: d)
                       Options: -GameDir <path>, -ArchivePath <zip>, -Version <ver>, -Channel <ch>, -WhatIf
  build-deploy <mod>   Build archive AND cleanly wipe + deploy to game folder (alias: bd)
                       Options: accepts all build + deploy options (e.g. -Bump, -SkipPak, -GameDir)
  wipe         <mod>   Wipe ONLY this mod (ue4ss\Mods\<Mod> + its .pak files) (aliases: w, clean, uninstall)
                       Options: -GameDir <path>, -WhatIf
  release      <mod>   Build & publish a tagged GitHub Release via gh CLI (aliases: r, publish)
                       Options: --dry-run (-DryRun), --force-update (-ForceUpdate), -SkipBuild, -Version, -Channel
  changelog    <mod>   Update folder-scoped Git changelog in <mod>/README.md
                       Options: -Version <ver>, -MaxCommits <n>
  test         <mod>   Validate JSON configs and run offline Lua unit/regression tests + coverage (alias: t)
                       Options: -LuaExe <path>, -NoCoverage, -CoverageDetails, -MinCoverage <pct>,
                                -LcovPath <path>, -CoverageMarkdownPath <path>
  editor       <mod>   Launch the standalone Web/HTML Spell & Combo Editor GUI (aliases: gui, editor-dev)
                       Options: -Sandbox, -CleanSandbox, -SeedMockCatalog, -SmokeTest,
                                -Deployed, -GameDir <path>, -UserDir <path>, -Port <n>, -NoBrowser
  backup               Back up local RuneScape: Dragonwilds saves
  list                 List mods in this repo, versions, pak status, and local deploy status (aliases: ls, status)
                       Options: -GameDir <path>
  help                 Show this help message

Examples:
  .\mod.ps1 build arcane-wilds
  .\mod.ps1 deploy arcane-wilds
  .\mod.ps1 build-deploy arcane-wilds
  .\mod.ps1 build-deploy arcane-wilds -Bump patch
  .\mod.ps1 build-deploy arcane-wilds -SkipPak
  .\mod.ps1 wipe arcane-wilds
  .\mod.ps1 wipe arcane-wilds -WhatIf
  .\mod.ps1 release arcane-wilds --dry-run
  .\mod.ps1 editor arcane-wilds -Sandbox -SeedMockCatalog
  .\mod.ps1 editor arcane-wilds -SmokeTest
  .\mod.ps1 list

Game Directory:
  Defaults to `$env:RSDW_GAME_DIR if set, otherwise: C:\steam\steamapps\common\RSDragonwilds
  Override per command with -GameDir "<path>".
"@
}

$cmd = if ($Command) { $Command.ToLowerInvariant() } else { "help" }

switch ($cmd) {
    { $_ -in @("help", "-help", "--help", "-h", "-?") } {
        Show-Help
        return
    }

    { $_ -in @("list", "ls", "status") } {
        $parsed = Parse-CliArgs -RawArgs $RemainingArgs -SwitchNames @()
        $gameDir = if ($parsed.Named.ContainsKey("GameDir")) {
            [string]$parsed.Named["GameDir"]
        } elseif ($env:RSDW_GAME_DIR) {
            $env:RSDW_GAME_DIR
        } else {
            "C:\steam\steamapps\common\RSDragonwilds"
        }

        $mods = Get-RepoMods
        if ($mods.Count -eq 0) {
            Write-Host "No mods found in '$repoRoot'." -ForegroundColor Yellow
            return
        }

        $gameSub = if (Test-Path -LiteralPath (Join-Path $gameDir "RSDragonwilds\Binaries\Win64")) {
            Join-Path $gameDir "RSDragonwilds"
        } elseif ((Split-Path -Leaf $gameDir) -ieq "RSDragonwilds" -and (Test-Path -LiteralPath (Join-Path $gameDir "Binaries\Win64"))) {
            $gameDir
        } else {
            $null
        }

        $rows = foreach ($m in $mods) {
            $deployedStatus = "n/a (game dir not found)"
            if ($gameSub) {
                $modDirPresent = Test-Path -LiteralPath (Join-Path $gameSub "Binaries\Win64\ue4ss\Mods\$($m.ModName)")
                $pakPresent    = if ($m.PakName) {
                    Test-Path -LiteralPath (Join-Path $gameSub "Content\Paks\$($m.PakInstallFolder)\$($m.PakName).pak")
                } else { $false }

                if ($modDirPresent -and $pakPresent) {
                    $deployedStatus = "deployed (UE4SS + Pak)"
                } elseif ($modDirPresent -and $m.PakName) {
                    $deployedStatus = "deployed (UE4SS only)"
                } elseif ($modDirPresent) {
                    $deployedStatus = "deployed (UE4SS)"
                } elseif ($pakPresent) {
                    $deployedStatus = "partial (Pak only)"
                } else {
                    $deployedStatus = "not deployed"
                }
            }

            [PSCustomObject]@{
                Folder   = $m.Folder
                ModName  = $m.ModName
                Version  = $m.Version
                Pak      = if ($m.PakName) { "$($m.PakName).pak" } else { "-" }
                Deployed = $deployedStatus
            }
        }

        $rows | Format-Table -AutoSize
        Write-Host "GameDir: $gameDir" -ForegroundColor DarkGray
        return
    }

    { $_ -in @("build", "b", "archive") } {
        $parsed = Parse-CliArgs -RawArgs $RemainingArgs -SwitchNames @(
            "SkipPak", "ForceRebuildPak", "Verbose", "Debug"
        )
        $params = $parsed.Named
        if (-not $params.ContainsKey("ModFolder")) {
            if ($parsed.Positional.Count -lt 1) {
                throw "Missing mod name. Example: .\mod.ps1 build arcane-wilds"
            }
            $params["ModFolder"] = [string]$parsed.Positional[0]
        }
        $params["ModFolder"] = Resolve-ModFolderName $params["ModFolder"]
        & (Join-Path $scriptsDir "build-mod.ps1") @params
        return
    }

    { $_ -in @("build-deploy", "bd") } {
        $parsed = Parse-CliArgs -RawArgs $RemainingArgs -SwitchNames @(
            "SkipPak", "ForceRebuildPak", "WhatIf", "Confirm", "Verbose", "Debug"
        )
        $all = $parsed.Named
        if (-not $all.ContainsKey("ModFolder")) {
            if ($parsed.Positional.Count -lt 1) {
                throw "Missing mod name. Example: .\mod.ps1 build-deploy arcane-wilds"
            }
            $all["ModFolder"] = [string]$parsed.Positional[0]
        }
        $modFolder = Resolve-ModFolderName $all["ModFolder"]

        $buildKeys  = @("Version", "Channel", "Bump", "EngineDir", "SkipPak", "ForceRebuildPak")
        $deployKeys = @("GameDir", "Version", "Channel", "WhatIf", "Confirm")

        $buildParams  = @{ ModFolder = $modFolder }
        $deployParams = @{ ModFolder = $modFolder }

        foreach ($k in $all.Keys) {
            if ($k -ieq "ModFolder") { continue }
            $matchedBuild  = @($buildKeys  | Where-Object { $_ -ieq $k })
            $matchedDeploy = @($deployKeys | Where-Object { $_ -ieq $k })
            if ($matchedBuild.Count -eq 0 -and $matchedDeploy.Count -eq 0) {
                throw "Unknown option '-$k' for 'build-deploy'."
            }
            if ($matchedBuild.Count -gt 0)  { $buildParams[$matchedBuild[0]]   = $all[$k] }
            if ($matchedDeploy.Count -gt 0) { $deployParams[$matchedDeploy[0]] = $all[$k] }
        }
        if ($buildParams.ContainsKey("Bump") -and $deployParams.ContainsKey("Version")) {
            $deployParams.Remove("Version")
        }

        & (Join-Path $scriptsDir "build-mod.ps1") @buildParams
        & (Join-Path $scriptsDir "deploy-mod.ps1") @deployParams
        return
    }

    { $_ -in @("deploy", "d") } {
        $parsed = Parse-CliArgs -RawArgs $RemainingArgs -SwitchNames @(
            "Wipe", "WhatIf", "Confirm", "Verbose", "Debug"
        )
        $params = $parsed.Named
        if (-not $params.ContainsKey("ModFolder")) {
            if ($parsed.Positional.Count -lt 1) {
                throw "Missing mod name. Example: .\mod.ps1 deploy arcane-wilds"
            }
            $params["ModFolder"] = [string]$parsed.Positional[0]
        }
        $params["ModFolder"] = Resolve-ModFolderName $params["ModFolder"]
        & (Join-Path $scriptsDir "deploy-mod.ps1") @params
        return
    }

    { $_ -in @("wipe", "w", "clean", "uninstall") } {
        $parsed = Parse-CliArgs -RawArgs $RemainingArgs -SwitchNames @(
            "WhatIf", "Confirm", "Verbose", "Debug"
        )
        $params = $parsed.Named
        if (-not $params.ContainsKey("ModFolder")) {
            if ($parsed.Positional.Count -lt 1) {
                throw "Missing mod name. Example: .\mod.ps1 wipe arcane-wilds"
            }
            $params["ModFolder"] = [string]$parsed.Positional[0]
        }
        $params["ModFolder"] = Resolve-ModFolderName $params["ModFolder"]
        $params["Wipe"] = $true
        & (Join-Path $scriptsDir "deploy-mod.ps1") @params
        return
    }

    { $_ -in @("release", "r", "publish") } {
        $parsed = Parse-CliArgs -RawArgs $RemainingArgs `
            -SwitchNames @("ForceUpdate", "DryRun", "SkipBuild", "Verbose", "Debug") `
            -PassThroughFlags @("--force-update", "-force-update", "--dry-run", "-dry-run", "--skip-build")
        $params = $parsed.Named
        if (-not $params.ContainsKey("ModFolder")) {
            if ($parsed.Positional.Count -lt 1) {
                throw "Missing mod name. Example: .\mod.ps1 release arcane-wilds --dry-run"
            }
            $params["ModFolder"] = [string]$parsed.Positional[0]
        }
        $params["ModFolder"] = Resolve-ModFolderName $params["ModFolder"]
        $extra = $parsed.PassThrough
        if ($extra.Count -gt 0) {
            & (Join-Path $scriptsDir "publish-release.ps1") @params @extra
        } else {
            & (Join-Path $scriptsDir "publish-release.ps1") @params
        }
        return
    }

    "changelog" {
        $parsed = Parse-CliArgs -RawArgs $RemainingArgs -SwitchNames @("Verbose", "Debug")
        $params = $parsed.Named
        if (-not $params.ContainsKey("ModFolder")) {
            if ($parsed.Positional.Count -lt 1) {
                throw "Missing mod name. Example: .\mod.ps1 changelog arcane-wilds"
            }
            $params["ModFolder"] = [string]$parsed.Positional[0]
        }
        $params["ModFolder"] = Resolve-ModFolderName $params["ModFolder"]
        & (Join-Path $scriptsDir "update-changelog.ps1") @params
        return
    }

    { $_ -in @("test", "t") } {
        $parsed = Parse-CliArgs -RawArgs $RemainingArgs -SwitchNames @("NoCoverage", "CoverageDetails", "Verbose", "Debug")
        $params = $parsed.Named
        if (-not $params.ContainsKey("ModFolder")) {
            if ($parsed.Positional.Count -ge 1) {
                $params["ModFolder"] = [string]$parsed.Positional[0]
            } else {
                $params["ModFolder"] = "arcane-wilds"
            }
        }
        $params["ModFolder"] = Resolve-ModFolderName $params["ModFolder"]
        & (Join-Path $scriptsDir "test-mod.ps1") @params
        return
    }

    { $_ -in @("editor", "gui", "editor-dev") } {
        $parsed = Parse-CliArgs -RawArgs $RemainingArgs -SwitchNames @(
            "Deployed", "Sandbox", "CleanSandbox", "SeedMockCatalog", "SmokeTest", "NoBrowser", "Verbose", "Debug"
        )
        $params = $parsed.Named
        if (-not $params.ContainsKey("ModFolder")) {
            if ($parsed.Positional.Count -ge 1) {
                $params["ModFolder"] = [string]$parsed.Positional[0]
            } else {
                $params["ModFolder"] = "arcane-wilds"
            }
        }
        $params["ModFolder"] = Resolve-ModFolderName $params["ModFolder"]
        & (Join-Path $scriptsDir "dev-editor.ps1") @params
        return
    }

    "backup" {
        & (Join-Path $scriptsDir "auto-backup-saves.ps1")
        return
    }

    default {
        Write-Host "Unknown command '$Command'." -ForegroundColor Red
        Write-Host ""
        Show-Help
        exit 1
    }
}
