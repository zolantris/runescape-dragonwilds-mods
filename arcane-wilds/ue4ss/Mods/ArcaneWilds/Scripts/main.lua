-- ArcaneWilds v1.68.0
-- Move-While-Casting + Cross-Element & Ancient Magicks Chaining + Rune Consumption + Montage Pacing

local MOD_VERSION = "1.68.0"
local MOD_DIR = debug.getinfo(1, "S").source:match("^@?(.*[\\/])Scripts[\\/]") or "ue4ss\\Mods\\ArcaneWilds\\"
local SCRIPTS_DIR = MOD_DIR .. "Scripts\\"
local CONFIG_PATH = MOD_DIR .. "config.txt"
local COMBO_RULES_PATH = MOD_DIR .. "combo_rules.txt"
local SPELL_NAMES_PATH = MOD_DIR .. "spell_names.txt"
local CUSTOM_SPELLS_PATH = MOD_DIR .. "custom_spells.txt"
local DETECTED_PATH = MOD_DIR .. "detected_spells.txt"

if not package.path:find(SCRIPTS_DIR, 1, true) then
    package.path = SCRIPTS_DIR .. "?.lua;" .. package.path
end

local RuleParser = require("rule_parser")
local SpellScanner = require("spell_scanner")
local CustomSpells = require("custom_spells")

local DEFAULT_SPELL_NAMES_CONTENT = table.concat({
    "# ArcaneWilds Direct Spell Name -> Asset Map (Hot-Reloaded Automatically on Save!)",
    "# Format: Category.name = DA_Spell_AssetName",
    "AncientMagicks.ice_barrage   = HAM_IceBarrage",
    "AncientMagicks.blood_barrage = HAM_BloodBarrage",
    "AncientMagicks.smoke_barrage = HAM_SmokeBarrage",
    "AncientMagicks.shadow_barrage = HAM_ShadowBarrage",
    "HAM_IceBarrage.ice_barrage       = HAM_IceBarrage",
    "HAM_BloodBarrage.blood_barrage   = HAM_BloodBarrage",
    "HAM_SmokeBarrage.smoke_barrage   = HAM_SmokeBarrage",
    "HAM_ShadowBarrage.shadow_barrage = HAM_ShadowBarrage",
    "Water.bolt      = DA_Spell_Primary_Water_01",
    "Water.waterfall = DA_Spell_Primary_Water_02",
    "Water.wave      = DA_Spell_Primary_Water_03",
    "Water.tsunami   = DA_Spell_Primary_Water_04",
    "Water_Wand.bolt      = DA_Spell_Primary_Water_Wand_01",
    "Water_Wand.waterfall = DA_Spell_Primary_Water_Wand_02",
    "Water_Wand.wave      = DA_Spell_Primary_Water_Wand_03",
    "Water_Wand.tsunami   = DA_Spell_Primary_Water_Wand_04",
    "Fire.bolt           = DA_Spell_Primary_Fire_01",
    "Fire.bolt_1         = DA_Spell_Primary_Fire_01",
    "Fire.bolt_2         = DA_Spell_Primary_Fire_02",
    "Fire.burst          = DA_Spell_Primary_Fire_03",
    "Fire.explosion      = DA_Spell_Primary_Fire_04",
    "Fire.bolt_explosive = DA_Spell_Primary_Fire_04",
    "Fire.volcano        = DA_Spell_Primary_Fire_04",
    "Fire.meteor         = DA_Spell_Primary_Fire_04",
    "Fire_Wand.bolt           = DA_Spell_Primary_Fire_Wand_01",
    "Fire_Wand.bolt_1         = DA_Spell_Primary_Fire_Wand_01",
    "Fire_Wand.bolt_2         = DA_Spell_Primary_Fire_Wand_02",
    "Fire_Wand.burst          = DA_Spell_Primary_Fire_Wand_03",
    "Fire_Wand.explosion      = DA_Spell_Primary_Fire_Wand_04",
    "Fire_Wand.bolt_explosive = DA_Spell_Primary_Fire_Wand_04",
    "Fire_Wand.volcano        = DA_Spell_Primary_Fire_Wand_04",
    "Fire_Wand.meteor         = DA_Spell_Primary_Fire_Wand_04",
    "Air.bolt         = DA_Spell_Primary_Air_01",
    "Air.gust         = DA_Spell_Primary_Air_02",
    "Air.vortex       = DA_Spell_Primary_Air_03",
    "Air.slam         = DA_Spell_Primary_Air_04",
    "Air.ground_smash = DA_Spell_Primary_Air_04",
    "Air_Wand.bolt   = DA_Spell_Primary_Air_Wand_01",
    "Air_Wand.gust   = DA_Spell_Primary_Air_Wand_02",
    "Air_Wand.vortex = DA_Spell_Primary_Air_Wand_03",
    "Air_Wand.slam   = DA_Spell_Primary_Air_Wand_04",
    "Earth.bolt    = DA_Spell_Primary_Earth_01",
    "Earth.spike   = DA_Spell_Primary_Earth_02",
    "Earth.shatter = DA_Spell_Primary_Earth_03",
    "Earth.boulder = DA_Spell_Primary_Earth_04",
    "Earth_Wand.bolt    = DA_Spell_Primary_Earth_Wand_01",
    "Earth_Wand.spike   = DA_Spell_Primary_Earth_Wand_02",
    "Earth_Wand.shatter = DA_Spell_Primary_Earth_Wand_03",
    "Earth_Wand.boulder = DA_Spell_Primary_Earth_Wand_04"
}, "\n") .. "\n"

local DEFAULT_COMBO_RULES_CONTENT = table.concat({
    "# ArcaneWilds Custom Combo Rules (Hot-Reloaded Automatically on Save!)",
    "# Syntax: Category@spell,spell:speed -> Category@spell,spell:speed :weight;",
    "Water@wave,bolt:2.5 -> Fire@bolt,explosion:2.5 :5;",
    "HAM_BloodBarrage@blood_barrage:2.0 -> HAM_IceBarrage@ice_barrage:2.0 :5;",
    "HAM_IceBarrage@ice_barrage:2.0 -> HAM_BloodBarrage@blood_barrage:2.0 :5;"
}, "\n") .. "\n"

local Config = {
    Enabled = true,
    DebugMode = false,
    AllowDebugCommands = false,
    DebugHotkey = "OEM_5",
    RequireModifierKey = true,
    ModifierKey = "RMB",
    ConsumeRunesOnSwappedCasts = true,
    EnableAutoAttackHold = true,
    AutoAttackAllCombos = false,
    AutoAttackIntervalMs = 65,
    DefaultComboCutoff = 2,
    BonusSpeedVariancePct = 25,
    UnlockAir = true,
    UnlockFire = true,
    UnlockWater = true,
    UnlockEarth = true,
    UnlockModdedCombat = true,
    UnlockUtilitySpells = false,
    KeepGroundSmashAnchored = true,
    MaxFinisherSpeedClamp = 5.0,
    MaxMoveSpeed = 600.0,
    ActiveComboRulesCount = "Loading combo_rules.txt...",
    DetectedSpellsSummary = "Auto-detecting on world load..."
}

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
    RuneItemDataCache = {},        -- [elemLower] = ItemData UObject (e.g., "fire" -> DA_Item_Rune_Fire)
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

