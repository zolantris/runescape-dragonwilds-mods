-- Tests for combo_rules.json, combo_rules_examples.json, rule_parser.lua, and combat_engine.lua macro selection

local T = require("test_harness")
local Mock = require("ue4ss_mock")
local RuleParser = require("rule_parser")
local ConfigManager = require("config_manager")
local CombatEngine = require("combat_engine")

local function ReadFile(path)
    local f, err = io.open(path, "r")
    T.AssertNotNil(f, "failed to open " .. tostring(path) .. ": " .. tostring(err))
    local raw = f:read("*a")
    f:close()
    return raw
end

local function LoadDefaultNameMaps()
    local raw = ReadFile(MOD_ROOT .. "/spell_names.txt")
    return RuleParser.ParseSpellNameMap(raw)
end

T.Suite("combo_rules + rule_parser + combat_engine", function()
    T.Test("parses shipped combo_rules.json and skips enabled=false rules", function()
        local byCat, globalMap = LoadDefaultNameMaps()
        local raw = ReadFile(MOD_ROOT .. "/combo_rules.json")
        local macros, err = RuleParser.ParseWeightedMacros(raw, byCat, globalMap, {})
        T.AssertNil(err)
        T.AssertEq(#macros, 1, "only 1 rule is enabled in shipped combo_rules.json")

        local m = macros[1]
        T.AssertEq(m.name, "Air Bolt -> Saradomin Godsword")
        T.AssertEq(m.weight, 5)
        T.AssertEq(#m.stages, 2)

        -- Stage 1: Air@bolt:1.5
        T.AssertEq(m.stages[1].elementLower, "air")
        T.AssertNear(m.stages[1].speed, 1.5)
        T.AssertEq(#m.stages[1].steps, 1)
        T.AssertEq(m.stages[1].steps[1].assetName, "DA_Spell_Primary_Air_01")

        -- Stage 2: { spell = "SaradominGodsword", speed = 1.0 } (category omitted)
        T.AssertEq(m.stages[2].elementLower, "saradomingodsword")
        T.AssertNear(m.stages[2].speed, 1.0)
        T.AssertEq(m.stages[2].steps[1].assetName, "SaradominGodsword")
    end)

    T.Test("parses all 20 example rules in combo_rules_examples.json with zero errors", function()
        local byCat, globalMap = LoadDefaultNameMaps()
        local raw = ReadFile(MOD_ROOT .. "/combo_rules_examples.json")
        local macros, err = RuleParser.ParseWeightedMacros(raw, byCat, globalMap, {})
        T.AssertNil(err)
        T.AssertEq(#macros, 20)

        -- Check 3-element chain (Fire -> Water -> Air)
        local threeStage = nil
        for _, m in ipairs(macros) do
            if m.name == "3-Element Chain (Fire -> Water -> Air)" then
                threeStage = m
                break
            end
        end
        T.AssertNotNil(threeStage)
        T.AssertEq(threeStage.weight, 3)
        T.AssertEq(#threeStage.stages, 3)
        T.AssertEq(threeStage.stages[1].steps[2].assetName, "DA_Spell_Primary_Fire_02")
        T.AssertEq(threeStage.stages[2].steps[1].assetName, "DA_Spell_Primary_Water_03")
        T.AssertEq(threeStage.stages[3].steps[2].assetName, "DA_Spell_Primary_Air_04")
    end)

    T.Test("supports compact chain shorthand inside JSON rules", function()
        local byCat, globalMap = LoadDefaultNameMaps()
        local raw = [[{
            "rules": [
                {
                    "name": "Compact Fire Air",
                    "weight": 7,
                    "chain": "Fire@bolt_1,bolt_2:2.2 -> Air@gust,vortex:2.1"
                }
            ]
        }]]
        local macros, err = RuleParser.ParseWeightedMacros(raw, byCat, globalMap, {})
        T.AssertNil(err)
        T.AssertEq(#macros, 1)
        T.AssertEq(macros[1].weight, 7)
        T.AssertEq(#macros[1].stages, 2)
        T.AssertNear(macros[1].stages[1].speed, 2.2)
        T.AssertNear(macros[1].stages[2].speed, 2.1)
    end)

    T.Test("regression: legacy single-stage DSL parses :speed :weight in consistent order", function()
        local byCat, globalMap = LoadDefaultNameMaps()
        local macros, err = RuleParser.ParseWeightedMacros("Air@bolt,gust,vortex,slam:2.2 :5;", byCat, globalMap, {})
        T.AssertNil(err)
        T.AssertEq(#macros, 1)
        T.AssertNear(macros[1].stages[1].speed, 2.2, 1e-4, "single-stage token 2 must be speed")
        T.AssertNear(macros[1].weight, 5.0, 1e-4, "single-stage token 3 must be weight")
        T.AssertEq(#macros[1].stages[1].steps, 4)
        T.AssertEq(macros[1].stages[1].steps[4].assetName, "DA_Spell_Primary_Air_04")
    end)

    T.Test("CombatEngine.PickWeightedMacroForElement isolates elements and falls back from wand to base", function()
        Mock.Reset()
        local byCat, globalMap = LoadDefaultNameMaps()
        local airObj = Mock.MakeUObject("DominionSpellData /Game/DA_Spell_Primary_Air_01.DA_Spell_Primary_Air_01")
        local fireObj = Mock.MakeUObject("DominionSpellData /Game/DA_Spell_Primary_Fire_01.DA_Spell_Primary_Fire_01")

        local jsonRules = [[{
            "rules": [
                { "name": "Air Only", "weight": 5, "stages": [{ "category": "Air", "spells": ["bolt"], "speed": 2.0 }] },
                { "name": "Fire Only", "weight": 5, "stages": [{ "category": "Fire", "spells": ["bolt_1"], "speed": 2.0 }] }
            ]
        }]]
        local macros = RuleParser.ParseWeightedMacros(jsonRules, byCat, globalMap, {})
        local state = {
            ParsedMacros = macros,
            SpellRegistry = {
                ["da_spell_primary_air_01"] = { spellObj = airObj, shortName = "DA_Spell_Primary_Air_01", categoryTag = "Air" },
                ["da_spell_primary_fire_01"] = { spellObj = fireObj, shortName = "DA_Spell_Primary_Fire_01", categoryTag = "Fire" }
            },
            SpellChains = {}
        }

        local pickedAir = CombatEngine.PickWeightedMacroForElement(state, "Air", "DA_Spell_Primary_Air_01")
        T.AssertNotNil(pickedAir)
        T.AssertEq(pickedAir.name, "Air Only")

        local pickedWandFallback = CombatEngine.PickWeightedMacroForElement(state, "Air_Wand", nil)
        T.AssertNotNil(pickedWandFallback)
        T.AssertEq(pickedWandFallback.name, "Air Only")

        -- Water has no matching rule -> must NEVER cross-pick Air or Fire!
        local pickedWater = CombatEngine.PickWeightedMacroForElement(state, "Water", nil)
        T.AssertNil(pickedWater)
    end)

    T.Test("ConfigManager.ResolveStepEntry resolves custom spell stages without category duplication", function()
        local sgsEntry = {
            shortName = "SaradominGodsword",
            fullName = "CustomSuppressBase/SaradominGodsword",
            suppressBaseSpell = true
        }
        local state = {
            SpellRegistry = { ["saradomingodsword"] = sgsEntry },
            SpellChains = {}
        }
        local byCat, globalMap = LoadDefaultNameMaps()
        local raw = ReadFile(MOD_ROOT .. "/combo_rules.json")
        local macros = RuleParser.ParseWeightedMacros(raw, byCat, globalMap, {})
        local stage2 = macros[1].stages[2]
        local resolved = ConfigManager.ResolveStepEntry(state, stage2, stage2.steps[1])
        T.AssertEq(resolved, sgsEntry)
    end)

    T.Test("returns error on malformed combo_rules.json", function()
        local macros, err = RuleParser.ParseWeightedMacros('{ "rules": [ { "weight": 5 } ] }', {}, {}, {})
        T.AssertNil(macros)
        T.AssertNotNil(err)
        T.AssertContains(err, "missing 'stages' array or 'chain' string")
    end)
end)
