# Resize & Drag Window (`ResizeAndDragWindow` v0.1.0-alpha)

Standalone **UE4SS** mod for **RuneScape: Dragonwilds** that lets you freely drag and scale UMG menu panels (`Inventory`, `Chests`, `Personal Chests`, `Crafting Stations`, `Building`, `Spellcasting`, and `Pause/Save` menus) with cross-session per-panel position persistence.

Designed to stack cleanly alongside [**Ultra-Wide Menu Alignment**](../ultra-wide-menu-alignment/README.md) and **Rune UI**.

## Controls (While a Managed Panel Is Open)

| Action | Mouse / Wheel | Keyboard Alternative |
| :--- | :--- | :--- |
| **Drag / Move Active Panel** | Hold **Middle Mouse Button** + Move Cursor | **`Alt + Arrow Keys`** (`20px` per tap) |
| **Resize / Scale Active Panel** | **`Alt + Mouse Wheel`** | **`Alt + NumPad +`** / **`Alt + NumPad -`** |
| **Reset Active Panel** | — | **`Alt + Backspace`** or **`Alt + NumPad 0`** |

## Mod Menu Settings (`Esc > MODS > Resize & Drag Window`)
* **Enable Resize & Drag Window:** Master toggle.
* **Enable Middle-Mouse Drag:** Toggle holding Middle Mouse Button to drag open panels.
* **Enable Alt + Arrow Key Nudging:** Toggle keyboard positioning.
* **Enable Alt + Scroll / NumPad Scaling:** Toggle panel scaling (`0.50x` - `1.75x`).
* **Drag Sensitivity / Scale Step:** Tune mouse drag speed and resize increments.

## Changelog

<!-- CHANGELOG:START -->
### v0.1.0-alpha

- **2026-11-22** - Initial `ResizeAndDragWindow` implementation with per-panel persistence (`panel_layouts.lua`)
<!-- CHANGELOG:END -->
