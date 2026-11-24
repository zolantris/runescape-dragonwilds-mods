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

## Changelog

<!-- CHANGELOG:START -->
### v1.70.0

- **2026-11-24** - - Add support for flames of zamorak - ensure clamp is much higher at 5x speed ([bebde2a](https://github.com/zolantris/runescape-dragonwilds-mods/commit/bebde2a90282647efc6c089d1158790edba3e838))
- **2026-11-24** - add scaffolding for custom spells/scripts to be aliased as full spells ([fcec123](https://github.com/zolantris/runescape-dragonwilds-mods/commit/fcec1237e9420447e800fe819746d61b7784a985))
- **2026-11-24** - add arcane-wilds mod ([a9c35dd](https://github.com/zolantris/runescape-dragonwilds-mods/commit/a9c35dd916ec1c539845452cc72236386c9deb38))
- **2026-11-22** - Fix missing commits issue with stale tag ([122495f](https://github.com/zolantris/runescape-dragonwilds-mods/commit/122495fbe7cc96152d1b7b8b7021c8fd063b6eee))
- **2026-11-22** - Fix changelog linking ([39366ca](https://github.com/zolantris/runescape-dragonwilds-mods/commit/39366cae242e63c55f17e1a5a194e15bdc702e03))
- **2026-11-22** - autocommit release readme updates before pushing tag ([7733b20](https://github.com/zolantris/runescape-dragonwilds-mods/commit/7733b20bf5083a9e8a0d174afb3af1f0ff387718))
- **2026-11-22** - bump to 1.3.6 to test diff again ([9a6f2c8](https://github.com/zolantris/runescape-dragonwilds-mods/commit/9a6f2c8b466785b44fd2e3d1cc637c12ed98d603))
- **2026-11-22** - bump to 1.3.5 to test diff ([c272bc9](https://github.com/zolantris/runescape-dragonwilds-mods/commit/c272bc95b53e9946a1041cdd043eca5cde3efc29))
- **2026-11-22** - get publish release script to work and show diff ([57b6884](https://github.com/zolantris/runescape-dragonwilds-mods/commit/57b6884859107241bc15e5fd28685e5300f947f4))
- **2026-11-22** - Fix release scripts and update readme ([927ad9d](https://github.com/zolantris/runescape-dragonwilds-mods/commit/927ad9da46c48f830c966e3f32b852b933e2975f))
- **2026-11-22** - reorganize repo ([150120c](https://github.com/zolantris/runescape-dragonwilds-mods/commit/150120cad88104ab9cc93e3671de690898012a0c))
- **2026-11-22** - 1.2.9 working with both pause menu and inventory alignment and does not interfere with other panels ([76fab60](https://github.com/zolantris/runescape-dragonwilds-mods/commit/76fab605670f4b24d88be91b1935571c0560eb21))
- **2026-11-22** - Initial commit ([0739035](https://github.com/zolantris/runescape-dragonwilds-mods/commit/0739035e6728071f701375b584fe1cfc1f7b3517))
<!-- CHANGELOG:END -->
