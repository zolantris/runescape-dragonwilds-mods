-- ArcaneWilds v1.70.0 - Configuration, Hot-Reload File I/O & Registry Manager
-- Handles config.txt, spell_names.txt, custom_spells.txt, combo_rules.txt, and merged spell registry.

local RuleParser = require("rule_parser")
local SpellScanner = require("spell_scanner")
local CustomSpells = require("custom_spells")

local ConfigManager = {}

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

local DEFAULT_COMBO_RULES_JSON_CONTENT = [[{
  "$schema": "./schemas/combo_rules.schema.json",
  "rules": [
    {
      "name": "Air Full Chain",
      "enabled": true,
      "weight": 5,
      "stages": [
        { "category": "Air", "spells": ["bolt", "gust", "vortex", "slam"], "speed": 2.2 }
      ]
    },
    {
      "name": "Water Full Chain",
      "enabled": true,
      "weight": 5,
      "stages": [
        { "category": "Water", "spells": ["bolt", "waterfall", "wave", "tsunami"], "speed": 2.2 }
      ]
    },
    {
      "name": "Water Opener -> Saradomin Godsword",
      "enabled": true,
      "weight": 5,
      "stages": [
        { "category": "Water", "spells": ["bolt", "waterfall", "wave"], "speed": 2.0 },
        { "spell": "SaradominGodsword", "speed": 1.5 }
      ]
    },
    {
      "name": "Fire Opener -> Air Finisher",
      "enabled": true,
      "weight": 5,
      "stages": [
        { "category": "Fire", "spells": ["bolt_1", "bolt_2"], "speed": 2.2 },
        { "category": "Air", "spells": ["gust", "vortex"], "speed": 2.2 }
      ]
    },
    {
      "name": "Earth Opener -> Flames of Zamorak",
      "enabled": true,
      "weight": 5,
      "stages": [
        { "category": "Earth", "spells": ["bolt", "spike", "shatter"], "speed": 2.0 },
        { "spell": "FlamesOfZamorak", "speed": 2.0 }
      ]
    }
  ]
}
]]

local DEFAULT_CUSTOM_SPELLS_JSON_CONTENT = [[{
  "$schema": "./schemas/custom_spells.schema.json",
  "spells": {}
}
]]

local DEFAULT_QUICK_CAST_CONTENT = table.concat({
    "# ArcaneWilds Quick-Cast Hotkeys (Hot-Reloaded Automatically on Save!)",
    "# Syntax: [Modifier +] Key1, Key2 = SpellName (or Category@spell:speed -> ...)",
    "# Modifiers: Block (RMB / LT / RB), Shift, Alt, Ctrl, None",
    "# Controller Aliases: GP_X, GP_Y, GP_B, GP_A, GP_LB, GP_RB, GP_LT, GP_RT",
    "Block + 1, GP_X = SaradominGodsword",
    "Block + 2, GP_Y = FlamesOfZamorak",
    "Block + 3, GP_B = StormOfArmadyl",
    "Block + 4, GP_A = SaradominStrike"
}, "\n") .. "\n"

local ORDERED_CONFIG_KEYS = {
    "Enabled", "DebugMode", "AllowDebugCommands", "DebugHotkey",
    "RequireModifierKey", "ModifierKey", "ConsumeRunesOnSwappedCasts",
    "EnableQuickCastHotkeys", "QuickCastRequireModifier", "QuickCastSuppressGameActions",
    "ActiveQuickCastCount",
    "QuickCastHotkey1", "QuickCastSpell1",
    "QuickCastHotkey2", "QuickCastSpell2",
    "QuickCastHotkey3", "QuickCastSpell3",
    "QuickCastHotkey4", "QuickCastSpell4",
    "TriggerComboOnModifierHold", "EnableAutoAttackHold", "AutoAttackAllCombos", "AutoAttackIntervalMs",
    "DefaultComboCutoff", "BonusSpeedVariancePct",
    "UnlockAir", "UnlockFire", "UnlockWater", "UnlockEarth",
    "UnlockModdedCombat", "UnlockUtilitySpells", "KeepGroundSmashAnchored", "MaxFinisherSpeedClamp", "InjectSpecialBarOnSpecials", "SpecialBarInjectAmount", "RequireSpecialEnergyForSpecials", "MinSpecialEnergyCost", "AllowFastSpecialCast", "MaxSpecialCastRate", "PostSpecialPauseSec", "AnimRepeatPadSec",
    "AutoTargetMaxDistance", "AutoTargetConeDeg",
    "EnableStaffDamageScaling", "StaffBaselineTier", "StaffTierStep", "StaffMasterworkBonus", "NoStaffDamageMultiplier",
    "EnforceSpellLevelRequirements", "DefaultCustomSpellRequiredMagicLevel", "NotifyOnLockedSpellCast", "LockedSpellNotifyStyle", "LockedSpellNotifyCooldownSec",
    "MaxMoveSpeed", "ActiveComboRulesCount", "DetectedSpellsSummary"
}

