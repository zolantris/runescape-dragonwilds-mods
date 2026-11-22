# CenteredPanels v1.2.9 (RSDragonwilds UE4SS)

Centers dynamic modal panels (Inventory, Chests, Crafting, Processing, Composter, Enchanting, Building, Spellcasting, Pause/Save Menu) on 32:9 / 21:9 ultrawide monitors while leaving your persistent HUD untouched for Rune UI.

## What Was Fixed in v1.2.9
- **Root Cause Solved:** `WBP_Inventory_MainPanel_C` (and all `*_MainPanel_C` screens) are pre-created at startup inside `CanvasPanelSlot` with `Anchors=(0.00,0.00)-(1.00,1.00)`, and the game resets or maintains full-screen anchors when opening the screen.
- **Persistent Anchor Guard + RenderTranslation Support:** Hooks `Construct` and `AddToViewport` directly on the exact `*_MainPanel_C` Blueprint classes, and only when a panel is actively visible (`vis == 0` or `vis == 4`) enforces `CanvasPanelSlot:SetAnchors({ Minimum={X=MinX,Y=0}, Maximum={X=MaxX,Y=1} })` plus optional `SetRenderTranslation` horizontal offset.
- **Live Nudging & Hotkeys:**
  - `NumPad 8` : Force re-apply centering to active panels right now
  - `NumPad +` / `NumPad -` : Live nudge horizontal translation X by +/- 40px (and saves to `config.txt`)
  - `NumPad 7` / `F7` : Save clean compact + full timestamped snapshots to `snapshots\` (excluding `WBP_FloatingDamage` / `WBP_FloatingText` spam)

## Installation (Vortex)
1. Drag `CenteredPanels-v1.2.9.zip` into Vortex's **Drop File(s)** box.
2. Click **Install**, **Enable**, and **Deploy Mods**.
