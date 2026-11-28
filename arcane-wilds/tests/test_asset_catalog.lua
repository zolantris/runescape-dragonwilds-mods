-- Offline unit & regression tests for asset_catalog.lua (Spells, VFX, SFX, Montages catalog)

local T = require("test_harness")
local Mock = require("ue4ss_mock")
local Json = require("json")
local AssetCatalog = require("asset_catalog")

local function MakeTempDir()
    local base = os.getenv("TEMP") or os.getenv("TMP") or "."
    local sep = package.config:sub(1, 1)
    local dir = base .. sep .. "aw_catalog_test_" .. tostring(math.random(100000, 999999))
    os.execute('mkdir "' .. dir .. '" >nul 2>&1')
    return dir, sep
end

local function CleanupTempDir(dir)
    if dir and dir ~= "" then
        os.execute('rmdir /s /q "' .. dir .. '" >nul 2>&1')
    end
end

T.Suite("AssetCatalog (Detected Spells, VFX, SFX, Montages)", function()
    T.Test("BuildCatalog discovers mocked NiagaraSystem, SoundBase, AnimMontage and skips Default__ CDOs", function()
        Mock.Reset()

        local vfx1 = Mock.MakeUObject("NiagaraSystem /Game/Art/VFX/NS_ArcaneBolt.NS_ArcaneBolt")
        local vfxCdo = Mock.MakeUObject("NiagaraSystem /Game/Art/VFX/Default__NS_Ignored.Default__NS_Ignored")
        Mock.RegisterClassInstance("NiagaraSystem", vfx1)
        Mock.RegisterClassInstance("NiagaraSystem", vfxCdo)

        local sfx1 = Mock.MakeUObject("SoundCue /Game/Audio/Spells/SC_LightningStrike.SC_LightningStrike")
        local sfxCdo = Mock.MakeUObject("SoundWave /Engine/Transient.Default__SoundWave")
        Mock.RegisterClassInstance("SoundBase", sfx1)
        Mock.RegisterClassInstance("SoundBase", sfxCdo)

        local mont1 = Mock.MakeUObject("AnimMontage /Game/Art/Animation/AM_Spell_Air_01.AM_Spell_Air_01")
        Mock.RegisterClassInstance("AnimMontage", mont1)

        local baseSpellRegistry = {
            da_spell_primary_air_01 = {
                shortName = "DA_Spell_Primary_Air_01",
                fullName = "DominionSpellData /Game/Spells/Combat/Air/DA_Spell_Primary_Air_01.DA_Spell_Primary_Air_01",
                categoryTag = "Air",
                stepIndex = 0,
                montageName = "AM_Spell_Air_01",
                montageObj = mont1,
                isModded = false,
                isSpecialSpell = false,
            },
        }

        local catalog = AssetCatalog.BuildCatalog({
            modVersion = "1.1.0",
            baseSpellRegistry = baseSpellRegistry,
            orderedChains = { { tag = "Air" } },
            nameMapByCat = { air = { bolt = "DA_Spell_Primary_Air_01" } },
            globalNameMap = {},
            vfxPathLookup = {
                windstep = "/Game/Art/VFX/Library/Spells/Windstep/NS_Windstep_Launch.NS_Windstep_Launch",
            },
        })

        T.AssertEq(catalog.schemaVersion, 1)
        T.AssertEq(catalog.format, "arcane-wilds.detected_catalog")
        T.AssertEq(catalog.modVersion, "1.1.0")
        T.AssertEq(#catalog.categories, 1)
        T.AssertEq(catalog.categories[1], "Air")

        T.AssertEq(#catalog.spells, 1)
        T.AssertEq(catalog.spells[1].shortName, "DA_Spell_Primary_Air_01")
        T.AssertEq(catalog.spells[1].aliases[1], "bolt")

        -- 2 VFX (1 from NiagaraSystem scan + 1 from vfxPathLookup), Default__ skipped
        T.AssertEq(#catalog.vfx, 2)
        T.AssertEq(#catalog.sfx, 1)
        T.AssertEq(catalog.sfx[1].shortName, "SC_LightningStrike")
        T.AssertEq(#catalog.montages, 1)
        T.AssertEq(catalog.montages[1].shortName, "AM_Spell_Air_01")
    end)

    T.Test("ExportCatalogFile persists and merges across scans and overlays alias files", function()
        Mock.Reset()
        local dir, sep = MakeTempDir()
        local ok, testErr = pcall(function()
            local outPath = dir .. sep .. "detected_catalog.json"
            local sfxNamesPath = dir .. sep .. "sfx_names.txt"

            local sf = io.open(sfxNamesPath, "w")
            sf:write("# Friendly SFX aliases\nthunder = /Game/Audio/Spells/SC_Thunder.SC_Thunder\n")
            sf:close()

            -- Scan 1: Sound A + VFX A
            Mock.RegisterClassInstance("SoundBase", Mock.MakeUObject("SoundCue /Game/Audio/Spells/SC_Thunder.SC_Thunder"))
            Mock.RegisterClassInstance("NiagaraSystem", Mock.MakeUObject("NiagaraSystem /Game/VFX/NS_Fireball.NS_Fireball"))

            local cat1, err1 = AssetCatalog.ExportCatalogFile(outPath, {
                modVersion = "1.1.0",
                sfxNamesPath = sfxNamesPath,
            })
            T.AssertNil(err1)
            T.AssertEq(#cat1.vfx, 1)
            T.AssertEq(#cat1.sfx, 1)
            T.AssertEq(cat1.sfx[1].aliases[1], "thunder")

            -- Scan 2: Reset UE4SS loaded objects (simulating moving to a new zone) and load Sound B
            Mock.Reset()
            Mock.RegisterClassInstance("SoundBase", Mock.MakeUObject("SoundWave /Game/Audio/Spells/SW_IceShatter.SW_IceShatter"))

            local cat2, err2 = AssetCatalog.ExportCatalogFile(outPath, {
                modVersion = "1.1.0",
                sfxNamesPath = sfxNamesPath,
            })
            T.AssertNil(err2)
            -- Previously discovered VFX A and Sound A must still be preserved alongside Sound B!
            T.AssertEq(#cat2.vfx, 1)
            T.AssertEq(#cat2.sfx, 2)

            -- Verify file on disk decodes cleanly as valid JSON with schemaVersion == 1
            local rf = io.open(outPath, "r")
            local raw = rf:read("*a")
            rf:close()
            local decoded, decErr = Json.Decode(raw)
            T.AssertNil(decErr)
            T.AssertEq(decoded.schemaVersion, 1)
            T.AssertEq(#decoded.sfx, 2)
        end)
        CleanupTempDir(dir)
        if not ok then error(testErr) end
    end)

    T.Test("ExportCatalogFile returns error cleanly on missing output path", function()
        Mock.Reset()
        local cat, err = AssetCatalog.ExportCatalogFile("", {})
        T.AssertNil(cat)
        T.AssertNotNil(err)
    end)
end)
