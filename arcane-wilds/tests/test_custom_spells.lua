-- Tests for custom_spells.json, custom_spells.lua, and timeline_parser.lua

local T = require("test_harness")
local Mock = require("ue4ss_mock")
local CustomSpells = require("custom_spells")
local TimelineParser = require("timeline_parser")

local function ReadFile(path)
    local f, err = io.open(path, "r")
    T.AssertNotNil(f, "failed to open " .. tostring(path) .. ": " .. tostring(err))
    local raw = f:read("*a")
    f:close()
    return raw
end

T.Suite("custom_spells + timeline_parser", function()
    T.Test("parses shipped custom_spells.json with zero errors and filters disabled spells", function()
        local raw = ReadFile(MOD_ROOT .. "/custom_spells.json")
        local defs, err = CustomSpells.ParseDefinitions(raw)
        T.AssertNil(err)
        T.AssertNotNil(defs)

        -- 9 enabled spells, 2 disabled examples (SaradominGodsword, SaradominTempest)
        T.AssertNotNil(defs["flamesofzamorak"], "FlamesOfZamorak should be loaded")
        T.AssertNotNil(defs["saradominstrike"], "SaradominStrike should be loaded")
        T.AssertNotNil(defs["stormofarmadyl"], "StormOfArmadyl should be loaded")
        T.AssertNotNil(defs["airblast"], "AirBlast should be loaded")
        T.AssertNotNil(defs["fireblast"], "FireBlast should be loaded")
        T.AssertNotNil(defs["waterwave"], "WaterWave should be loaded")
        T.AssertNotNil(defs["arcanedodgeforward"], "ArcaneDodgeForward should be loaded")
        T.AssertNotNil(defs["firesurgecombo"], "FireSurgeCombo should be loaded")
        T.AssertNotNil(defs["tidalsurgecombo"], "TidalSurgeCombo should be loaded")
        T.AssertNil(defs["saradomingodsword"], "Disabled SaradominGodsword tester must be skipped")
        T.AssertNil(defs["saradomintempest"], "Disabled SaradominTempest must be skipped")

        -- FlamesOfZamorak
        local foz = defs["flamesofzamorak"]
        T.AssertEq(foz.displayName, "Flames of Zamorak")
        T.AssertEq(foz.requiredMagicLevel, 20)
        T.AssertFalse(foz.unlockedByDefault)
        T.AssertEq(foz.baseSpell, "DA_ZamorakStaff_Special")
        T.AssertFalse(foz.suppressBaseSpell)
        T.AssertEq(foz.category, "Fire")
        T.AssertNear(foz.speed, 1.8)
        T.AssertTrue(foz.clamp)
        T.AssertEq(foz.runeCost, "fire")
        T.AssertEq(foz.runeCount, 2)

        -- SaradominStrike (chainstrike barrage)
        local ss = defs["saradominstrike"]
        T.AssertEq(ss.requiredMagicLevel, 30)
        T.AssertTrue(ss.scaleWithStaff)
        T.AssertEq(ss.damageScaling, "full")
        T.AssertTrue(ss.suppressBaseSpell)
        T.AssertNil(ss.baseSpell)
        T.AssertNear(ss.stepAdvanceAt, 0.85)
        T.AssertEq(ss.autoTargetRange, 2500)
        T.AssertEq(ss.autoTargetCone, 60)
        T.AssertEq(ss.runeCost, "air")
        T.AssertEq(ss.runeCount, 2)
        T.AssertNotNil(ss.jsonCues)
        T.AssertEq(#ss.jsonCues, 1)

        -- StormOfArmadyl (impact-tracked multi-cue timeline)
        local soa = defs["stormofarmadyl"]
        T.AssertEq(soa.requiredMagicLevel, 77)
        T.AssertTrue(soa.scaleWithStaff)
        T.AssertEq(soa.damageScaling, "full")
        T.AssertTrue(soa.suppressBaseSpell)
        T.AssertNear(soa.stepAdvanceAt, 0.9)
        T.AssertEq(soa.autoTargetRange, 2500)
        T.AssertNotNil(soa.jsonCues)
        T.AssertEq(#soa.jsonCues, 3)

        -- AirBlast, FireBlast, WaterWave (singular native baseSpell examples)
        local ab = defs["airblast"]
        T.AssertEq(ab.displayName, "Air Blast")
        T.AssertEq(ab.baseSpell, "DA_Spell_Primary_Air_03")
        T.AssertFalse(ab.suppressBaseSpell)
        T.AssertEq(ab.category, "Air")
        T.AssertNear(ab.speed, 1.6)
        T.AssertTrue(ab.clamp)
        T.AssertEq(ab.runeCost, "air")
        T.AssertEq(ab.runeCount, 1)

        local fb = defs["fireblast"]
        T.AssertEq(fb.baseSpell, "DA_Spell_Primary_Fire_03")
        T.AssertFalse(fb.suppressBaseSpell)
        T.AssertEq(fb.category, "Fire")
        T.AssertEq(fb.runeCost, "fire")

        local ww = defs["waterwave"]
        T.AssertEq(ww.baseSpell, "DA_Spell_Primary_Water_03")
        T.AssertFalse(ww.suppressBaseSpell)
        T.AssertEq(ww.category, "Water")
        T.AssertEq(ww.runeCost, "water")

        -- ArcaneDodgeForward (animation + sfx + vfx dodge surge)
        local adf = defs["arcanedodgeforward"]
        T.AssertEq(adf.displayName, "Arcane Dodge Forward")
        T.AssertTrue(adf.suppressBaseSpell)
        T.AssertNil(adf.baseSpell)
        T.AssertEq(adf.category, "Air")
        T.AssertNear(adf.speed, 1.5)
        T.AssertTrue(adf.clamp)
        T.AssertEq(adf.runeCost, "air")
        T.AssertEq(adf.runeCount, 1)
        T.AssertEq(adf.overlapPolicy, "parallel")
        T.AssertNotNil(adf.jsonCues)
        T.AssertEq(#adf.jsonCues, 3)
        local adfTl, adfWarn = TimelineParser.BuildTimeline(adf)
        T.AssertNotNil(adfTl)
        T.AssertEq(#adfWarn, 0)
        T.AssertEq(#adfTl.cues, 3)
        T.AssertEq(adfTl.cues[1].type, "anim")
        T.AssertEq(adfTl.cues[1].asset, "AM_PlayerM_Dodge_Surge_Fwd")
        T.AssertEq(adfTl.cues[2].type, "sfx")
        T.AssertEq(adfTl.cues[3].type, "vfx")

        -- FireSurgeCombo & TidalSurgeCombo (multi-spell combo custom spells)
        local fsc = defs["firesurgecombo"]
        T.AssertTrue(fsc.suppressBaseSpell)
        T.AssertNil(fsc.baseSpell)
        T.AssertEq(fsc.category, "Fire")
        T.AssertEq(fsc.runeCost, "fire")
        T.AssertEq(fsc.runeCount, 2)
        T.AssertEq(#fsc.jsonCues, 3)

        local tsc = defs["tidalsurgecombo"]
        T.AssertTrue(tsc.suppressBaseSpell)
        T.AssertNil(tsc.baseSpell)
        T.AssertEq(tsc.category, "Water")
        T.AssertEq(tsc.runeCost, "water")
        T.AssertEq(tsc.runeCount, 2)
        T.AssertEq(#tsc.jsonCues, 3)
    end)

    T.Test("builds validated timelines from SaradominStrike (chainstrike) and StormOfArmadyl (anchored cues)", function()
        local raw = ReadFile(MOD_ROOT .. "/custom_spells.json")
        local defs, err = CustomSpells.ParseDefinitions(raw)
        T.AssertNil(err)

        -- 1. SaradominStrike chainstrike cue
        local tlSS, warnSS = TimelineParser.BuildTimeline(defs["saradominstrike"])
        T.AssertNotNil(tlSS)
        T.AssertEq(#warnSS, 0, "expected zero timeline warnings for SaradominStrike")
        T.AssertFalse(tlSS.isLegacyCompiled)
        T.AssertEq(#tlSS.cues, 1)
        local cs = tlSS.cues[1]
        T.AssertEq(cs.type, "chainstrike")
        T.AssertEq(cs.asset, "lightning")
        T.AssertFalse(cs.params.requireLock)
        T.AssertTrue(cs.params.los)
        T.AssertEq(cs.params.skill, "magic")
        T.AssertEq(cs.params.baseStrikes, 1)
        T.AssertEq(cs.params.levelsPerStrike, 20)
        T.AssertEq(cs.params.maxStrikes, 5)
        T.AssertNear(cs.params.interval, 0.4)
        T.AssertEq(cs.params.chainRadius, 650)
        T.AssertTrue(cs.params.preferUnique)
        T.AssertEq(cs.params.dmgMin, 65)
        T.AssertEq(cs.params.dmgMax, 125)
        T.AssertEq(cs.params.damageClass, "Magical")
        T.AssertEq(cs.params.force, 260)
        T.AssertNear(cs.params.stun, 0.75)
        T.AssertNear(cs.params.scale.X, 0.35)
        T.AssertNear(cs.params.scale.Z, 0.45)
        T.AssertEq(cs.params.sfx, "lightning")
        T.AssertNear(cs.params.dur, 0.9)

        -- 2. StormOfArmadyl multi-cue anchored timeline (@0.00 -> >bolt -> &)
        local tl, warnings = TimelineParser.BuildTimeline(defs["stormofarmadyl"])
        T.AssertNotNil(tl)
        T.AssertEq(#warnings, 0, "expected zero timeline warnings for StormOfArmadyl")
        T.AssertFalse(tl.isLegacyCompiled)
        T.AssertEq(#tl.cues, 3)

        -- Cue 1: Spell @0.00 id=bolt trackImpact=true
        local c1 = tl.cues[1]
        T.AssertEq(c1.type, "spell")
        T.AssertEq(c1.idLower, "bolt")
        T.AssertEq(c1.asset, "DA_Spell_Primary_Air_01")
        T.AssertTrue(c1.params.trackImpact)
        T.AssertNear(c1.params.impactTimeout, 1.8)

        -- Cue 2: Hit >bolt anchored to Cue 1
        local c2 = tl.cues[2]
        T.AssertEq(c2.type, "hit")
        T.AssertEq(c2.timing.mode, "after_end")
        T.AssertEq(c2.anchorIndex, 1)
        T.AssertEq(c2.params.target, "impact")
        T.AssertEq(c2.params.radius, 350)
        T.AssertEq(c2.params.dmgMin, 75)
        T.AssertEq(c2.params.dmgMax, 140)
        T.AssertEq(c2.params.damageClass, "Magical")
        T.AssertEq(c2.params.force, 260)
        T.AssertNear(c2.params.pushback, 750)
        T.AssertNear(c2.params.launchZ, 260)
        T.AssertNear(c2.params.stun, 0.6)

        -- Cue 3: VFX & anchored to Cue 2
        local c3 = tl.cues[3]
        T.AssertEq(c3.type, "vfx")
        T.AssertEq(c3.timing.mode, "sync_start")
        T.AssertEq(c3.anchorIndex, 2)
        T.AssertEq(c3.asset, "/Game/Art/VFX/Library/Spells/Windstep/NS_Windstep_Launch.NS_Windstep_Launch")
        T.AssertNear(c3.params.scale.X, 0.15)
        T.AssertNear(c3.params.scale.Z, 0.15)
        T.AssertNear(c3.params.dur, 0.5)
    end)

    T.Test("builds multi-spell timelines for FireSurgeCombo and TidalSurgeCombo", function()
        local raw = ReadFile(MOD_ROOT .. "/custom_spells.json")
        local defs = CustomSpells.ParseDefinitions(raw)

        local tlFire, warnFire = TimelineParser.BuildTimeline(defs["firesurgecombo"])
        T.AssertNotNil(tlFire)
        T.AssertEq(#warnFire, 0)
        T.AssertFalse(tlFire.isLegacyCompiled)
        T.AssertEq(#tlFire.cues, 3)
        T.AssertEq(tlFire.cues[1].type, "spell")
        T.AssertEq(tlFire.cues[1].asset, "DA_Spell_Primary_Fire_01")
        T.AssertEq(tlFire.cues[2].asset, "DA_Spell_Primary_Fire_03")
        T.AssertNear(tlFire.cues[2].timing.offset, 0.45)
        T.AssertEq(tlFire.cues[3].asset, "DA_Spell_Primary_Fire_04")
        T.AssertNear(tlFire.cues[3].timing.offset, 0.95)

        local tlWater, warnWater = TimelineParser.BuildTimeline(defs["tidalsurgecombo"])
        T.AssertNotNil(tlWater)
        T.AssertEq(#warnWater, 0)
        T.AssertFalse(tlWater.isLegacyCompiled)
        T.AssertEq(#tlWater.cues, 3)
        T.AssertEq(tlWater.cues[1].asset, "DA_Spell_Primary_Water_01")
        T.AssertEq(tlWater.cues[2].asset, "DA_Spell_Primary_Water_03")
        T.AssertEq(tlWater.cues[3].asset, "DA_Spell_Primary_Water_04")
    end)

    T.Test("compiles legacy flat montage + spinHitbox fields into anim + hit cues", function()
        local fixture = [[{
            "spells": {
                "LegacySpinTest": {
                    "enabled": true,
                    "scaleWithStaff": false,
                    "baseSpell": null,
                    "category": "Air",
                    "montage": "AM_PlayerM_Attack_2H_Greatsword_Secondary",
                    "spinHitbox": true,
                    "hitRadius": 400,
                    "hitDamageMin": 85,
                    "hitDamageMax": 165,
                    "hitDelaySec": 0.35,
                    "damageClass": "Melee",
                    "damageForce": 260,
                    "floatieOffsetZ": 90,
                    "runeCost": { "type": "air", "count": 1 }
                }
            }
        }]]
        local defs, err = CustomSpells.ParseDefinitions(fixture)
        T.AssertNil(err)
        local sgs = defs["legacyspintest"]
        T.AssertFalse(sgs.scaleWithStaff)
        T.AssertTrue(sgs.suppressBaseSpell)
        T.AssertTrue(sgs.spinHitbox)
        T.AssertEq(sgs.damageClass, "melee")

        local tl, warnings = TimelineParser.BuildTimeline(sgs)
        T.AssertNotNil(tl)
        T.AssertEq(#warnings, 0)
        T.AssertTrue(tl.isLegacyCompiled)
        T.AssertEq(#tl.cues, 2)
        T.AssertEq(tl.cues[1].type, "anim")
        T.AssertEq(tl.cues[1].asset, "AM_PlayerM_Attack_2H_Greatsword_Secondary")
        T.AssertEq(tl.cues[2].type, "hit")
        T.AssertNear(tl.cues[2].timing.offset, 0.35)
        T.AssertEq(tl.cues[2].params.dmgMin, 85)
        T.AssertEq(tl.cues[2].params.dmgMax, 165)
    end)

    T.Test("regression: DominionSpellData asset in montage/anim cue is rejected safely without AnimSequence scan", function()
        Mock.Reset()
        CustomSpells.ClearCache()
        local TimelineRunner = require("timeline_runner")
        TimelineRunner.ClearValidationCache()

        local air3 = Mock.MakeUObject("DominionSpellData /Game/Spells/DA_Spell_Primary_Air_03.DA_Spell_Primary_Air_03")
        local pc = Mock.MakeUObject("DominionPlayerController /Game/Maps/Main.PC")
        local pawn = Mock.MakeUObject("BP_PlayerCharacter_C /Game/Maps/Main.Player", {
            K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
            K2_GetActorRotation = function() return { Pitch = 0, Yaw = 0, Roll = 0 } end
        })
        Mock.RegisterClassInstance("PlayerController", pc)

        local animSeqScanned = false
        local origFindAllOf = _G.FindAllOf
        _G.FindAllOf = function(clsName)
            if clsName == "AnimSequence" or clsName == "AnimMontage" then
                animSeqScanned = true
            end
            return origFindAllOf(clsName)
        end

        local ok, testErr = pcall(function()
            local badJson = [[{
                "spells": {
                    "BadAirBlast": {
                        "enabled": true,
                        "baseSpell": null,
                        "category": "Air",
                        "montage": "DA_Spell_Primary_Air_03"
                    }
                }
            }]]
            local defs, err = CustomSpells.ParseDefinitions(badJson)
            T.AssertNil(err)
            local spellRegistry = {
                ["da_spell_primary_air_03"] = {
                    spellObj = air3,
                    shortName = "DA_Spell_Primary_Air_03",
                    fullName = air3:GetFullName(),
                    categoryTag = "Air"
                }
            }
            local entries = CustomSpells.BuildCustomRegistryEntries(
                defs, spellRegistry, {}, {},
                function(o) return o:GetFullName() end,
                function(s) return s:match("%.([^%.]+)$") or s end
            )
            T.AssertNotNil(entries["badairblast"])
            T.AssertNil(entries["badairblast"].montageObj, "DA_Spell_* must not resolve as AnimMontage")
            T.AssertFalse(animSeqScanned, "BuildCustomRegistryEntries must not scan AnimMontage for DA_Spell_*")

            local state = { SpellRegistry = spellRegistry, ActiveTimelines = {} }
            local tlInst = TimelineRunner.StartSpellTimeline(
                {}, state, pawn, nil, entries["badairblast"], 1.0,
                CustomSpells, function(o) return o:GetFullName() end, nil
            )
            T.AssertNotNil(tlInst)
            T.AssertFalse(animSeqScanned, "TimelineRunner must reject DA_Spell_* anim cue before scanning AnimSequence")
        end)
        _G.FindAllOf = origFindAllOf
        if not ok then error(testErr) end
    end)

    T.Test("JSON format matches legacy INI custom_spells.txt semantics identically", function()
        local legacyIni = [[
[TestStrike]
DisplayName        = Test Strike
RequiredMagicLevel = 30
ScaleWithStaff     = true
DamageScaling      = full
BaseSpell          = none
Category           = Air
Speed              = 1.6
Clamp              = true
RuneCost           = air
RuneCount          = 2
StepAdvanceAt      = 0.90
AutoTargetRange    = 700
AutoTargetCone     = 45
Spell = @0.00 | DA_Spell_Primary_Air_01 | id=bolt | trackImpact=true | impactTimeout=1.8
Hit   = >bolt | target=impact | radius=350 | dmg=65..125 | class=Magical | force=260
VFX   = &     | lightning | target=impact | scale=0.35,0.35,0.45 | dur=1.10
]]
        local jsonEquivalent = [[{
            "spells": {
                "TestStrike": {
                    "displayName": "Test Strike",
                    "requiredMagicLevel": 30,
                    "scaleWithStaff": true,
                    "damageScaling": "full",
                    "baseSpell": null,
                    "category": "Air",
                    "speed": 1.6,
                    "clamp": true,
                    "runeCost": { "type": "air", "count": 2 },
                    "stepAdvanceAt": 0.9,
                    "autoTarget": { "range": 700, "cone": 45 },
                    "cues": [
                        { "type": "spell", "id": "bolt", "at": "@0.00", "asset": "DA_Spell_Primary_Air_01", "trackImpact": true, "impactTimeout": 1.8 },
                        { "type": "hit", "at": ">bolt", "target": "impact", "radius": 350, "damage": [65, 125], "class": "Magical", "force": 260 },
                        { "type": "vfx", "at": "&", "asset": "lightning", "target": "impact", "scale": [0.35, 0.35, 0.45], "duration": 1.1 }
                    ]
                }
            }
        }]]

        local iniDefs = CustomSpells.ParseDefinitions(legacyIni)
        local jsonDefs, err = CustomSpells.ParseDefinitions(jsonEquivalent)
        T.AssertNil(err)

        local a, b = iniDefs["teststrike"], jsonDefs["teststrike"]
        T.AssertEq(a.displayName, b.displayName)
        T.AssertEq(a.requiredMagicLevel, b.requiredMagicLevel)
        T.AssertEq(a.scaleWithStaff, b.scaleWithStaff)
        T.AssertEq(a.damageScaling, b.damageScaling)
        T.AssertEq(a.suppressBaseSpell, b.suppressBaseSpell)
        T.AssertEq(a.category, b.category)
        T.AssertNear(a.speed, b.speed)
        T.AssertEq(a.clamp, b.clamp)
        T.AssertEq(a.runeCost, b.runeCost)
        T.AssertEq(a.runeCount, b.runeCount)
        T.AssertNear(a.stepAdvanceAt, b.stepAdvanceAt)
        T.AssertEq(a.autoTargetRange, b.autoTargetRange)
        T.AssertEq(a.autoTargetCone, b.autoTargetCone)

        local tlA = TimelineParser.BuildTimeline(a)
        local tlB = TimelineParser.BuildTimeline(b)
        T.AssertEq(#tlA.cues, #tlB.cues)
        for i = 1, #tlA.cues do
            T.AssertEq(tlA.cues[i].type, tlB.cues[i].type)
            T.AssertEq(tlA.cues[i].timing.mode, tlB.cues[i].timing.mode)
            T.AssertEq(tlA.cues[i].anchorIndex, tlB.cues[i].anchorIndex)
            T.AssertEq(tlA.cues[i].asset, tlB.cues[i].asset)
            T.AssertEq(tlA.cues[i].params.target, tlB.cues[i].params.target)
        end
        T.AssertEq(tlA.cues[2].params.dmgMin, tlB.cues[2].params.dmgMin)
        T.AssertEq(tlA.cues[2].params.dmgMax, tlB.cues[2].params.dmgMax)
        T.AssertNear(tlA.cues[3].params.scale.Z, tlB.cues[3].params.scale.Z)
    end)

    T.Test("supports structured timing objects, pattern objects, targetAnim, and vfxFloats/vfxVecs", function()
        local raw = [[{
            "spells": {
                "FancySpell": {
                    "category": "Air",
                    "staffBonus": { "Armadyl": 1.35, "Zamorak": 1.25 },
                    "cues": [
                        { "type": "anim", "id": "opener", "at": 0.0, "asset": "AM_Opener", "duration": 0.5 },
                        { "type": "vfx", "at": { "after": "opener", "offset": -0.1 }, "asset": "lightning", "pattern": { "kind": "ring", "count": 4, "radius": 180 }, "vfxFloats": { "Scale": 0.5 }, "vfxVecs": { "Tint": [1, 0.5, 0] } },
                        { "type": "targetAnim", "at": { "syncWith": "opener", "offset": 0.2 }, "asset": "AM_HitReact", "radius": 450 }
                    ]
                }
            }
        }]]
        local defs, err = CustomSpells.ParseDefinitions(raw)
        T.AssertNil(err)
        local def = defs["fancyspell"]
        T.AssertEq(def.staffBonus.Armadyl, 1.35)
        local tl, warnings = TimelineParser.BuildTimeline(def)
        T.AssertEq(#warnings, 0)
        T.AssertEq(tl.cues[2].timing.mode, "after_end")
        T.AssertEq(tl.cues[2].anchorIndex, 1)
        T.AssertNear(tl.cues[2].timing.offset, -0.1)
        T.AssertEq(tl.cues[2].params.pattern.kind, "ring")
        T.AssertEq(tl.cues[2].params.pattern.count, 4)
        T.AssertEq(tl.cues[2].params.pattern.radius, 180)
        T.AssertEq(tl.cues[2].params.vfxFloats[1].name, "Scale")
        T.AssertNear(tl.cues[2].params.vfxFloats[1].value, 0.5)
        T.AssertEq(tl.cues[2].params.vfxVecs[1].name, "Tint")
        T.AssertNear(tl.cues[2].params.vfxVecs[1].value.Y, 0.5)
        T.AssertEq(tl.cues[3].type, "anim")
        T.AssertEq(tl.cues[3].params.target, "targets")
        T.AssertEq(tl.cues[3].timing.mode, "sync_start")
        T.AssertEq(tl.cues[3].anchorIndex, 1)
    end)

    T.Test("BuildCustomRegistryEntries registers JSON custom spells with mock UE4SS objects", function()
        Mock.Reset()
        local airRune = Mock.MakeUObject("DominionItemData /Game/Items/Runes/DA_Rune_Air.DA_Rune_Air")
        local zamSpell = Mock.MakeUObject("DominionSpellData /Game/Gameplay/Character/Player/Spells/Specials/ZamorakStaff/DA_ZamorakStaff_Special.DA_ZamorakStaff_Special")
        local pc = Mock.MakeUObject("DominionPlayerController /Game/Maps/Main.PC")
        Mock.RegisterClassInstance("PlayerController", pc)

        local spellRegistry = {
            ["da_zamorakstaff_special"] = {
                spellObj = zamSpell,
                shortName = "DA_ZamorakStaff_Special",
                fullName = zamSpell:GetFullName(),
                categoryTag = "Fire"
            }
        }
        local runeCache = { air = airRune }
        local raw = ReadFile(MOD_ROOT .. "/custom_spells.json")
        local defs = CustomSpells.ParseDefinitions(raw)
        local entries = CustomSpells.BuildCustomRegistryEntries(
            defs, spellRegistry, {}, runeCache,
            function(o) return o:GetFullName() end,
            function(s) return s:match("%.([^%.]+)$") or s end
        )

        T.AssertNotNil(entries["flamesofzamorak"])
        T.AssertEq(entries["flamesofzamorak"].spellObj, zamSpell)
        T.AssertEq(entries["flamesofzamorak"].requiredMagicLevel, 20)
        T.AssertFalse(entries["flamesofzamorak"].unlockedByDefault)

        T.AssertNotNil(entries["saradominstrike"])
        T.AssertTrue(entries["saradominstrike"].hasTimeline)
        T.AssertTrue(entries["saradominstrike"].suppressBaseSpell)
        T.AssertEq(#entries["saradominstrike"].costItems, 1)
        T.AssertEq(entries["saradominstrike"].costItems[1].count, 2)
    end)

    T.Test("returns error on malformed JSON without crashing", function()
        local defs, err = CustomSpells.ParseDefinitions('{ "spells": { "Broken": [ } }')
        T.AssertNil(defs)
        T.AssertNotNil(err)
        T.AssertContains(err, "line 1")
    end)
end)
