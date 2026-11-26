# Minimal UE 5.6 Stub Project (`RSDragonwilds`) — Dominion Damage Bridge

This lightweight Unreal Engine 5.6 project exposes **only** the minimal `/Script/Dominion` damage & floating-number interfaces extracted from your local (gitignored) `UHTHeaderDump/` folder, plus an editor-only commandlet (`DominionEditor`) that automatically generates and compiles `/Game/Mods/ArcaneWilds/BFL_ArcaneWildsDamage.uasset`.

Everything is driven automatically by **`scripts/build-mod.ps1`** whenever a mod contains a `pak.json` (like `arcane-wilds/pak.json`):

```powershell
# Builds ArcaneWilds: syncs stubs -> compiles UE 5.6 Editor -> generates BFL_ArcaneWildsDamage
# -> cooks ONLY /Game/Mods/ArcaneWilds -> packs ArcaneWildsDamageBridge_P.pak
# -> bundles UE4SS Lua + pak into archives/ArcaneWilds-v<Version>.zip
.\scripts\build-mod.ps1 -ModFolder arcane-wilds

# Skip UE pak build if you want a quick Lua-only archive:
.\scripts\build-mod.ps1 -ModFolder arcane-wilds -SkipPak

# Force re-sync of UHT stubs and re-generation of BFL_ArcaneWildsDamage.uasset:
.\scripts\build-mod.ps1 -ModFolder arcane-wilds -ForceRebuildPak
```

---

## How It Works

1. **`scripts/sync-ue-damage-stubs.ps1`** extracts only the ~26 `/Script/Dominion` damage & floaties headers (`UDamageFunctionLibrary`, `UDamageComponent`, `UAiDamageComponent`, `IDamageable`, `UDamageFloatiesSubsystem`, `UDamageInflictionComponent`, `FDominionDamageEvent`, `FTypeDamage`, etc.) from your local gitignored `UHTHeaderDump/Dominion/Public/` into `unreal-engine/RSDragonwilds/Source/Dominion/` (also gitignored).
2. **`DominionEditor` (`GenerateArcaneWildsDamageBridge`)** is an editor-only C++ commandlet (never cooked into the `.pak`) that builds, compiles, and saves `/Game/Mods/ArcaneWilds/BFL_ArcaneWildsDamage` with `ApplyArcaneWildsDamage(Target, Instigator, DamageAmount, DamageClass, HitLocation, InstigatorLocation, Force, AttackId) -> bool`, wiring `GetComponentByClass(UDamageComponent)` -> `PredictDamage` -> `UDamageFunctionLibrary::ApplyDamage`.
3. **`scripts/build-mod.ps1`** cooks **only** `/Game/Mods/ArcaneWilds`, packs the cooked `.uasset`/`.uexp` files into `ArcaneWildsDamageBridge_P.pak`, and stages the Vortex-ready combo archive:
   ```text
   RSDragonwilds/
   ├── Binaries/Win64/ue4ss/Mods/ArcaneWilds/...
   └── Content/Paks/~mods/ArcaneWildsDamageBridge_P.pak
   ```
4. At runtime, `custom_spells.lua` detects `/Game/Mods/ArcaneWilds/BFL_ArcaneWildsDamage` automatically (Tier 1) and also supports direct Lua calls to `PredictDamage` / `UDamageFunctionLibrary::ApplyDamage` / `UDamageFloatiesSubsystem::DisplayDamage` if the `.pak` is not installed.
