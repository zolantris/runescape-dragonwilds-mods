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

    T.Test("ResolveQuickCastEntry resolves normal spells via aliases, qualified names, discovered lookup, and chains", function()
        Mock.Reset()
        local SpellScanner = require("spell_scanner")
        SpellScanner.ClearSnapshots()

        local airVortexObj = Mock.MakeUObject("DominionSpellData /Game/Spells/DA_Spell_Primary_Air_03.DA_Spell_Primary_Air_03")
        local airBoltObj = Mock.MakeUObject("DominionSpellData /Game/Spells/DA_Spell_Primary_Air_01.DA_Spell_Primary_Air_01")
        local airWandBoltObj = Mock.MakeUObject("DominionSpellData /Game/Spells/DA_Spell_Primary_Air_Wand_01.DA_Spell_Primary_Air_Wand_01")
        local waterWaveObj = Mock.MakeUObject("DominionSpellData /Game/Spells/DA_Spell_Primary_Water_03.DA_Spell_Primary_Water_03")
        local staleObj = Mock.MakeUObject("DominionSpellData /Game/Spells/DA_Spell_Stale.DA_Spell_Stale", { _valid = false })

        local state = {
            SpellRegistry = {
                da_spell_primary_air_03 = { spellObj = airVortexObj, shortName = "DA_Spell_Primary_Air_03" },
                da_spell_primary_air_01 = { spellObj = airBoltObj, shortName = "DA_Spell_Primary_Air_01" },
                da_spell_primary_air_wand_01 = { spellObj = airWandBoltObj, shortName = "DA_Spell_Primary_Air_Wand_01" },
                da_spell_primary_water_03 = { spellObj = waterWaveObj, shortName = "DA_Spell_Primary_Water_03" },
                da_spell_stale = { spellObj = staleObj, shortName = "DA_Spell_Stale" },
            },
            GlobalNameMap = {
                global_wave = "DA_Spell_Primary_Water_03",
            },
            NameMapByCat = {
                air = { vortex = "DA_Spell_Primary_Air_03", bolt = "DA_Spell_Primary_Air_01" },
                air_wand = { bolt = "DA_Spell_Primary_Air_Wand_01" },
                water = { wave = "DA_Spell_Primary_Water_03" },
            },
            DiscoveredLookup = {
                am_spell_primary_air_03 = "DA_Spell_Primary_Air_03",
            },
            SpellChains = {
                air = { stepNames = { [0] = "DA_Spell_Primary_Air_01", [2] = "DA_Spell_Primary_Air_03" } },
            },
            CustomSpellDefs = {},
            RuneItemDataCache = {},
        }

        -- 1. Direct normal spell asset
        local e1 = ConfigManager.ResolveQuickCastEntry(state, "DA_Spell_Primary_Air_03")
        T.AssertNotNil(e1)
        T.AssertEq(e1.shortName, "DA_Spell_Primary_Air_03")

        -- 2. Global alias
        local e2 = ConfigManager.ResolveQuickCastEntry(state, "global_wave")
        T.AssertNotNil(e2)
        T.AssertEq(e2.shortName, "DA_Spell_Primary_Water_03")

        -- 3. Category-qualified alias (e.g. Air.vortex, Water.wave)
        local e3 = ConfigManager.ResolveQuickCastEntry(state, "Air.vortex")
        T.AssertNotNil(e3)
        T.AssertEq(e3.shortName, "DA_Spell_Primary_Air_03")

        local e3b = ConfigManager.ResolveQuickCastEntry(state, "Air_Wand.bolt")
        T.AssertNotNil(e3b)
        T.AssertEq(e3b.shortName, "DA_Spell_Primary_Air_Wand_01")

        -- 4. Unqualified alias (e.g. vortex, wave, bolt prefers base category over *_wand)
        local e4 = ConfigManager.ResolveQuickCastEntry(state, "vortex")
        T.AssertNotNil(e4)
        T.AssertEq(e4.shortName, "DA_Spell_Primary_Air_03")

        local e4b = ConfigManager.ResolveQuickCastEntry(state, "bolt")
        T.AssertNotNil(e4b)
        T.AssertEq(e4b.shortName, "DA_Spell_Primary_Air_01")

        -- 5. DiscoveredLookup (montage name)
        local e5 = ConfigManager.ResolveQuickCastEntry(state, "AM_Spell_Primary_Air_03")
        T.AssertNotNil(e5)
        T.AssertEq(e5.shortName, "DA_Spell_Primary_Air_03")

        -- 6. Chain name fallback
        local e6 = ConfigManager.ResolveQuickCastEntry(state, "Air")
        T.AssertNotNil(e6)
        T.AssertEq(e6.shortName, "DA_Spell_Primary_Air_01")

        -- 7. Invalid / stale / empty inputs return nil
        T.AssertNil(ConfigManager.ResolveQuickCastEntry(state, "DA_Spell_Stale"))
        T.AssertNil(ConfigManager.ResolveQuickCastEntry(state, "NonExistentSpell"))
        T.AssertNil(ConfigManager.ResolveQuickCastEntry(state, "   "))
        T.AssertNil(ConfigManager.ResolveQuickCastEntry(nil, "vortex"))
    end)

    T.Test("ScanAndPatchSpells registers unclassified DominionSpellData and UtilitySpellData for Quick-Cast", function()
        Mock.Reset()
        local SpellScanner = require("spell_scanner")
        SpellScanner.ClearSnapshots()

        local standaloneSpell = Mock.MakeUObject(
            "DominionSpellData /Game/Spells/DA_Spell_Standalone_Nova.DA_Spell_Standalone_Nova",
            { SpellModules = {} }
        )
        local utilitySpell = Mock.MakeUObject(
            "UtilitySpellData /Game/Spells/DA_Utility_Windstep.DA_Utility_Windstep",
            { SpellModules = {} }
        )
        Mock.RegisterClassInstance("DominionSpellData", standaloneSpell)
        Mock.RegisterClassInstance("UtilitySpellData", utilitySpell)

        local cfg = { Enabled = true, UnlockUtilitySpells = false, MaxMoveSpeed = 600.0 }
        local _, _, reg, lookup = SpellScanner.ScanAndPatchSpells(cfg, "test", nil, {}, {}, nil)

        T.AssertNotNil(reg["da_spell_standalone_nova"], "Unclassified DominionSpellData should be registered")
        T.AssertEq(reg["da_spell_standalone_nova"].categoryTag, "Spell")
        T.AssertEq(lookup["da_spell_standalone_nova"], "DA_Spell_Standalone_Nova")

        T.AssertNotNil(reg["da_utility_windstep"], "UtilitySpellData should be registered even when UnlockUtilitySpells is false")
        T.AssertEq(reg["da_utility_windstep"].categoryTag, "Utility")
        T.AssertTrue(reg["da_utility_windstep"].isUtilitySpell)
        T.AssertEq(lookup["da_utility_windstep"], "DA_Utility_Windstep")
    end)
end)
