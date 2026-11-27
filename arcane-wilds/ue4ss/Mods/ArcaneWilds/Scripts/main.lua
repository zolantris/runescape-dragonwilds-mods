-- ArcaneWilds v1.70.0
-- Thin Entrypoint & Main Loop Coordinator
-- Modules:
--   config_manager.lua  -> config.txt, spell_names.txt, custom_spells.txt, combo_rules.txt hot-reload & registry
--   spell_scanner.lua   -> DominionSpellData discovery, movement unlock, detected_spells.txt export
--   custom_spells.lua   -> Custom spell definitions (FlamesOfZamorak, StormOfArmadyl, etc.) & VFX/SFX hooks
--   equipment_runes.lua -> Equipped rune/staff/Ancient Magicks detection & inventory rune deduction
--   combat_engine.lua   -> Weighted macro state machine, montage pacing clamps & auto-attack triggering

local MOD_VERSION = "1.70.0"
local MOD_DIR = debug.getinfo(1, "S").source:match("^@?(.*[\\/])Scripts[\\/]") or "ue4ss\\Mods\\ArcaneWilds\\"
local SCRIPTS_DIR = MOD_DIR .. "Scripts\\"

if not package.path:find(SCRIPTS_DIR, 1, true) then
    package.path = SCRIPTS_DIR .. "?.lua;" .. package.path
end

local Paths = {
    CONFIG_PATH             = MOD_DIR .. "config.txt",
    COMBO_RULES_JSON_PATH   = MOD_DIR .. "combo_rules.json",
    COMBO_RULES_PATH        = MOD_DIR .. "combo_rules.txt",
    SPELL_NAMES_PATH        = MOD_DIR .. "spell_names.txt",
    CUSTOM_SPELLS_JSON_PATH = MOD_DIR .. "custom_spells.json",
    CUSTOM_SPELLS_PATH      = MOD_DIR .. "custom_spells.txt",
    QUICK_CAST_PATH         = MOD_DIR .. "quick_cast.txt",
    DETECTED_PATH           = MOD_DIR .. "detected_spells.txt",
    DETECTED_VFX_PATH       = MOD_DIR .. "detected_vfx.txt",
    VFX_NAMES_PATH          = MOD_DIR .. "vfx_names.txt"
}

local SpellScanner   = require("spell_scanner")
local CustomSpells   = require("custom_spells")
local TimelineRunner = require("timeline_runner")
local ConfigManager  = require("config_manager")
local EquipmentRunes = require("equipment_runes")
local CombatEngine   = require("combat_engine")
local ProgressionScaling = require("progression_scaling")
local InputBlocker   = require("input_blocker")

local Config = ConfigManager.CreateDefaultConfig()

local State = {
    ModifierHeld = false,
    AnchorElement = nil,
    LastKnownEquippedElement = nil,
    LastKnownWeaponSuffix = "",
    HasMagicWeaponEquipped = false,
    LastKnownWeaponName = nil,
    LastKnownRuneName = nil,
    ActiveMacro = nil,
    StageIndex = 1,
    StepInStage = 1,
    LastObservedChainedSpell = nil,
    LastCastSpellData = nil,
    StepInFlight = false,
    InFlightSpellObj = nil,
    InFlightStartedTime = 0,
    ActiveStageTargetSpeed = 1.0,
    ActiveStageIsAirSmash = false,
    PendingAnchorReturn = false,
    LastAutoAttackTime = 0,
    LastTriggeredSpellTime = 0,
    LastConfigPollTime = 0,
    LastScanTime = 0,
    LastSpellNamesRaw = nil,
    LastCustomSpellsRaw = nil,
    LastComboRulesRaw = nil,
    LastQuickCastRaw = nil,
    LastRulesStatusWritten = "",
    LastQuickCastStatusWritten = "",
    LastDetectedSummaryWritten = "",
    BoundDebugKey = nil,
    SpellChains = {},
    AllChainsList = {},
    SpellRegistry = {},
    BaseSpellRegistry = {},
    CustomSpellDefs = {},
    DiscoveredLookup = {},
    RuneItemDataCache = {},
    NameMapByCat = {},
    GlobalNameMap = {},
    ParsedMacros = {},
    QuickCastBindings = {},
    ActiveTimelines = {},
    VfxPathLookup = {},
    LastVfxScanTime = 0
}

local function Log(msg)
    print("[ArcaneWilds] " .. tostring(msg) .. "\n")
end

local function DebugLog(msg)
    if Config.DebugMode then
        print("[ArcaneWilds][DEBUG] " .. tostring(msg) .. "\n")
    end
end

local function RefreshVfxCatalog(forceLog)
    local lookup = TimelineRunner.ExportLoadedVfxFile(
        Paths.DETECTED_VFX_PATH,
        forceLog and Log or DebugLog,
        State.VfxPathLookup)
    -- Overlay optional user-defined friendly aliases from vfx_names.txt on top
    TimelineRunner.LoadVfxCatalogFile(Paths.VFX_NAMES_PATH, lookup)
    State.VfxPathLookup = lookup
end