local function Trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function ParseBool(v, defaultVal)
    if v == nil then return defaultVal end
    local l = Trim(tostring(v)):lower()
    if l == "true" or l == "1" or l == "yes" or l == "on" then return true end
    if l == "false" or l == "0" or l == "no" or l == "off" then return false end
    return defaultVal
end

local function SaveConfigFile()
    local f = io.open(CONFIG_PATH, "w")
    if not f then return end
    local orderedKeys = {
        "Enabled", "DebugMode", "AllowDebugCommands", "DebugHotkey",
        "RequireModifierKey", "ModifierKey", "ConsumeRunesOnSwappedCasts",
        "EnableAutoAttackHold", "AutoAttackAllCombos", "AutoAttackIntervalMs",
        "DefaultComboCutoff", "BonusSpeedVariancePct",
        "UnlockAir", "UnlockFire", "UnlockWater", "UnlockEarth",
        "UnlockModdedCombat", "UnlockUtilitySpells", "KeepGroundSmashAnchored", "MaxFinisherSpeedClamp",
        "MaxMoveSpeed", "ActiveComboRulesCount", "DetectedSpellsSummary"
    }
    for _, k in ipairs(orderedKeys) do
        f:write(k .. "=" .. tostring(Config[k]) .. "\n")
    end
    f:close()
end

local function ResolveStepEntry(stage, stepDescriptor)
    if not stepDescriptor then return nil end

    if stepDescriptor.assetName and stepDescriptor.assetName ~= "" then
        local exact = State.SpellRegistry[stepDescriptor.assetName:lower()]
        if exact and exact.spellObj and exact.spellObj:IsValid() then
            return exact
        end
    end

    local catLower = stage and stage.elementLower or nil
    if catLower and catLower ~= "*" then
        if State.SpellRegistry[catLower] and State.SpellRegistry[catLower].spellObj and State.SpellRegistry[catLower].spellObj:IsValid() then
            return State.SpellRegistry[catLower]
        end
        local chain = State.SpellChains[catLower]
        if chain then
            local idx = stepDescriptor.fallbackIndex or 0
            local sName = chain.stepNames and chain.stepNames[idx]
            if sName and State.SpellRegistry[sName:lower()] then
                return State.SpellRegistry[sName:lower()]
            end
        end
    end

    return nil
end

local function DescribeStepDescriptor(stage, stepDescriptor)
    if not stepDescriptor then return "<nil>" end
    local tok = tostring(stepDescriptor.token or "?")
    local targetAsset = stepDescriptor.assetName
    local entry = ResolveStepEntry(stage, stepDescriptor)

    if not entry then
        if targetAsset then
            return string.format("'%s' -> '%s' [NOT FOUND IN LOADED SPELLS]", tok, tostring(targetAsset))
        end
        return string.format("'%s' [UNRESOLVED]", tok)
    end

    local mSuffix = (entry.montageName and entry.montageName ~= "") and (" | Montage=" .. entry.montageName) or ""
    if tok:lower() == entry.shortName:lower() then
        return string.format("%s (%s)%s", entry.shortName, entry.fullName, mSuffix)
    end
    return string.format("'%s' -> %s (%s)%s", tok, entry.shortName, entry.fullName, mSuffix)
end

