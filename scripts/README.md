# Monorepo Build & Release Scripts

> Part of the **[RuneScape: Dragonwilds Mods Monorepo](../README.md)** ([`zolantris/runescape-dragonwilds-mods`](https://github.com/zolantris/runescape-dragonwilds-mods)).

This directory contains PowerShell automation scripts for packaging UE4SS mods into Vortex-ready `.zip` archives, syncing versions and changelogs, backing up saves, and publishing tagged releases to GitHub.

---

## Unified CLI (`.\mod.ps1`)

Run everything from the repo root through the unified **[`mod.ps1`](../mod.ps1)** CLI, which delegates to the scripts in this directory:

```powershell
# Build archive ONLY (does not touch game folder)
.\mod.ps1 build arcane-wilds

# Cleanly deploy latest built archive ONLY (wipes old mod files first)
.\mod.ps1 deploy arcane-wilds

# Build archive AND cleanly wipe + deploy to C:\steam\steamapps\common\RSDragonwilds
.\mod.ps1 build-deploy arcane-wilds
.\mod.ps1 build-deploy arcane-wilds -Bump patch
.\mod.ps1 build-deploy arcane-wilds -SkipPak

# Wipe ONLY ArcaneWilds (ue4ss\Mods\ArcaneWilds + ArcaneWildsDamageBridge_P.pak)
.\mod.ps1 wipe arcane-wilds
.\mod.ps1 wipe arcane-wilds -WhatIf   # Preview without deleting

# List all mods, versions, pak names, and deploy status
.\mod.ps1 list

# Preview or publish a GitHub Release
.\mod.ps1 release arcane-wilds --dry-run
.\mod.ps1 release arcane-wilds

# Back up saves / show all commands
.\mod.ps1 backup
.\mod.ps1 help
```

> **Game Folder**: Defaults to `$env:RSDW_GAME_DIR` if set, otherwise `C:\steam\steamapps\common\RSDragonwilds`. Pass `-GameDir "<path>"` to override on `deploy`, `build-deploy`, `wipe`, or `list`.

---

## Available Scripts

| Script | Purpose | Key Parameters |
| :--- | :--- | :--- |
| **`..\mod.ps1`** | Unified root CLI that delegates `build`, `deploy`, `build-deploy` (`bd`), `wipe`, `release`, `changelog`, `backup`, `list`, and `help` to the scripts below (accepts either folder name like `arcane-wilds` or mod name like `ArcaneWilds`). | `<command> [mod] [options]` |
| **`build-mod.ps1`** | Builds the `.zip` archive **only** (never touches your game folder or mutates `README.md`). Reads `<ModFolder>/version.json`, optionally bumps the semantic version, syncs version numbers into staged `modmenu.json` and `Scripts/main.lua`, builds & cooks any UE Blueprint `.pak` declared in `<ModFolder>/pak.json`, strips debug snapshots/logs, and outputs `archives/<ModName>-v<Version>.zip`. | `-ModFolder` *(required)*, `-Version`, `-Channel`, `-Bump` (`patch` \| `minor` \| `major`), `-EngineDir`, `-SkipPak`, `-ForceRebuildPak` |
| **`deploy-mod.ps1`** | Cleanly deploys a built mod `.zip` archive into your game directory (supports both Combo UE4SS + `.pak` and UE4SS-only archives). Always wipes **only that mod's** UE4SS folder and `.pak` files first so no stale files persist across deploys. Pass `-Wipe` to remove the mod without redeploying. | `-ModFolder` *(required)*, `-GameDir`, `-ArchivePath`, `-Version`, `-Channel`, `-Wipe`, `-WhatIf` |
| **`sync-ue-damage-stubs.ps1`** | Extracts only the minimal `/Script/Dominion` damage & floaties UHT headers from gitignored `UHTHeaderDump/` into `unreal-engine/RSDragonwilds/Source/Dominion/` (invoked automatically by `build-mod.ps1` when needed). | `-HeaderDumpDir`, `-TargetModuleDir` |
| **`update-changelog.ps1`** | Updates the `# Title` version header and injects folder-scoped Git commits into the `<!-- CHANGELOG:START -->` ... `<!-- CHANGELOG:END -->` block of `<ModFolder>/README.md`. | `-ModFolder` *(required)*, `-Version`, `-MaxCommits` *(default: `50`)* |
| **`publish-release.ps1`** | Updates `<ModFolder>/README.md` changelog via `update-changelog.ps1`, builds the release archive, commits & pushes updated release metadata (`README.md` / `version.json`), creates an annotated Git tag (`<ModName>-v<Version>`), pushes the tag, and publishes a GitHub Release with the `.zip` asset and extracted changelog notes via `gh`. Bails out if the tag/release already exists unless `--force-update` is passed. | `-ModFolder` *(required)*, `-Version`, `-Channel`, `--force-update` (`-ForceUpdate`), `--dry-run` (`-DryRun`), `-SkipBuild` |
| **`auto-backup-saves.ps1`** | Local utility script for backing up *RuneScape: Dragonwilds* character and world save files. | *(Run directly via PowerShell)* |

---

## Common Workflows

### 1. Build, Deploy, or Build & Deploy
Each command has a single clear responsibility:
```powershell
# Build archive ONLY (does not touch game folder)
.\mod.ps1 build arcane-wilds

# Deploy latest built archive ONLY (wipes old mod files first)
.\mod.ps1 deploy arcane-wilds

# Build archive AND cleanly wipe + deploy to game folder
.\mod.ps1 build-deploy arcane-wilds
.\mod.ps1 build-deploy arcane-wilds -GameDir "D:\SteamLibrary\steamapps\common\RSDragonwilds"
```

### 2. Wipe Only This Mod
Wipes only the target mod's `ue4ss\Mods\<ModName>` folder and `.pak` files without touching UE4SS, other mods, or base game files:
```powershell
.\mod.ps1 wipe arcane-wilds
.\mod.ps1 wipe arcane-wilds -WhatIf
```

### 3. Bump Version & Build (or Build & Deploy)
Increments the `patch` (`1.3.4` -> `1.3.5`), `minor`, or `major` version in `version.json` and packages the archive (without modifying `README.md`):
```powershell
.\mod.ps1 build ultra-wide-menu-alignment -Bump patch
.\mod.ps1 build-deploy ultra-wide-menu-alignment -Bump patch
```

### 4. Preview a GitHub Release (`--dry-run`)
Validates `version.json`, checks remote tag conflicts, and prints the exact tag name, asset path, and release notes without modifying Git or GitHub:
```powershell
.\mod.ps1 release ultra-wide-menu-alignment --dry-run
```

### 5. Publish a Tagged GitHub Release
Requires the [GitHub CLI (`gh`)](https://cli.github.com/) (`winget install --id GitHub.cli` and `gh auth login`):
```powershell
# Create a new release (aborts if tag already exists)
.\mod.ps1 release ultra-wide-menu-alignment

# Overwrite an existing tag and re-upload the release archive
.\mod.ps1 release ultra-wide-menu-alignment --force-update
```

---

## How Mod Packaging Works
1. Each top-level mod folder keeps its runtime files under `<ModFolder>/ue4ss/Mods/<ModName>/` and keeps its documentation (`README.md`) and metadata (`version.json`) at `<ModFolder>/`.
2. During `build-mod.ps1`, the script stages `ue4ss/`, strips any local `snapshots/` or `*.log` files, copies `<ModFolder>/README.md` into `ue4ss/Mods/<ModName>/README.md`, and compresses the `ue4ss/` folder into `archives/<ModName>-v<Version>.zip`.
3. Because `ue4ss/Mods/<ModName>/` sits at the root of the `.zip`, **Vortex** automatically recognizes it as a **`UE4SS Mod`** on drag-and-drop.
