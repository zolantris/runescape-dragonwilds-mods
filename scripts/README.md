# Monorepo Build & Release Scripts

> Part of the **[RuneScape: Dragonwilds Mods Monorepo](../README.md)** ([`zolantris/runescape-dragonwilds-mods`](https://github.com/zolantris/runescape-dragonwilds-mods)).

This directory contains PowerShell automation scripts for packaging UE4SS mods into Vortex-ready `.zip` archives, syncing versions and changelogs, backing up saves, and publishing tagged releases to GitHub.

---

## Available Scripts

| Script | Purpose | Key Parameters |
| :--- | :--- | :--- |
| **`build-mod.ps1`** | Reads `<ModFolder>/version.json`, optionally bumps the semantic version, updates `README.md`, syncs version numbers into `modmenu.json` and `Scripts/main.lua`, strips debug snapshots/logs, and outputs `archives/<ModName>-v<Version>.zip`. | `-ModFolder` *(required)*, `-Version`, `-Channel`, `-Bump` (`patch` \| `minor` \| `major`), `-SkipChangelog` |
| **`update-changelog.ps1`** | Updates the `# Title` version header and injects folder-scoped Git commits into the `<!-- CHANGELOG:START -->` ... `<!-- CHANGELOG:END -->` block of `<ModFolder>/README.md`. | `-ModFolder` *(required)*, `-Version`, `-MaxCommits` *(default: `30`)* |
| **`publish-release.ps1`** | Builds the release archive, creates an annotated Git tag (`<ModName>-v<Version>`), pushes the tag, and publishes a GitHub Release with the `.zip` asset and extracted changelog notes via `gh`. Bails out if the tag/release already exists unless `--force-update` is passed. | `-ModFolder` *(required)*, `-Version`, `-Channel`, `--force-update` (`-ForceUpdate`), `--dry-run` (`-DryRun`), `-SkipBuild` |
| **`auto-backup-saves.ps1`** | Local utility script for backing up *RuneScape: Dragonwilds* character and world save files. | *(Run directly via PowerShell)* |

---

## Common Workflows

### 1. Build a Vortex-Ready Archive Locally
Builds `archives/UltraWideMenuAlignment-v<Version>.zip` using the version defined in `ultra-wide-menu-alignment/version.json`:
```powershell
.\scripts\build-mod.ps1 -ModFolder ultra-wide-menu-alignment
```

### 2. Bump Version & Build
Increments the `patch` (`1.3.4` -> `1.3.5`), `minor`, or `major` version in `version.json`, updates the README title and changelog, and packages the archive:
```powershell
.\scripts\build-mod.ps1 -ModFolder ultra-wide-menu-alignment -Bump patch
```

### 3. Preview a GitHub Release (`--dry-run`)
Validates `version.json`, checks remote tag conflicts, and prints the exact tag name, asset path, and release notes without modifying Git or GitHub:
```powershell
.\scripts\publish-release.ps1 -ModFolder ultra-wide-menu-alignment --dry-run
```

### 4. Publish a Tagged GitHub Release
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