local function RefreshSpells()
    local chains, ordered, registry, _, summary = SpellScanner.ScanAndPatchSpells(
        Config, MOD_VERSION, Paths.DETECTED_PATH, State.NameMapByCat, State.GlobalNameMap, Log)
    State.SpellChains = chains
    State.AllChainsList = ordered
    State.BaseSpellRegistry = registry
    CustomSpells.ClearCache()
    ConfigManager.RebuildMergedRegistry(State)
    EquipmentRunes.DiscoverRuneItemAssets(State)

    if summary ~= State.LastDetectedSummaryWritten then
        State.LastDetectedSummaryWritten = summary
        Config.DetectedSpellsSummary = summary
        ConfigManager.SaveConfigFile(Paths, Config)
    end

    if State.LastValidComboRulesRaw then
        local RuleParser = require("rule_parser")
        local parsed, err = RuleParser.ParseWeightedMacros(
            State.LastValidComboRulesRaw, State.NameMapByCat, State.GlobalNameMap, State.DiscoveredLookup)
        if parsed and not err then
            State.ParsedMacros = parsed
        end
    end
    if Config.DebugMode and not State._LoggedInitialSpellMap and next(State.SpellRegistry) ~= nil then
        State._LoggedInitialSpellMap = true
        ConfigManager.LogParsedMacrosSpellMapping(Config, State, Log, "Initial Spell Scan -> Direct Spell Asset Mapping")
    end

    local now = os.clock()
    if State.LastVfxScanTime == 0 or (now - State.LastVfxScanTime) >= 12.0 then
        State.LastVfxScanTime = now
        RefreshVfxCatalog(State._ExportedVfxOnce ~= true)
        State._ExportedVfxOnce = true
    end
end

local function GetPlayerPawnAndComponents()
    local pc = FindFirstOf("DominionPlayerController") or FindFirstOf("PlayerController")
    if not pc or not pc:IsValid() then return nil, nil, nil, nil end
    local pawn = nil
    pcall(function() pawn = pc.Pawn end)
    if not pawn or not pawn:IsValid() then return pc, nil, nil, nil end

    local combatMagic = nil
    local actionPerformer = nil
    pcall(function() combatMagic = pawn.PlayerCombatMagicComponent end)
    pcall(function() actionPerformer = pawn.PlayerActionPerformerComponent end)
    return pc, pawn, combatMagic, actionPerformer
end

