# Arcane Wilds

A 100% script-driven **UE4SS** magic combat overhaul for **RuneScape: Dragonwilds**. Arcane Wilds unlocks full movement while casting (Air-safe Freecast), adds Block-stance and hotkey cross-element / Ancient Magicks spell chaining via hot-reloaded text rules, clamps delayed finisher animation speeds so `AnimNotify` triggers stay reliable, and deducts matching runes accurately on swapped casts.

---

## Features

* **Move-While-Casting (Air-Safe Freecast)**: Unlocks movement (`bBlockMovement = false`) across Air, Fire, Water, Earth, modded combat chains (Conjurer & Ancient Magicks), and utility spells without modifying `.pak` files.
* **Block-Stance & Hotkey Spell Chaining**: Hold Block (`RMB` / `LT` / `RB`) or your configured modifier key to chain multi-stage combos across elements, Staff/Wand variants, and Ancient Magicks barrages—returning cleanly to your equipped anchor spell at the end of every chain.
* **Hot-Reloadable Rules & Direct Asset Names**: Edit `combo_rules.txt` and `spell_names.txt` live while in-game—changes reload automatically on save (`Ctrl+S`) without clipping long strings in Mod Menu or requiring a UE4SS mod reload.
* **Notify-Safe Animation Speed Clamps**: Speeds up basic bolts and transitions while clamping multi-stage/delayed finishers (`Meteor`, `Volcano`, `Air Slam`, `Boulder`) at `1.35x` when enabled so `AnimNotify` damage and projectile spawns are never skipped.
* **Rune-Accurate Swapped Casting**: Deducts matching elemental and Ancient Magicks runes from your inventory whenever a macro swaps elements or triggers off-anchor spells.
* **Hold-to-Auto-Attack**: Continuously loops basic casts or active spell chains while holding attack until released.

---

## Controls & Usage

| Input / Action | Default | Behavior |
| :--- | :--- | :--- |
| **Combat Stance Modifier** | `RMB` (Block) / `LT` / `RB` | Hold while casting to engage weighted spell chains from `combo_rules.txt`. Releasing returns cleanly to your equipped anchor rune/spell. |
| **Attack / Cast** | `LMB` | Triggers the next step in your active chain (or loops continuously if `EnableAutoAttackHold=true`). |
| **Debug Dump / Rescan** | `SHIFT + \` (`OEM_5`) | When `AllowDebugCommands=true`, forces a spell rescan and dumps rule-to-asset mappings to `UE4SS.log` and `detected_spells.txt`. |

### Air 4th-Hit Finisher Aiming Tip
* **Air 4th-Hit Finisher (`DA_Spell_Primary_Air_04`)**: Works out of the box while moving—flick your aim slightly downwards and then immediately upwards when firing on the move so the ground-slam projectile spawns and tracks cleanly.

---

## Configuration Files (`ue4ss/Mods/ArcaneWilds/`)

* **`combo_rules.txt`**: Define weighted spell chains using friendly names or exact `DA_Spell_*` asset names:
  ```text
  # Syntax: Category@Spell1,Spell2:Speed -> NextCategory@Spell3:Speed :Weight;
  Fire@bolt_1,bolt_2,bolt_3,volcano:2.0 -> Water@tsunami:2.0 -> Air@gust,wind_2,wind_3,slam:2.0 :5;
  ```
* **`spell_names.txt`**: Maps human-readable names (such as `volcano`, `tsunami`, `ice_barrage`, `blood_barrage`, `StormOfArmadyl`, `IbanBlast`) directly 1-to-1 to their Unreal `DominionSpellData` asset names.
* **`config.txt` / Mod Menu (`Esc > MODS`)**: Configure `ModifierKey`, `EnableAutoAttackHold`, `KeepGroundSmashAnchored`, `ConsumeRunesOnSwappedCasts`, `MaxMoveSpeed`, `BonusSpeedVariancePct`, and per-element movement unlocks.
* **`detected_spells.txt`**: Auto-generated reference listing every `DominionSpellData` asset, `AnimMontage`, and active alias discovered in your current session.

---

## Installation

### Prerequisites
* [**UE4SS for RuneScape: Dragonwilds**](https://nexusmods.com) (v3.0.1+) installed in `RSDragonwilds\Binaries\Win64\`.
* *(Optional)* [**Mod Menu**](https://nexusmods.com/mods/548) to toggle settings in-game under **`Esc > MODS`**.

### Vortex or Manual Install
1. Install via **Vortex** (drag the release `.zip` into Vortex and deploy) or extract `ue4ss\Mods\ArcaneWilds\` into:
   ```text
   <SteamLibrary>\steamapps\common\RSDragonwilds\RSDragonwilds\Binaries\Win64\
   ```
2. Ensure `enabled.txt` is present inside `Binaries\Win64\ue4ss\Mods\ArcaneWilds\`.

---

## Compatibility & Multiplayer

* **Zero Asset Overrides**: 100% Lua script-driven—patch-safe and compatible with `.pak` spell/visual mods (including Hydra's Ancient Magicks and Conjurer mods).
* **Multiplayer**: Works client-side for Freecast and standard chaining; for best animation-speed and stamina/rune synchronization in co-op, have both Host and Clients install the mod.