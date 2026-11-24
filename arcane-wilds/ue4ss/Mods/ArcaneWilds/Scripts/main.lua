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
    ["MOUSE5"] = "ThumbMouseButton2"
}

local function NormalizeKeyName(raw)
    local up = (tostring(raw or "BackSlash")):gsub("^%s*(.-)%s*$", "%1"):upper()
    if FRIENDLY_KEY_ALIASES[up] then
        return FRIENDLY_KEY_ALIASES[up]
    end
    return tostring(raw or "BackSlash"):gsub("^%s*(.-)%s*$", "%1")
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
                CombatEngine.TriggerSpellEntryForPlayer(Config, State, pawn, targetEntry, DebugLog)
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

    if curActor and (State.ActiveStageTargetSpeed or 1.0) > 1.0 and not (expectedEntry and expectedEntry.isSpecialSpell) then
        CombatEngine.ApplyMontageRateToInstance(
            Config, pawn, expectedEntry and expectedEntry.montageObj,
            State.ActiveStageTargetSpeed, State.ActiveStageIsAirSmash)
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
        -- Special spells (like DA_ZamorakStaff_Special) spawn a persistent AoE actor via SpellModule_SpawnActor;
        -- advance once the initial cast windup (~0.85s) finishes rather than waiting for the persistent AoE puddle to expire.
        local specialCastReady = isSpecialInFlight and elapsed >= 0.85
        local castCompleted = (curActor == nil) or (curActorData ~= nil and curActorData ~= State.InFlightSpellObj) or specialCastReady
        local safetyTimeout = elapsed >= 4.5
        if castCompleted or safetyTimeout then
            State.StepInFlight = false
            State.InFlightSpellObj = nil
            CombatEngine.AdvanceLockedMacro(Config, State, pawn, combatMagic, DebugLog)
        end
    else
        local curChained = nil
        pcall(function() curChained = combatMagic.LastChainedSpell end)
        if curChained and curChained:IsValid() and curChained ~= State.LastObservedChainedSpell then
            State.LastObservedChainedSpell = curChained
            if not curActor then
                CombatEngine.AdvanceLockedMacro(Config, State, pawn, combatMagic, DebugLog)
            end
        end
    end
end

local function TickAutoAttack(now, pc, pawn, combatMagic)
    if not Config.EnableAutoAttackHold then return end
    local atkDown = CombatEngine.IsPrimaryAttackDown(pc)
    local shouldAuto = atkDown and (State.ModifierHeld or Config.AutoAttackAllCombos)
    local intervalSec = math.max(0.03, (tonumber(Config.AutoAttackIntervalMs) or 65) / 1000.0)

    if not shouldAuto or State.StepInFlight or (now - State.LastAutoAttackTime) < intervalSec then
        return
    end

    local isBusy = false
    if combatMagic and combatMagic:IsValid() then
        pcall(function()
            local actor = combatMagic.CurrentSpellActor
            if actor and actor:IsValid() then isBusy = true end
        end)
    end

    if isBusy or (now - (State.LastTriggeredSpellTime or 0)) < 0.14 then
        return
    end

    State.LastAutoAttackTime = now
    State.LastTriggeredSpellTime = now
    if State.ModifierHeld and State.ActiveMacro then
        local stage = State.ActiveMacro.stages[State.StageIndex]
        if stage then
            local stepDesc = stage.steps[State.StepInStage] or stage.steps[1]
            local entry = ConfigManager.ResolveStepEntry(State, stage, stepDesc)
            if entry and entry.spellObj then
                State.StepInFlight = true
                State.InFlightSpellObj = entry.spellObj
                State.InFlightStartedTime = now
                CombatEngine.TriggerSpellEntryForPlayer(Config, State, pawn, entry, DebugLog)
            end
        end
    elseif Config.AutoAttackAllCombos then
        State.PendingAnchorReturn = false
        local anchor = EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, State, DebugLog) or State.AnchorElement
        if combatMagic and combatMagic:IsValid() then
            pcall(function()
                if combatMagic.LastChainedSpell and combatMagic.LastChainedSpell:IsValid() then
                    local chainedName = SpellScanner.SafeGetName(combatMagic.LastChainedSpell):lower()
                    local baseAnchor = (anchor or ""):lower():gsub("_wand$", ""):gsub("_hold$", "")
                    if baseAnchor ~= "" and not chainedName:find(baseAnchor, 1, true) then
                        combatMagic.LastChainedSpell = nil
                    end
                end
            end)
        end
        local chain = anchor and State.SpellChains[anchor:lower()]
        local starterName = chain and chain.stepNames and chain.stepNames[0]
        local starterEntry = starterName and State.SpellRegistry[starterName:lower()]
        if starterEntry then
            CombatEngine.TriggerSpellEntryForPlayer(Config, State, pawn, starterEntry, DebugLog)
        end
    end
end

LoopAsync(50, function()
    local now = os.clock()
    if (now - State.LastConfigPollTime) >= 0.30 then
        State.LastConfigPollTime = now
        ConfigManager.LoadConfigFile(Paths, Config, State, Log, false)
        BindDebugHotkey()
    end

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
        CombatEngine.EngageModifierAndRollMacro(Config, State, pawn, combatMagic, Log, DebugLog)
    elseif not modDown and State.ModifierHeld then
        State.ModifierHeld = false
        CombatEngine.ReleaseModifierAndRevert(Config, State, pawn, combatMagic, Log, DebugLog)
    end

    if State.PendingAnchorReturn and not State.ActiveMacro and combatMagic and combatMagic:IsValid() then
        TickAnchorReturn(now, pawn, combatMagic)
    end

    if State.ModifierHeld and State.ActiveMacro and combatMagic and combatMagic:IsValid() then
        TickActiveMacro(now, pawn, combatMagic)
    end

    CustomSpells.TickProjectileImpactAoE(State, pawn, combatMagic)
    TickAutoAttack(now, pc, pawn, combatMagic)
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
