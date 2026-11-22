# Ultra-Wide Menu Alignment (`UltraWideMenuAlignment` v--force-update)

Centers dynamic UI panels (Player Inventory, Chests, Personal Chests, Crafting Stations, Processing Stations, Building, Spellcasting, and Pause/Save menus) into an ultrawide safe zone while leaving your persistent HUD untouched for HUD layout mods like **Rune UI**.

## Archive & Monorepo Structure
```text
ue4ss/
└── Mods/
    └── UltraWideMenuAlignment/
        ├── enabled.txt
        ├── config.txt
        ├── modmenu.json
        ├── README.md
        └── Scripts/
            ├── config.lua
            └── main.lua
```

## Known Target Panel Classes (`Scripts/config.lua`)

| Group Key | Blueprint Class Name | In-Game Screen | Mount Type |
| :--- | :--- | :--- | :--- |
| `inventory` | `WBP_Inventory_MainPanel_C` | Player Backpack / Equipment / Runes | HUD Canvas (`InVp=false`) |
| `containers` | `WBP_WorldActorInventory_MainPanel_C` | Storage Chests & Personal Chests | HUD Canvas (`InVp=false`) |
| `stations` | `WBP_Crafting_MainPanel_C` | Crafting Bench / Artisan Tables | HUD Canvas (`InVp=false`) |
| `stations` | `WBP_ProcessingStation_MainPanel_C` | Smelter / Kiln / Tannery | HUD Canvas (`InVp=false`) |
| `stations` | `WBP_Composter_MainPanel_C` | Composter | HUD Canvas (`InVp=false`) |
| `stations` | `WBP_Enchanting_MainPanel_C` | Enchanting / Runic Altar | HUD Canvas (`InVp=false`) |
| `build_spells` | `WBP_Building_MainPanel_C` | Construction / Build Menu | HUD Canvas (`InVp=false`) |
| `build_spells` | `WBP_Spellcasting_MainPanel_C` | Spellbook / Spellcasting Wheel | HUD Canvas (`InVp=false`) |
| `pause_menu` | `WBP_InGameScreensRoot_C` | Esc / Pause / Save Menu | Root Viewport (`InVp=true`) |

## Developer & AI Debugging Guide (Finding New Panels)
1. **Enable Debug Hotkeys:** Turn **Enable Debug Hotkeys (`Shift + F7/F8/F9`)** ON in **`Esc > MODS > Ultra-Wide Menu Alignment`** (or set `EnableDebugHotkeys=1` in `config.txt`).
2. **Capture a Two-Press Diff Snapshot (`Shift + F7`):**
   - Press **`Shift + F7`** (or **`Shift + NumPad 7`**) with all menus closed (baseline).
   - Open the target panel and press **`Shift + F7`** again.
   - Check `snapshots/snapshot_short_YYYY-MM-DD_HH-MM-SS.txt` for `[NEW/CHANGED]` lines with `vis=0` or `vis=4` and copy the class name before `_21474...`.
3. **UE4SS Live View Tip:** Never use `*` or spaces in Live View search; include a trailing underscore (e.g., `WBP_Inventory_MainPanel_C_`) to filter out `/Game/` templates.
4. **Crash-Safety Rules:**
   - Never call `GetVisibility()` or `GetParent()` on `/Game/` CDO templates (`Default__`).
   - Never hook base `/Script/UMG.Widget:SetVisibility`.
   - Never shift inner child widgets independently of their parent `*_MainPanel_C` (breaks `RetainerBox` clipping masks).

## Changelog

<!-- CHANGELOG:START -->
### v--force-update

- **2026-11-22** - reorganize repo (`150120c`)
- **2026-11-22** - 1.2.9 working with both pause menu and inventory alignment and does not interfere with other panels (`76fab60`)
<!-- CHANGELOG:END -->
