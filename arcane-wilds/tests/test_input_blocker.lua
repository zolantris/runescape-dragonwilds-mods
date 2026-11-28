-- Tests for runtime EnhancedInput Quick-Cast key blocker (input_blocker.lua)

local T = require("test_harness")
local Mock = require("ue4ss_mock")
local ConfigManager = require("config_manager")
local InputBlocker = require("input_blocker")

local ALIASES = {
    ["1"] = "One",
    ["2"] = "Two",
    ["3"] = "Three",
    ["4"] = "Four",
    ["GP_X"] = "Gamepad_FaceButton_Left",
    ["GP_Y"] = "Gamepad_FaceButton_Top",
    ["GP_B"] = "Gamepad_FaceButton_Right",
    ["GP_A"] = "Gamepad_FaceButton_Bottom",
    ["TAB"] = "Tab",
    ["RMB"] = "RightMouseButton"
}

local function NormalizeKey(raw)
    local s = tostring(raw or ""):gsub("^%s*(.-)%s*$", "%1")
    local up = s:upper()
    if ALIASES[up] then return ALIASES[up] end
    if #s == 1 and s:match("%a") then return up end
    return s
end

local function ParseKeyList(rawStr)
    local out = {}
    for tok in tostring(rawStr or ""):gmatch("[^,|;]+") do
        local k = NormalizeKey(tok)
        if k ~= "" then table.insert(out, k) end
    end
    return out
end

