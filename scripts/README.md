# Monorepo Build & Release Scripts

> Part of the **[RuneScape: Dragonwilds Mods Monorepo](../README.md)** ([`zolantris/runescape-dragonwilds-mods`](https://github.com/zolantris/runescape-dragonwilds-mods)).

This directory contains PowerShell automation scripts for packaging UE4SS mods into Vortex-ready `.zip` archives, syncing versions and changelogs, backing up saves, and publishing tagged releases to GitHub.

---

## Available Scripts

| Script | Purpose | Key Parameters |
| :--- | :--- | :--- |
| **`build-mod.ps1`** | Reads `<ModFolder>/version.json`, optionally bumps the semantic version, updates `README.md`, syncs version numbers into `modmenu.json` and `Scripts/main.lua`, automatically builds & cooks any UE Blueprint `.pak` declared in `<ModFolder>/pak.json` (such as `arcane-wilds/pak.json`), strips debug snapshots/logs, outputs `archives/<ModName>-v<Version>.zip`, and **auto-deploys** the archive cleanly to your local game folder (wiping only this mod's previous files first). | `-ModFolder` *(required)*, `-Version`, `-Channel`, `-Bump` (`patch` \| `minor` \| `major`), `-EngineDir`, `-GameDir` *(default: `$env:RSDW_GAME_DIR` or `C:\steam\steamapps\common\RSDragonwilds`)*, `-SkipChangelog`, `-SkipPak`, `-ForceRebuildPak`, `-SkipDeploy` |
| **`deploy-mod.ps1`** | Cleanly deploys a built mod `.zip` archive into your *RuneScape: Dragonwilds* game directory (supports both Combo UE4SS + `.pak` and UE4SS-only archives). Always wipes **only that mod's** UE4SS folder and `.pak` files first so no stale files or folder structures persist across deploys. Pass `-Wipe` to remove the mod without redeploying. | `-ModFolder` *(required)*, `-GameDir`, `-ArchivePath`, `-Version`, `-Channel`, `-Wipe`, `-WhatIf` |
| **`wipe-mod.ps1`** | Removes **only** the specified mod from the game directory (its `ue4ss\Mods\<ModName>` folder, its `.pak`/`.utoc`/`.ucas`/`.sig` files, and any previously deployed files tracked in the local manifest) while leaving UE4SS, other mods, and base game files untouched. | `-ModFolder` *(required)*, `-GameDir`, `-WhatIf` |
| **`sync-ue-damage-stubs.ps1`** | Extracts only the minimal `/Script/Dominion` damage & floaties UHT headers from gitignored `UHTHeaderDump/` into `unreal-engine/RSDragonwilds/Source/Dominion/` (invoked automatically by `build-mod.ps1` when needed). | `-HeaderDumpDir`, `-TargetModuleDir` |
| **`update-changelog.ps1`** | Updates the `# Title` version header and injects folder-scoped Git commits into the `<!-- CHANGELOG:START -->` ... `<!-- CHANGELOG:END -->` block of `<ModFolder>/README.md`. | `-ModFolder` *(required)*, `-Version`, `-MaxCommits` *(default: `30`)* |
| **`publish-release.ps1`** | Builds the release archive, creates an annotated Git tag (`<ModName>-v<Version>`), pushes the tag, and publishes a GitHub Release with the `.zip` asset and extracted changelog notes via `gh`. Bails out if the tag/release already exists unless `--force-update` is passed. | `-ModFolder` *(required)*, `-Version`, `-Channel`, `--force-update` (`-ForceUpdate`), `--dry-run` (`-DryRun`), `-SkipBuild` |
| **`auto-backup-saves.ps1`** | Local utility script for backing up *RuneScape: Dragonwilds* character and world save files. | *(Run directly via PowerShell)* |

---

## Common Workflows

### 1. Build & Auto-Deploy Locally
Builds `archives/<ModName>-v<Version>.zip` and automatically wipes + deploys a fresh copy of that mod into `C:\steam\steamapps\common\RSDragonwilds` (or `$env:RSDW_GAME_DIR` / `-GameDir`):
```powershell
# Build and auto-deploy to default game folder
.\scripts\build-mod.ps1 -ModFolder arcane-wilds

# Build and auto-deploy to a custom game folder
.\scripts\build-mod.ps1 -ModFolder arcane-wilds -GameDir "D:\SteamLibrary\steamapps\common\RSDragonwilds"

# Build archive only (skip local deployment)
.\scripts\build-mod.ps1 -ModFolder ultra-wide-menu-alignment -SkipDeploy
```

### 2. Re-Deploy or Wipe a Single Mod (Mod-Only Clean Reset)
Wipe only one mod's `ue4ss\Mods\<ModName>` folder and its `.pak` files without touching UE4SS, other mods, or base game files:
```powershell
# Wipe ONLY ArcaneWilds (mod folder + ArcaneWildsDamageBridge_P.pak)
.\scripts\wipe-mod.ps1 -ModFolder arcane-wilds

# Preview what would be wiped without deleting anything
.\scripts\wipe-mod.ps1 -ModFolder arcane-wilds -WhatIf

# Re-deploy the latest built archive cleanly (wipes old files first)
.\scripts\deploy-mod.ps1 -ModFolder arcane-wilds
```

### 3. Bump Version & Build
Increments the `patch` (`1.3.4` -> `1.3.5`), `minor`, or `major` version in `version.json`, updates the README title and changelog, packages the archive, and auto-deploys:
```powershell
.\scripts\build-mod.ps1 -ModFolder ultra-wide-menu-alignment -Bump patch
```

### 4. Preview a GitHub Release (`--dry-run`)
Validates `version.json`, checks remote tag conflicts, and prints the exact tag name, asset path, and release notes without modifying Git or GitHub:
```powershell
.\scripts\publish-release.ps1 -ModFolder ultra-wide-menu-alignment --dry-run
```

### 5. Publish a Tagged GitHub Release
Requires the [GitHub CLI (`gh`)](https://cli.github.com/) (`winget install --id GitHub.cli` and `gh auth login`):
```powershell
# Create a new release (aborts if tag already exists)
.\scripts\publish-release.ps1 -ModFolder ultra-wide-menu-alignment

# Overwrite an existing tag and re-upload the release archive
.\scripts\publish-release.ps1 -ModFolder ultra-wide-menu-alignment --force-update
```

---

## How Mod Packaging Works
1. Each top-level mod folder keeps its runtime files under `<ModFolder>/ue4ss/Mods/<ModName>/` and keeps its documentation (`README.md`) and metadata (`version.json`) at `<ModFolder>/`.
2. During `build-mod.ps1`, the script stages `ue4ss/`, strips any local `snapshots/` or `*.log` files, copies `<ModFolder>/README.md` into `ue4ss/Mods/<ModName>/README.md`, and compresses the `ue4ss/` folder into `archives/<ModName>-v<Version>.zip`.
3. Because `ue4ss/Mods/<ModName>/` sits at the root of the `.zip`, **Vortex** automatically recognizes it as a **`UE4SS Mod`** on drag-and-drop.
