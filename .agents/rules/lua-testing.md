---
trigger: model_decision
description: Use when writing, modifying, or reviewing Lua mod code, unit/regression tests, UE4SS mocks, JSON schemas, or Lua code coverage.
---

# Lua Testing & Coverage Playbook

## Running Tests & Coverage

Always validate JSON configs, Lua tests, and Lua line coverage from the repo root:

```powershell
# Default: JSON validation + Lua unit/regression tests + Lua line coverage table
.\mod.ps1 test arcane-wilds

# Inspect uncovered line ranges for every Lua script
.\mod.ps1 test arcane-wilds -CoverageDetails

# Emit standard LCOV (for VS Code Coverage Gutters / tooling)
.\mod.ps1 test arcane-wilds -CoverageDetails -LcovPath arcane-wilds/tests/coverage.lcov

# Enforce a minimum total line coverage threshold
.\mod.ps1 test arcane-wilds -MinCoverage 40

# Direct Lua 5.4 invocation (matches GitHub Actions CI)
lua arcane-wilds/tests/run_tests.lua --coverage-details
```

## Test Suite Architecture (`arcane-wilds/tests/`)

- `run_tests.lua`: Entry point; installs `ue4ss_mock` globals, starts `coverage.lua` **before** requiring test suites so module load & runtime lines are captured, runs all `test_*.lua` modules, prints coverage, and exits non-zero on any test or coverage threshold failure.
- `test_harness.lua`: Zero-dependency assertions (`T.Suite`, `T.Test`, `T.AssertTrue`, `T.AssertFalse`, `T.AssertNil`, `T.AssertNotNil`, `T.AssertEq`, `T.AssertNear`, `T.AssertContains`).
- `ue4ss_mock.lua`: Offline UE4SS runtime stubs (`StaticFindObject`, `FindFirstOf`, `FindAllOf`, `LoadAsset`, `StaticConstructObject`, `FName`, `FText`, `FString`, `ExecuteInGameThread`, `ExecuteWithDelay`, etc.) and `Mock.MakeUObject` / `Mock.RegisterPath` / `Mock.RegisterClassInstance` / `Mock.Reset`.
- `coverage.lua`: Zero-dependency Lua 5.4 line coverage collector using `debug.sethook("l")` and pure-Lua executable-line analysis. Automatically discovers all `Scripts/*.lua` files so untested `0.0%` modules are never hidden.

### Adding a New Test File

1. Create `arcane-wilds/tests/test_<feature>.lua`.
2. Register `require("test_<feature>")` in `arcane-wilds/tests/run_tests.lua`.
3. If you create a new Lua module under `Scripts/`, verify it appears in the coverage table and achieves strong line coverage for all new logic.

## Test Quality Checklist

Before considering tests complete, verify every item:

- [ ] **Feature coverage**: Every new function, branch, config flag, and cue/rule option has targeted tests.
- [ ] **Regression coverage**: Bug fixes test the exact faulty input/state (e.g., stale UObject references, JSON `false` vs `nil`, double-multiplied speed rates, malformed config hot-reload preserving last-known-good state).
- [ ] **Reversibility**: Config toggles and runtime patches test both enabling and disabling/restoring original values.
- [ ] **Error handling**: Parsers and loaders are tested with malformed input and verified to return errors cleanly without throwing uncaught exceptions or corrupting live state.
- [ ] **Isolation**: Each test starts with `Mock.Reset()` (and resets module state like `SpellScanner.ClearSnapshots()` when patching objects). Temporary files are created in `TEMP`/`TMP` with unique prefixes and deleted in a `pcall`-safe cleanup block.
- [ ] **No mock-of-SUT**: Mock UE4SS/UE5 engine boundaries only—call the real mod functions under test.
- [ ] **Coverage verified**: Run `.\mod.ps1 test arcane-wilds -CoverageDetails` and verify newly added or edited lines in `Scripts/*.lua` are executed (not listed under `missed:`).

## Writing Testable UE4SS Lua Code

- Keep pure logic (parsing, validation, math, targeting/priority scoring, scaling, state machines, config persistence) in dedicated modules under `Scripts/` rather than buried inside `main.lua` keybind/tick closures.
- Accept dependencies or state tables explicitly (e.g., `(cfg, pawn, ...)` or `(paths, config, state, logFn)`) so tests can pass lightweight `Mock.MakeUObject` fixtures without global coupling.
- Avoid hidden global mutations that persist across test cases; provide a reset/clear helper when a module caches UE4SS snapshots.

## JSON & Draft-07 Schema Validation

When modifying `custom_spells.json`, `combo_rules.json`, `combo_rules_examples.json`, or files under `arcane-wilds/ue4ss/Mods/ArcaneWilds/schemas/`:

1. Update the corresponding Draft-07 schema in `schemas/`.
2. Add Lua parser/runtime tests covering the new JSON fields (including explicit `false` / `0` / `null` values).
3. Ensure both `.\mod.ps1 test arcane-wilds` and Draft-07 schema validation (matching `.github/workflows/arcane-wilds-tests.yml`) pass.
