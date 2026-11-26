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
    CONFIG_PATH       = MOD_DIR .. "config.txt",
    COMBO_RULES_PATH  = MOD_DIR .. "combo_rules.txt",
    SPELL_NAMES_PATH  = MOD_DIR .. "spell_names.txt",
    CUSTOM_SPELLS_PATH = MOD_DIR .. "custom_spells.txt",
    DETECTED_PATH     = MOD_DIR .. "detected_spells.txt"
}

local SpellScanner   = require("spell_scanner")
local CustomSpells   = require("custom_spells")
local ConfigManager  = require("config_manager")
local EquipmentRunes = require("equipment_runes")
local CombatEngine   = require("combat_engine")

local Config = ConfigManager.CreateDefaultConfig()

local State = {
    ModifierHeld = false,
    AnchorElement = nil,
    LastKnownEquippedElement = nil,
    LastKnownWeaponSuffix = "",
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
    LastRulesStatusWritten = "",
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
    ParsedMacros = {}
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
    Log("AnchorCategory=" .. tostring(State.AnchorElement)
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
    ["NUM9"] = "NumPadNine"
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
    if Config.EnableQuickCastHotkeys == false then return false end
    if not pc or not pc:IsValid() or not pawn or not pawn:IsValid() then return false end

    State._QuickCastPrevDown = State._QuickCastPrevDown or {}
    local slots = {
        { key = Config.QuickCastHotkey1, spell = Config.QuickCastSpell1 },
        { key = Config.QuickCastHotkey2, spell = Config.QuickCastSpell2 },
        { key = Config.QuickCastHotkey3, spell = Config.QuickCastSpell3 }
    }

    local modReqOk = (Config.QuickCastRequireModifier == false) or State.ModifierHeld
    local firedAny = false

    for idx, slot in ipairs(slots) do
        local keyName = NormalizeKeyName(slot.key)
        local spellName = tostring(slot.spell or ""):gsub("^%s*(.-)%s*$", "%1")
        if keyName ~= "" and spellName ~= "" then
            local isDown = false
            pcall(function()
                isDown = pc:IsInputKeyDown({ KeyName = FName(keyName) })
            end)
            local wasDown = State._QuickCastPrevDown[idx] == true
            State._QuickCastPrevDown[idx] = isDown

            if isDown and not wasDown and modReqOk and not firedAny then
                if (now - (State._LastQuickCastTime or 0)) >= 0.35 then
                    local entry = ResolveQuickCastEntry(spellName)
                    if entry then
                        State._LastQuickCastTime = now
                        State.LastAutoAttackTime = now
                        State.LastTriggeredSpellTime = now
                        State._LastTriggeredSpellPtr = nil
                        State.StepInFlight = false
                        State.InFlightSpellObj = nil
                        local prefix = (Config.QuickCastRequireModifier ~= false) and (tostring(Config.ModifierKey or "RMB") .. "+") or ""
                        Log(string.format("QuickCast #%d [%s%s] -> %s", idx, prefix, keyName, tostring(entry.shortName or spellName)))
                        CombatEngine.TriggerSpellEntryForPlayer(Config, State, pawn, entry, DebugLog, combatMagic)
                        firedAny = true
                    else
                        Log(string.format("QuickCast #%d [%s]: spell '%s' not found in loaded/custom spells", idx, keyName, spellName))
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
    local anchor = State.AnchorElement or State.LastKnownEquippedElement
    local anchorChain = anchor and State.SpellChains[anchor:lower()]
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
        -- Suppress-base-spell custom steps don't spawn a native CurrentSpellActor, so advance cleanly once elapsed >= 0.65s.
        local stillPlayingMontage = (CombatEngine.GetActiveMontageObj(pawn) ~= nil)
        local specialCastReady = isSpecialInFlight and (elapsed >= 1.10 or (elapsed >= 0.85 and not stillPlayingMontage))
        local suppressStepReady = isSuppressStep and (elapsed >= 0.65)
        local castCompleted = suppressStepReady or (not isSuppressStep and ((curActor == nil and elapsed >= 0.20) or (curActorData ~= nil and curActorData ~= State.InFlightSpellObj) or specialCastReady))
        local safetyTimeout = elapsed >= 4.5
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
    if not Config.EnableAutoAttackHold and Config.TriggerComboOnModifierHold == false then return end
    local atkDown = CombatEngine.IsPrimaryAttackDown(pc)
    local modAutoTrigger = (Config.TriggerComboOnModifierHold ~= false) and State.ModifierHeld and (State.ActiveMacro ~= nil)
    local holdAtkTrigger = Config.EnableAutoAttackHold and atkDown and (State.ModifierHeld or Config.AutoAttackAllCombos)
    if not modAutoTrigger and not holdAtkTrigger then
        return
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
        State.LastAutoAttackTime = now
        State.LastTriggeredSpellTime = now
        State.StepInFlight = true
        State.InFlightSpellObj = entry.spellObj
        State.InFlightStartedTime = now
        CombatEngine.TriggerSpellEntryForPlayer(Config, State, pawn, entry, DebugLog, combatMagic)
    elseif holdAtkTrigger then
        if isBusy or (now - (State.LastTriggeredSpellTime or 0)) < 0.35 then
            return
        end
        local anchor = EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, State, DebugLog) or State.AnchorElement
        local _, mappedSpell = CombatEngine.ResolveClosestElementSpellAndCategory(state or State, anchor, State.LastKnownWeaponSuffix)
        local chain = anchor and State.SpellChains[anchor:lower()]
        local starterName = (mappedSpell) or (chain and chain.stepNames and chain.stepNames[0])
        local starterEntry = starterName and State.SpellRegistry[starterName:lower()]
        if starterEntry and starterEntry.spellObj and starterEntry.spellObj:IsValid() then
            State.PendingAnchorReturn = false
            State.LastAutoAttackTime = now
            State.LastTriggeredSpellTime = now
            State.StepInFlight = true
            State.InFlightSpellObj = starterEntry.spellObj
            State.InFlightStartedTime = now
            CombatEngine.TriggerSpellEntryForPlayer(Config, State, pawn, starterEntry, DebugLog, combatMagic)
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

    if not Config.Enabled then return false end

    local pc, pawn, combatMagic = GetPlayerPawnAndComponents()
    if not pc then return false end
    PollHotkeyListener(pc)
    if not pawn then return false end
    if not State._InstalledEquipmentHooks then
        EquipmentRunes.InstallEquipmentSwapHooks(State, combatMagic, Log, DebugLog)
    end

    if (now - State.LastScanTime) >= 3.0 then
        State.LastScanTime = now
        RefreshSpells()
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
            local busyNow = false
            if combatMagic and combatMagic:IsValid() then
                pcall(function()
                    local a = combatMagic.CurrentSpellActor
                    if a and a:IsValid() then busyNow = true end
                end)
            end
            if ent1 and ent1.spellObj and ent1.spellObj:IsValid() then
                State.LastAutoAttackTime = now
                State.LastTriggeredSpellTime = now
                State.StepInFlight = true
                State.InFlightSpellObj = ent1.spellObj
                State.InFlightStartedTime = now
                CombatEngine.TriggerSpellEntryForPlayer(Config, State, pawn, ent1, DebugLog, combatMagic)
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
