-- Offline unit & regression tests for schema_migrator.lua and schemaVersion integration

local T = require("test_harness")
local Mock = require("ue4ss_mock")
local Json = require("json")
local SchemaMigrator = require("schema_migrator")
local CustomSpells = require("custom_spells")
local RuleParser = require("rule_parser")
local ConfigManager = require("config_manager")

local function MakeTempDir()
    local base = os.getenv("TEMP") or os.getenv("TMP") or "."
    local sep = package.config:sub(1, 1)
    local dir = base .. sep .. "aw_schema_test_" .. tostring(math.random(100000, 999999))
    os.execute('mkdir "' .. dir .. '" >nul 2>&1')
    return dir, sep
end

local function CleanupTempDir(dir)
    if dir and dir ~= "" then
        os.execute('rmdir /s /q "' .. dir .. '" >nul 2>&1')
    end
end

T.Suite("SchemaMigrator & Schema Versioning", function()
    T.Test("Current versions and format IDs are defined for all document kinds", function()
        Mock.Reset()
        T.AssertEq(SchemaMigrator.MOD_SCHEMA_VERSION, 1)
        T.AssertEq(SchemaMigrator.GetCurrentVersion("custom_spells"), 1)
        T.AssertEq(SchemaMigrator.GetCurrentVersion("combo_rules"), 1)
        T.AssertEq(SchemaMigrator.GetCurrentVersion("detected_catalog"), 1)
        T.AssertEq(SchemaMigrator.GetCurrentVersion("bundle"), 1)
        T.AssertEq(SchemaMigrator.GetFormatId("custom_spells"), "arcane-wilds.custom_spells")
        T.AssertEq(SchemaMigrator.GetFormatId("combo_rules"), "arcane-wilds.combo_rules")
        T.AssertEq(SchemaMigrator.GetFormatId("detected_catalog"), "arcane-wilds.detected_catalog")
        T.AssertEq(SchemaMigrator.GetFormatId("bundle"), "arcane-wilds.bundle")
    end)

    T.Test("ReadVersion treats missing schemaVersion as 0 and rejects invalid values", function()
        Mock.Reset()
        local v0, err0 = SchemaMigrator.ReadVersion({ spells = {} })
        T.AssertNil(err0)
        T.AssertEq(v0, 0)

        local v1, err1 = SchemaMigrator.ReadVersion({ schemaVersion = 1, spells = {} })
        T.AssertNil(err1)
        T.AssertEq(v1, 1)

        local _, errNeg = SchemaMigrator.ReadVersion({ schemaVersion = -1 })
        T.AssertNotNil(errNeg)
        T.AssertContains(errNeg, "schemaVersion")

        local _, errFloat = SchemaMigrator.ReadVersion({ schemaVersion = 1.5 })
        T.AssertNotNil(errFloat)

        local _, errStr = SchemaMigrator.ReadVersion({ schemaVersion = "1" })
        T.AssertNotNil(errStr)

        local _, errNonTbl = SchemaMigrator.ReadVersion("not a table")
        T.AssertNotNil(errNonTbl)
    end)

    T.Test("DetectKind recognizes format headers and structural shapes", function()
        Mock.Reset()
        T.AssertEq(SchemaMigrator.DetectKind({ format = "arcane-wilds.bundle" }), "bundle")
        T.AssertEq(SchemaMigrator.DetectKind({ spells = {}, rules = {} }), "bundle")
        T.AssertEq(SchemaMigrator.DetectKind({ spells = {} }), "custom_spells")
        T.AssertEq(SchemaMigrator.DetectKind({ rules = {} }), "combo_rules")
        T.AssertEq(SchemaMigrator.DetectKind({ { name = "raw array" } }), "combo_rules")
        T.AssertEq(SchemaMigrator.DetectKind({ vfx = {}, sfx = {} }), "detected_catalog")
        T.AssertNil(SchemaMigrator.DetectKind({ foo = "bar" }))
        T.AssertNil(SchemaMigrator.DetectKind(nil))
    end)

    T.Test("Legacy v0 documents auto-migrate cleanly to v1", function()
        Mock.Reset()
        local spDoc, spErr, spNotes = SchemaMigrator.Migrate("custom_spells", { spells = { TestSpell = { enabled = true } } })
        T.AssertNil(spErr)
        T.AssertEq(spDoc.schemaVersion, 1)
        T.AssertNotNil(spDoc.spells.TestSpell)
        T.AssertEq(#spNotes, 1)

        local cbDoc, cbErr, cbNotes = SchemaMigrator.Migrate("combo_rules", { { name = "LegacyArray", stages = {} } })
        T.AssertNil(cbErr)
        T.AssertEq(cbDoc.schemaVersion, 1)
        T.AssertEq(#cbDoc.rules, 1)
        T.AssertEq(#cbNotes, 1)

        local catDoc, catErr = SchemaMigrator.Migrate("detected_catalog", { spells = {} })
        T.AssertNil(catErr)
        T.AssertEq(catDoc.schemaVersion, 1)
        T.AssertEq(catDoc.format, "arcane-wilds.detected_catalog")

        local bunDoc, bunErr = SchemaMigrator.Migrate("bundle", { spells = {}, rules = {} })
        T.AssertNil(bunErr)
        T.AssertEq(bunDoc.schemaVersion, 1)
        T.AssertEq(bunDoc.format, "arcane-wilds.bundle")
    end)

    T.Test("Multi-step synthetic migration pipeline runs sequentially (v1 -> v2 -> v3)", function()
        Mock.Reset()
        local registry = {
            [1] = function(doc)
                doc.step1 = true
                return doc, "v1->v2 applied"
            end,
            [2] = function(doc)
                doc.step2 = doc.step1 and "ok" or "fail"
                return doc, "v2->v3 applied"
            end,
        }
        local migrated, err, notes = SchemaMigrator.Migrate("custom_spells", { schemaVersion = 1, spells = {} }, {
            targetVersion = 3,
            registry = registry,
        })
        T.AssertNil(err)
        T.AssertEq(migrated.schemaVersion, 3)
        T.AssertTrue(migrated.step1)
        T.AssertEq(migrated.step2, "ok")
        T.AssertEq(#notes, 2)
        T.AssertEq(notes[1], "v1->v2 applied")
        T.AssertEq(notes[2], "v2->v3 applied")
    end)

    T.Test("Future schemaVersion > current is rejected cleanly without corrupting live config", function()
        Mock.Reset()
        local futureSpellsJson = '{"schemaVersion": 99, "spells": { "FutureSpell": { "enabled": true } }}'
        local defs, spErr = CustomSpells.ParseDefinitions(futureSpellsJson)
        T.AssertNil(defs)
        T.AssertNotNil(spErr)
        T.AssertContains(spErr, "newer than supported version")

        local futureComboJson = '{"schemaVersion": 99, "rules": []}'
        local macros, cbErr = RuleParser.ParseWeightedMacros(futureComboJson, {}, {}, {})
        T.AssertNil(macros)
        T.AssertNotNil(cbErr)
        T.AssertContains(cbErr, "newer than supported version")

        -- Verify ConfigManager preserves previous valid state on hot-reload of future schemaVersion
        local dir, sep = MakeTempDir()
        local ok, testErr = pcall(function()
            local paths = {
                CONFIG_PATH = dir .. sep .. "config.txt",
                COMBO_RULES_JSON_PATH = dir .. sep .. "combo_rules.json",
                SPELL_NAMES_PATH = dir .. sep .. "spell_names.txt",
                CUSTOM_SPELLS_JSON_PATH = dir .. sep .. "custom_spells.json",
            }
            local cfg = ConfigManager.CreateDefaultConfig()
            local st = { BaseSpellRegistry = {}, SpellRegistry = {}, SpellChains = {}, RuneItemDataCache = {}, DiscoveredLookup = {}, ParsedMacros = {} }

            local f = io.open(paths.CUSTOM_SPELLS_JSON_PATH, "w")
            f:write('{"schemaVersion": 1, "spells": { "ValidSpell": { "enabled": true, "category": "Air" } }}')
            f:close()

            local changed1 = ConfigManager.LoadCustomSpellsFile(paths, st, function() end)
            T.AssertTrue(changed1)
            T.AssertNotNil(st.CustomSpellDefs["validspell"])

            -- Overwrite with unsupported future schemaVersion
            local f2 = io.open(paths.CUSTOM_SPELLS_JSON_PATH, "w")
            f2:write(futureSpellsJson)
            f2:close()

            local changed2 = ConfigManager.LoadCustomSpellsFile(paths, st, function() end)
            T.AssertFalse(changed2)
            T.AssertNotNil(st.LastCustomSpellsError)
            T.AssertNotNil(st.CustomSpellDefs["validspell"])
        end)
        CleanupTempDir(dir)
        if not ok then error(testErr) end
    end)

    T.Test("Json.EmptyArray and Json.AsArray encode empty lists as [] instead of {}", function()
        Mock.Reset()
        local doc = {
            emptyList = Json.EmptyArray(),
            taggedEmpty = Json.AsArray({}),
            nonEmpty = Json.AsArray({ "a", "b" }),
            emptyObj = {},
        }
        local encoded, err = Json.Encode(doc)
        T.AssertNil(err)
        T.AssertContains(encoded, '"emptyList":[]')
        T.AssertContains(encoded, '"taggedEmpty":[]')
        T.AssertContains(encoded, '"nonEmpty":["a","b"]')
        T.AssertContains(encoded, '"emptyObj":{}')
    end)
end)