local function RunDebugInspection()
    if not Config.AllowDebugCommands then return end
    ConfigManager.LoadConfigFile(Paths, Config, State, Log, true)
    RefreshSpells()
    Log("=== DEBUG DUMP (combo_rules.json, custom_spells.json & spell_names.txt reloaded; detected_spells.txt updated) ===")
    local pc, pawn, combatMagic, actionPerformer = GetPlayerPawnAndComponents()
    if pawn and pawn:IsValid() then
        EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, State, DebugLog)
    end
    Log("HasMagicWeapon=" .. tostring(State.HasMagicWeaponEquipped)
        .. " (" .. tostring(State.LastKnownWeaponName or "None") .. ")"
        .. " | EquippedRune=" .. tostring(State.LastKnownRuneName or "None")
        .. " | AnchorCategory=" .. tostring(State.AnchorElement)
        .. " | LastKnownEquipped=" .. tostring(State.LastKnownEquippedElement)
        .. " | LoadedRules=" .. tostring(#State.ParsedMacros))
    ProgressionScaling.LogDebugSummary(Config, State, pc, pawn, Log)
    Log("QuickCastInputBlocker: " .. InputBlocker.GetDebugStatus(State))
    ConfigManager.LogParsedMacrosSpellMapping(Config, State, Log, "SHIFT+DebugHotkey: Combo Rules -> Direct Spell Asset Mapping")
    if pawn and pawn:IsValid() then
        local targets = { combatMagic, actionPerformer, pawn.InputBuffer }
        for _, obj in ipairs(targets) do
            if obj and obj:IsValid() then
                Log("Component: " .. SpellScanner.SafeGetName(obj))
            end
        end
        TimelineRunner.InspectPlayerAnimSlotsAndMontages(pawn, Log)
        local airChain = State.SpellChains and State.SpellChains["air"]
        if airChain and airChain.steps then
            if airChain.steps[0] then SpellScanner.DumpSpellModules(airChain.steps[0], "Air_01 (Reference)", Log) end
            if airChain.steps[3] then SpellScanner.DumpSpellModules(airChain.steps[3], "Air_04 (4th Finisher)", Log) end
        end
        RefreshVfxCatalog(true)
    end
end

local CANDIDATE_KEY_NAMES = {
    "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
    "BackSlash", "Slash", "Semicolon", "Apostrophe", "LeftBracket", "RightBracket",
    "Period", "Comma", "Minus", "Equals", "Grave", "Insert", "Delete", "Home", "End", "PageUp", "PageDown",
    "NumPadZero", "NumPadOne", "NumPadTwo", "NumPadThree", "NumPadFour",
    "NumPadFive", "NumPadSix", "NumPadSeven", "NumPadEight", "NumPadNine",
    "ThumbMouseButton", "ThumbMouseButton2"
}

local FRIENDLY_KEY_ALIASES = {
    ["\\"] = "BackSlash",
    ["BACKSLASH"] = "BackSlash",
    ["OEM_5"] = "BackSlash",
    ["/"] = "Slash",
    ["FORWARDSLASH"] = "Slash",
    ["`"] = "Grave",
    ["TILDE"] = "Grave",
    ["MOUSE4"] = "ThumbMouseButton",
    ["MB4"] = "ThumbMouseButton",
    ["MOUSE5"] = "ThumbMouseButton2",
    ["MB5"] = "ThumbMouseButton2",
    ["MMB"] = "MiddleMouseButton",
    ["LMB"] = "LeftMouseButton",
    ["RMB"] = "RightMouseButton",
    ["MWHEELUP"] = "MouseScrollUp",
    ["MOUSEWHEELUP"] = "MouseScrollUp",
    ["MWHEELDOWN"] = "MouseScrollDown",
    ["MOUSEWHEELDOWN"] = "MouseScrollDown",
    ["TAB"] = "Tab",
    ["SPACE"] = "SpaceBar",
    ["SPACEBAR"] = "SpaceBar",
    ["ENTER"] = "Enter",
    ["CAPSLOCK"] = "CapsLock",
    ["0"] = "Zero",
    ["1"] = "One",
    ["2"] = "Two",
    ["3"] = "Three",
    ["4"] = "Four",
    ["5"] = "Five",
    ["6"] = "Six",
    ["7"] = "Seven",
    ["8"] = "Eight",
    ["9"] = "Nine",
    ["NUM0"] = "NumPadZero",
    ["NUM1"] = "NumPadOne",
    ["NUM2"] = "NumPadTwo",
    ["NUM3"] = "NumPadThree",
    ["NUM4"] = "NumPadFour",
    ["NUM5"] = "NumPadFive",
    ["NUM6"] = "NumPadSix",
    ["NUM7"] = "NumPadSeven",
    ["NUM8"] = "NumPadEight",
    ["NUM9"] = "NumPadNine",
    ["GP_X"] = "Gamepad_FaceButton_Left",
    ["GAMEPAD_X"] = "Gamepad_FaceButton_Left",
    ["CONTROLLER_X"] = "Gamepad_FaceButton_Left",
    ["GP_Y"] = "Gamepad_FaceButton_Top",
    ["GAMEPAD_Y"] = "Gamepad_FaceButton_Top",
    ["CONTROLLER_Y"] = "Gamepad_FaceButton_Top",
    ["GP_B"] = "Gamepad_FaceButton_Right",
    ["GAMEPAD_B"] = "Gamepad_FaceButton_Right",
    ["CONTROLLER_B"] = "Gamepad_FaceButton_Right",
    ["GP_A"] = "Gamepad_FaceButton_Bottom",
    ["GAMEPAD_A"] = "Gamepad_FaceButton_Bottom",
    ["CONTROLLER_A"] = "Gamepad_FaceButton_Bottom",
    ["GP_LB"] = "Gamepad_LeftShoulder",
    ["GP_RB"] = "Gamepad_RightShoulder",
    ["GP_LT"] = "Gamepad_LeftTrigger",
    ["GP_RT"] = "Gamepad_RightTrigger",
    ["GP_UP"] = "Gamepad_DPad_Up",
    ["DPAD_UP"] = "Gamepad_DPad_Up",
    ["GP_DOWN"] = "Gamepad_DPad_Down",
    ["DPAD_DOWN"] = "Gamepad_DPad_Down",
    ["GP_LEFT"] = "Gamepad_DPad_Left",
    ["DPAD_LEFT"] = "Gamepad_DPad_Left",
    ["GP_RIGHT"] = "Gamepad_DPad_Right",
    ["DPAD_RIGHT"] = "Gamepad_DPad_Right"
}

local function NormalizeKeyName(raw)
    local trimmed = tostring(raw or ""):gsub("^%s*(.-)%s*$", "%1")
    if trimmed == "" then return "" end
    local up = trimmed:upper()
    if FRIENDLY_KEY_ALIASES[up] then
        return FRIENDLY_KEY_ALIASES[up]
    end
    if #trimmed == 1 and trimmed:match("%a") then
        return up
    end
    return trimmed
end

local function ParseKeyList(rawStr)
    local keys = {}
    local s = tostring(rawStr or "")
    for token in s:gmatch("[^,|;]+") do
        local k = NormalizeKeyName(token)
        if k ~= "" then
            table.insert(keys, k)
        end
    end
    return keys
end

local function GetQuickCastBindingsList()
    if State.QuickCastBindings and #State.QuickCastBindings > 0 then
        return State.QuickCastBindings
    end
    local fallback = {}
    local defaultMod = (Config.QuickCastRequireModifier ~= false) and "BLOCK" or "NONE"
    for i = 1, 4 do
        local kStr = tostring(Config["QuickCastHotkey" .. i] or ""):gsub("^%s*(.-)%s*$", "%1")
        local spStr = tostring(Config["QuickCastSpell" .. i] or ""):gsub("^%s*(.-)%s*$", "%1")
        if kStr ~= "" and spStr ~= "" then
            table.insert(fallback, {
                modifier = defaultMod,
                keysRaw = kStr,
                target = spStr,
                isCombo = (spStr:find("@", 1, true) ~= nil) or (spStr:find("->", 1, true) ~= nil)
            })
        end
    end
    return fallback
end

local function IsQuickCastModifierSatisfied(pc, modName)
    local m = tostring(modName or "NONE"):upper()
    if m == "NONE" or m == "" then return true end
    if m == "BLOCK" or m == "RMB" or m == "MODIFIER" then
        return State.ModifierHeld == true
    end
    local down = false
    pcall(function()
        if m == "SHIFT" then
            down = pc:IsInputKeyDown({ KeyName = FName("LeftShift") }) or pc:IsInputKeyDown({ KeyName = FName("RightShift") })
        elseif m == "ALT" then
            down = pc:IsInputKeyDown({ KeyName = FName("LeftAlt") }) or pc:IsInputKeyDown({ KeyName = FName("RightAlt") })
        elseif m == "CTRL" or m == "CONTROL" then
            down = pc:IsInputKeyDown({ KeyName = FName("LeftControl") }) or pc:IsInputKeyDown({ KeyName = FName("RightControl") })
        else
            local norm = NormalizeKeyName(m)
            if norm ~= "" then
                down = pc:IsInputKeyDown({ KeyName = FName(norm) })
            end
        end
    end)
    return down
end

local function SyncQuickCastInputSuppression(pc)
    if not pc or not pc:IsValid() then
        InputBlocker.Clear(State, Log, DebugLog)
        return false
    end
    return InputBlocker.Sync(
        Config,
        State,
        pc,
        GetQuickCastBindingsList(),
        ParseKeyList,
        IsQuickCastModifierSatisfied,
        NormalizeKeyName,
        Log,
        DebugLog
    )
end

local function ResolveQuickCastEntry(spellName)
    local clean = tostring(spellName or ""):gsub("^%s*(.-)%s*$", "%1")
    if clean == "" then return nil end
    local low = clean:lower()
    if State.SpellRegistry[low] then
        return State.SpellRegistry[low]
    end
    if State.GlobalNameMap and State.GlobalNameMap[low] then
        local mapped = State.GlobalNameMap[low]:lower()
        if State.SpellRegistry[mapped] then
            return State.SpellRegistry[mapped]
        end
    end
    if State.CustomSpellDefs and State.CustomSpellDefs[low] then
        local rebuilt = CustomSpells.BuildCustomRegistryEntries(
            { [low] = State.CustomSpellDefs[low] },
            State.SpellRegistry, State.SpellChains, State.RuneItemDataCache,
            SpellScanner.SafeGetName, SpellScanner.ExtractShortObjectName)
        if rebuilt[low] then
            State.SpellRegistry[low] = rebuilt[low]
            return rebuilt[low]
        end
    end
    return nil
end

local function PollQuickCastHotkeys(now, pc, pawn, combatMagic)
    if Config.EnableQuickCastHotkeys == false then
        InputBlocker.Clear(State, Log, DebugLog)
        return false
    end
    if not pc or not pc:IsValid() or not pawn or not pawn:IsValid() then return false end

    local bindings = GetQuickCastBindingsList()
    SyncQuickCastInputSuppression(pc)

    State._QuickCastPrevDown = State._QuickCastPrevDown or {}
    local firedAny = false

    for idx, binding in ipairs(bindings) do
        local keyList = ParseKeyList(binding.keysRaw)
        local targetStr = tostring(binding.target or ""):gsub("^%s*(.-)%s*$", "%1")
        if #keyList > 0 and targetStr ~= "" then
            local anyDown = false
            local triggeredKey = nil
            for _, keyName in ipairs(keyList) do
                local isDown = false
                pcall(function()
                    isDown = pc:IsInputKeyDown({ KeyName = FName(keyName) })
                end)
                if isDown then
                    anyDown = true
                    triggeredKey = keyName
                    break
                end
            end
            local wasDown = State._QuickCastPrevDown[idx] == true
            State._QuickCastPrevDown[idx] = anyDown

            local effMod = binding.modifier
            if Config.QuickCastRequireModifier == false and (effMod == "BLOCK" or effMod == "RMB" or effMod == "MODIFIER") then
                effMod = "NONE"
            end
            local modOk = IsQuickCastModifierSatisfied(pc, effMod)

            if anyDown and not wasDown and modOk and not firedAny then
                if (now - (State._LastQuickCastTime or 0)) >= 0.35 then
                    local prefix = (effMod and effMod ~= "NONE") and (effMod .. "+") or ""
                    if binding.isCombo then
                        local RuleParser = require("rule_parser")
                        local ruleStr = targetStr:match(";$") and targetStr or (targetStr .. ";")
                        local parsed = RuleParser.ParseWeightedMacros(ruleStr, State.NameMapByCat, State.GlobalNameMap, State.DiscoveredLookup)
                        if parsed and parsed[1] then
                            local macroUnlocked, lockInfo = ProgressionScaling.CheckMacroUnlocked(
                                Config, pc, pawn, State, parsed[1], ConfigManager.ResolveStepEntry)
                            if not macroUnlocked then
                                State._LastQuickCastTime = now
                                ProgressionScaling.NotifySpellLocked(Config, pc, pawn, lockInfo, Log)
                                firedAny = true
                            else
                                State._LastQuickCastTime = now
                                State.ActiveMacro = parsed[1]
                                State.StageIndex = 1
                                State.StepInStage = 1
                                State.StepInFlight = false
                                State.InFlightSpellObj = nil
                                State._LastTriggeredSpellPtr = nil
                                Log(string.format("QuickCast #%d [%s%s] -> Combo: %s", idx, prefix, tostring(triggeredKey), targetStr))
                                local st1 = parsed[1].stages[1]
                                local sd1 = st1 and st1.steps[1]
                                local ent1 = sd1 and ConfigManager.ResolveStepEntry(State, st1, sd1)
                                CombatEngine.ApplyStageSpeedAndPriming(Config, State, combatMagic, st1, 1, pawn, DebugLog)
                                if ent1 then
                                    State.LastAutoAttackTime = now
                                    State.LastTriggeredSpellTime = now
                                    State.StepInFlight = true
                                    State.InFlightSpellObj = ent1.spellObj
                                    State.InFlightStartedTime = now
                                    CombatEngine.TriggerSpellEntryForPlayer(Config, State, pawn, ent1, DebugLog, combatMagic, true)
                                end
                                firedAny = true
                            end
                        else
                            Log(string.format("QuickCast #%d [%s%s]: combo '%s' failed to parse", idx, prefix, tostring(triggeredKey), targetStr))
                        end
                    else
                        local entry = ResolveQuickCastEntry(targetStr)
                        if entry then
                            local spellUnlocked, lockInfo = ProgressionScaling.CheckSpellUnlocked(Config, pc, pawn, entry)
                            if not spellUnlocked then
                                State._LastQuickCastTime = now
                                ProgressionScaling.NotifySpellLocked(Config, pc, pawn, lockInfo, Log)
                                firedAny = true
                            else
                                State._LastQuickCastTime = now
                                State.LastAutoAttackTime = now
                                State.LastTriggeredSpellTime = now
                                State._LastTriggeredSpellPtr = nil
                                State.StepInFlight = false
                                State.InFlightSpellObj = nil
                                Log(string.format("QuickCast #%d [%s%s] -> %s", idx, prefix, tostring(triggeredKey), tostring(entry.shortName or targetStr)))
                                CombatEngine.TriggerSpellEntryForPlayer(Config, State, pawn, entry, DebugLog, combatMagic, true)
                                firedAny = true
                            end
                        else
                            Log(string.format("QuickCast #%d [%s%s]: spell '%s' not found in loaded/custom spells", idx, prefix, tostring(triggeredKey), targetStr))
                        end
                    end
                end
            end
        else
            State._QuickCastPrevDown[idx] = false
        end
    end

    return firedAny
end

local function PollHotkeyListener(pc)
    if not State.ListeningForDebugHotkey then return end
    if not pc or not pc:IsValid() then return end
    if (os.clock() - (State.ListenerStartedAt or 0)) < 0.25 then return end

    for _, kName in ipairs(CANDIDATE_KEY_NAMES) do
        local pressed = false
        pcall(function()
            pressed = pc:IsInputKeyDown({ KeyName = FName(kName) })
        end)
        if pressed then
            State.ListeningForDebugHotkey = false
            Config.DebugHotkey = kName
            State.BoundDebugKey = nil
            ConfigManager.SaveConfigFile(Paths, Config)
            Log("Captured new DebugHotkey via input listener: [" .. kName .. "] (saved to config.txt; press SHIFT + " .. kName .. " for debug dump)")
            return
        end
    end
end

local function StartHotkeyListener()
    if State.ListeningForDebugHotkey then return end
    State.ListeningForDebugHotkey = true
    State.ListenerStartedAt = os.clock()
    Log("Hotkey listener ACTIVE: press any bindable key (e.g. F9, F10, BackSlash, Insert, NumPadOne) to bind DebugHotkey...")
end

local function BindDebugHotkey()
    local rawTrim = tostring(Config.DebugHotkey or "BackSlash"):gsub("^%s*(.-)%s*$", "%1")
    local upper = rawTrim:upper()
    if upper == "LISTEN" or upper == "BIND" or upper == "CAPTURE" or upper == "?" then
        StartHotkeyListener()
        return
    end
    State.ListeningForDebugHotkey = false

    local normalized = NormalizeKeyName(rawTrim)
    if State.BoundDebugKey == normalized then return end
    State.BoundDebugKey = normalized

    local keyEnum = Key[normalized] or Key[upper] or Key.BackSlash or Key.OEM_5
    pcall(function()
        RegisterKeyBind(keyEnum, { ModifierKey.SHIFT }, function()
            if Config.AllowDebugCommands then
                ExecuteInGameThread(function() RunDebugInspection() end)
            end
        end)
    end)
    Log("Debug dump hotkey bound to: SHIFT + " .. tostring(normalized) .. " (set DebugHotkey=LISTEN in config.txt to rebind interactively)")
end

local function TickAnchorReturn(now, pc, pawn, combatMagic)
    local anchor = EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, State, DebugLog)
    local wantsComboContinue = State.ModifierHeld and ((Config.TriggerComboOnModifierHold == true) or CombatEngine.IsPrimaryAttackDown(pc))
    if not anchor or not wantsComboContinue then
        State.PendingAnchorReturn = false
        if not State.ActiveMacro then
            State.StepInFlight = false
            State.InFlightSpellObj = nil
        end
        return
    end
    local anchorChain = State.SpellChains[anchor:lower()]
    local starterName = anchorChain and anchorChain.stepNames and anchorChain.stepNames[0]
    local starterEntry = starterName and State.SpellRegistry[starterName:lower()]

    local curActor = nil
    pcall(function()
        local actor = combatMagic.CurrentSpellActor
        if actor and actor:IsValid() then curActor = actor end
    end)

    if not State.StepInFlight then
        if not curActor and (now - (State.LastTriggeredSpellTime or 0)) >= 0.16 then
            local targetEntry = (starterEntry and starterEntry.spellObj and starterEntry.spellObj:IsValid())
                and starterEntry
                or (anchor and State.SpellRegistry[anchor:lower()])
            if targetEntry and targetEntry.spellObj and targetEntry.spellObj:IsValid() then
                if CombatEngine.TriggerSpellEntryForPlayer(Config, State, pawn, targetEntry, DebugLog, combatMagic) then
                    State.LastTriggeredSpellTime = now
                    State.LastAutoAttackTime = now
                    State.StepInFlight = true
                    State.InFlightSpellObj = targetEntry.spellObj
                    State.InFlightStartedTime = now
                    DebugLog("Casting return-to-anchor spell [" .. tostring(anchor) .. "] before any re-roll")
                end
            else
                State.PendingAnchorReturn = false
                if wantsComboContinue then
                    CombatEngine.RollAndEngageMacroForAnchor(Config, State, pawn, combatMagic, anchor, Log, DebugLog)
                end
            end
        end
    else
        local retElapsed = now - (State.InFlightStartedTime or now)
        local returnCastDone = (curActor == nil) and (retElapsed >= 0.35)
        local returnTimeout = retElapsed >= 3.0
        if returnCastDone or returnTimeout then
            State.StepInFlight = false
            State.InFlightSpellObj = nil
            State.PendingAnchorReturn = false
            pcall(function() combatMagic.LastChainedSpell = nil end)
            if wantsComboContinue then
                DebugLog("Anchor return cast finished -> Re-rolling combo strictly from [" .. tostring(anchor) .. "]")
                CombatEngine.RollAndEngageMacroForAnchor(Config, State, pawn, combatMagic, anchor, Log, DebugLog)
            else
                DebugLog("Anchor return cast finished (Attack/Modifier released) -> Staying cleanly on [" .. tostring(anchor) .. "]")
            end
        end
    end
end

local function TickActiveMacro(now, pawn, combatMagic)
    local curActor, curActorData = nil, nil
    pcall(function()
        local actor = combatMagic.CurrentSpellActor
        if actor and actor:IsValid() then
            curActor = actor
            if actor.Data and actor.Data:IsValid() then curActorData = actor.Data end
        end
    end)

    local curStage = State.ActiveMacro.stages[State.StageIndex]
    if not curStage then return end

    local expectedDesc = curStage.steps[State.StepInStage] or curStage.steps[1]
    local expectedEntry = ConfigManager.ResolveStepEntry(State, curStage, expectedDesc)

    local curMont = CombatEngine.GetActiveMontageObj(pawn)
    if curMont then
        State.LastActiveMontageObj = curMont
        if not State.LastActiveMontageSeenAt then
            State.LastActiveMontageSeenAt = now
        end
    else
        State.LastActiveMontageSeenAt = nil
    end

    -- If this step's montage is already running from a previous combo (or just finished within AnimRepeatPadSec),
    -- pad the wait time before applying fast rate / triggering so the first hit stays fast and repeat hits pad cleanly.
    -- Skip repeat padding for explicit parallel-overlap custom timelines (e.g. rapid-fire StormOfArmadyl).
    local isParallelCustom = expectedEntry and expectedEntry.isCustomSpell and expectedEntry.hasTimeline
        and expectedEntry.timeline and ((expectedEntry.timeline.overlapPolicy or "replace"):lower() == "parallel")
    local padWindow = math.max(0.0, tonumber(Config.AnimRepeatPadSec) or 0.45)
    if expectedEntry and expectedEntry.montageObj and padWindow > 0 and not isParallelCustom then
        local sameMontRunning = (curMont and curMont == expectedEntry.montageObj)
        local recentSameMont = (State.LastActiveMontageObj == expectedEntry.montageObj)
            and ((now - (State.LastActiveMontageSeenAt or now)) < padWindow)
        if (sameMontRunning or recentSameMont) and not State._AppliedPadForCurrentStep then
            State._AppliedPadForCurrentStep = true
            State.AnimPadUntil = math.max(State.AnimPadUntil or 0, now + padWindow)
            DebugLog(string.format("Padding repeat animation [%s] for %.2fs (preventing overlap from previous combo)",
                tostring(expectedEntry.montageName or "Montage"), padWindow))
        end
    end

    if (State.AnimPadUntil or 0) > now then
        return
    end

    if curActor and (State.ActiveStageTargetSpeed or 1.0) > 1.0 then
        if expectedEntry and expectedEntry.isSpecialSpell then
            if Config.AllowFastSpecialCast ~= false then
                local capRate = math.max(1.0, tonumber(Config.MaxSpecialCastRate) or 1.8)
                local fastSpecRate = math.min(State.ActiveStageTargetSpeed, capRate)
                CombatEngine.ApplyMontageRateToInstance(
                    Config, pawn, expectedEntry.montageObj, fastSpecRate, false)
            end
        else
            CombatEngine.ApplyMontageRateToInstance(
                Config, pawn, expectedEntry and expectedEntry.montageObj,
                State.ActiveStageTargetSpeed, State.ActiveStageIsAirSmash)
        end
    end

    if curActorData and expectedEntry and expectedEntry.spellObj and curActorData == expectedEntry.spellObj then
        if not State.StepInFlight or State.InFlightSpellObj ~= curActorData then
            State.StepInFlight = true
            State.InFlightSpellObj = curActorData
            State.InFlightStartedTime = now
            State.LastCastSpellData = curActorData
        end
    end

    if State.StepInFlight then
        local elapsed = now - (State.InFlightStartedTime or now)
        local isSpecialInFlight = expectedEntry and expectedEntry.isSpecialSpell
        local isSuppressStep = expectedEntry and expectedEntry.suppressBaseSpell
        -- Special spells spawn persistent actors; advance after initial windup.
        -- Timeline-backed suppress-base-spell steps advance on StepAdvanceAt or when the timeline completes.
        local stillPlayingMontage = (CombatEngine.GetActiveMontageObj(pawn) ~= nil)
        local specialCastReady = isSpecialInFlight and (elapsed >= 1.10 or (elapsed >= 0.85 and not stillPlayingMontage))
        local suppressStepReady = false
        local stepSafetyCap = 4.5
        if isSuppressStep then
            if expectedEntry and expectedEntry.hasTimeline then
                local estDur = expectedEntry.timeline and expectedEntry.timeline.estimatedDuration or 1.0
                stepSafetyCap = math.max(4.5, estDur + 2.5)
                suppressStepReady = (elapsed >= 0.12) and (not TimelineRunner.IsSpellTimelineBusy(State, expectedEntry, now))
            else
                suppressStepReady = (elapsed >= 0.65)
            end
        end
        local castCompleted = suppressStepReady or (not isSuppressStep and ((curActor == nil and elapsed >= 0.20) or (curActorData ~= nil and curActorData ~= State.InFlightSpellObj) or specialCastReady))
        local safetyTimeout = elapsed >= stepSafetyCap
        if castCompleted or safetyTimeout then
            if isSpecialInFlight then
                local pauseSec = math.max(0.0, tonumber(Config.PostSpecialPauseSec) or 0.65)
                if pauseSec > 0 then
                    State.SpecialPostPauseUntil = now + pauseSec
                    DebugLog(string.format("Pausing %.2fs after special sequence before next step/cycle", pauseSec))
                end
            end
            State.StepInFlight = false
            State.InFlightSpellObj = nil
            State._AppliedPadForCurrentStep = false
        CombatEngine.AdvanceLockedMacro(Config, State, pawn, combatMagic, DebugLog)
        end
    else
        local curChained = nil
        pcall(function() curChained = combatMagic.LastChainedSpell end)
        if curChained and curChained:IsValid() and curChained ~= State.LastObservedChainedSpell then
            State.LastObservedChainedSpell = curChained
            if not curActor then
                State._AppliedPadForCurrentStep = false
        CombatEngine.AdvanceLockedMacro(Config, State, pawn, combatMagic, DebugLog)
            end
        end
    end
end

local function TickAutoAttack(now, pc, pawn, combatMagic)
    local atkDown = CombatEngine.IsPrimaryAttackDown(pc)
    State.PrimaryAttackHeld = atkDown
    local modAutoTrigger = (Config.TriggerComboOnModifierHold == true) and State.ModifierHeld and (State.ActiveMacro ~= nil)
    local modAtkTrigger = State.ModifierHeld and atkDown
    local holdAtkTrigger = Config.EnableAutoAttackHold and atkDown and (State.ModifierHeld or Config.AutoAttackAllCombos)
    if not modAutoTrigger and not modAtkTrigger and not holdAtkTrigger then
        return
    end

    -- When holding Block/Modifier and pressing normal Attack, roll & lock the matching combo
    -- immediately from equipped staff/wand + equipped runes (no prior cast needed).
    if State.ModifierHeld and not State.ActiveMacro and not State.PendingAnchorReturn and atkDown then
        if (now - (State._LastIdleComboReRollTime or 0)) >= 0.20 then
            State._LastIdleComboReRollTime = now
            CombatEngine.EngageModifierAndRollMacro(Config, State, pawn, combatMagic, Log, DebugLog)
        end
    end

    local intervalSec = math.max(0.10, (tonumber(Config.AutoAttackIntervalMs) or 65) / 1000.0)
    if (State.SpecialPostPauseUntil or 0) > now or (State.AnimPadUntil or 0) > now then
        return
    end
    if State.StepInFlight or (now - State.LastAutoAttackTime) < intervalSec then
        return
    end

    local isBusy = false
    if combatMagic and combatMagic:IsValid() then
        pcall(function()
            local actor = combatMagic.CurrentSpellActor
            if actor and actor:IsValid() then isBusy = true end
        end)
    end

    if State.ModifierHeld and State.ActiveMacro and (atkDown or Config.TriggerComboOnModifierHold == true) then
        local st = State.ActiveMacro.stages[State.StageIndex]
        local sd = st and (st.steps[State.StepInStage] or st.steps[1])
        local entry = sd and ConfigManager.ResolveStepEntry(State, st, sd)
        if not entry then return end
        local isParallelTimeline = entry.isCustomSpell and entry.hasTimeline and entry.timeline
            and ((entry.timeline.overlapPolicy or "replace"):lower() == "parallel")
        local minTriggerGap = entry.isSpecialSpell and 0.45 or (isParallelTimeline and 0.12 or 0.25)
        if (isBusy and not isParallelTimeline) or (now - (State.LastTriggeredSpellTime or 0)) < minTriggerGap then
            return
        end
        if CombatEngine.TriggerSpellEntryForPlayer(Config, State, pawn, entry, DebugLog, combatMagic) then
            State.LastAutoAttackTime = now
            State.LastTriggeredSpellTime = now
            State.StepInFlight = true
            State.InFlightSpellObj = entry.spellObj
            State.InFlightStartedTime = now
        end
    elseif holdAtkTrigger and not State.ModifierHeld then
        if isBusy or (now - (State.LastTriggeredSpellTime or 0)) < 0.35 then
            return
        end
        local anchor = EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, State, DebugLog)
        if not anchor then return end
        local _, mappedSpell = CombatEngine.ResolveClosestElementSpellAndCategory(State, anchor, State.LastKnownWeaponSuffix)
        local chain = anchor and State.SpellChains[anchor:lower()]
        local starterName = (mappedSpell) or (chain and chain.stepNames and chain.stepNames[0])
        local starterEntry = starterName and State.SpellRegistry[starterName:lower()]
        if starterEntry and starterEntry.spellObj and starterEntry.spellObj:IsValid() then
            if CombatEngine.TriggerSpellEntryForPlayer(Config, State, pawn, starterEntry, DebugLog, combatMagic) then
                State.PendingAnchorReturn = false
                State.LastAutoAttackTime = now
                State.LastTriggeredSpellTime = now
                State.StepInFlight = true
                State.InFlightSpellObj = starterEntry.spellObj
                State.InFlightStartedTime = now
            end
        end
    end