function ConfigManager.Trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function ConfigManager.ParseBool(v, defaultVal)
    if v == nil then return defaultVal end
    local l = ConfigManager.Trim(tostring(v)):lower()
    if l == "true" or l == "1" or l == "yes" or l == "on" then return true end
    if l == "false" or l == "0" or l == "no" or l == "off" then return false end
    return defaultVal
end

function ConfigManager.CreateDefaultConfig()
    return {
        Enabled = true,
        DebugMode = true,
        AllowDebugCommands = true,
        DebugHotkey = "OEM_5",
        RequireModifierKey = true,
        ModifierKey = "RMB",
        ConsumeRunesOnSwappedCasts = true,
        EnableQuickCastHotkeys = true,
        QuickCastRequireModifier = true,
        QuickCastSuppressGameActions = true,
        ActiveQuickCastCount = "Loading quick_cast.txt...",
        QuickCastHotkey1 = "1,GP_X",
        QuickCastSpell1 = "SaradominGodsword",
        QuickCastHotkey2 = "2,GP_Y",
        QuickCastSpell2 = "FlamesOfZamorak",
        QuickCastHotkey3 = "3,GP_B",
        QuickCastSpell3 = "StormOfArmadyl",
        QuickCastHotkey4 = "4,GP_A",
        QuickCastSpell4 = "SaradominStrike",
        TriggerComboOnModifierHold = false,
        EnableAutoAttackHold = true,
        AutoAttackAllCombos = true,
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
        InjectSpecialBarOnSpecials = true,
        SpecialBarInjectAmount = 100.0,
        RequireSpecialEnergyForSpecials = false,
        MinSpecialEnergyCost = 25.0,
        AllowFastSpecialCast = true,
        MaxSpecialCastRate = 1.8,
        PostSpecialPauseSec = 0.65,
        AnimRepeatPadSec = 0.45,
        AutoTargetMaxDistance = 700.0,
        AutoTargetConeDeg = 45.0,
        EnableStaffDamageScaling = true,
        StaffBaselineTier = 1,
        StaffTierStep = 0.30,
        StaffMasterworkBonus = 0.15,
        NoStaffDamageMultiplier = 0.50,
        EnforceSpellLevelRequirements = true,
        DefaultCustomSpellRequiredMagicLevel = 0,
        NotifyOnLockedSpellCast = true,
        LockedSpellNotifyStyle = "auto",
        LockedSpellNotifyCooldownSec = 1.5,
        MaxMoveSpeed = 600.0,
        ActiveComboRulesCount = "Loading combo_rules.json...",
        DetectedSpellsSummary = "Auto-detecting on world load..."
    }
end

function ConfigManager.SaveConfigFile(paths, config)
    local f = io.open(paths.CONFIG_PATH, "w")
    if not f then return end
    for _, k in ipairs(ORDERED_CONFIG_KEYS) do
        f:write(k .. "=" .. tostring(config[k]) .. "\n")
    end
    f:close()
end

