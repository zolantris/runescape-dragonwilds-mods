# Repository Engineering & Code Instructions

This monorepo contains modular **UE4SS** Lua mods for *RuneScape: Dragonwilds* (such as `arcane-wilds/` and `ultra-wide-menu-alignment/`), managed via the root `.\mod.ps1` CLI.

## Mandatory Lua Testing Requirements

1. **Tests Required for All New Features & Fixes**
   - Every new Lua feature, behavior change, config option, schema field, or bug fix **must** include offline Lua unit or regression tests under `<mod>/tests/` and be registered in `<mod>/tests/run_tests.lua`.
   - Every bug fix **must** include a regression test that reproduces the original failure mode and verifies the fix prevents recurrence.
   - Structure new Lua logic into testable, modular functions so core rules, parsers, state transitions, and UE4SS patching logic can be exercised offline under standalone Lua 5.4 without launching the game.

2. **All Tests Must Pass Before Finishing**
   - Before finishing any code or config change, run the mod test suite and confirm **zero failures**:
     ```powershell
     .\mod.ps1 test arcane-wilds
     ```
   - When modifying JSON configs (`custom_spells.json`, `combo_rules.json`, `combo_rules_examples.json`) or schemas under `schemas/`, update the corresponding Draft-07 JSON Schema and verify validation passes.
   - Never delete, skip, or weaken existing assertions just to make a test pass.

3. **Test Quality Standards**
   - **Behavior over implementation**: Test observable outputs, state transitions, and side effects rather than private implementation trivia.
   - **Cover edge cases and error paths**: Include invalid input, malformed JSON, `false` vs `nil` handling, boundary/clamp limits, toggle reversibility (enable + restore), and fallback behavior—not only the happy path.
   - **Meaningful assertions**: Assert specific values and post-conditions using `test_harness.lua` helpers (`AssertEq`, `AssertNear`, `AssertTrue`, `AssertFalse`, `AssertNil`, `AssertNotNil`, `AssertContains`). Avoid shallow "did not error" tests.
   - **Isolation & determinism**: Reset mock state (`Mock.Reset()`) and module caches (e.g. `SpellScanner.ClearSnapshots()`) at the start of each test, always clean up temporary files inside a `pcall`-guarded block, and avoid execution-order dependencies or real-time sleeps.
   - **Faithful mocks**: Use `ue4ss_mock.lua` to stub UE4SS/UE5 objects cleanly; never mock the module under test.

4. **Lua Code Coverage**
   - Line coverage is collected automatically on every test run via `arcane-wilds/tests/coverage.lua` (zero-dependency Lua 5.4 `debug.sethook` coverage).
   - For any Lua file you add or modify, run with missed-line details and inspect coverage on your changed code:
     ```powershell
     .\mod.ps1 test arcane-wilds -CoverageDetails
     ```
   - Ensure new features and modified branches are covered by tests and do not regress coverage on touched modules.
   - Standard LCOV output is supported via `-LcovPath <path>` (e.g. `arcane-wilds/tests/coverage.lcov`, gitignored) and optional floor enforcement via `-MinCoverage <percent>`.

## Repository Conventions

- Use `.\mod.ps1` for testing, building, deploying, and releasing mods (`.\mod.ps1 help` for all commands).
- Keep mods strictly offline-testable under Lua 5.4 with zero external LuaRocks dependencies so both Windows (`winget install DEVCOM.Lua`) and GitHub Actions CI run identically.
- Consult `.agents/rules/lua-testing.md` for detailed Lua test harness, mock, schema, and coverage conventions.
- Consult `.agents/rules/debugging.md` when inspecting crashes, runtime errors, or `UE4SS.log`.
