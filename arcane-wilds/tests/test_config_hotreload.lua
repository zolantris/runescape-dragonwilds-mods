-- Tests for ConfigManager hot-reload safety, .json/.txt fallback, and ProgressionScaling

local T = require("test_harness")
local Mock = require("ue4ss_mock")
local ConfigManager = require("config_manager")
local ProgressionScaling = require("progression_scaling")

local function WriteFile(path, content)
    local f, err = io.open(path, "w")
    T.AssertNotNil(f, "failed to write " .. tostring(path) .. ": " .. tostring(err))
    f:write(content)
    f:close()
end

local function RemoveFileSafe(path)
    if path then pcall(os.remove, path) end
end

local function MakeTempPaths(tag)
    local base = os.getenv("TEMP") or os.getenv("TMP") or "."
    local prefix = base .. "/arcanewilds_test_" .. tag .. "_"
    return {
        CONFIG_PATH             = prefix .. "config.txt",
        COMBO_RULES_JSON_PATH   = prefix .. "combo_rules.json",
        COMBO_RULES_PATH        = prefix .. "combo_rules.txt",
        SPELL_NAMES_PATH        = prefix .. "spell_names.txt",
        CUSTOM_SPELLS_JSON_PATH = prefix .. "custom_spells.json",
        CUSTOM_SPELLS_PATH      = prefix .. "custom_spells.txt",
        QUICK_CAST_PATH         = prefix .. "quick_cast.txt"
    }
end

local function CleanupPaths(paths)
    for _, p in pairs(paths) do
        RemoveFileSafe(p)
    end
end

T.Suite("config_manager hot-reload + progression_scaling", function()
    T.Test("prefers .json over .txt and preserves last-known-good state on syntax error", function()
        local paths = MakeTempPaths("hotreload")
        CleanupPaths(paths)

        local okRun, errRun = pcall(function()
            WriteFile(paths.CUSTOM_SPELLS_JSON_PATH, [[{
                "spells": {
                    "ValidSpell": {
                        "category": "Fire",
                        "baseSpell": "DA_Spell_Primary_Fire_01",
                        "speed": 1.5
                    }
                }
            }]])
            WriteFile(paths.COMBO_RULES_JSON_PATH, [[{
                "rules": [
                    { "name": "Valid Rule", "weight": 5, "stages": [{ "category": "Air", "spells": ["bolt"], "speed": 2.0 }] }
                ]
            }]])

            local config = ConfigManager.CreateDefaultConfig()
            local state = {
                BaseSpellRegistry = {},
                SpellRegistry = {},
                SpellChains = {},
                CustomSpellDefs = {},
                ParsedMacros = {},
                NameMapByCat = {},
                GlobalNameMap = {},
                DiscoveredLookup = {}
            }
            local logs = {}
            local function logFn(msg) table.insert(logs, tostring(msg)) end

            -- Initial valid load
            ConfigManager.LoadComboRulesFile(paths, config, state, logFn, true)
            T.AssertNotNil(state.CustomSpellDefs["validspell"])
            T.AssertEq(#state.ParsedMacros, 1)
            T.AssertEq(state.ParsedMacros[1].name, "Valid Rule")
            T.AssertContains(config.ActiveComboRulesCount, "1 macro(s) active from combo_rules.json")

            -- Now simulate player saving broken JSON mid-edit -> must keep previous valid defs & macros!
            WriteFile(paths.CUSTOM_SPELLS_JSON_PATH, '{ "spells": { "Broken": ')
            WriteFile(paths.COMBO_RULES_JSON_PATH, '{ "rules": [ broken ')

            ConfigManager.LoadComboRulesFile(paths, config, state, logFn, false)
            T.AssertNotNil(state.LastCustomSpellsError)
            T.AssertNotNil(state.LastComboRulesError)
            T.AssertNotNil(state.CustomSpellDefs["validspell"], "previous custom spells must stay active on JSON error")
            T.AssertEq(#state.ParsedMacros, 1, "previous combo rules must stay active on JSON error")
            T.AssertEq(state.ParsedMacros[1].name, "Valid Rule")
            T.AssertContains(config.ActiveComboRulesCount, "ERROR in combo_rules.json")
        end)

        CleanupPaths(paths)
        if not okRun then error(errRun) end
    end)

    T.Test("falls back cleanly to legacy .txt when .json files do not exist", function()
        local paths = MakeTempPaths("legacy_fallback")
        CleanupPaths(paths)

        local okRun, errRun = pcall(function()
            WriteFile(paths.CUSTOM_SPELLS_PATH, "[LegacySpell]\nCategory = Air\nBaseSpell = DA_Spell_Primary_Air_01\nSpeed = 1.7\n")
            WriteFile(paths.COMBO_RULES_PATH, "Air@bolt,gust:2.1 :4;\n")

            local config = ConfigManager.CreateDefaultConfig()
            local state = {
                BaseSpellRegistry = {},
                SpellRegistry = {},
                SpellChains = {},
                CustomSpellDefs = {},
                ParsedMacros = {},
                NameMapByCat = {},
                GlobalNameMap = {},
                DiscoveredLookup = {}
            }

            ConfigManager.LoadComboRulesFile(paths, config, state, function() end, true)
            T.AssertNotNil(state.CustomSpellDefs["legacyspell"])
            T.AssertNear(state.CustomSpellDefs["legacyspell"].speed, 1.7)
            T.AssertEq(#state.ParsedMacros, 1)
            T.AssertNear(state.ParsedMacros[1].stages[1].speed, 2.1)
            T.AssertNear(state.ParsedMacros[1].weight, 4.0)
            T.AssertContains(config.ActiveComboRulesCount, "combo_rules.txt")
        end)

        CleanupPaths(paths)
        if not okRun then error(errRun) end
    end)

    T.Test("ProgressionScaling enforces level requirements and formats display names", function()
        local config = ConfigManager.CreateDefaultConfig()
        local entry = {
            shortName = "StormOfArmadyl",
            isCustomSpell = true,
            requiredMagicLevel = 40,
            requiredSkill = "Magic",
            unlockedByDefault = false,
            customDef = { displayName = "Storm of Armadyl" }
        }
        T.AssertEq(ProgressionScaling.FormatSpellDisplayName(entry), "Storm of Armadyl")

        -- Without valid skill component, level is nil -> locked when EnforceSpellLevelRequirements=true
        local unlocked, info = ProgressionScaling.CheckSpellUnlocked(config, nil, nil, entry)
        T.AssertFalse(unlocked)
        T.AssertNotNil(info)
        T.AssertEq(info.requiredLevel, 40)
        T.AssertContains(info.reason, "Storm of Armadyl requires Magic Level 40")

        -- Disabled enforcement unlocks immediately
        config.EnforceSpellLevelRequirements = false
        local unlockedBypass = ProgressionScaling.CheckSpellUnlocked(config, nil, nil, entry)
        T.AssertTrue(unlockedBypass)
    end)
end)
