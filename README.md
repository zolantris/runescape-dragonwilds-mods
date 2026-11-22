# RuneScape: Dragonwilds — Quality of Life Mods

A collection of lightweight, modular **UE4SS** quality-of-life (QoL) mods for **RuneScape: Dragonwilds**, maintained as a single monorepo at [`zolantris/runescape-dragonwilds-mods`](https://github.com/zolantris/runescape-dragonwilds-mods).

Each mod in this repository is packaged independently in the standard `ue4ss/Mods/<ModName>/` structure for one-click installation via **Vortex** or manual extraction into your game directory.

---

## Mods Overview

| Mod | Folder | Status | Description | Download |
| :--- | :--- | :--- | :--- | :--- |
| **Ultra-Wide Menu Alignment** | [`ultra-wide-menu-alignment/`](./ultra-wide-menu-alignment/README.md) | **Deployed / Supported** | Centers Inventory, Chests, Personal Chests, Crafting Stations, and Pause/Save menus into an ultrawide safe zone (`MinX`/`MaxX`) while leaving your persistent HUD untouched for HUD layout mods like Rune UI. | [Latest Release](https://github.com) |
| **Resize & Drag Window** | `resize-and-drag-window/` | **Planned / In Development** | Standalone UMG window dragging and scaling with cross-session per-panel position persistence. | *Coming Soon* |
| **Centered Panels (Legacy)** | — | **Deprecated / Not Supported** | Early prototype superseded by **Ultra-Wide Menu Alignment** (`v1.3.3+`). Do not install alongside `UltraWideMenuAlignment`. | — |

---

## Installation (Vortex & Manual)

### Prerequisites
* [**UE4SS for RuneScape: Dragonwilds**](https://nexusmods.com) (v3.0.1+) installed in `RSDragonwilds\Binaries\Win64\`.
* *(Optional)* [**Mod Menu**](https://nexusmods.com/mods/548) to adjust settings in-game under **`Esc > MODS`**.

### Installing via Vortex
1. Download the desired `<ModName>-vX.Y.Z.zip` archive from the [**GitHub Releases**](https://github.com) page.
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
