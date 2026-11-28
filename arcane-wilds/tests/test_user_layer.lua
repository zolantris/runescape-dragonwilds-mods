-- Offline unit & regression tests for Persistent User Layer vs. Immutable Mod Defaults

local T = require("test_harness")
local Mock = require("ue4ss_mock")
local ConfigManager = require("config_manager")

local function MakeTempDir()
    local base = os.getenv("TEMP") or os.getenv("TMP") or "."
    local sep = package.config:sub(1, 1)
    local dir = base .. sep .. "aw_userlayer_test_" .. tostring(math.random(100000, 999999))
    os.execute('mkdir "' .. dir .. '" >nul 2>&1')
    return dir, sep
end

local function CleanupTempDir(dir)
    if dir and dir ~= "" then
        os.execute('rmdir /s /q "' .. dir .. '" >nul 2>&1')
    end
end

local function WriteText(path, content)
    local f = io.open(path, "w")
    assert(f, "failed to open for write: " .. tostring(path))
    f:write(content)
    f:close()
end

local function MakeBaseState()
    return {
        BaseSpellRegistry = {},
        SpellRegistry = {},
        SpellChains = {},
        RuneItemDataCache = {},
        DiscoveredLookup = {},
        ParsedMacros = {},
        NameMapByCat = {},
        GlobalNameMap = {},
        QuickCastBindings = {},
    }
end