end

-- All UObject access, input polling, spell triggers, montage playback, and timeline ticks run
-- inside a SINGLE serialized Game-Thread tick to prevent UE4SS Lua/UObject concurrency crashes (0xC0000005).
local function RunMainGameThreadTick()
    local now = os.clock()
    if (now - State.LastConfigPollTime) >= 0.30 then
        State.LastConfigPollTime = now
        ConfigManager.LoadConfigFile(Paths, Config, State, Log, false)
        State.Enabled = Config.Enabled
        BindDebugHotkey()
    end
    State.Enabled = Config.Enabled

    if not Config.Enabled then
        InputBlocker.Clear(State, Log, DebugLog)
        CustomSpells.ClearAllCrowdControl(DebugLog)
        return
    end

    local pc, pawn, combatMagic = GetPlayerPawnAndComponents()
    if not pc then
        InputBlocker.Clear(State, Log, DebugLog)
        return
    end
    PollHotkeyListener(pc)
    if not pawn then
        InputBlocker.Clear(State, Log, DebugLog)
        return
    end

    local curPawnId = SpellScanner.SafeGetName(pawn)
    if State._LastPawnIdentity and curPawnId ~= "" and State._LastPawnIdentity ~= curPawnId then
        State._LastPawnIdentity = curPawnId
        State._WasPlayerDead = false
        InputBlocker.Clear(State, Log, DebugLog)
        CombatEngine.RecoverFromDeathOrRespawn(Config, State, combatMagic, pawn, Log, DebugLog, "pawn-changed")
    elseif curPawnId ~= "" then
        State._LastPawnIdentity = curPawnId
    end

    -- Detect player death / respawn immediately so ArcaneWilds NEVER triggers abilities or holds
    -- EnhancedInput blocker contexts while the player is dead (prevents stuck CastingTag / Block lockout!).
    local isDead = CombatEngine.IsPlayerDead(pawn)
    if isDead then
        if not State._WasPlayerDead then
            State._WasPlayerDead = true
            InputBlocker.Clear(State, Log, DebugLog)
            CombatEngine.RecoverFromDeathOrRespawn(Config, State, combatMagic, pawn, Log, DebugLog, "player-died")
        else
            InputBlocker.Clear(State, Log, DebugLog)
        end
        return
    elseif State._WasPlayerDead then
        State._WasPlayerDead = false
        InputBlocker.Clear(State, Log, DebugLog)
        CombatEngine.RecoverFromDeathOrRespawn(Config, State, combatMagic, pawn, Log, DebugLog, "player-respawned")
        EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, State, DebugLog)
    end
    if not State._InstalledEquipmentHooks then
        EquipmentRunes.InstallEquipmentSwapHooks(State, combatMagic, Log, DebugLog)
    end
    EquipmentRunes.EnsureEquipmentDelegates(pawn, combatMagic, State, DebugLog)

    if (now - State.LastScanTime) >= 3.0 then
        State.LastScanTime = now
        RefreshSpells()
    end

    if not State.ActiveMacro and not State.PendingAnchorReturn then
        EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, State, DebugLog)
    end

    local modDown = CombatEngine.IsModifierDown(Config, pc)
    State.PrimaryAttackHeld = CombatEngine.IsPrimaryAttackDown(pc)
    if modDown and not State.ModifierHeld then
        State.ModifierHeld = true
        State._AppliedPadForCurrentStep = false
        SyncQuickCastInputSuppression(pc)
        if Config.TriggerComboOnModifierHold == true then
            CombatEngine.EngageModifierAndRollMacro(Config, State, pawn, combatMagic, Log, DebugLog)
            if State.ActiveMacro and pawn and pawn:IsValid() then
                local st1 = State.ActiveMacro.stages[1]
                local sd1 = st1 and (st1.steps[1])
                local ent1 = sd1 and ConfigManager.ResolveStepEntry(State, st1, sd1)
                if ent1 and ((ent1.spellObj and ent1.spellObj:IsValid()) or ent1.suppressBaseSpell) then
                    if CombatEngine.TriggerSpellEntryForPlayer(Config, State, pawn, ent1, DebugLog, combatMagic) then
                        State.LastAutoAttackTime = now
                        State.LastTriggeredSpellTime = now
                        State.StepInFlight = true
                        State.InFlightSpellObj = ent1.spellObj
                        State.InFlightStartedTime = now
                    end
                end
            end
        end
    elseif not modDown and State.ModifierHeld then
        State.ModifierHeld = false
        SyncQuickCastInputSuppression(pc)
        State.StepInFlight = false
        State.InFlightSpellObj = nil
        State.SpecialPostPauseUntil = 0
        State.AnimPadUntil = 0
        State.LastTriggeredSpellTime = 0
        CustomSpells.StopForcedMontage(State, pawn)
        CombatEngine.ReleaseModifierAndRevert(Config, State, pawn, combatMagic, Log, DebugLog)
    end

    if not State.ModifierHeld then
        State.StepInFlight = false
        State.InFlightSpellObj = nil
        State.SpecialPostPauseUntil = 0
        State.AnimPadUntil = 0
        if State.LastForcedMontageObj ~= nil then
            CustomSpells.StopForcedMontage(State, pawn)
        end
    end

    local quickCastFired = PollQuickCastHotkeys(now, pc, pawn, combatMagic)

    if State.ActiveTimelines and #State.ActiveTimelines > 0 then
        TimelineRunner.Tick(now, Config, State, pawn, combatMagic, CustomSpells, SpellScanner.SafeGetName, DebugLog)
    end
    CustomSpells.TickCrowdControl(now, DebugLog)

    local inPostSpecialPause = (State.SpecialPostPauseUntil or 0) > now
    if not quickCastFired and State.PendingAnchorReturn and not State.ActiveMacro and not inPostSpecialPause and combatMagic and combatMagic:IsValid() then
        TickAnchorReturn(now, pc, pawn, combatMagic)
    end

    if not quickCastFired and State.ModifierHeld and State.ActiveMacro and combatMagic and combatMagic:IsValid() then
        TickActiveMacro(now, pawn, combatMagic)
    end

    CustomSpells.TickProjectileImpactAoE(State, pawn, combatMagic, Config)
    if not quickCastFired then
        TickAutoAttack(now, pc, pawn, combatMagic)
    end
