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

local DEFAULT_COMBO_RULES_CONTENT = table.concat({
    "# ArcaneWilds Custom Combo Rules (Hot-Reloaded Automatically on Save!)",
    "# Syntax: Category@spell,spell:speed -> Category@spell,spell:speed :weight;",
    "Air@bolt,gust,vortex,slam:2.2 :5;",
    "Water@bolt,waterfall,wave,tsunami:2.2 :5;",
    "Fire@bolt_1,bolt_2:2.2 -> Air@gust,vortex:2.2 :5;",
    "Earth@bolt,spike,shatter:2.0 -> FlamesOfZamorak@FlamesOfZamorak:2.0 :5;"
}, "\n") .. "\n"

local ORDERED_CONFIG_KEYS = {
    "Enabled", "DebugMode", "AllowDebugCommands", "DebugHotkey",
    "RequireModifierKey", "ModifierKey", "ConsumeRunesOnSwappedCasts",
    "EnableAutoAttackHold", "AutoAttackAllCombos", "AutoAttackIntervalMs",
    "DefaultComboCutoff", "BonusSpeedVariancePct",
    "UnlockAir", "UnlockFire", "UnlockWater", "UnlockEarth",
    "UnlockModdedCombat", "UnlockUtilitySpells", "KeepGroundSmashAnchored", "MaxFinisherSpeedClamp",
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
        DebugMode = false,
        AllowDebugCommands = false,
        DebugHotkey = "OEM_5",
        RequireModifierKey = true,
        ModifierKey = "RMB",
        ConsumeRunesOnSwappedCasts = true,
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
        MaxMoveSpeed = 600.0,
        ActiveComboRulesCount = "Loading combo_rules.txt...",
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
        local exact = state.SpellRegistry[stepDescriptor.assetName:lower()]
        if exact and exact.spellObj and exact.spellObj:IsValid() then
            return exact
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

function ConfigManager.LoadCustomSpellsFile(paths, state, logFn)
    local f = io.open(paths.CUSTOM_SPELLS_PATH, "r")
    if not f then
        local wf = io.open(paths.CUSTOM_SPELLS_PATH, "w")
        if wf then
            wf:write("-- Arcane Wilds Custom Spells (see custom_spells.txt template)\n")
            wf:close()
        end
        return false
    end
    local raw = f:read("*a") or ""
    f:close()
    if state.LastCustomSpellsRaw ~= raw then
        local isInitial = (state.LastCustomSpellsRaw == nil)
        state.LastCustomSpellsRaw = raw
        state.CustomSpellDefs = CustomSpells.ParseDefinitions(raw)
        if not isInitial then
            logFn("Hot-reloaded custom_spells.txt")
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

function ConfigManager.LoadComboRulesFile(paths, config, state, logFn, forceRebuild, legacyRuleFallback)
    local namesChanged = ConfigManager.LoadSpellNamesFile(paths, state)
    local customChanged = ConfigManager.LoadCustomSpellsFile(paths, state, logFn)
    if customChanged then
        CustomSpells.ClearCache()
        if next(state.BaseSpellRegistry) ~= nil then
            ConfigManager.RebuildMergedRegistry(state)
        end
    end

    local f = io.open(paths.COMBO_RULES_PATH, "r")
    if not f then
        local wf = io.open(paths.COMBO_RULES_PATH, "w")
        if wf then
            if legacyRuleFallback and ConfigManager.Trim(legacyRuleFallback) ~= "" then
                wf:write("# Migrated from config.txt WeightedComboRules\n")
                wf:write(ConfigManager.Trim(legacyRuleFallback) .. "\n")
            else
                wf:write(DEFAULT_COMBO_RULES_CONTENT)
            end
            wf:close()
        end
        f = io.open(paths.COMBO_RULES_PATH, "r")
        if not f then return end
    end

    local lines = {}
    for line in f:lines() do
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
    f:close()

    local combinedRules = table.concat(lines, " ")
    if forceRebuild or namesChanged or customChanged or state.LastComboRulesRaw ~= combinedRules then
        local isInitial = (state.LastComboRulesRaw == nil)
        state.LastComboRulesRaw = combinedRules
        state.ParsedMacros = RuleParser.ParseWeightedMacros(
            combinedRules, state.NameMapByCat, state.GlobalNameMap, state.DiscoveredLookup)

        local statusStr = string.format("%d macro(s) active from combo_rules.txt", #state.ParsedMacros)
        config.ActiveComboRulesCount = statusStr
        if statusStr ~= state.LastRulesStatusWritten then
            state.LastRulesStatusWritten = statusStr
            ConfigManager.SaveConfigFile(paths, config)
        end

        if isInitial then
            logFn("Loaded " .. tostring(#state.ParsedMacros) .. " macro(s) from combo_rules.txt")
        else
            logFn("Hot-reloaded combo_rules.txt / spell_names.txt -> " .. tostring(#state.ParsedMacros) .. " macro(s) active!")
            for idx, m in ipairs(state.ParsedMacros) do
                logFn(string.format("  Rule #%d [weight=%s, stages=%d]: %s", idx, tostring(m.weight), #m.stages, m.raw))
            end
            ConfigManager.LogParsedMacrosSpellMapping(config, state, logFn, "Hot-Reloaded Combo Rules -> Direct Spell Asset Mapping")
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

    ConfigManager.LoadComboRulesFile(paths, config, state, logFn, forceRebuildMacros, legacyWeightedRules)
end

return ConfigManager
