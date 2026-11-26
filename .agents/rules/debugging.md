---
trigger: model_decision
description: Use when debugging crashes, runtime errors, or inspecting UE4SS and game logs.
---

# Crash & Game Logs
- When asked to inspect crash reports, runtime errors, or game output, always read `UE4SS.log` located at `C:\steam\steamapps\common\RSDragonwilds\RSDragonwilds\Binaries\Win64\ue4ss\UE4SS.log`.
- Check the bottom of the log file first for recent stack traces or Lua/C++ mod errors.
- UE4ss.log can be large so avoid getting entire log and instead search for our mod's name.