function ConfigManager.ResolveStepEntry(state, stage, stepDescriptor)
    if not stepDescriptor then return nil end

    if stepDescriptor.assetName and stepDescriptor.assetName ~= "" then
        local kLower = stepDescriptor.assetName:lower()
        local exact = state.SpellRegistry[kLower]
        if exact and ((exact.spellObj and exact.spellObj:IsValid()) or exact.suppressBaseSpell) then
            return exact
        end
        if state.CustomSpellDefs and state.CustomSpellDefs[kLower] then
            local rebuilt = CustomSpells.BuildCustomRegistryEntries(
                { [kLower] = state.CustomSpellDefs[kLower] },
                state.SpellRegistry, state.SpellChains, state.RuneItemDataCache,
                SpellScanner.SafeGetName, SpellScanner.ExtractShortObjectName)
            if rebuilt[kLower] then
                state.SpellRegistry[kLower] = rebuilt[kLower]
                return rebuilt[kLower]
            end
        end
    end

    local catLower = stage and stage.elementLower or nil
    if catLower and catLower ~= "*" then
        if state.SpellRegistry[catLower] and state.SpellRegistry[catLower].spellObj and state.SpellRegistry[catLower].spellObj:IsValid() then
            return state.SpellRegistry[catLower]
        end
        local chain = state.SpellChains[catLower]
        if chain then
            local idx = stepDescriptor.fallbackIndex or 0
            local sName = chain.stepNames and chain.stepNames[idx]
            if sName and state.SpellRegistry[sName:lower()] then
                return state.SpellRegistry[sName:lower()]
            end
        end
    end

    return nil
end

function ConfigManager.DescribeStepDescriptor(state, stage, stepDescriptor)
    if not stepDescriptor then return "<nil>" end
    local tok = tostring(stepDescriptor.token or "?")
    local targetAsset = stepDescriptor.assetName
    local entry = ConfigManager.ResolveStepEntry(state, stage, stepDescriptor)

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

