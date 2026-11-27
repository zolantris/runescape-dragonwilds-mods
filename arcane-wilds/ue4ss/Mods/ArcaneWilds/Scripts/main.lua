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
    CONFIG_PATH        = MOD_DIR .. "config.txt",
    COMBO_RULES_PATH   = MOD_DIR .. "combo_rules.txt",
    SPELL_NAMES_PATH   = MOD_DIR .. "spell_names.txt",
    CUSTOM_SPELLS_PATH = MOD_DIR .. "custom_spells.txt",
    QUICK_CAST_PATH    = MOD_DIR .. "quick_cast.txt",
    DETECTED_PATH      = MOD_DIR .. "detected_spells.txt"
}

local SpellScanner   = require("spell_scanner")
local CustomSpells   = require("custom_spells")
local TimelineRunner = require("timeline_runner")
local ConfigManager  = require("config_manager")
local EquipmentRunes = require("equipment_runes")
local CombatEngine   = require("combat_engine")

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
    ActiveTimelines = {}
}

local function Log(msg)
    print("[ArcaneWilds] " .. tostring(msg) .. "\n")
end

local function DebugLog(msg)
    if Config.DebugMode then
        print("[ArcaneWilds][DEBUG] " .. tostring(msg) .. "\n")
    end
end

local function RefreshSpells()
    local chains, ordered, registry, _, summary = SpellScanner.ScanAndPatchSpells(
        Config, MOD_VERSION, Paths.DETECTED_PATH, State.NameMapByCat, State.GlobalNameMap)
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

    if State.LastComboRulesRaw then
        local RuleParser = require("rule_parser")
        State.ParsedMacros = RuleParser.ParseWeightedMacros(
            State.LastComboRulesRaw, State.NameMapByCat, State.GlobalNameMap, State.DiscoveredLookup)
    end
    if Config.DebugMode and not State._LoggedInitialSpellMap and next(State.SpellRegistry) ~= nil then
        State._LoggedInitialSpellMap = true
        ConfigManager.LogParsedMacrosSpellMapping(Config, State, Log, "Initial Spell Scan -> Direct Spell Asset Mapping")
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
    Log("=== DEBUG DUMP (combo_rules.txt & spell_names.txt reloaded; detected_spells.txt updated) ===")
    local _, pawn, combatMagic, actionPerformer = GetPlayerPawnAndComponents()
    if pawn and pawn:IsValid() then
        EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, State, DebugLog)
    end
    Log("HasMagicWeapon=" .. tostring(State.HasMagicWeaponEquipped)
        .. " (" .. tostring(State.LastKnownWeaponName or "None") .. ")"
        .. " | EquippedRune=" .. tostring(State.LastKnownRuneName or "None")
        .. " | AnchorCategory=" .. tostring(State.AnchorElement)
        .. " | LastKnownEquipped=" .. tostring(State.LastKnownEquippedElement)
        .. " | LoadedRules=" .. tostring(#State.ParsedMacros))
    ConfigManager.LogParsedMacrosSpellMapping(Config, State, Log, "SHIFT+DebugHotkey: Combo Rules -> Direct Spell Asset Mapping")
    if pawn and pawn:IsValid() then
        local targets = { combatMagic, actionPerformer, pawn.InputBuffer }
        for _, obj in ipairs(targets) do
            if obj and obj:IsValid() then
                Log("Component: " .. SpellScanner.SafeGetName(obj))
            end
        end
        TimelineRunner.InspectPlayerAnimSlotsAndMontages(pawn, Log)
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
    ["GP_RT"] = "Gamepad_RightTrigger"
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

local function ResolveQuickCastBlockerAssets()
    if State._QuickCastIMC and State._QuickCastIMC:IsValid()
        and State._QuickCastIA and State._QuickCastIA:IsValid() then
        return State._QuickCastIMC, State._QuickCastIA
    end
    if State._TriedLoadQuickCastBlocker then
        return nil, nil
    end
    State._TriedLoadQuickCastBlocker = true

    local imc, ia = nil, nil
    pcall(function()
        imc = StaticFindObject("/Game/Mods/ArcaneWilds/IMC_ArcaneWildsQuickCastBlock.IMC_ArcaneWildsQuickCastBlock")
        ia  = StaticFindObject("/Game/Mods/ArcaneWilds/IA_ArcaneWildsKeyBlocker.IA_ArcaneWildsKeyBlocker")
    end)
    if (not imc or not imc:IsValid() or not ia or not ia:IsValid()) and type(LoadAsset) == "function" then
        pcall(function() LoadAsset("/Game/Mods/ArcaneWilds/IA_ArcaneWildsKeyBlocker.IA_ArcaneWildsKeyBlocker") end)
        pcall(function() LoadAsset("/Game/Mods/ArcaneWilds/IMC_ArcaneWildsQuickCastBlock.IMC_ArcaneWildsQuickCastBlock") end)
        pcall(function()
            imc = StaticFindObject("/Game/Mods/ArcaneWilds/IMC_ArcaneWildsQuickCastBlock.IMC_ArcaneWildsQuickCastBlock")
            ia  = StaticFindObject("/Game/Mods/ArcaneWilds/IA_ArcaneWildsKeyBlocker.IA_ArcaneWildsKeyBlocker")
        end)
    end
    if imc and imc:IsValid() and ia and ia:IsValid() then
        State._QuickCastIMC = imc
        State._QuickCastIA = ia
        DebugLog("Loaded EnhancedInput Quick-Cast blocker IMC & IA from IoStore pak")
        return imc, ia
    end
    return nil, nil
end

local function SyncQuickCastBlockerMappings(imc, ia)
    local allKeys = {}
    local seen = {}
    for _, binding in ipairs(GetQuickCastBindingsList()) do
        local m = tostring(binding.modifier or "NONE"):upper()
        if m == "BLOCK" or m == "RMB" or m == "MODIFIER" then
            for _, k in ipairs(ParseKeyList(binding.keysRaw)) do
                if not seen[k] then
                    seen[k] = true
                    table.insert(allKeys, k)
                end
            end
        end
    end
    local sig = table.concat(allKeys, ",")
    if State._QuickCastBlockerSig == sig then return end

    local defaultSig = "One,Gamepad_FaceButton_Left,Two,Gamepad_FaceButton_Top,Three,Gamepad_FaceButton_Right,Four,Gamepad_FaceButton_Bottom"
    if sig == defaultSig and State._QuickCastBlockerSig == nil then
        State._QuickCastBlockerSig = sig
        return
    end

    local bridgeCDO = nil
    pcall(function()
        bridgeCDO = StaticFindObject("/Game/Mods/ArcaneWilds/BFL_ArcaneWildsDamage.Default__BFL_ArcaneWildsDamage_C")
        if (not bridgeCDO or not bridgeCDO:IsValid()) and type(LoadAsset) == "function" then
            LoadAsset("/Game/Mods/ArcaneWilds/BFL_ArcaneWildsDamage.BFL_ArcaneWildsDamage_C")
            bridgeCDO = StaticFindObject("/Game/Mods/ArcaneWilds/BFL_ArcaneWildsDamage.Default__BFL_ArcaneWildsDamage_C")
        end
    end)
    if bridgeCDO and bridgeCDO:IsValid() then
        pcall(function()
            imc:UnmapAll()
            for _, k in ipairs(allKeys) do
                bridgeCDO:MapKeySafe(imc, ia, { KeyName = FName(k) })
            end
            State._QuickCastBlockerSig = sig
            DebugLog("Updated Quick-Cast input blocker keys from quick_cast.txt: " .. sig)
        end)
    end
end

local function SetQuickCastInputSuppressed(shouldSuppress)
    if Config.EnableQuickCastHotkeys == false or Config.QuickCastSuppressGameActions == false then
        shouldSuppress = false
    end
    local wantBlocked = (shouldSuppress == true)
    if (State._QuickCastInputBlocked == true) == wantBlocked then return end

    State._QuickCastInputBlocked = wantBlocked
    local function applyOnGameThread()
        pcall(function()
            local imc, ia = ResolveQuickCastBlockerAssets()
            if not imc or not ia then
                State._QuickCastInputBlocked = false
                return
            end
            local sub = FindFirstOf("EnhancedInputLocalPlayerSubsystem")
            if not sub or not sub:IsValid() then
                State._QuickCastInputBlocked = false
                return
            end
            if wantBlocked then
                SyncQuickCastBlockerMappings(imc, ia)
                sub:AddMappingContext(imc, 9999, {
                    bIgnoreAllPressedKeysUntilRelease = false,
                    bForceImmediately = true,
                    bNotifyUserSettings = false
                })
                DebugLog("Quick-Cast input blocker ON (Priority 9999: Hotbar 1-4 & Controller X/Y/B/A suppressed)")
            else
                sub:RemoveMappingContext(imc, {
                    bIgnoreAllPressedKeysUntilRelease = true,
                    bForceImmediately = true,
                    bNotifyUserSettings = false
                })
                DebugLog("Quick-Cast input blocker OFF (Hotbar 1-4 & Controller X/Y/B/A restored)")
            end
        end)
    end

    if type(ExecuteInGameThread) == "function" then
        pcall(function() ExecuteInGameThread(applyOnGameThread) end)
    else
        applyOnGameThread()
    end
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
        SetQuickCastInputSuppressed(false)
        return false
    end
    if not pc or not pc:IsValid() or not pawn or not pawn:IsValid() then return false end

    local bindings = GetQuickCastBindingsList()
    local hasBlockBinding = false
    for _, b in ipairs(bindings) do
        local m = tostring(b.modifier or "NONE"):upper()
        if m == "BLOCK" or m == "RMB" or m == "MODIFIER" then
            hasBlockBinding = true
            break
        end
    end
    SetQuickCastInputSuppressed(hasBlockBinding and State.ModifierHeld)

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
                                CombatEngine.TriggerSpellEntryForPlayer(Config, State, pawn, ent1, DebugLog, combatMagic)
                            end
                            firedAny = true
                        else
                            Log(string.format("QuickCast #%d [%s%s]: combo '%s' failed to parse", idx, prefix, tostring(triggeredKey), targetStr))
                        end
                    else
                        local entry = ResolveQuickCastEntry(targetStr)
                        if entry then
                            State._LastQuickCastTime = now
                            State.LastAutoAttackTime = now
                            State.LastTriggeredSpellTime = now
                            State._LastTriggeredSpellPtr = nil
                            State.StepInFlight = false
                            State.InFlightSpellObj = nil
                            Log(string.format("QuickCast #%d [%s%s] -> %s", idx, prefix, tostring(triggeredKey), tostring(entry.shortName or targetStr)))
                            CombatEngine.TriggerSpellEntryForPlayer(Config, State, pawn, entry, DebugLog, combatMagic)
                            firedAny = true
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

local function TickAnchorReturn(now, pawn, combatMagic)
    local anchor = EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, State, DebugLog)
    if not anchor then
        State.PendingAnchorReturn = false
        State.StepInFlight = false
        State.InFlightSpellObj = nil
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
                State.LastTriggeredSpellTime = now
                State.LastAutoAttackTime = now
                State.StepInFlight = true
                State.InFlightSpellObj = targetEntry.spellObj
                State.InFlightStartedTime = now
                CombatEngine.TriggerSpellEntryForPlayer(Config, State, pawn, targetEntry, DebugLog, combatMagic)
                DebugLog("Casting return-to-anchor spell [" .. tostring(anchor) .. "] before any re-roll")
            else
                State.PendingAnchorReturn = false
                if State.ModifierHeld then
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
            if State.ModifierHeld then
                DebugLog("Anchor return cast finished -> Re-rolling combo strictly from [" .. tostring(anchor) .. "]")
                CombatEngine.RollAndEngageMacroForAnchor(Config, State, pawn, combatMagic, anchor, Log, DebugLog)
            else
                DebugLog("Anchor return cast finished (Modifier released) -> Staying cleanly on [" .. tostring(anchor) .. "]")
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
    local padWindow = math.max(0.0, tonumber(Config.AnimRepeatPadSec) or 0.45)
    if expectedEntry and expectedEntry.montageObj and padWindow > 0 then
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
    local modAutoTrigger = (Config.TriggerComboOnModifierHold ~= false) and State.ModifierHeld and (State.ActiveMacro ~= nil)
    local modAtkTrigger = State.ModifierHeld and atkDown
    local holdAtkTrigger = Config.EnableAutoAttackHold and atkDown and (State.ModifierHeld or Config.AutoAttackAllCombos)
    if not modAutoTrigger and not modAtkTrigger and not holdAtkTrigger then
        return
    end

    -- If holding Block/Modifier and pressing Attack while no macro is currently locked,
    -- roll a fresh macro immediately from equipped staff/wand + equipped runes (no prior cast needed).
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

    if State.ModifierHeld and State.ActiveMacro then
        local st = State.ActiveMacro.stages[State.StageIndex]
        local sd = st and (st.steps[State.StepInStage] or st.steps[1])
        local entry = sd and ConfigManager.ResolveStepEntry(State, st, sd)
        if not entry then return end
        local minTriggerGap = entry.isSpecialSpell and 0.45 or 0.25
        if isBusy or (now - (State.LastTriggeredSpellTime or 0)) < minTriggerGap then
            return
        end
        if CombatEngine.TriggerSpellEntryForPlayer(Config, State, pawn, entry, DebugLog, combatMagic) then
            State.LastAutoAttackTime = now
            State.LastTriggeredSpellTime = now
            State.StepInFlight = true
            State.InFlightSpellObj = entry.spellObj
            State.InFlightStartedTime = now
        end
    elseif holdAtkTrigger then
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

LoopAsync(50, function()
    local now = os.clock()
    if (now - State.LastConfigPollTime) >= 0.30 then
        State.LastConfigPollTime = now
        ConfigManager.LoadConfigFile(Paths, Config, State, Log, false)
        State.Enabled = Config.Enabled
        BindDebugHotkey()
    end
    State.Enabled = Config.Enabled

    if not Config.Enabled then
        SetQuickCastInputSuppressed(false)
        return false
    end

    local pc, pawn, combatMagic = GetPlayerPawnAndComponents()
    if not pc then return false end
    PollHotkeyListener(pc)
    if not pawn then return false end
    if not State._InstalledEquipmentHooks then
        EquipmentRunes.InstallEquipmentSwapHooks(State, combatMagic, Log, DebugLog)
    end
    EquipmentRunes.EnsureEquipmentDelegates(pawn, combatMagic, State, DebugLog)

    if (now - State.LastScanTime) >= 3.0 then
        State.LastScanTime = now
        if type(ExecuteInGameThread) == "function" then
            pcall(function() ExecuteInGameThread(function() RefreshSpells() end) end)
        else
            RefreshSpells()
        end
    end

    if not State.ActiveMacro and not State.PendingAnchorReturn then
        EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, State, DebugLog)
    end

    local modDown = CombatEngine.IsModifierDown(Config, pc)
    if modDown and not State.ModifierHeld then
        State.ModifierHeld = true
        State._AppliedPadForCurrentStep = false
        CombatEngine.EngageModifierAndRollMacro(Config, State, pawn, combatMagic, Log, DebugLog)
        if Config.TriggerComboOnModifierHold ~= false and State.ActiveMacro and pawn and pawn:IsValid() then
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
    elseif not modDown and State.ModifierHeld then
        State.ModifierHeld = false
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

    local inPostSpecialPause = (State.SpecialPostPauseUntil or 0) > now
    if not quickCastFired and State.PendingAnchorReturn and not State.ActiveMacro and not inPostSpecialPause and combatMagic and combatMagic:IsValid() then
        TickAnchorReturn(now, pawn, combatMagic)
    end

    if not quickCastFired and State.ModifierHeld and State.ActiveMacro and combatMagic and combatMagic:IsValid() then
        TickActiveMacro(now, pawn, combatMagic)
    end

    CustomSpells.TickProjectileImpactAoE(State, pawn, combatMagic)
    if not quickCastFired then
        TickAutoAttack(now, pc, pawn, combatMagic)
    end
    return false
end)

-- Dedicated 16ms (~60Hz) timeline scheduler loop: near-zero cost when idle, crisp timing for
-- montage crossfades, layered slots, timed hitboxes, VFX/SFX, and non-player actor animations.
LoopAsync(16, function()
    if not Config.Enabled then return false end
    if not State.ActiveTimelines or #State.ActiveTimelines == 0 then return false end
    local _, pawn, combatMagic = GetPlayerPawnAndComponents()
    if not pawn then return false end
    TimelineRunner.Tick(os.clock(), Config, State, pawn, combatMagic, CustomSpells, SpellScanner.SafeGetName, DebugLog)
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
EquipmentRunes.InstallEquipmentSwapHooks(State, nil, Log, DebugLog)
BindDebugHotkey()
Log("v" .. MOD_VERSION .. " initialized cleanly (modular architecture).")
