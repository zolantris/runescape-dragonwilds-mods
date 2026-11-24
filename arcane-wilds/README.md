# Arcane Wilds

**Arcane Wilds** is a script-driven UE4SS magic combat mod for *RuneScape: Dragonwilds* combining move-while-casting (Air-safe Freecast), cross-element and Ancient Magicks spell chaining, Block (`RMB` / `LT` / `RB`) and hotkey stance modifiers, custom spell scaffolding (`custom_spells.txt`), notify-safe animation speed clamping, rune-accurate consumption, and hold-to-auto-attack.

## Features & Controls

* **Zero Asset Overrides**: 100% runtime Lua script-driven—patch-safe and compatible with `.pak` mods.
* **Custom Spell Scaffolding (`custom_spells.txt`)**:
  * Define custom named spells (such as `FlamesOfZamorak`, `StormOfArmadyl`, `SaradominStrike`, `GuthixClaws`, `IbanBlast`) backed by a base `DominionSpellData` ability plus optional VFX (`NiagaraSystem` / `SpawnActor` / `GameplayEffect`), SFX (`SoundWave` / `SoundCue`), `AnimMontage`, and `Speed` overrides.
  * Hot-reloads automatically on save (`Ctrl+S`) and registers custom spells into the runtime spell registry and `spell_names.txt` / `combo_rules.txt` so you can chain them like native spells.
* **Freecast & Hold-to-Auto-Attack**: Unlocks movement during supported spell montages (configurable per category in `config.txt` / Mod Menu) and supports holding Left-Click / Right Trigger to chain casts cleanly when idle.
* **Block & Modifier Stance (`RMB` / `LT` / `RB` or `SHIFT`)**:
  * Supports `RMB` / `BLOCK` (Right Mouse Button, Gamepad Left Trigger, or Gamepad Left Shoulder) as well as `SHIFT`, `ALT`, `CTRL`, `MOUSE4`, `MOUSE5`, and `MMB` via `ModifierKey`.
  * Returns to your original starting spell before rolling any new combo so swapped elements never chain into unintended loops.
* **Direct Spell-Name Combo System (`combo_rules.txt` & `spell_names.txt`)**:
  * Edit `combo_rules.txt` and `spell_names.txt` directly in any text editor and save (`Ctrl+S`)—changes hot-reload live in-game without Mod Menu text clipping.
* **Notify-Safe Animation Speed Clamps**:
  * Caps playback speed via `MaxFinisherSpeedClamp` (`5.0x` by default when `KeepGroundSmashAnchored=true`) on delayed/multi-stage finishers (`Meteor`, `Volcano`, `Air Slam`, `Boulder`, or `Clamp=true` custom spells) so `AnimNotify` damage and projectile spawn triggers are not skipped.
* **Air 4th-Hit Finisher Tip**:
  * Flick aim slightly downwards then immediately upwards when firing the 4th Air finisher on the move so the projectile renders and tracks cleanly.
* **Multiplayer**:
  * Works client-side for Freecast and standard chaining; recommend Host + Clients both install when using high `AnimationSpeed` multipliers or custom VFX/SFX overrides.

## Folder Layout

Place `ue4ss/Mods/ArcaneWilds/` into your `RSDragonwilds/Binaries/Win64/` directory (or deploy via Vortex).