T.Suite("Persistent User Layer vs Immutable Mod Defaults", function()
    T.Test("ResolveUserDir and BuildUserPaths construct isolated user profile paths", function()
        Mock.Reset()
        local resolved = ConfigManager.ResolveUserDir("C:\\CustomProfile\\ArcaneWilds")
        T.AssertContains(resolved, "CustomProfile")
        local uPaths = ConfigManager.BuildUserPaths(resolved)
        T.AssertContains(uPaths.USER_SPELLS_PATH, "user_spells.json")
        T.AssertContains(uPaths.USER_COMBOS_PATH, "user_combos.json")
        T.AssertContains(uPaths.USER_QUICK_CAST_PATH, "user_quick_cast.json")
    end)

    T.Test("ResolveUserDir prefers RSDragonwilds Saved Config path when it exists and falls back to top-level ArcaneWilds", function()
        Mock.Reset()
        local localAppData = os.getenv("LOCALAPPDATA") or os.getenv("APPDATA")
        local envOverride = os.getenv("ARCANE_WILDS_USER_DIR")
        if localAppData and localAppData ~= "" and (not envOverride or envOverride == "") then
            local sep = package.config:sub(1, 1)
            local cleanBase = localAppData:gsub("[\\/]+$", "")
            local expectedGameConfig = cleanBase .. sep .. "RSDragonwilds" .. sep .. "Saved" .. sep .. "Config"

            local checkedPath = nil
            local primary = ConfigManager.ResolveUserDir(nil, function(p)
                checkedPath = p
                return true
            end)
            T.AssertEq(checkedPath, expectedGameConfig)
            T.AssertEq(primary, expectedGameConfig .. sep .. "ArcaneWilds" .. sep)

            local fallback = ConfigManager.ResolveUserDir(nil, function()
                return false
            end)
            T.AssertEq(fallback, cleanBase .. sep .. "ArcaneWilds" .. sep)

            -- Default filesystem check without injected stub still returns a valid ArcaneWilds path
            local realResolved = ConfigManager.ResolveUserDir()
            T.AssertNotNil(realResolved)
            T.AssertContains(realResolved, "ArcaneWilds" .. sep)
        end
    end)

    T.Test("Built-in default spells are immutable, toggleable via disabledDefaults, and coexist with user spells", function()
        Mock.Reset()
        local dir, sep = MakeTempDir()
        local ok, testErr = pcall(function()
            local modDir = dir .. sep .. "mod"
            local userDir = dir .. sep .. "user"
            os.execute('mkdir "' .. modDir .. '" >nul 2>&1')
            os.execute('mkdir "' .. userDir .. '" >nul 2>&1')

            local paths = {
                CONFIG_PATH = modDir .. sep .. "config.txt",
                CUSTOM_SPELLS_JSON_PATH = modDir .. sep .. "custom_spells.json",
                USER_SPELLS_PATH = userDir .. sep .. "user_spells.json",
            }

            WriteText(paths.CUSTOM_SPELLS_JSON_PATH, [[{
                "schemaVersion": 1,
                "spells": {
                    "FlamesOfZamorak": { "enabled": true, "category": "Fire", "speed": 1.8 },
                    "StormOfArmadyl": { "enabled": true, "category": "Air", "speed": 1.6 }
                }
            }]])

            -- User disables FlamesOfZamorak, tries to overwrite StormOfArmadyl (must be blocked!),
            -- and adds their own custom spell MyArcaneBlast.
            WriteText(paths.USER_SPELLS_PATH, [[{
                "schemaVersion": 1,
                "format": "arcane-wilds.user_spells",
                "disabledDefaults": ["FlamesOfZamorak"],
                "spells": {
                    "StormOfArmadyl": { "enabled": true, "category": "Fire", "speed": 9.9 },
                    "MyArcaneBlast": { "enabled": true, "category": "Water", "speed": 2.1 }
                }
            }]])

            local logs = {}
            local st = MakeBaseState()
            local changed = ConfigManager.LoadCustomSpellsFile(paths, st, function(m) logs[#logs + 1] = m end)
            T.AssertTrue(changed)

            -- FlamesOfZamorak was disabled by user
            T.AssertNil(st.CustomSpellDefs["flamesofzamorak"])
            -- StormOfArmadyl kept the authoritative mod default (Air, speed 1.6), NOT user's Fire 9.9!
            T.AssertNotNil(st.CustomSpellDefs["stormofarmadyl"])
            T.AssertEq(st.CustomSpellDefs["stormofarmadyl"].category, "Air")
            T.AssertNear(st.CustomSpellDefs["stormofarmadyl"].speed, 1.6, 0.001)
            T.AssertTrue(st.CustomSpellDefs["stormofarmadyl"].isModDefault)
            -- User's own spell loaded cleanly
            T.AssertNotNil(st.CustomSpellDefs["myarcaneblast"])
            T.AssertEq(st.CustomSpellDefs["myarcaneblast"].category, "Water")
            T.AssertTrue(st.CustomSpellDefs["myarcaneblast"].isUserSpell)

            -- Warning was logged about built-in collision
            local warned = false
            for _, l in ipairs(logs) do
                if l:find("StormOfArmadyl", 1, true) and l:find("built-in", 1, true) then
                    warned = true
                end
            end
            T.AssertTrue(warned)

            -- Re-enabling FlamesOfZamorak hot-reloads it cleanly
            WriteText(paths.USER_SPELLS_PATH, [[{
                "schemaVersion": 1,
                "disabledDefaults": [],
                "spells": {
                    "MyArcaneBlast": { "enabled": true, "category": "Water", "speed": 2.1 }
                }
            }]])
            local changed2 = ConfigManager.LoadCustomSpellsFile(paths, st, function() end)
            T.AssertTrue(changed2)
            T.AssertNotNil(st.CustomSpellDefs["flamesofzamorak"])
            T.AssertNotNil(st.CustomSpellDefs["myarcaneblast"])
        end)
        CleanupTempDir(dir)
        if not ok then error(testErr) end
    end)

    T.Test("User combos can disable individual defaults, disable all defaults, and append custom rules", function()
        Mock.Reset()
        local dir, sep = MakeTempDir()
        local ok, testErr = pcall(function()
            local modDir = dir .. sep .. "mod"
            local userDir = dir .. sep .. "user"
            os.execute('mkdir "' .. modDir .. '" >nul 2>&1')
            os.execute('mkdir "' .. userDir .. '" >nul 2>&1')

            local paths = {
                CONFIG_PATH = modDir .. sep .. "config.txt",
                SPELL_NAMES_PATH = modDir .. sep .. "spell_names.txt",
                CUSTOM_SPELLS_JSON_PATH = modDir .. sep .. "custom_spells.json",
                COMBO_RULES_JSON_PATH = modDir .. sep .. "combo_rules.json",
                USER_COMBOS_PATH = userDir .. sep .. "user_combos.json",
            }
            WriteText(paths.CUSTOM_SPELLS_JSON_PATH, '{"schemaVersion":1,"spells":{}}')
            WriteText(paths.COMBO_RULES_JSON_PATH, [[{
                "schemaVersion": 1,
                "rules": [
                    { "id": "default.fire_to_air", "name": "Fire -> Air", "enabled": true, "weight": 5, "stages": [{ "category": "Fire", "spells": ["bolt_1"], "speed": 2.0 }] },
                    { "id": "default.water_chain", "name": "Water Chain", "enabled": true, "weight": 5, "stages": [{ "category": "Water", "spells": ["bolt"], "speed": 2.0 }] },
                    { "id": "default.storm_of_armadyl", "name": "StormOfArmadyl", "enabled": false, "weight": 5, "stages": [{ "category": "Air", "spells": ["StormOfArmadyl"], "speed": 1.6 }] }
                ]
            }]])

            -- Disable 1 enabled default combo, enable 1 shipped-disabled default combo, and add 1 user combo
            WriteText(paths.USER_COMBOS_PATH, [[{
                "schemaVersion": 1,
                "disableAllDefaults": false,
                "disabledDefaultIds": ["default.fire_to_air"],
                "enabledDefaultIds": ["default.storm_of_armadyl"],
                "rules": [
                    { "name": "My Earth Finisher", "enabled": true, "weight": 7, "stages": [{ "category": "Earth", "spells": ["bolt"], "speed": 2.5 }] }
                ]
            }]])

            local cfg = ConfigManager.CreateDefaultConfig()
            local st = MakeBaseState()
            ConfigManager.LoadComboRulesFile(paths, cfg, st, function() end, true, nil)
            T.AssertEq(#st.ParsedMacros, 3)
            T.AssertEq(st.ParsedMacros[1].id, "default.water_chain")
            T.AssertEq(st.ParsedMacros[2].id, "default.storm_of_armadyl")
            T.AssertEq(st.ParsedMacros[3].name, "My Earth Finisher")
            T.AssertTrue(st.ParsedMacros[3].isUserCombo)

            -- Now disable ALL defaults so only user combos run
            WriteText(paths.USER_COMBOS_PATH, [[{
                "schemaVersion": 1,
                "disableAllDefaults": true,
                "disabledDefaultIds": [],
                "rules": [
                    { "name": "Only My Combo", "enabled": true, "weight": 5, "stages": [{ "category": "Air", "spells": ["bolt"], "speed": 2.0 }] }
                ]
            }]])
            ConfigManager.LoadComboRulesFile(paths, cfg, st, function() end, false, nil)
            T.AssertEq(#st.ParsedMacros, 1)
            T.AssertEq(st.ParsedMacros[1].name, "Only My Combo")
        end)
        CleanupTempDir(dir)
        if not ok then error(testErr) end
    end)

    T.Test("User quick_cast.json overrides default quick_cast.txt and falls back cleanly when disabled or malformed", function()
        Mock.Reset()
        local dir, sep = MakeTempDir()
        local ok, testErr = pcall(function()
            local modDir = dir .. sep .. "mod"
            local userDir = dir .. sep .. "user"
            os.execute('mkdir "' .. modDir .. '" >nul 2>&1')
            os.execute('mkdir "' .. userDir .. '" >nul 2>&1')

            local paths = {
                CONFIG_PATH = modDir .. sep .. "config.txt",
                QUICK_CAST_JSON_PATH = modDir .. sep .. "quick_cast.json",
                QUICK_CAST_PATH = modDir .. sep .. "quick_cast.txt",
                USER_QUICK_CAST_PATH = userDir .. sep .. "user_quick_cast.json",
            }
            WriteText(paths.QUICK_CAST_JSON_PATH, [[{
                "schemaVersion": 1,
                "bindings": [
                    { "enabled": true, "modifier": "BLOCK", "keys": ["1", "GP_X"], "target": "SaradominGodsword" }
                ]
            }]])

            local cfg = ConfigManager.CreateDefaultConfig()
            local st = MakeBaseState()

            -- 1. No user file -> uses default quick_cast.json
            ConfigManager.LoadQuickCastFile(paths, cfg, st, function() end, true, false)
            T.AssertEq(#st.QuickCastBindings, 1)
            T.AssertEq(st.QuickCastBindings[1].target, "SaradominGodsword")
            T.AssertContains(cfg.ActiveQuickCastCount, "quick_cast.json")

            -- 2. User quick_cast.json with overrideDefaults=true -> overrides defaults
            WriteText(paths.USER_QUICK_CAST_PATH, [[{
                "schemaVersion": 1,
                "overrideDefaults": true,
                "bindings": [
                    { "enabled": true, "modifier": "SHIFT", "keys": ["F", "GP_Y"], "target": "MyCustomSpell" },
                    { "enabled": false, "modifier": "BLOCK", "keys": ["2"], "target": "DisabledSlot" }
                ]
            }]])
            ConfigManager.LoadQuickCastFile(paths, cfg, st, function() end, false, false)
            T.AssertEq(#st.QuickCastBindings, 1)
            T.AssertEq(st.QuickCastBindings[1].modifier, "SHIFT")
            T.AssertEq(st.QuickCastBindings[1].target, "MyCustomSpell")
            T.AssertEq(st.QuickCastBindings[1].keysRaw, "F, GP_Y")

            -- 3. Malformed user_quick_cast.json -> falls back cleanly to quick_cast.json
            WriteText(paths.USER_QUICK_CAST_PATH, "{ broken json")
            ConfigManager.LoadQuickCastFile(paths, cfg, st, function() end, false, false)
            T.AssertEq(#st.QuickCastBindings, 1)
            T.AssertEq(st.QuickCastBindings[1].target, "SaradominGodsword")

            -- 4. Malformed quick_cast.json -> preserves previous bindings without crashing
            os.remove(paths.USER_QUICK_CAST_PATH)
            WriteText(paths.QUICK_CAST_JSON_PATH, "{ broken base json")
            ConfigManager.LoadQuickCastFile(paths, cfg, st, function() end, false, false)
            T.AssertEq(#st.QuickCastBindings, 1)
            T.AssertEq(st.QuickCastBindings[1].target, "SaradominGodsword")

            -- 5. Mod Menu slot edit writes valid quick_cast.json
            cfg.QuickCastHotkey1 = "5, GP_LB"
            cfg.QuickCastSpell1 = "AirBlast"
            ConfigManager.LoadQuickCastFile(paths, cfg, st, function() end, false, true)
            T.AssertEq(st.QuickCastBindings[1].target, "AirBlast")
            T.AssertEq(st.QuickCastBindings[1].keysRaw, "5, GP_LB")
        end)
        CleanupTempDir(dir)
        if not ok then error(testErr) end
    end)

    T.Test("Malformed or future-schema user_spells.json preserves last-known-good live spells", function()
        Mock.Reset()
        local dir, sep = MakeTempDir()
        local ok, testErr = pcall(function()
            local paths = {
                CUSTOM_SPELLS_JSON_PATH = dir .. sep .. "custom_spells.json",
                USER_SPELLS_PATH = dir .. sep .. "user_spells.json",
            }
            WriteText(paths.CUSTOM_SPELLS_JSON_PATH, '{"schemaVersion":1,"spells":{"DefaultOne":{"enabled":true,"category":"Air"}}}')
            WriteText(paths.USER_SPELLS_PATH, '{"schemaVersion":1,"spells":{"UserGood":{"enabled":true,"category":"Fire"}}}')

            local st = MakeBaseState()
            T.AssertTrue(ConfigManager.LoadCustomSpellsFile(paths, st, function() end))
            T.AssertNotNil(st.CustomSpellDefs["usergood"])

            -- Corrupt with unsupported future schemaVersion
            WriteText(paths.USER_SPELLS_PATH, '{"schemaVersion":99,"spells":{}}')
            T.AssertFalse(ConfigManager.LoadCustomSpellsFile(paths, st, function() end))
            T.AssertNotNil(st.LastCustomSpellsError)
            T.AssertNotNil(st.CustomSpellDefs["usergood"])
        end)
        CleanupTempDir(dir)
        if not ok then error(testErr) end
    end)

    T.Test("ConfigManager persists and reloads Web Editor hotkey settings", function()
        Mock.Reset()
        local dir, sep = MakeTempDir()
        local ok, testErr = pcall(function()
            local paths = {
                CONFIG_PATH = dir .. sep .. "config.txt",
                COMBO_RULES_JSON_PATH = dir .. sep .. "combo_rules.json",
                SPELL_NAMES_PATH = dir .. sep .. "spell_names.txt",
                CUSTOM_SPELLS_JSON_PATH = dir .. sep .. "custom_spells.json",
                QUICK_CAST_PATH = dir .. sep .. "quick_cast.txt",
            }
            local cfg = ConfigManager.CreateDefaultConfig()
            T.AssertTrue(cfg.EnableWebEditorHotkey)
            T.AssertEq(cfg.WebEditorHotkey, "F9")
            T.AssertFalse(cfg.LaunchWebEditorNow)

            cfg.EnableWebEditorHotkey = false
            cfg.WebEditorHotkey = "F10"
            cfg.LaunchWebEditorNow = true
            ConfigManager.SaveConfigFile(paths, cfg)

            local reloaded = ConfigManager.CreateDefaultConfig()
            local st = MakeBaseState()
            ConfigManager.LoadConfigFile(paths, reloaded, st, function() end, true)
            T.AssertFalse(reloaded.EnableWebEditorHotkey)
            T.AssertEq(reloaded.WebEditorHotkey, "F10")
            T.AssertTrue(reloaded.LaunchWebEditorNow)
        end)
        CleanupTempDir(dir)
        if not ok then error(testErr) end
    end)
end)