local function LogParsedMacrosSpellMapping(headerLabel)
    if not Config.DebugMode and not Config.AllowDebugCommands then
        return
    end
    Log("=== " .. tostring(headerLabel or "Combo Rules -> Direct Spell Asset Mapping") .. " ===")
    if #State.ParsedMacros == 0 then
        Log("  (No active macros parsed from combo_rules.txt)")
        return
    end
    for rIdx, m in ipairs(State.ParsedMacros) do
        Log(string.format("  Rule #%d [weight=%s, stages=%d]: %s", rIdx, tostring(m.weight), #m.stages, m.raw))
        for sIdx, st in ipairs(m.stages) do
            local resolvedParts = {}
            for _, desc in ipairs(st.steps) do
                table.insert(resolvedParts, DescribeStepDescriptor(st, desc))
            end
            Log(string.format("    Stage %d [%s @ %.2fx]: %s",
                sIdx, tostring(st.element), tonumber(st.speed) or 1.0, table.concat(resolvedParts, " ; ")))
        end
    end
end

local function LoadSpellNamesFile()
    local f = io.open(SPELL_NAMES_PATH, "r")
    if not f then
        local wf = io.open(SPELL_NAMES_PATH, "w")
        if wf then
            wf:write(DEFAULT_SPELL_NAMES_CONTENT)
            wf:close()
        end
        f = io.open(SPELL_NAMES_PATH, "r")
        if not f then return false end
    end
    local raw = f:read("*a") or ""
    f:close()
    if State.LastSpellNamesRaw ~= raw then
        State.LastSpellNamesRaw = raw
        State.NameMapByCat, State.GlobalNameMap = RuleParser.ParseSpellNameMap(raw)
        return true
    end
    return false
end

local function LoadCustomSpellsFile()
    local f = io.open(CUSTOM_SPELLS_PATH, "r")
    if not f then
        local wf = io.open(CUSTOM_SPELLS_PATH, "w")
        if wf then
            wf:write("-- Arcane Wilds Custom Spells (see custom_spells.txt template)\n")
            wf:close()
        end
        return false
    end
    local raw = f:read("*a") or ""
    f:close()
    if State.LastCustomSpellsRaw ~= raw then
        local isInitial = (State.LastCustomSpellsRaw == nil)
        State.LastCustomSpellsRaw = raw
        State.CustomSpellDefs = CustomSpells.ParseDefinitions(raw)
        if not isInitial then
            Log("Hot-reloaded custom_spells.txt")
        end
        return true
    end
    return false
end

local function RebuildMergedRegistry()
    local merged = {}
    for k, v in pairs(State.BaseSpellRegistry) do
        merged[k] = v
    end
    local lookup = {}
    for k, entry in pairs(merged) do
        lookup[k] = entry.shortName
        if entry.montageName and entry.montageName ~= "" then
            lookup[entry.montageName:lower()] = entry.shortName
        end
    end
    local customEntries = CustomSpells.BuildCustomRegistryEntries(
        State.CustomSpellDefs, merged, State.SpellChains, State.RuneItemDataCache,
        SpellScanner.SafeGetName, SpellScanner.ExtractShortObjectName)
    for k, cEntry in pairs(customEntries) do
        merged[k] = cEntry
        lookup[k] = cEntry.shortName
    end
    State.SpellRegistry = merged
    State.DiscoveredLookup = lookup
end

local function LoadComboRulesFile(forceRebuild, legacyRuleFallback)
    local namesChanged = LoadSpellNamesFile()
    local customChanged = LoadCustomSpellsFile()
    if customChanged then
        RebuildMergedRegistry()
    end

    local f = io.open(COMBO_RULES_PATH, "r")
    if not f then
        local wf = io.open(COMBO_RULES_PATH, "w")
        if wf then
            if legacyRuleFallback and Trim(legacyRuleFallback) ~= "" then
                wf:write("# Migrated from config.txt WeightedComboRules\n")
                wf:write(Trim(legacyRuleFallback) .. "\n")
            else
                wf:write(DEFAULT_COMBO_RULES_CONTENT)
            end
            wf:close()
        end
        f = io.open(COMBO_RULES_PATH, "r")
        if not f then return end
    end

    local lines = {}
    for line in f:lines() do
        local clean = Trim(line)
        if clean ~= "" and not clean:match("^#") and not clean:match("^;") then
            local hashPos = clean:find("#", 1, true)
            if hashPos then
                clean = Trim(clean:sub(1, hashPos - 1))
            end
            if clean ~= "" then
                if not clean:match(";$") and (clean:find("@", 1, true) or clean:find("->", 1, true)) then
                    clean = clean .. ";"
                end
                table.insert(lines, clean)
            end
        end
    end
    f:close()

    local combinedRules = table.concat(lines, " ")
    if forceRebuild or namesChanged or customChanged or State.LastComboRulesRaw ~= combinedRules then
        local isInitial = (State.LastComboRulesRaw == nil)
        State.LastComboRulesRaw = combinedRules
        State.ParsedMacros = RuleParser.ParseWeightedMacros(
            combinedRules, State.NameMapByCat, State.GlobalNameMap, State.DiscoveredLookup)

        local statusStr = string.format("%d macro(s) active from combo_rules.txt", #State.ParsedMacros)
        Config.ActiveComboRulesCount = statusStr
        if statusStr ~= State.LastRulesStatusWritten then
            State.LastRulesStatusWritten = statusStr
            SaveConfigFile()
        end

        if isInitial then
            Log("Loaded " .. tostring(#State.ParsedMacros) .. " macro(s) from combo_rules.txt")
        else
            Log("Hot-reloaded combo_rules.txt / spell_names.txt -> " .. tostring(#State.ParsedMacros) .. " macro(s) active!")
            for idx, m in ipairs(State.ParsedMacros) do
                Log(string.format("  Rule #%d [weight=%s, stages=%d]: %s", idx, tostring(m.weight), #m.stages, m.raw))
            end
            LogParsedMacrosSpellMapping("Hot-Reloaded Combo Rules -> Direct Spell Asset Mapping")
        end
    end
end

local function LoadConfigFile(forceRebuildMacros)
    local legacyWeightedRules = nil
    local f = io.open(CONFIG_PATH, "r")
    if not f then
        SaveConfigFile()
        LoadComboRulesFile(true, nil)
        return
    end

    local prevDebug = Config.AllowDebugCommands

    for line in f:lines() do
        local clean = Trim(line)
        if clean ~= "" and not clean:match("^#") and not clean:match("^;") then
            local k, v = clean:match("^([^=]+)=(.*)$")
            if k and v then
                k = Trim(k)
                v = Trim(v)
                if k == "Enabled" then Config.Enabled = ParseBool(v, true)
                elseif k == "DebugMode" then Config.DebugMode = ParseBool(v, false)
                elseif k == "AllowDebugCommands" then Config.AllowDebugCommands = ParseBool(v, false)
                elseif k == "DebugHotkey" then Config.DebugHotkey = (v ~= "" and v or "OEM_5")
                elseif k == "RequireModifierKey" then Config.RequireModifierKey = ParseBool(v, true)
                elseif k == "ModifierKey" then Config.ModifierKey = (v ~= "" and v:upper() or "SHIFT")
                elseif k == "ConsumeRunesOnSwappedCasts" then Config.ConsumeRunesOnSwappedCasts = ParseBool(v, true)
                elseif k == "EnableAutoAttackHold" then Config.EnableAutoAttackHold = ParseBool(v, true)
                elseif k == "AutoAttackAllCombos" then Config.AutoAttackAllCombos = ParseBool(v, false)
                elseif k == "AutoAttackIntervalMs" then Config.AutoAttackIntervalMs = tonumber(v) or 65
                elseif k == "DefaultComboCutoff" then Config.DefaultComboCutoff = math.max(1, math.min(4, math.floor(tonumber(v) or 2)))
                elseif k == "WeightedComboRules" then legacyWeightedRules = v
                elseif k == "BonusSpeedVariancePct" then Config.BonusSpeedVariancePct = tonumber(v) or 25
                elseif k == "UnlockAir" then Config.UnlockAir = ParseBool(v, true)
                elseif k == "UnlockFire" then Config.UnlockFire = ParseBool(v, true)
                elseif k == "UnlockWater" then Config.UnlockWater = ParseBool(v, true)
                elseif k == "UnlockEarth" then Config.UnlockEarth = ParseBool(v, true)
                elseif k == "UnlockModdedCombat" then Config.UnlockModdedCombat = ParseBool(v, true)
                elseif k == "UnlockUtilitySpells" then Config.UnlockUtilitySpells = ParseBool(v, false)
                elseif k == "KeepGroundSmashAnchored" then Config.KeepGroundSmashAnchored = ParseBool(v, true)
                elseif k == "MaxFinisherSpeedClamp" then Config.MaxFinisherSpeedClamp = math.max(1.0, tonumber(v) or 5.0)
                elseif k == "MaxMoveSpeed" then Config.MaxMoveSpeed = tonumber(v) or 600.0
                elseif k == "ActiveComboRulesCount" then Config.ActiveComboRulesCount = v
                elseif k == "DetectedSpellsSummary" then Config.DetectedSpellsSummary = v
                end
            end
        end
    end
    f:close()

    if prevDebug ~= Config.AllowDebugCommands then
        if Config.AllowDebugCommands then
            Log("Debug mode ENABLED (hotkey: SHIFT + " .. tostring(Config.DebugHotkey) .. ")")
        else
            Log("Debug mode DISABLED")
        end
    end

    LoadComboRulesFile(forceRebuildMacros, legacyWeightedRules)
end

-- Discover rune ItemData assets (Fire, Water, Air, Earth, Blood, Ice, Smoke, Shadow, etc.) so swapped casts consume real runes
local function DiscoverRuneItemAssets()
    local items = FindAllOf("DominionItemData") or FindAllOf("ItemData")
    if not items then return end
    for _, item in ipairs(items) do
        if item and item:IsValid() then
            local full = SpellScanner.SafeGetName(item):lower()
            local short = SpellScanner.ExtractShortObjectName(full):lower()
            if full:find("rune") or short:find("rune") or full:find("magicammo") then
                if short:find("fire") then State.RuneItemDataCache["fire"] = item
                elseif short:find("water") then State.RuneItemDataCache["water"] = item
                elseif short:find("air") or short:find("wind") then State.RuneItemDataCache["air"] = item
                elseif short:find("earth") then State.RuneItemDataCache["earth"] = item
                elseif short:find("blood") then State.RuneItemDataCache["blood"] = item
                elseif short:find("ice") or short:find("frost") then State.RuneItemDataCache["ice"] = item
                elseif short:find("smoke") then State.RuneItemDataCache["smoke"] = item
                elseif short:find("shadow") then State.RuneItemDataCache["shadow"] = item
                elseif short:find("death") then State.RuneItemDataCache["death"] = item
                elseif short:find("chaos") then State.RuneItemDataCache["chaos"] = item
                elseif short:find("nature") then State.RuneItemDataCache["nature"] = item
                elseif short:find("law") then State.RuneItemDataCache["law"] = item
                end
            end
        end
    end
end

local function RefreshSpells()
    local chains, ordered, registry, discovered, summary = SpellScanner.ScanAndPatchSpells(
        Config, MOD_VERSION, DETECTED_PATH, State.NameMapByCat, State.GlobalNameMap)
    State.SpellChains = chains
    State.AllChainsList = ordered
    State.BaseSpellRegistry = registry
    RebuildMergedRegistry()
    DiscoverRuneItemAssets()

    if summary ~= State.LastDetectedSummaryWritten then
        State.LastDetectedSummaryWritten = summary
        Config.DetectedSpellsSummary = summary
        SaveConfigFile()
    end

    if State.LastComboRulesRaw then
        State.ParsedMacros = RuleParser.ParseWeightedMacros(
            State.LastComboRulesRaw, State.NameMapByCat, State.GlobalNameMap, State.DiscoveredLookup)
    end
    if Config.DebugMode and not State._LoggedInitialSpellMap and next(State.SpellRegistry) ~= nil then
        State._LoggedInitialSpellMap = true
        LogParsedMacrosSpellMapping("Initial Spell Scan -> Direct Spell Asset Mapping")
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

-- Check whether an Ancient Magicks spell (HAM_*) is currently toggled ON in HydraAncientMagicks
-- Returns the active HAM_* category if toggled ON, or nil if toggled OFF / not active.
local function GetActiveAncientMagicksToggle(pawn, combatMagic)
    local activeHam = nil
    pcall(function()
        local subsys = FindFirstOf("CombatSpellDataSubsystem")
        if subsys and subsys:IsValid() then
            local toggleProps = { "ActiveBarrageSpell", "SelectedBarrage", "CurrentAncientSpell", "ActiveSpell", "ToggledSpell" }
            for _, prop in ipairs(toggleProps) do
                local val = nil
                pcall(function() val = subsys[prop] end)
                if val and type(val) == "userdata" and val:IsValid() then
                    local sName = SpellScanner.ExtractShortObjectName(SpellScanner.SafeGetName(val))
                    if sName:lower():find("^ham_") then
                        activeHam = sName
                        break
                    end
                end
            end
        end
    end)

    -- Also check if player has an active Ancient Magicks gameplay tag / effect when toggled on
    if not activeHam and pawn and pawn:IsValid() then
        pcall(function()
            local asc = pawn.AbilitySystemComponent
            if asc and asc:IsValid() then
                -- Only treat HAM_* as active if CurrentSpellActor is an HAM spell; never lock permanently!
                if combatMagic and combatMagic:IsValid() and combatMagic.CurrentSpellActor and combatMagic.CurrentSpellActor:IsValid() then
                    local d = combatMagic.CurrentSpellActor.Data
                    if d and d:IsValid() then
                        local sName = SpellScanner.ExtractShortObjectName(SpellScanner.SafeGetName(d))
                        if sName:lower():find("^ham_") then
                            activeHam = sName
                        end
                    end
                end
            end
        end)
    end

    return activeHam
end

-- Always read live equipped weapon & runes first so swapping runes immediately exits Ancient Magicks / old elements!
local function DetectEquippedCategory(pawn, combatMagic)
    if not pawn or not pawn:IsValid() then
        return State.LastKnownEquippedElement
    end

    local detectedElem = nil
    local weaponSuffix = State.LastKnownWeaponSuffix
    local hasExplicitRuneEquipped = false

    pcall(function()
        local equipComp = pawn.PlayerEquipmentComponent
        if equipComp and equipComp:IsValid() then
            local weaponProps = { "RightHandEquipment", "HeldRightEquipment", "MainHandEquipment" }
            for _, prop in ipairs(weaponProps) do
                local wObj = nil
                pcall(function() wObj = equipComp[prop] end)
                if wObj and wObj:IsValid() then
                    local wName = SpellScanner.SafeGetName(wObj):lower()
                    pcall(function()
                        if wObj.ItemData and wObj.ItemData:IsValid() then
                            wName = wName .. " " .. SpellScanner.SafeGetName(wObj.ItemData):lower()
                        end
                    end)
                    if wName:find("wand") then
                        weaponSuffix = "_Wand"
                    elseif wName:find("staff") then
                        weaponSuffix = ""
                    end
                end
            end

            local ammoProps = { "EquippedMagicAmmo", "MagicAmmo", "CurrentMagicAmmo" }
            for _, prop in ipairs(ammoProps) do
                local itemObj = nil
                pcall(function() itemObj = equipComp[prop] end)
                if itemObj and itemObj:IsValid() then
                    local itemName = SpellScanner.SafeGetName(itemObj)
                    local itemDataObj = nil
                    pcall(function() itemDataObj = itemObj.ItemData end)
                    if itemDataObj and itemDataObj:IsValid() then
                        itemName = itemName .. " " .. SpellScanner.SafeGetName(itemDataObj)
                    end
                    local elem = SpellScanner.ClassifyEquippedName(itemName)
                    if elem then
                        detectedElem = elem
                        hasExplicitRuneEquipped = true
                        if itemDataObj and itemDataObj:IsValid() then
                            State.RuneItemDataCache[elem:lower()] = itemDataObj
                        end
                        break
                    end
                end
            end
        end
    end)

    if not detectedElem then
        pcall(function()
            local pc = pawn.Controller
            if pc and pc:IsValid() and pc.LoadoutComponent and pc.LoadoutComponent:IsValid() then
                local loadout = pc.LoadoutComponent
                local loadoutProps = { "MagicAmmo1", "MagicAmmo", "HeldRight", "EquippedItems" }
                for _, prop in ipairs(loadoutProps) do
                    local val = nil
                    pcall(function() val = loadout[prop] end)
                    if val and type(val) == "userdata" and val:IsValid() then
                        local itemName = SpellScanner.SafeGetName(val)
                        local itemDataObj = nil
                        pcall(function() itemDataObj = val.ItemData end)
                        if itemDataObj and itemDataObj:IsValid() then
                            itemName = itemName .. " " .. SpellScanner.SafeGetName(itemDataObj)
                        end
                        if itemName:lower():find("wand") then
                            weaponSuffix = "_Wand"
                        elseif itemName:lower():find("staff") then
                            weaponSuffix = ""
                        end
                        local elem = SpellScanner.ClassifyEquippedName(itemName)
                        if elem then
                            detectedElem = elem
                            hasExplicitRuneEquipped = true
                            if itemDataObj and itemDataObj:IsValid() then
                                State.RuneItemDataCache[elem:lower()] = itemDataObj
                            end
                            break
                        end
                    end
                end
            end
        end)
    end

    -- Check active Ancient Magicks toggle ONLY if not currently overridden by a different equipped standard rune,
    -- or if an HAM_* spell is explicitly toggled ON in CombatSpellDataSubsystem
    local activeHam = GetActiveAncientMagicksToggle(pawn, combatMagic)
    if activeHam and not hasExplicitRuneEquipped then
        detectedElem = activeHam
    elseif activeHam and hasExplicitRuneEquipped then
        -- If the player swapped to standard elemental runes while Ancient Magicks was left dangling in LastChainedSpell,
        -- clear LastChainedSpell so Ancient Magicks cannot trap the player!
        if combatMagic and combatMagic:IsValid() and not State.ActiveMacro then
            pcall(function()
                if combatMagic.LastChainedSpell and combatMagic.LastChainedSpell:IsValid() then
                    local chainedName = SpellScanner.SafeGetName(combatMagic.LastChainedSpell):lower()
                    if chainedName:find("ham_") or chainedName:find("ancientstaff") then
                        combatMagic.LastChainedSpell = nil
                        DebugLog("Cleared stale Ancient Magicks LastChainedSpell after rune swap to " .. tostring(detectedElem))
                    end
                end
            end)
        end
    end

    -- Last resort fallback: inspect LastChainedSpell / CurrentSpellActor ONLY when no macro is active
    -- and ignore stale HAM_* references if LastKnownEquippedElement was already a standard element
    if not detectedElem and combatMagic and combatMagic:IsValid() and not State.ActiveMacro then
        pcall(function()
            if combatMagic.LastChainedSpell and combatMagic.LastChainedSpell:IsValid() then
                local full = SpellScanner.SafeGetName(combatMagic.LastChainedSpell)
                local cat = SpellScanner.ClassifySpellAsset(full, SpellScanner.ExtractShortObjectName(full))
                if cat and not cat:lower():find("^ham_") then
                    detectedElem = cat:gsub("_Wand$", ""):gsub("_Hold$", "")
                    weaponSuffix = cat:find("_Wand$") and "_Wand" or ""
                end
            end
        end)
        if not detectedElem then
            pcall(function()
                if combatMagic.CurrentSpellActor and combatMagic.CurrentSpellActor:IsValid() then
                    local spellData = combatMagic.CurrentSpellActor.Data
                    if spellData and spellData:IsValid() then
                        local full = SpellScanner.SafeGetName(spellData)
                        local cat = SpellScanner.ClassifySpellAsset(full, SpellScanner.ExtractShortObjectName(full))
                        if cat and not cat:lower():find("^ham_") then
                            detectedElem = cat:gsub("_Wand$", ""):gsub("_Hold$", "")
                            weaponSuffix = cat:find("_Wand$") and "_Wand" or ""
                        end
                    end
                end
            end)
        end
    end

    State.LastKnownWeaponSuffix = weaponSuffix
    if detectedElem then
        local isBaseFour = (detectedElem == "Fire" or detectedElem == "Water" or detectedElem == "Air" or detectedElem == "Earth")
        local fullCat = isBaseFour and (detectedElem .. weaponSuffix) or detectedElem

        -- If the player physically swapped runes/elements while idle (and not mid-anchor-return), reset stale anchor state
        if not State.ActiveMacro and not State.PendingAnchorReturn and State.LastKnownEquippedElement and State.LastKnownEquippedElement ~= fullCat then
            DebugLog("Equipped element changed: " .. tostring(State.LastKnownEquippedElement) .. " -> " .. tostring(fullCat))
            State.AnchorElement = fullCat
            State.PendingAnchorReturn = false
            State.LastObservedChainedSpell = nil
            if combatMagic and combatMagic:IsValid() then
                pcall(function() combatMagic.LastChainedSpell = nil end)
            end
        end

        State.LastKnownEquippedElement = fullCat
        return fullCat
    end
    return State.LastKnownEquippedElement
end

-- Deduct real runes/items from player inventory when TriggerModularAbilityForPlayer bypasses native ammo consumption
local function ConsumeItemsFromInventory(pawn, itemData, count)
    if not pawn or not pawn:IsValid() or not itemData or not itemData:IsValid() then
        return false
    end
    local qty = math.max(1, math.floor(count or 1))
    local consumed = false

    local invTargets = {}
    pcall(function()
        if pawn.InventoryComponent and pawn.InventoryComponent:IsValid() then
            table.insert(invTargets, pawn.InventoryComponent)
        end
    end)
    pcall(function()
        local pc = pawn.Controller
        if pc and pc:IsValid() and pc.InventoryComponent and pc.InventoryComponent:IsValid() then
            table.insert(invTargets, pc.InventoryComponent)
        end
    end)
    pcall(function()
        if pawn.PlayerEquipmentComponent and pawn.PlayerEquipmentComponent:IsValid() then
            table.insert(invTargets, pawn.PlayerEquipmentComponent)
        end
    end)

    for _, inv in ipairs(invTargets) do
        -- Try standard Dominion inventory removal methods
        local methodNames = { "RemoveItem", "ConsumeItem", "RemoveItemsByData", "Server_RemoveItem" }
        for _, mName in ipairs(methodNames) do
            if not consumed and inv[mName] then
                local ok, res = pcall(function()
                    return inv[mName](inv, itemData, qty)
                end)
                if ok and (res == nil or res == true) then
                    consumed = true
                    break
                end
            end
        end
        if consumed then break end
    end

    -- Fallback: try DominionRuntimeBlueprintLibrary item removal helper if exposed
    if not consumed then
        pcall(function()
            local bpLib = StaticFindObject("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
            if bpLib and bpLib:IsValid() then
                if bpLib.RemoveItemFromPlayer then
                    local ok, res = pcall(function() return bpLib:RemoveItemFromPlayer(pawn, itemData, qty) end)
                    if ok and (res == nil or res == true) then consumed = true end
                elseif bpLib.ConsumeItemForPlayer then
                    local ok, res = pcall(function() return bpLib:ConsumeItemForPlayer(pawn, itemData, qty) end)
                    if ok and (res == nil or res == true) then consumed = true end
                end
            end
        end)
    end

    return consumed
end

local function ConsumeRunesForSpellEntry(pawn, entry)
    if not Config.ConsumeRunesOnSwappedCasts or not pawn or not pawn:IsValid() or not entry then
        return true
    end

    -- 1. If the spell asset explicitly specifies SpellModule_CostItems (e.g. HAM_IceBarrage / HAM_BloodBarrage), consume those exact items
    if entry.costItems and #entry.costItems > 0 then
        for _, cost in ipairs(entry.costItems) do
            if cost.itemData and cost.itemData:IsValid() then
                local ok = ConsumeItemsFromInventory(pawn, cost.itemData, cost.count)
                DebugLog(string.format("Rune/Cost consume [%s]: %s x%d -> %s",
                    tostring(entry.shortName), tostring(cost.itemName), cost.count, tostring(ok)))
            end
        end
        return true
    end

    -- 2. Otherwise, for standard elemental / wand casts triggered directly by ArcaneWilds, consume 1 matching element rune
    local catLower = (entry.categoryTag or ""):lower():gsub("_wand$", ""):gsub("_hold$", "")
    local runeItem = State.RuneItemDataCache[catLower]
    if not runeItem or not runeItem:IsValid() then
        DiscoverRuneItemAssets()
        runeItem = State.RuneItemDataCache[catLower]
    end

    if runeItem and runeItem:IsValid() then
        local ok = ConsumeItemsFromInventory(pawn, runeItem, 1)
        DebugLog(string.format("Swapped element rune consume [%s]: %s x1 -> %s",
            tostring(entry.shortName), SpellScanner.ExtractShortObjectName(SpellScanner.SafeGetName(runeItem)), tostring(ok)))
    end
    return true
end

local function PickWeightedMacroForElement(anchorCategory)
    if #State.ParsedMacros == 0 then return nil end
    local anchorLower = anchorCategory and anchorCategory:lower() or nil
    local baseLower = anchorLower and anchorLower:gsub("_wand$", ""):gsub("_hold$", "") or nil
    local candidates = {}

    if anchorLower then
        for _, m in ipairs(State.ParsedMacros) do
            if m.stages[1] and m.stages[1].elementLower == anchorLower then
                table.insert(candidates, m)
            end
        end
        if #candidates == 0 and baseLower ~= anchorLower then
            for _, m in ipairs(State.ParsedMacros) do
                if m.stages[1] and m.stages[1].elementLower == baseLower then
                    table.insert(candidates, m)
                end
            end
        end
        if #candidates == 0 then
            for _, m in ipairs(State.ParsedMacros) do
                if m.stages[1] and m.stages[1].elementLower == "*" then
                    table.insert(candidates, m)
                end
            end
        end
    else
        for _, m in ipairs(State.ParsedMacros) do
            if m.stages[1] and m.stages[1].elementLower == "*" then
                table.insert(candidates, m)
            end
        end
    end

    if #candidates == 0 then return nil end

    local totalWeight = 0.0
    for _, m in ipairs(candidates) do
        totalWeight = totalWeight + (m.weight or 1.0)
    end
    if totalWeight <= 0.0 then return candidates[1] end

    local roll = math.random() * totalWeight
    local acc = 0.0
    for _, m in ipairs(candidates) do
        acc = acc + (m.weight or 1.0)
        if roll <= acc then return m end
    end
    return candidates[#candidates]
end

local function SetAllComboMontageRates(targetRate)
    for _, entry in pairs(State.SpellRegistry) do
        local montage = entry.montageObj
        if montage and montage:IsValid() then
            local clampMax = math.max(1.0, tonumber(Config.MaxFinisherSpeedClamp) or 5.0)
            if entry.isSmash and Config.KeepGroundSmashAnchored then
                pcall(function() montage.RateScale = math.min(targetRate, clampMax) end)
            else
                pcall(function() montage.RateScale = targetRate end)
            end
        end
    end
end

local function IsNotifyClampedEntry(entry)
    if not entry then return false end
    local sName = (entry.shortName or ""):lower()
    local mName = (entry.montageName or ""):lower()
    return entry.isSmash
        or sName:find("slam") ~= nil
        or sName:find("smash") ~= nil
        or sName:find("meteor") ~= nil
        or mName:find("meteor") ~= nil
        or mName:find("slam") ~= nil
end

local function ApplyMontageRateToInstance(pawn, montageObj, targetRate, isAirSmash)
    local effectiveRate = targetRate
    if isAirSmash and Config.KeepGroundSmashAnchored then
        local clampMax = math.max(1.0, tonumber(Config.MaxFinisherSpeedClamp) or 5.0)
        effectiveRate = math.min(targetRate, clampMax)
    end
    if montageObj and montageObj:IsValid() then
        pcall(function() montageObj.RateScale = effectiveRate end)
    end
    if pawn and pawn:IsValid() then
        pcall(function()
            local mesh = pawn.Mesh
            if mesh and mesh:IsValid() then
                local animInst = mesh:GetAnimInstance()
                if animInst and animInst:IsValid() then
                    local activeMontage = animInst:GetCurrentActiveMontage()
                    if activeMontage and activeMontage:IsValid() then
                        activeMontage.RateScale = effectiveRate
                        pcall(function() animInst:Montage_SetPlayRate(activeMontage, effectiveRate) end)
                    end
                end
            end
        end)
    end
end

local function ApplyStageSpeedAndPriming(combatMagic, stage, stepInStage, pawn)
    if not stage then return end
    local stepDesc = stage.steps[stepInStage] or stage.steps[1]
    local previewEntry = ResolveStepEntry(stage, stepDesc)
    local effectiveBaseSpeed = (previewEntry and previewEntry.customOverrideSpeed) or stage.speed
    local variedSpeed = RuleParser.ComputeVariedSpeed(effectiveBaseSpeed, Config.BonusSpeedVariancePct)
    local stepDesc = stage.steps[stepInStage] or stage.steps[1]
    local entry = ResolveStepEntry(stage, stepDesc)
    local isAirSmash = IsNotifyClampedEntry(entry)

    State.ActiveStageTargetSpeed = variedSpeed
    State.ActiveStageIsAirSmash = isAirSmash
    State.StepInFlight = false
    State.InFlightSpellObj = nil

    if Config.DebugMode then
        DebugLog(string.format("Stage %d/%d Step %d/%d (speed=%.2fx, base=%.2fx) => %s",
            State.StageIndex, State.ActiveMacro and #State.ActiveMacro.stages or 0,
            stepInStage, #stage.steps, variedSpeed, tonumber(stage.speed) or 1.0,
            DescribeStepDescriptor(stage, stepDesc)))
    end

    if entry and entry.montageObj and entry.montageObj:IsValid() then
        ApplyMontageRateToInstance(pawn, entry.montageObj, variedSpeed, isAirSmash)
    end
    local targetChain = State.SpellChains[stage.elementLower]
    if targetChain then
        for idx, montage in pairs(targetChain.montages) do
            if montage and montage:IsValid() then
                local chainAirSmash = (idx == 3 and stage.elementLower:find("^air") ~= nil)
                ApplyMontageRateToInstance(nil, montage, variedSpeed, chainAirSmash)
            end
        end
    end

    if combatMagic and combatMagic:IsValid() then
        if entry and entry.prevSpellObj and entry.prevSpellObj:IsValid() then
            pcall(function() combatMagic.LastChainedSpell = entry.prevSpellObj end)
            State.LastObservedChainedSpell = entry.prevSpellObj
        else
            pcall(function() combatMagic.LastChainedSpell = nil end)
            State.LastObservedChainedSpell = nil
        end
    end
end

local function RestoreAnchorElementAndReset(combatMagic)
    local anchor = State.AnchorElement or State.LastKnownEquippedElement
    State.ActiveMacro = nil
    State.StageIndex = 1
    State.StepInStage = 1
    State.PendingAnchorReturn = false
    State.StepInFlight = false
    State.InFlightSpellObj = nil
    State.ActiveStageTargetSpeed = 1.0
    State.ActiveStageIsAirSmash = false
    State.LastObservedChainedSpell = nil
    State.LastCastSpellData = nil

    if combatMagic and combatMagic:IsValid() then
        pcall(function() combatMagic.LastChainedSpell = nil end)
    end
    if not State.ModifierHeld then
        SetAllComboMontageRates(1.0)
    end
    DebugLog("Restored anchor category: " .. tostring(anchor or "None"))
end

-- Trigger spell ability AND deduct real runes/items when casting via ArcaneWilds
local function TriggerSpellEntryForPlayer(pawn, entry)
    if not pawn or not pawn:IsValid() or not entry or not entry.spellObj or not entry.spellObj:IsValid() then
        return false
    end
    local bpLib = StaticFindObject("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
    if bpLib and bpLib:IsValid() then
        local ok = pcall(function()
            bpLib:TriggerModularAbilityForPlayer(pawn, entry.spellObj)
        end)
        if ok then
            ConsumeRunesForSpellEntry(pawn, entry)
            CustomSpells.TriggerCustomPresentation(pawn, entry, SpellScanner.SafeGetName)
            return true
        end
    end
    return false
end

local function IsModifierDown(pc)
    if not Config.RequireModifierKey then return true end
    if not pc or not pc:IsValid() then return false end
    local mk = (Config.ModifierKey or "RMB"):upper()
    local down = false
    pcall(function()
        if mk == "RMB" or mk == "BLOCK" or mk == "RIGHTMOUSE" then
            down = pc:IsInputKeyDown({ KeyName = FName("RightMouseButton") })
                or pc:IsInputKeyDown({ KeyName = FName("Gamepad_LeftTrigger") })
                or pc:IsInputKeyDown({ KeyName = FName("Gamepad_LeftShoulder") })
        elseif mk == "SHIFT" then
            down = pc:IsInputKeyDown({ KeyName = FName("LeftShift") }) or pc:IsInputKeyDown({ KeyName = FName("RightShift") })
        elseif mk == "ALT" then
            down = pc:IsInputKeyDown({ KeyName = FName("LeftAlt") }) or pc:IsInputKeyDown({ KeyName = FName("RightAlt") })
        elseif mk == "CTRL" then
            down = pc:IsInputKeyDown({ KeyName = FName("LeftControl") }) or pc:IsInputKeyDown({ KeyName = FName("RightControl") })
        elseif mk == "MOUSE4" then
            down = pc:IsInputKeyDown({ KeyName = FName("ThumbMouseButton") })
        elseif mk == "MOUSE5" then
            down = pc:IsInputKeyDown({ KeyName = FName("ThumbMouseButton2") })
        elseif mk == "MMB" then
            down = pc:IsInputKeyDown({ KeyName = FName("MiddleMouseButton") })
        else
            down = pc:IsInputKeyDown({ KeyName = FName(mk) })
        end
    end)
    return down
end

local function IsPrimaryAttackDown(pc)
    if not pc or not pc:IsValid() then return false end
    local down = false
    pcall(function()
        down = pc:IsInputKeyDown({ KeyName = FName("LeftMouseButton") })
            or pc:IsInputKeyDown({ KeyName = FName("Gamepad_RightTrigger") })
    end)
    return down
end

local function RollAndEngageMacroForAnchor(pawn, combatMagic, anchor)
    local macro = PickWeightedMacroForElement(anchor)
    State.ActiveMacro = macro
    State.StageIndex = 1
    State.StepInStage = 1
    State.PendingAnchorReturn = false
    State.LastCastSpellData = nil

    if macro then
        Log(string.format("Anchor [%s] -> Locked macro (%d stages): %s",
            tostring(anchor or "None"), #macro.stages, macro.raw))
        ApplyStageSpeedAndPriming(combatMagic, macro.stages[1], 1, pawn)
    else
        Log(string.format("Anchor [%s] -> No matching rule in combo_rules.txt, using fallback cutoff (%d)",
            tostring(anchor or "None"), Config.DefaultComboCutoff))
    end
end

local function EngageModifierAndRollMacro(pawn, combatMagic)
    local anchor = DetectEquippedCategory(pawn, combatMagic)
    State.AnchorElement = anchor
    RollAndEngageMacroForAnchor(pawn, combatMagic, anchor)
end

local function ReleaseModifierAndRevert(pawn, combatMagic)
    local originalAnchor = State.AnchorElement
    local hadSwappedStage = (State.ActiveMacro ~= nil and State.StageIndex > 1)
    RestoreAnchorElementAndReset(combatMagic)
    SetAllComboMontageRates(1.0)
    if hadSwappedStage and originalAnchor then
        -- Queue one return-to-original-spell cast so the player never stays stuck on the swapped ending element
        State.AnchorElement = originalAnchor
        State.PendingAnchorReturn = true
        Log("Modifier RELEASED mid-swap -> Returning to original spell [" .. tostring(originalAnchor) .. "] & 100% base speed")
    else
        local currentEquipped = DetectEquippedCategory(pawn, combatMagic) or originalAnchor
        State.AnchorElement = currentEquipped
        Log("Modifier RELEASED -> Restored anchor [" .. tostring(currentEquipped or "None") .. "] & 100% base speed")
    end
end

local function AdvanceLockedMacro(pawn, combatMagic)
    local macro = State.ActiveMacro
    if not macro or not macro.stages or #macro.stages == 0 then return end

    local curStage = macro.stages[State.StageIndex]
    if not curStage then
        RestoreAnchorElementAndReset(combatMagic)
        return
    end

    if State.StepInStage < #curStage.steps then
        State.StepInStage = State.StepInStage + 1
        ApplyStageSpeedAndPriming(combatMagic, curStage, State.StepInStage, pawn)
    elseif State.StageIndex < #macro.stages then
        State.StageIndex = State.StageIndex + 1
        State.StepInStage = 1
        ApplyStageSpeedAndPriming(combatMagic, macro.stages[State.StageIndex], 1, pawn)
    else
        -- Macro finished: strictly lock to the ORIGINAL starting anchor spell (never re-detect from the ending swapped spell!)
        local lockedAnchor = State.AnchorElement or State.LastKnownEquippedElement
        State.AnchorElement = lockedAnchor
        State.ActiveMacro = nil
        State.StageIndex = 1
        State.StepInStage = 1
        State.PendingAnchorReturn = true
        State.StepInFlight = false
        State.InFlightSpellObj = nil
        State.LastObservedChainedSpell = nil
        State.LastCastSpellData = nil

        if combatMagic and combatMagic:IsValid() then
            pcall(function() combatMagic.LastChainedSpell = nil end)
        end

        SetAllComboMontageRates(1.0)
        DebugLog("Macro finished -> Returning to original anchor [" .. tostring(lockedAnchor or "None") .. "] before next roll")
    end
end

local function RunDebugInspection()
    if not Config.AllowDebugCommands then return end
    LoadConfigFile(true)
    RefreshSpells()
    Log("=== DEBUG DUMP (combo_rules.txt & spell_names.txt reloaded; detected_spells.txt updated) ===")
    local _, pawn, combatMagic, actionPerformer = GetPlayerPawnAndComponents()
    Log("AnchorCategory=" .. tostring(State.AnchorElement)
        .. " | LastKnownEquipped=" .. tostring(State.LastKnownEquippedElement)
        .. " | LoadedRules=" .. tostring(#State.ParsedMacros))
    LogParsedMacrosSpellMapping("SHIFT+DebugHotkey: Combo Rules -> Direct Spell Asset Mapping")
    if pawn and pawn:IsValid() then
        local targets = {
            { label = "PlayerCombatMagicComponent", obj = combatMagic },
            { label = "PlayerActionPerformerComponent", obj = actionPerformer },
            { label = "InputBuffer", obj = pawn.InputBuffer }
        }
        for _, t in ipairs(targets) do
            if t.obj and t.obj:IsValid() then
                Log("Component: " .. SpellScanner.SafeGetName(t.obj))
            end
        end
    end
end

local function BindDebugHotkey()
    local rawKey = (Config.DebugHotkey or "OEM_5"):upper()
    if rawKey == "\\" or rawKey == "BACKSLASH" then rawKey = "OEM_5" end
    if State.BoundDebugKey == rawKey then return end
    State.BoundDebugKey = rawKey

    local keyEnum = Key[rawKey] or Key.OEM_5
    pcall(function()
        RegisterKeyBind(keyEnum, { ModifierKey.SHIFT }, function()
            if Config.AllowDebugCommands then
                ExecuteInGameThread(function()
                    RunDebugInspection()
                end)
            end
        end)
    end)
end

LoopAsync(50, function()
    local now = os.clock()
    if (now - State.LastConfigPollTime) >= 0.30 then
        State.LastConfigPollTime = now
        LoadConfigFile(false)
        BindDebugHotkey()
    end

    if not Config.Enabled then return false end

    local pc, pawn, combatMagic = GetPlayerPawnAndComponents()
    if not pc or not pawn then return false end

    if (now - State.LastScanTime) >= 3.0 then
        State.LastScanTime = now
        RefreshSpells()
    end

    if not State.ActiveMacro and not State.PendingAnchorReturn then
        DetectEquippedCategory(pawn, combatMagic)
    end

    local modDown = IsModifierDown(pc)
    if modDown and not State.ModifierHeld then
        State.ModifierHeld = true
        EngageModifierAndRollMacro(pawn, combatMagic)
    elseif not modDown and State.ModifierHeld then
        State.ModifierHeld = false
        ReleaseModifierAndRevert(pawn, combatMagic)
    end

    -- When a macro completes, return to the ORIGINAL starting anchor spell FIRST and wait for it to finish
    -- before rolling any new combo (so the ending spell of the chain NEVER starts a new chain!)
    if State.PendingAnchorReturn and not State.ActiveMacro and combatMagic and combatMagic:IsValid() then
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
            -- Step 1: Fire the original starting anchor spell once when idle
            if not curActor and (now - (State.LastTriggeredSpellTime or 0)) >= 0.16 then
                if starterEntry and starterEntry.spellObj and starterEntry.spellObj:IsValid() then
                    State.LastTriggeredSpellTime = now
                    State.LastAutoAttackTime = now
                    State.StepInFlight = true
                    State.InFlightSpellObj = starterEntry.spellObj
                    State.InFlightStartedTime = now
                    TriggerSpellEntryForPlayer(pawn, starterEntry)
                    DebugLog("Casting return-to-anchor spell [" .. tostring(anchor) .. "] before any re-roll")
                else
                    -- Standalone spell (e.g. HAM_BloodBarrage) where starter is in SpellRegistry directly
                    local directEntry = anchor and State.SpellRegistry[anchor:lower()]
                    if directEntry and directEntry.spellObj and directEntry.spellObj:IsValid() then
                        State.LastTriggeredSpellTime = now
                        State.LastAutoAttackTime = now
                        State.StepInFlight = true
                        State.InFlightSpellObj = directEntry.spellObj
                        State.InFlightStartedTime = now
                        TriggerSpellEntryForPlayer(pawn, directEntry)
                        DebugLog("Casting return-to-anchor standalone spell [" .. tostring(anchor) .. "] before any re-roll")
                    else
                        State.PendingAnchorReturn = false
                        if State.ModifierHeld then
                            RollAndEngageMacroForAnchor(pawn, combatMagic, anchor)
                        end
                    end
                end
            end
        else
            -- Step 2: Wait for the return-to-anchor cast to finish, then re-roll strictly from `anchor` ONLY if Modifier is still held
            local returnCastDone = (curActor == nil)
            local returnTimeout = (now - (State.InFlightStartedTime or now)) >= 3.0
            if returnCastDone or returnTimeout then
                State.StepInFlight = false
                State.InFlightSpellObj = nil
                State.PendingAnchorReturn = false
                if combatMagic and combatMagic:IsValid() then
                    pcall(function() combatMagic.LastChainedSpell = nil end)
                end
                if State.ModifierHeld then
                    DebugLog("Anchor return cast finished -> Re-rolling combo strictly from [" .. tostring(anchor) .. "]")
                    RollAndEngageMacroForAnchor(pawn, combatMagic, anchor)
                else
                    DebugLog("Anchor return cast finished (Modifier released) -> Staying cleanly on [" .. tostring(anchor) .. "]")
                end
            end
        end
    end

    if State.ModifierHeld and State.ActiveMacro and combatMagic and combatMagic:IsValid() then
        local curActor = nil
        local curActorData = nil
        pcall(function()
            local actor = combatMagic.CurrentSpellActor
            if actor and actor:IsValid() then
                curActor = actor
                if actor.Data and actor.Data:IsValid() then
                    curActorData = actor.Data
                end
            end
        end)

        if curActor and (State.ActiveStageTargetSpeed or 1.0) > 1.0 then
            local curStage = State.ActiveMacro.stages[State.StageIndex]
            local curDesc = curStage and (curStage.steps[State.StepInStage] or curStage.steps[1])
            local curEntry = curDesc and ResolveStepEntry(curStage, curDesc)
            ApplyMontageRateToInstance(pawn, curEntry and curEntry.montageObj, State.ActiveStageTargetSpeed, State.ActiveStageIsAirSmash)
        end

        local curStage = State.ActiveMacro.stages[State.StageIndex]
        if curStage then
            local expectedDesc = curStage.steps[State.StepInStage] or curStage.steps[1]
            local expectedEntry = ResolveStepEntry(curStage, expectedDesc)

            if curActorData and expectedEntry and expectedEntry.spellObj and curActorData == expectedEntry.spellObj then
                if not State.StepInFlight or State.InFlightSpellObj ~= curActorData then
                    State.StepInFlight = true
                    State.InFlightSpellObj = curActorData
                    State.InFlightStartedTime = now
                    State.LastCastSpellData = curActorData
                end
            end

            if State.StepInFlight then
                local castCompleted = (curActor == nil) or (curActorData ~= nil and curActorData ~= State.InFlightSpellObj)
                local safetyTimeout = (now - (State.InFlightStartedTime or now)) >= 4.5
                if castCompleted or safetyTimeout then
                    State.StepInFlight = false
                    State.InFlightSpellObj = nil
                    AdvanceLockedMacro(pawn, combatMagic)
                end
            else
                local curChained = nil
                pcall(function() curChained = combatMagic.LastChainedSpell end)
                if curChained and curChained:IsValid() and curChained ~= State.LastObservedChainedSpell then
                    State.LastObservedChainedSpell = curChained
                    if not curActor then
                        AdvanceLockedMacro(pawn, combatMagic)
                    end
                end
            end
        end
    end

    if Config.EnableAutoAttackHold then
        local atkDown = IsPrimaryAttackDown(pc)
        local shouldAuto = atkDown and (State.ModifierHeld or Config.AutoAttackAllCombos)
        local intervalSec = math.max(0.03, (tonumber(Config.AutoAttackIntervalMs) or 65) / 1000.0)

        if shouldAuto and not State.StepInFlight and (now - State.LastAutoAttackTime) >= intervalSec then
            local isBusy = false
            if combatMagic and combatMagic:IsValid() then
                pcall(function()
                    local actor = combatMagic.CurrentSpellActor
                    if actor and actor:IsValid() then isBusy = true end
                end)
            end

            if not isBusy and (now - (State.LastTriggeredSpellTime or 0)) >= 0.14 then
                State.LastAutoAttackTime = now
                State.LastTriggeredSpellTime = now
                if State.ModifierHeld and State.ActiveMacro then
                    local stage = State.ActiveMacro.stages[State.StageIndex]
                    if stage then
                        local stepDesc = stage.steps[State.StepInStage] or stage.steps[1]
                        local entry = ResolveStepEntry(stage, stepDesc)
                        if entry and entry.spellObj then
                            State.StepInFlight = true
                            State.InFlightSpellObj = entry.spellObj
                            State.InFlightStartedTime = now
                            TriggerSpellEntryForPlayer(pawn, entry)
                        end
                    end
                elseif Config.AutoAttackAllCombos then
                    local anchor = DetectEquippedCategory(pawn, combatMagic) or State.AnchorElement
                    local chain = anchor and State.SpellChains[anchor:lower()]
                    local starterName = chain and chain.stepNames and chain.stepNames[0]
                    local starterEntry = starterName and State.SpellRegistry[starterName:lower()]
                    if starterEntry then
                        TriggerSpellEntryForPlayer(pawn, starterEntry)
                    end
                end
            end
        end
    end

    return false
end)

NotifyOnNewObject("/Script/Dominion.DominionSpellData", function()
    ExecuteInGameThread(function()
        RefreshSpells()
    end)
end)

LoadConfigFile(true)
BindDebugHotkey()
Log("v" .. MOD_VERSION .. " initialized cleanly (ArcaneWilds active: rune consumption + Ancient Magicks reset fix).")
