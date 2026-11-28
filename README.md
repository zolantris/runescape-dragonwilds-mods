# RuneScape: Dragonwilds — Quality of Life & Combat Mods

A collection of lightweight, modular **UE4SS** quality-of-life (QoL) and magic combat mods for **RuneScape: Dragonwilds**, maintained as a single monorepo at [`zolantris/runescape-dragonwilds-mods`](https://github.com/zolantris/runescape-dragonwilds-mods).

Each mod in this repository is packaged independently in the standard `ue4ss/Mods/<ModName>/` structure for one-click installation via **Vortex** or manual extraction into your game directory.

* **Discord:** [Join our Discord](https://discord.gg/QwktYjdbtx)
* **Support:** [Support on Ko-fi](https://ko-fi.com/zolantris)

---

## Mods Overview

| Mod | Folder | Status | Description | Download |
| :--- | :--- | :--- | :--- | :--- |
| **Arcane Wilds** | [`arcane-wilds/`](./arcane-wilds/README.md) | **Active / Supported** | Script-driven magic combat overhaul featuring move-while-casting (Air-safe Freecast), Block (`RMB` / `LT` / `LB`) & hotkey cross-element / Ancient Magicks spell chaining, custom spell timelines, notify-safe animation speed clamping, rune-accurate consumption, and the visual [Arcane Wilds Studio](https://zolantris.github.io/runescape-dragonwilds-mods/) web/local config editor. | [Releases](https://github.com/zolantris/runescape-dragonwilds-mods/releases) |
| **Ultra-Wide Menu Alignment** | [`ultra-wide-menu-alignment/`](./ultra-wide-menu-alignment/README.md) | **Deployed / Supported** | Centers Inventory, Chests, Personal Chests, Crafting Stations, and Pause/Save menus into an ultrawide safe zone (`MinX`/`MaxX`) while leaving your persistent HUD untouched for HUD layout mods like Rune UI. | [Releases](https://github.com/zolantris/runescape-dragonwilds-mods/releases) |
| **Resize & Drag Window** | `resize-and-drag-window/` | **Planned / In Development** | Standalone UMG window dragging and scaling with cross-session per-panel position persistence. | *Coming Soon* |

---

## Installation (Vortex & Manual)

### Prerequisites
- [**UE4SS for RuneScape: Dragonwilds**](https://nexusmods.com) (v3.0.1+) installed in `RSDragonwilds\Binaries\Win64\`.
- *(Optional)* [**Mod Menu**](https://nexusmods.com/mods/548) to adjust settings in-game under **`Esc > MODS`**.

### Installing via Vortex
1. Download the desired `<ModName>-vX.Y.Z.zip` archive from the [**GitHub Releases**](https://github.com/zolantris/runescape-dragonwilds-mods/releases) page.
2. Drag the `.zip` file into Vortex's **Drop File(s)** area—Vortex will automatically detect the `ue4ss\Mods\` layout and set **Mod Type** to **`UE4SS Mod`**.
3. Enable the mod and click **Deploy Mods**.

### Manual Installation
1. Extract the `<ModName>-vX.Y.Z.zip` archive directly into:
   ```text
   <SteamLibrary>\steamapps\common\RSDragonwilds\RSDragonwilds\Binaries\Win64\
   ```
2. Verify that `enabled.txt` exists inside `Binaries\Win64\ue4ss\Mods\<ModName>\`.

---

## Repository Structure & Automation

```text
runescape-dragonwilds-mods/
├── arcane-wilds/                 # Arcane Wilds mod source & docs
│   ├── README.md
│   ├── version.json
│   └── ue4ss/
│       └── Mods/
│           └── ArcaneWilds/
├── archives/                     # Local build output (.zip) — gitignored
├── scripts/                      # Build, changelog, release, and save-backup automation
│   └── README.md                 # Automation & release pipeline documentation
├── ultra-wide-menu-alignment/    # UltraWideMenuAlignment mod source & docs
│   ├── README.md
│   ├── version.json
│   └── ue4ss/Mods/UltraWideMenuAlignment/
├── LICENSE                       # MIT License
└── README.md                     # Monorepo index (this file)
```

For building Vortex-ready archives, bumping semantic versions, generating per-mod changelogs, and publishing GitHub releases, see **[`scripts/README.md`](./scripts/README.md)**.

---

## License

Released under the [MIT License](./LICENSE).

## Running Tests & Lua Coverage

Arcane Wilds includes an offline JSON validation & Lua 5.4 unit/regression test suite with built-in zero-dependency line coverage (no running game required).

**Prerequisites:** Lua 5.4 (install once on Windows via `winget install DEVCOM.Lua`).

```powershell
# Validate all JSON configs/schemas and run Lua tests + coverage report
.\mod.ps1 test arcane-wilds

# Include missed line ranges and emit an LCOV file (compatible with VS Code Coverage Gutters)
.\mod.ps1 test arcane-wilds -CoverageDetails -LcovPath arcane-wilds/tests/coverage.lcov

# Enforce a minimum total line coverage threshold (optional)
.\mod.ps1 test arcane-wilds -MinCoverage 40

# Or run the Lua tests directly
lua arcane-wilds/tests/run_tests.lua --coverage-details
```