function ConfigManager.LogParsedMacrosSpellMapping(config, state, logFn, headerLabel)
    if not config.DebugMode and not config.AllowDebugCommands then
        return
    end
    logFn("=== " .. tostring(headerLabel or "Combo Rules -> Direct Spell Asset Mapping") .. " ===")
    if #state.ParsedMacros == 0 then
        logFn("  (No active macros parsed from combo_rules.txt)")
        return
    end
    for rIdx, m in ipairs(state.ParsedMacros) do
        logFn(string.format("  Rule #%d [weight=%s, stages=%d]: %s", rIdx, tostring(m.weight), #m.stages, m.raw))
        for sIdx, st in ipairs(m.stages) do
            local resolvedParts = {}
            for _, desc in ipairs(st.steps) do
                table.insert(resolvedParts, ConfigManager.DescribeStepDescriptor(state, st, desc))
            end
            logFn(string.format("    Stage %d [%s @ %.2fx]: %s",
                sIdx, tostring(st.element), tonumber(st.speed) or 1.0, table.concat(resolvedParts, " ; ")))
        end
    end
end

function ConfigManager.LoadSpellNamesFile(paths, state)
    local f = io.open(paths.SPELL_NAMES_PATH, "r")
    if not f then
        local wf = io.open(paths.SPELL_NAMES_PATH, "w")
        if wf then
            wf:write(DEFAULT_SPELL_NAMES_CONTENT)
            wf:close()
        end
        f = io.open(paths.SPELL_NAMES_PATH, "r")
        if not f then return false end
    end
    local raw = f:read("*a") or ""
    f:close()
    if state.LastSpellNamesRaw ~= raw then
        state.LastSpellNamesRaw = raw
        state.NameMapByCat, state.GlobalNameMap = RuleParser.ParseSpellNameMap(raw)
        return true
    end
    return false
end

local function ReadExistingFile(path)
    if not path or path == "" then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a") or ""
    f:close()
    return content
end

function ConfigManager.LoadCustomSpellsFile(paths, state, logFn)
    local jsonPath = paths.CUSTOM_SPELLS_JSON_PATH
    local txtPath  = paths.CUSTOM_SPELLS_PATH

    local activePath = nil
    local raw = nil
    local isJson = false

    if jsonPath then
        raw = ReadExistingFile(jsonPath)
        if raw ~= nil then
            activePath = jsonPath
            isJson = true
        end
    end
    if raw == nil and txtPath then
        raw = ReadExistingFile(txtPath)
        if raw ~= nil then
            activePath = txtPath
            isJson = false
        end
    end
    if raw == nil then
        local createPath = jsonPath or txtPath
        if createPath then
            local wf = io.open(createPath, "w")
            if wf then
                if jsonPath then
                    wf:write(DEFAULT_CUSTOM_SPELLS_JSON_CONTENT)
                else
                    wf:write("# Arcane Wilds Custom Spells\n")
                end
                wf:close()
            end
            raw = ReadExistingFile(createPath) or ""
            activePath = createPath
            isJson = (jsonPath ~= nil)
        else
            return false
        end
    end

    local sourceLabel = isJson and "custom_spells.json" or "custom_spells.txt"
    local rawKey = sourceLabel .. "\0" .. raw
    if state.LastCustomSpellsRaw ~= rawKey then
        local isInitial = (state.LastCustomSpellsRaw == nil)
        state.LastCustomSpellsRaw = rawKey
        local parsedDefs, parseErr = CustomSpells.ParseDefinitions(raw)
        if parseErr or not parsedDefs then
            state.LastCustomSpellsError = tostring(parseErr or "unknown parse error")
            if logFn then
                logFn(string.format("[ERROR] Failed to parse %s (%s) - keeping previous valid custom spells!",
                    sourceLabel, state.LastCustomSpellsError))
            end
            return false
        end
        state.LastCustomSpellsError = nil
        state.CustomSpellDefs = parsedDefs
        if not isInitial and logFn then
            logFn("Hot-reloaded " .. sourceLabel)
        end
        return true
    end
    return false
end

function ConfigManager.RebuildMergedRegistry(state)
    local merged = {}
    for k, v in pairs(state.BaseSpellRegistry) do
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
        state.CustomSpellDefs, merged, state.SpellChains, state.RuneItemDataCache,
        SpellScanner.SafeGetName, SpellScanner.ExtractShortObjectName)
    for k, cEntry in pairs(customEntries) do
        merged[k] = cEntry
        lookup[k] = cEntry.shortName
    end
    state.SpellRegistry = merged
    state.DiscoveredLookup = lookup
end

local function NormalizeLegacyComboRulesText(rawText)
    local lines = {}
    for line in tostring(rawText or ""):gmatch("[^\r\n]+") do
        local clean = ConfigManager.Trim(line)
        if clean ~= "" and not clean:match("^#") and not clean:match("^;") then
            local hashPos = clean:find("#", 1, true)
            if hashPos then
                clean = ConfigManager.Trim(clean:sub(1, hashPos - 1))
            end
            if clean ~= "" then
                if not clean:match(";$") and (clean:find("@", 1, true) or clean:find("->", 1, true)) then
                    clean = clean .. ";"
                end
                table.insert(lines, clean)
            end
        end
    end
    return table.concat(lines, " ")
end

function ConfigManager.LoadComboRulesFile(paths, config, state, logFn, forceRebuild, legacyRuleFallback)
    local namesChanged = ConfigManager.LoadSpellNamesFile(paths, state)
    local customChanged = ConfigManager.LoadCustomSpellsFile(paths, state, logFn)
    if customChanged then
        CustomSpells.ClearCache()
        pcall(function() require("timeline_runner").ClearValidationCache() end)
        if next(state.BaseSpellRegistry) ~= nil then
            ConfigManager.RebuildMergedRegistry(state)
        end
    end

    local jsonPath = paths.COMBO_RULES_JSON_PATH
    local txtPath  = paths.COMBO_RULES_PATH

    local raw = nil
    local isJson = false
    if jsonPath then
        raw = ReadExistingFile(jsonPath)
        if raw ~= nil then
            isJson = true
        end
    end
    if raw == nil and txtPath then
        raw = ReadExistingFile(txtPath)
        if raw ~= nil then
            isJson = false
        end
    end
    if raw == nil then
        local createPath = jsonPath or txtPath
        if not createPath then return end
        local wf = io.open(createPath, "w")
        if wf then
            if jsonPath and (not legacyRuleFallback or ConfigManager.Trim(legacyRuleFallback) == "") then
                wf:write(DEFAULT_COMBO_RULES_JSON_CONTENT)
                isJson = true
            elseif legacyRuleFallback and ConfigManager.Trim(legacyRuleFallback) ~= "" then
                wf:write("# Migrated from config.txt WeightedComboRules\n")
                wf:write(ConfigManager.Trim(legacyRuleFallback) .. "\n")
                isJson = false
            else
                wf:write(DEFAULT_COMBO_RULES_JSON_CONTENT)
                isJson = true
            end
            wf:close()
        end
        raw = ReadExistingFile(createPath)
        if raw == nil then return end
    end

    local sourceLabel = isJson and "combo_rules.json" or "combo_rules.txt"
    local parseInput = isJson and raw or NormalizeLegacyComboRulesText(raw)
    local rawKey = sourceLabel .. "\0" .. parseInput

    if forceRebuild or namesChanged or customChanged or state.LastComboRulesRaw ~= rawKey then
        local isInitial = (state.LastComboRulesRaw == nil)
        state.LastComboRulesRaw = rawKey
        local parsedMacros, parseErr = RuleParser.ParseWeightedMacros(
            parseInput, state.NameMapByCat, state.GlobalNameMap, state.DiscoveredLookup)

        if parseErr or not parsedMacros then
            state.LastComboRulesError = tostring(parseErr or "unknown parse error")
            local errStatus = string.format("ERROR in %s (%s)", sourceLabel, state.LastComboRulesError)
            config.ActiveComboRulesCount = errStatus
            if errStatus ~= state.LastRulesStatusWritten then
                state.LastRulesStatusWritten = errStatus
                ConfigManager.SaveConfigFile(paths, config)
            end
            if logFn then
                logFn(string.format("[ERROR] Failed to parse %s (%s) - keeping previous %d active macro(s)!",
                    sourceLabel, state.LastComboRulesError, #(state.ParsedMacros or {})))
            end
            return
        end

        state.LastComboRulesError = nil
        state.LastValidComboRulesRaw = parseInput
        state.ParsedMacros = parsedMacros

        local statusStr = string.format("%d macro(s) active from %s", #state.ParsedMacros, sourceLabel)
        config.ActiveComboRulesCount = statusStr
        if statusStr ~= state.LastRulesStatusWritten then
            state.LastRulesStatusWritten = statusStr
            ConfigManager.SaveConfigFile(paths, config)
        end

        if logFn then
            if isInitial then
                logFn("Loaded " .. tostring(#state.ParsedMacros) .. " macro(s) from " .. sourceLabel)
            else
                logFn("Hot-reloaded " .. sourceLabel .. " / spell_names.txt -> " .. tostring(#state.ParsedMacros) .. " macro(s) active!")
                for idx, m in ipairs(state.ParsedMacros) do
                    logFn(string.format("  Rule #%d [weight=%s, stages=%d]: %s", idx, tostring(m.weight), #m.stages, m.raw))
                end
                ConfigManager.LogParsedMacrosSpellMapping(config, state, logFn, "Hot-Reloaded Combo Rules -> Direct Spell Asset Mapping")
            end
        end
    end
end

local function ParseQuickCastBindings(rawText, defaultRequireMod)
    local bindings = {}
    if not rawText or rawText == "" then return bindings end
    for line in rawText:gmatch("[^\r\n]+") do
        local clean = ConfigManager.Trim(line)
        if clean ~= "" and not clean:match("^#") and not clean:match("^;") then
            local hashPos = clean:find("#", 1, true)
            if hashPos then
                clean = ConfigManager.Trim(clean:sub(1, hashPos - 1))
            end
            if clean ~= "" then
                local lhs, rhs = clean:match("^([^=]+)=(.+)$")
                if lhs and rhs then
                    lhs = ConfigManager.Trim(lhs)
                    rhs = ConfigManager.Trim(rhs)
                    if lhs ~= "" and rhs ~= "" then
                        local modifier = nil
                        local keysPart = lhs
                        local plusMod, rest = lhs:match("^([%w_]+)%s*%+%s*(.+)$")
                        if plusMod and rest then
                            modifier = ConfigManager.Trim(plusMod):upper()
                            keysPart = ConfigManager.Trim(rest)
                        else
                            modifier = defaultRequireMod and "BLOCK" or "NONE"
                        end
                        if modifier == "RMB" or modifier == "MODIFIER" or modifier == "MOD" then
                            modifier = "BLOCK"
                        elseif modifier == "OFF" or modifier == "FALSE" or modifier == "" then
                            modifier = "NONE"
                        end
                        local rawKeys = {}
                        for tok in keysPart:gmatch("[^,|;]+") do
                            local tk = ConfigManager.Trim(tok)
                            if tk ~= "" then table.insert(rawKeys, tk) end
                        end
                        if #rawKeys > 0 then
                            table.insert(bindings, {
                                modifier = modifier,
                                keysRaw = keysPart,
                                rawKeys = rawKeys,
                                target = rhs,
                                isCombo = (rhs:find("@", 1, true) ~= nil) or (rhs:find("->", 1, true) ~= nil),
                                raw = clean
                            })
                        end
                    end
                end
            end
        end
    end
    return bindings
end

local function SerializeQuickCastFromConfig(config)
    local prefix = (config.QuickCastRequireModifier ~= false) and "Block + " or ""
    local lines = {
        "# ArcaneWilds Quick-Cast Hotkeys (Hot-Reloaded Automatically on Save!)",
        "# Syntax: [Modifier +] Key1, Key2 = SpellName (or Category@spell:speed -> ...)",
        "# Modifiers: Block (RMB / LT / RB), Shift, Alt, Ctrl, None",
        "# Controller Aliases: GP_X, GP_Y, GP_B, GP_A, GP_LB, GP_RB, GP_LT, GP_RT"
    }
    for i = 1, 4 do
        local k = ConfigManager.Trim(config["QuickCastHotkey" .. i] or "")
        local sp = ConfigManager.Trim(config["QuickCastSpell" .. i] or "")
        if k ~= "" and sp ~= "" then
            table.insert(lines, prefix .. k .. " = " .. sp)
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

function ConfigManager.LoadQuickCastFile(paths, config, state, logFn, forceReload, modMenuSlotsChanged)
    if not paths.QUICK_CAST_PATH then return end

    if modMenuSlotsChanged then
        local newRaw = SerializeQuickCastFromConfig(config)
        local wf = io.open(paths.QUICK_CAST_PATH, "w")
        if wf then
            wf:write(newRaw)
            wf:close()
        end
    end

    local f = io.open(paths.QUICK_CAST_PATH, "r")
    if not f then
        local wf = io.open(paths.QUICK_CAST_PATH, "w")
        if wf then
            wf:write(DEFAULT_QUICK_CAST_CONTENT)
            wf:close()
        end
        f = io.open(paths.QUICK_CAST_PATH, "r")
        if not f then return end
    end
    local raw = f:read("*a") or ""
    f:close()

    if forceReload or state.LastQuickCastRaw ~= raw then
        local isInitial = (state.LastQuickCastRaw == nil)
        state.LastQuickCastRaw = raw
        state.QuickCastBindings = ParseQuickCastBindings(raw, config.QuickCastRequireModifier ~= false)

        -- Sync first 4 entries back into config.txt so Mod Menu reflects quick_cast.txt edits
        local changedCfg = false
        for i = 1, 4 do
            local b = state.QuickCastBindings[i]
            local newK = b and b.keysRaw or ""
            local newS = b and b.target or ""
            if config["QuickCastHotkey" .. i] ~= newK then
                config["QuickCastHotkey" .. i] = newK
                changedCfg = true
            end
            if config["QuickCastSpell" .. i] ~= newS then
                config["QuickCastSpell" .. i] = newS
                changedCfg = true
            end
        end

        local statusStr = string.format("%d binding(s) active from quick_cast.txt", #state.QuickCastBindings)
        config.ActiveQuickCastCount = statusStr
        if changedCfg or statusStr ~= state.LastQuickCastStatusWritten then
            state.LastQuickCastStatusWritten = statusStr
            ConfigManager.SaveConfigFile(paths, config)
        end

        -- Snapshot synced Mod Menu slot signature so we detect future Mod Menu edits
        state._LastModMenuQuickCastSig = table.concat({
            tostring(config.QuickCastHotkey1 or ""), tostring(config.QuickCastSpell1 or ""),
            tostring(config.QuickCastHotkey2 or ""), tostring(config.QuickCastSpell2 or ""),
            tostring(config.QuickCastHotkey3 or ""), tostring(config.QuickCastSpell3 or ""),
            tostring(config.QuickCastHotkey4 or ""), tostring(config.QuickCastSpell4 or "")
        }, "|")

        if isInitial then
            logFn("Loaded " .. tostring(#state.QuickCastBindings) .. " quick-cast binding(s) from quick_cast.txt")
        else
            logFn("Hot-reloaded quick_cast.txt -> " .. tostring(#state.QuickCastBindings) .. " binding(s) active!")
            for idx, b in ipairs(state.QuickCastBindings) do
                logFn(string.format("  QuickCast #%d [%s + %s] => %s", idx, tostring(b.modifier), tostring(b.keysRaw), tostring(b.target)))
            end
        end
    end
end

function ConfigManager.LoadConfigFile(paths, config, state, logFn, forceRebuildMacros)
    local legacyWeightedRules = nil
    local f = io.open(paths.CONFIG_PATH, "r")
    if not f then
        ConfigManager.SaveConfigFile(paths, config)
        ConfigManager.LoadComboRulesFile(paths, config, state, logFn, true, nil)
        return
    end

    local prevDebug = config.AllowDebugCommands

    for line in f:lines() do
        local clean = ConfigManager.Trim(line)
        if clean ~= "" and not clean:match("^#") and not clean:match("^;") then
            local k, v = clean:match("^([^=]+)=(.*)$")
            if k and v then
                k = ConfigManager.Trim(k)
                v = ConfigManager.Trim(v)
                if k == "Enabled" then config.Enabled = ConfigManager.ParseBool(v, true)
                elseif k == "DebugMode" then config.DebugMode = ConfigManager.ParseBool(v, false)
                elseif k == "AllowDebugCommands" then config.AllowDebugCommands = ConfigManager.ParseBool(v, false)
                elseif k == "DebugHotkey" then config.DebugHotkey = (v ~= "" and v or "OEM_5")
                elseif k == "RequireModifierKey" then config.RequireModifierKey = ConfigManager.ParseBool(v, true)
                elseif k == "ModifierKey" then config.ModifierKey = (v ~= "" and v:upper() or "SHIFT")
                elseif k == "ConsumeRunesOnSwappedCasts" then config.ConsumeRunesOnSwappedCasts = ConfigManager.ParseBool(v, true)
                elseif k == "EnableQuickCastHotkeys" then config.EnableQuickCastHotkeys = ConfigManager.ParseBool(v, true)
                elseif k == "QuickCastRequireModifier" then config.QuickCastRequireModifier = ConfigManager.ParseBool(v, true)
                elseif k == "QuickCastSuppressGameActions" then config.QuickCastSuppressGameActions = ConfigManager.ParseBool(v, true)
                elseif k == "ActiveQuickCastCount" then config.ActiveQuickCastCount = v
                elseif k == "QuickCastHotkey1" then config.QuickCastHotkey1 = v
                elseif k == "QuickCastSpell1" then config.QuickCastSpell1 = v
                elseif k == "QuickCastHotkey2" then config.QuickCastHotkey2 = v
                elseif k == "QuickCastSpell2" then config.QuickCastSpell2 = v
                elseif k == "QuickCastHotkey3" then config.QuickCastHotkey3 = v
                elseif k == "QuickCastSpell3" then config.QuickCastSpell3 = v
                elseif k == "QuickCastHotkey4" then config.QuickCastHotkey4 = v
                elseif k == "QuickCastSpell4" then config.QuickCastSpell4 = v
                elseif k == "TriggerComboOnModifierHold" then config.TriggerComboOnModifierHold = ConfigManager.ParseBool(v, false)
                elseif k == "EnableAutoAttackHold" then config.EnableAutoAttackHold = ConfigManager.ParseBool(v, true)
                elseif k == "AutoAttackAllCombos" then config.AutoAttackAllCombos = ConfigManager.ParseBool(v, true)
                elseif k == "AutoAttackIntervalMs" then config.AutoAttackIntervalMs = tonumber(v) or 65
                elseif k == "DefaultComboCutoff" then config.DefaultComboCutoff = math.max(1, math.min(4, math.floor(tonumber(v) or 2)))
                elseif k == "WeightedComboRules" then legacyWeightedRules = v
                elseif k == "BonusSpeedVariancePct" then config.BonusSpeedVariancePct = tonumber(v) or 25
                elseif k == "UnlockAir" then config.UnlockAir = ConfigManager.ParseBool(v, true)
                elseif k == "UnlockFire" then config.UnlockFire = ConfigManager.ParseBool(v, true)
                elseif k == "UnlockWater" then config.UnlockWater = ConfigManager.ParseBool(v, true)
                elseif k == "UnlockEarth" then config.UnlockEarth = ConfigManager.ParseBool(v, true)
                elseif k == "UnlockModdedCombat" then config.UnlockModdedCombat = ConfigManager.ParseBool(v, true)
                elseif k == "UnlockUtilitySpells" then config.UnlockUtilitySpells = ConfigManager.ParseBool(v, false)
                elseif k == "KeepGroundSmashAnchored" then config.KeepGroundSmashAnchored = ConfigManager.ParseBool(v, true)
                elseif k == "MaxFinisherSpeedClamp" then config.MaxFinisherSpeedClamp = math.max(1.0, tonumber(v) or 5.0)
                elseif k == "InjectSpecialBarOnSpecials" then config.InjectSpecialBarOnSpecials = ConfigManager.ParseBool(v, true)
                elseif k == "SpecialBarInjectAmount" then config.SpecialBarInjectAmount = tonumber(v) or 100.0
                elseif k == "RequireSpecialEnergyForSpecials" then config.RequireSpecialEnergyForSpecials = ConfigManager.ParseBool(v, false)
                elseif k == "MinSpecialEnergyCost" then config.MinSpecialEnergyCost = tonumber(v) or 25.0
                elseif k == "AllowFastSpecialCast" then config.AllowFastSpecialCast = ConfigManager.ParseBool(v, true)
                elseif k == "MaxSpecialCastRate" then config.MaxSpecialCastRate = math.max(1.0, tonumber(v) or 1.8)
                elseif k == "PostSpecialPauseSec" then config.PostSpecialPauseSec = math.max(0.0, tonumber(v) or 0.65)
                elseif k == "AnimRepeatPadSec" then config.AnimRepeatPadSec = math.max(0.0, tonumber(v) or 0.45)
                elseif k == "AutoTargetMaxDistance" then config.AutoTargetMaxDistance = math.max(100.0, tonumber(v) or 700.0)
                elseif k == "AutoTargetConeDeg" then config.AutoTargetConeDeg = math.max(5.0, math.min(180.0, tonumber(v) or 45.0))
                elseif k == "EnableStaffDamageScaling" then config.EnableStaffDamageScaling = ConfigManager.ParseBool(v, true)
                elseif k == "StaffBaselineTier" then config.StaffBaselineTier = math.max(1, math.floor(tonumber(v) or 1))
                elseif k == "StaffTierStep" then config.StaffTierStep = math.max(0.0, tonumber(v) or 0.30)
                elseif k == "StaffMasterworkBonus" then config.StaffMasterworkBonus = math.max(0.0, tonumber(v) or 0.15)
                elseif k == "NoStaffDamageMultiplier" then config.NoStaffDamageMultiplier = math.max(0.1, tonumber(v) or 0.50)
                elseif k == "EnforceSpellLevelRequirements" then config.EnforceSpellLevelRequirements = ConfigManager.ParseBool(v, true)
                elseif k == "DefaultCustomSpellRequiredMagicLevel" then config.DefaultCustomSpellRequiredMagicLevel = math.max(0, math.floor(tonumber(v) or 0))
                elseif k == "NotifyOnLockedSpellCast" then config.NotifyOnLockedSpellCast = ConfigManager.ParseBool(v, true)
                elseif k == "LockedSpellNotifyStyle" then config.LockedSpellNotifyStyle = (v ~= "" and v:lower() or "auto")
                elseif k == "LockedSpellNotifyCooldownSec" then config.LockedSpellNotifyCooldownSec = math.max(0.25, tonumber(v) or 1.5)
                elseif k == "MaxMoveSpeed" then config.MaxMoveSpeed = tonumber(v) or 600.0
                elseif k == "ActiveComboRulesCount" then config.ActiveComboRulesCount = v
                elseif k == "DetectedSpellsSummary" then config.DetectedSpellsSummary = v
                end
            end
        end
    end
    f:close()

    if prevDebug ~= config.AllowDebugCommands then
        if config.AllowDebugCommands then
            logFn("Debug mode ENABLED (hotkey: SHIFT + " .. tostring(config.DebugHotkey) .. ")")
        else
            logFn("Debug mode DISABLED")
        end
    end

    local curModMenuQuickCastSig = table.concat({
        tostring(config.QuickCastHotkey1 or ""), tostring(config.QuickCastSpell1 or ""),
        tostring(config.QuickCastHotkey2 or ""), tostring(config.QuickCastSpell2 or ""),
        tostring(config.QuickCastHotkey3 or ""), tostring(config.QuickCastSpell3 or ""),
        tostring(config.QuickCastHotkey4 or ""), tostring(config.QuickCastSpell4 or "")
    }, "|")
    local modMenuQuickCastChanged = (state._LastModMenuQuickCastSig ~= nil) and (state._LastModMenuQuickCastSig ~= curModMenuQuickCastSig)

    ConfigManager.LoadComboRulesFile(paths, config, state, logFn, forceRebuildMacros, legacyWeightedRules)
    ConfigManager.LoadQuickCastFile(paths, config, state, logFn, forceRebuildMacros, modMenuQuickCastChanged)
end

return ConfigManager