end

-- Persistent module-level GameThread callback (never creates per-tick closures that UE4SS Lua registry can GC!)
local function RunMainGameThreadTickGuarded()
    local ok, err = pcall(RunMainGameThreadTick)
    State._TickInFlight = false
    if not ok then
        Log("[ERROR] Main tick error: " .. tostring(err))
    end
end

-- Single 25ms (~40Hz) scheduler with re-entrancy lock + 0.50s watchdog so a dropped UE4SS callback can NEVER stall hotkeys.
LoopAsync(25, function()
    local now = os.clock()
    if State._TickInFlight then
        if (now - (State._TickInFlightAt or 0)) < 0.50 then
            return false
        end
        -- Watchdog recovery: previous ExecuteInGameThread callback was dropped by UE4SS
        State._TickInFlight = false
    end
    State._TickInFlight = true
    State._TickInFlightAt = now
    if type(ExecuteInGameThread) == "function" then
        local ok = pcall(function() ExecuteInGameThread(RunMainGameThreadTickGuarded) end)
        if not ok then State._TickInFlight = false end
    else
        RunMainGameThreadTickGuarded()
    end
    return false
end)

NotifyOnNewObject("/Script/Dominion.DominionSpellData", function()
    if State._PendingSpellScan then return end
    State._PendingSpellScan = true
    ExecuteWithDelay(400, function()
        State._PendingSpellScan = false
        ExecuteInGameThread(function() RefreshSpells() end)
    end)
end)

ConfigManager.LoadConfigFile(Paths, Config, State, Log, true)
TimelineRunner.LoadVfxCatalogFile(Paths.DETECTED_VFX_PATH, State.VfxPathLookup)
TimelineRunner.LoadVfxCatalogFile(Paths.VFX_NAMES_PATH, State.VfxPathLookup)
EquipmentRunes.InstallEquipmentSwapHooks(State, nil, Log, DebugLog)
BindDebugHotkey()
Log("v" .. MOD_VERSION .. " initialized cleanly (modular architecture).")