local function SetupEnhancedInputEnvironment(opts)
    opts = opts or {}
    Mock.Reset()

    local imcClass = Mock.MakeUObject("Class /Script/EnhancedInput.InputMappingContext")
    local iaClass  = Mock.MakeUObject("Class /Script/EnhancedInput.InputAction")
    local mapKeyFn = Mock.MakeUObject("Function /Script/EnhancedInput.InputMappingContext:MapKey", {
        ForEachProperty = function(_, cb)
            cb({ GetFName = function() return FName("Action") end })
            cb({ GetFName = function() return FName("ToKey") end })
        end
    })

    Mock.RegisterPath("/Script/EnhancedInput.InputMappingContext", imcClass)
    Mock.RegisterPath("/Script/EnhancedInput.InputAction", iaClass)
    Mock.RegisterPath("/Script/EnhancedInput.InputMappingContext:MapKey", mapKeyFn)

    local defaultGi = Mock.MakeUObject("GameInstance /Script/Engine.Default__GameInstance")
    local liveGi    = Mock.MakeUObject("DominionGameInstance /Engine/Transient.DominionGameInstance_0")
    Mock.RegisterClassInstance("GameInstance", defaultGi)
    Mock.RegisterClassInstance("GameInstance", liveGi)

    local subState = {
        addedCalls = {},
        removedCalls = {},
        activeContexts = {}
    }

    local defaultSub = Mock.MakeUObject("EnhancedInputLocalPlayerSubsystem /Script/EnhancedInput.Default__EnhancedInputLocalPlayerSubsystem", {
        AddMappingContext = function() error("must never call AddMappingContext on Default__ CDO") end,
        RemoveMappingContext = function() error("must never call RemoveMappingContext on Default__ CDO") end
    })
    local liveSub = Mock.MakeUObject("EnhancedInputLocalPlayerSubsystem /Engine/Transient.LocalPlayer_0:EnhancedInputLocalPlayerSubsystem_0", {
        AddMappingContext = function(_, imc, prio, modOpts)
            if opts.rejectNonEmptyOpts and modOpts and next(modOpts) ~= nil then
                error("simulated struct marshal rejection")
            end
            table.insert(subState.addedCalls, { imc = imc, prio = prio, opts = modOpts })
            subState.activeContexts[imc] = prio
        end,
        RemoveMappingContext = function(_, imc, modOpts)
            if opts.rejectNonEmptyOpts and modOpts and next(modOpts) ~= nil then
                error("simulated struct marshal rejection")
            end
            table.insert(subState.removedCalls, { imc = imc, opts = modOpts })
            subState.activeContexts[imc] = nil
        end,
        HasMappingContext = function(_, imc)
            return subState.activeContexts[imc] ~= nil
        end
    })
    Mock.RegisterClassInstance("EnhancedInputLocalPlayerSubsystem", defaultSub)
    Mock.RegisterClassInstance("EnhancedInputLocalPlayerSubsystem", liveSub)

    local constructed = {}
    Mock.OnStaticConstructObject = function(cls, outer)
        T.AssertEq(outer, liveGi, "must construct blocker assets on live GameInstance, not Default__")
        if cls == imcClass then
            local imc = Mock.MakeUObject("InputMappingContext /Engine/Transient.IMC_Dynamic_" .. tostring(#constructed + 1), {
                _mapped = {},
                UnmapAll = function(self)
                    self._mapped = {}
                end,
                MapKey = function(self, action, keyStruct)
                    table.insert(self._mapped, { action = action, key = keyStruct.KeyName:ToString() })
                end
            })
            table.insert(constructed, imc)
            return imc
        elseif cls == iaClass then
            local ia = Mock.MakeUObject("InputAction /Engine/Transient.IA_Dynamic_" .. tostring(#constructed + 1))
            table.insert(constructed, ia)
            return ia
        end
        return nil
    end

    local modeGameplay = Mock.MakeUObject("DominionInputMode /Game/Input/IM_Gameplay", { _addr = 1001 })
    local pc = Mock.MakeUObject("DominionPlayerController /Game/Maps/World.DominionPlayerController_0", {
        CurrentInputMode = modeGameplay
    })

    return {
        pc = pc,
        liveSub = liveSub,
        subState = subState,
        modeGameplay = modeGameplay
    }
end

T.Suite("input_blocker", function()
    T.Test("constructs IMC/IA dynamically without pak assets and skips Default__ CDOs", function()
        local env = SetupEnhancedInputEnvironment()
        local config = ConfigManager.CreateDefaultConfig()
        local state = {}
        local heldMods = { BLOCK = true }
        local bindings = {
            { modifier = "BLOCK", keysRaw = "1, GP_X", target = "SaradominGodsword" },
            { modifier = "BLOCK", keysRaw = "2, GP_Y", target = "FlamesOfZamorak" },
            { modifier = "BLOCK", keysRaw = "3, GP_B", target = "StormOfArmadyl" },
            { modifier = "BLOCK", keysRaw = "4, GP_A", target = "SaradominStrike" }
        }

        local ok = InputBlocker.Sync(
            config, state, env.pc, bindings, ParseKeyList,
            function(_, m) return heldMods[m] == true end,
            NormalizeKey
        )

        T.AssertTrue(ok, "blocker should activate when Block is held")
        T.AssertTrue(state._QuickCastInputBlocked, "state flag should be true")
        T.AssertEq(state._QuickCastBlockerSource, "StaticConstructObject")
        T.AssertTrue(state._QuickCastIA.bConsumeInput, "IA must set bConsumeInput=true")
        T.AssertTrue(state._QuickCastIA.bConsumesActionAndAxisMappings, "IA must set bConsumesActionAndAxisMappings=true")
        T.AssertFalse(state._QuickCastIA.bReserveAllMappings, "IA must set bReserveAllMappings=false to avoid global input lockout")
        T.AssertEq(state._QuickCastIMC.InputModeFilterOptions, 2, "IMC must set DoNotFilter (2)")
        T.AssertEq(state._QuickCastIMC.RegistrationTrackingMode, 0, "IMC must set Untracked (0)")
        T.AssertEq(#env.subState.addedCalls, 1)
        T.AssertEq(env.subState.addedCalls[1].prio, 100000)
        T.AssertEq(#state._QuickCastIMC._mapped, 8, "all 8 default Block keys should be mapped")

        -- Releasing Block removes the mapping context with bIgnoreAllPressedKeysUntilRelease = false
        heldMods.BLOCK = false
        local stillOn = InputBlocker.Sync(
            config, state, env.pc, bindings, ParseKeyList,
            function(_, m) return heldMods[m] == true end,
            NormalizeKey
        )
        T.AssertFalse(stillOn, "blocker should deactivate when Block is released")
        T.AssertFalse(state._QuickCastInputBlocked)
        T.AssertEq(#env.subState.removedCalls, 1)
        T.AssertFalse(env.subState.removedCalls[1].opts.bIgnoreAllPressedKeysUntilRelease, "must not lock out currently pressed keys on release")
    end)

    T.Test("blocks menu/shortcut hotkeys (Q, I, K, Tab) and never self-blocks active modifier keys", function()
        local env = SetupEnhancedInputEnvironment()
        local config = ConfigManager.CreateDefaultConfig()
        local state = {}
        local heldMods = { BLOCK = true, SHIFT = false }
        local bindings = {
            { modifier = "BLOCK", keysRaw = "1, Q, I, K, Tab, RMB", target = "StormOfArmadyl" },
            { modifier = "SHIFT", keysRaw = "5, E", target = "FlamesOfZamorak" }
        }

        local ok = InputBlocker.Sync(
            config, state, env.pc, bindings, ParseKeyList,
            function(_, m) return heldMods[m] == true end,
            NormalizeKey
        )
        T.AssertTrue(ok)
        -- RMB must be excluded so Block itself is never blocked; Shift keys are not active yet
        T.AssertEq(state._QuickCastBlockerSig, "One,Q,I,K,Tab")

        -- Now hold Shift as well -> keys update dynamically and re-apply
        heldMods.SHIFT = true
        InputBlocker.Sync(
            config, state, env.pc, bindings, ParseKeyList,
            function(_, m) return heldMods[m] == true end,
            NormalizeKey
        )
        T.AssertEq(state._QuickCastBlockerSig, "One,Q,I,K,Tab,5,E")
        T.AssertEq(#env.subState.addedCalls, 2)
    end)

    T.Test("re-applies blocker automatically if game clears mapping contexts or changes input mode", function()
        local env = SetupEnhancedInputEnvironment()
        local config = ConfigManager.CreateDefaultConfig()
        local state = {}
        local bindings = {
            { modifier = "BLOCK", keysRaw = "1, 2", target = "SaradominGodsword" }
        }
        local function alwaysBlock(_, m) return m == "BLOCK" end

        InputBlocker.Sync(config, state, env.pc, bindings, ParseKeyList, alwaysBlock, NormalizeKey)
        T.AssertEq(#env.subState.addedCalls, 1)

        -- Steady tick while already registered -> no redundant AddMappingContext spam
        InputBlocker.Sync(config, state, env.pc, bindings, ParseKeyList, alwaysBlock, NormalizeKey)
        T.AssertEq(#env.subState.addedCalls, 1)

        -- Simulate Dominion calling ClearAllMappings() mid-block
        env.subState.activeContexts = {}
        InputBlocker.Sync(config, state, env.pc, bindings, ParseKeyList, alwaysBlock, NormalizeKey)
        T.AssertEq(#env.subState.addedCalls, 2, "must re-apply when dropped by game")

        -- Simulate Dominion switching CurrentInputMode (e.g. LockOn targeting)
        env.pc.CurrentInputMode = Mock.MakeUObject("DominionInputMode /Game/Input/IM_LockOn", { _addr = 2002 })
        InputBlocker.Sync(config, state, env.pc, bindings, ParseKeyList, alwaysBlock, NormalizeKey)
        T.AssertEq(#env.subState.addedCalls, 3, "must re-apply when CurrentInputMode changes")
    end)

    T.Test("falls back cleanly to empty options struct {} if UE4SS rejects option fields", function()
        local env = SetupEnhancedInputEnvironment({ rejectNonEmptyOpts = true })
        local config = ConfigManager.CreateDefaultConfig()
        local state = {}
        local held = true
        local bindings = { { modifier = "BLOCK", keysRaw = "1", target = "SaradominGodsword" } }

        local ok = InputBlocker.Sync(
            config, state, env.pc, bindings, ParseKeyList,
            function() return held end,
            NormalizeKey
        )
        T.AssertTrue(ok, "AddMappingContext should succeed via {} fallback")
        T.AssertEq(#env.subState.addedCalls, 1)

        held = false
        InputBlocker.Sync(
            config, state, env.pc, bindings, ParseKeyList,
            function() return held end,
            NormalizeKey
        )
        T.AssertEq(#env.subState.removedCalls, 1, "RemoveMappingContext should succeed via {} fallback")
    end)

    T.Test("respects QuickCastSuppressGameActions=false and Enabled=false", function()
        local env = SetupEnhancedInputEnvironment()
        local config = ConfigManager.CreateDefaultConfig()
        local state = {}
        local bindings = { { modifier = "BLOCK", keysRaw = "1", target = "SaradominGodsword" } }

        InputBlocker.Sync(config, state, env.pc, bindings, ParseKeyList, function() return true end, NormalizeKey)
        T.AssertTrue(state._QuickCastInputBlocked)

        config.QuickCastSuppressGameActions = false
        local ok = InputBlocker.Sync(config, state, env.pc, bindings, ParseKeyList, function() return true end, NormalizeKey)
        T.AssertFalse(ok)
        T.AssertFalse(state._QuickCastInputBlocked)
        T.AssertEq(#env.subState.removedCalls, 1)
    end)
end)
