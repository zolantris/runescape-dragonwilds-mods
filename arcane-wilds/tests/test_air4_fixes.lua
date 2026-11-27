-- Regression tests for:
--   1. 4th Air spell (DA_Spell_Primary_Air_04) movement unlock (KeepGroundSmashAnchored=false default)
--      including SpellModule_StopMovementImmediately neutralization & AlternativeMontage root motion
--   2. Reversible movement anchoring toggle & decoupled EnableFinisherSpeedClamp
--   3. Staff 4th Air Combo Vertical Aim Fix (FixAir4thVerticalAim): FinishedCasting -> Immediate,
--      CasterForward -> TracedPlayerCameraForward on Transform & Movement, PositionOffset (60,0,50),
--      and clean restoration when FixAir4thVerticalAim=false.

local T = require("test_harness")
local Mock = require("ue4ss_mock")
local CombatEngine = require("combat_engine")
local ConfigManager = require("config_manager")
local CustomSpells = require("custom_spells")
local SpellScanner = require("spell_scanner")

local function MakeModuleArray(list)
    local arr = {}
    function arr:ForEach(cb)
        for i, m in ipairs(list) do
            cb(i, { get = function() return { Module = m } end })
        end
    end
    return arr
end

local function BuildMockAirSpells()
    local mont1 = Mock.MakeUObject("AnimMontage /Game/Anims/AM_Air_01.AM_Air_01", {
        bEnableRootMotionTranslation = true,
        bEnableRootMotionRotation = true
    })
    local pm1 = Mock.MakeUObject("SpellModule_PlayMontage /Game/Spells/Combat/Air/DA_Spell_Primary_Air_01.DA_Spell_Primary_Air_01:PM_0", {
        ModuleName = FName("PlayMontage"),
        Montage = mont1,
        bShouldBlockMovement = true,
        MaxMovementSpeedDuringMontage = 0.0,
        bShouldRotateToCameraForward = true,
        bAllowTriggeringNotifiesMultipleTimes = false
    })
    local tf1 = Mock.MakeUObject("SpellModule_Transform /Game/Spells/Combat/Air/DA_Spell_Primary_Air_01.DA_Spell_Primary_Air_01:TF_0", {
        ModuleName = FName("Transform"),
        Triggers = { bHasStateTrigger = true, StateTrigger = 0 },
        PositionOffset = { X = 60.0, Y = 0.0, Z = 50.0 },
        PositionRelativeSpace = 0,
        RotationRelativeSpace = 2, -- TracedPlayerCameraForward
        CameraTraceDistance = 5000.0
    })
    local mv1 = Mock.MakeUObject("SpellModule_Movement /Game/Spells/Combat/Air/DA_Spell_Primary_Air_01.DA_Spell_Primary_Air_01:MV_0", {
        ModuleName = FName("Movement"),
        Triggers = { bHasStateTrigger = true, StateTrigger = 0 },
        PitchRelativeSpace = 2, -- TracedPlayerCameraForward
        YawRelativeSpace = 2,
        CameraTraceDistance = 5000.0,
        CameraTraceIgnoreDistance = 150.0,
        DistanceToAimStraightForTarget = 400.0
    })
    local air1 = Mock.MakeUObject("DominionSpellData /Game/Gameplay/Character/Player/Spells/Combat/Air/DA_Spell_Primary_Air_01.DA_Spell_Primary_Air_01", {
        Modules = { Modules = MakeModuleArray({ pm1, tf1, mv1 }) }
    })

    local mont4 = Mock.MakeUObject("AnimMontage /Game/Anims/AM_Air_04.AM_Air_04", {
        bEnableRootMotionTranslation = true,
        bEnableRootMotionRotation = true
    })
    local altMont4 = Mock.MakeUObject("AnimMontage /Game/Anims/AM_Air_04_Alt.AM_Air_04_Alt", {
        bEnableRootMotionTranslation = true,
        bEnableRootMotionRotation = true
    })
    local pm4 = Mock.MakeUObject("SpellModule_PlayMontage /Game/Spells/Combat/Air/DA_Spell_Primary_Air_04.DA_Spell_Primary_Air_04:PM_0", {
        ModuleName = FName("PlayMontage"),
        Montage = mont4,
        AlternativeMontage = altMont4,
        bShouldBlockMovement = true,
        MaxMovementSpeedDuringMontage = 0.0,
        bShouldRotateToCameraForward = false,
        bAllowTriggeringNotifiesMultipleTimes = false
    })
    local stopMove4 = Mock.MakeUObject("SpellModule_StopMovementImmediately /Game/Spells/Combat/Air/DA_Spell_Primary_Air_04.DA_Spell_Primary_Air_04:StopMove_0", {
        ModuleName = FName("StopMove"),
        Triggers = {
            bHasStateTrigger = true,
            StateTrigger = 0,
            AnimNotifyClass = Mock.MakeUObject("Class /Game/Anims/AN_AirSlam.AN_AirSlam"),
            PlayMontageRef = { ModuleName = FName("PlayMontage") },
            CollisionRef = { ModuleName = FName("None") }
        }
    })
    -- Vanilla buggy Air_04 Transform & Movement (FinishedCasting=1, CasterForward=0, PositionOffset=(0,0,0))
    local tf4 = Mock.MakeUObject("SpellModule_Transform /Game/Spells/Combat/Air/DA_Spell_Primary_Air_04.DA_Spell_Primary_Air_04:TF_0", {
        ModuleName = FName("Transform"),
        Triggers = { bHasStateTrigger = true, StateTrigger = 1 }, -- FinishedCasting bug!
        PositionOffset = { X = 0.0, Y = 0.0, Z = 0.0 },
        PositionRelativeSpace = 0,
        RotationRelativeSpace = 0, -- CasterForward (flat!)
        CameraTraceDistance = 0.0
    })
    local mv4 = Mock.MakeUObject("SpellModule_Movement /Game/Spells/Combat/Air/DA_Spell_Primary_Air_04.DA_Spell_Primary_Air_04:MV_0", {
        ModuleName = FName("Movement"),
        Triggers = { bHasStateTrigger = true, StateTrigger = 1 }, -- FinishedCasting bug!
        PitchRelativeSpace = 0, -- CasterForward (flat!)
        YawRelativeSpace = 0,
        CameraTraceDistance = 0.0,
        CameraTraceIgnoreDistance = 0.0,
        DistanceToAimStraightForTarget = 0.0
    })
    local air4 = Mock.MakeUObject("DominionSpellData /Game/Gameplay/Character/Player/Spells/Combat/Air/DA_Spell_Primary_Air_04.DA_Spell_Primary_Air_04", {
        Modules = { Modules = MakeModuleArray({ pm4, stopMove4, tf4, mv4 }) }
    })

    return {
        air1 = air1, pm1 = pm1, mont1 = mont1, tf1 = tf1, mv1 = mv1,
        air4 = air4, pm4 = pm4, mont4 = mont4, altMont4 = altMont4,
        stopMove4 = stopMove4, tf4 = tf4, mv4 = mv4
    }
end

T.Suite("air4_movement_and_vertical_aim", function()
    T.Test("4th Air spell unlocks movement & neutralizes StopMovementImmediately by default, and restores when anchored", function()
        Mock.Reset()
        SpellScanner.ClearSnapshots()
        local fx = BuildMockAirSpells()
        Mock.RegisterClassInstance("DominionSpellData", fx.air1)
        Mock.RegisterClassInstance("DominionSpellData", fx.air4)

        local cfg = ConfigManager.CreateDefaultConfig()
        T.AssertFalse(cfg.KeepGroundSmashAnchored, "KeepGroundSmashAnchored must default to false so 4th Air moves freely")
        T.AssertTrue(cfg.EnableFinisherSpeedClamp, "EnableFinisherSpeedClamp must default to true")
        T.AssertTrue(cfg.FixAir4thVerticalAim, "FixAir4thVerticalAim must default to true")

        local logs = {}
        SpellScanner.ScanAndPatchSpells(cfg, "test", nil, {}, {}, function(m) table.insert(logs, m) end)

        -- 4th Air movement is fully unlocked
        T.AssertFalse(fx.pm4.bShouldBlockMovement, "Air_04 bShouldBlockMovement must be false")
        T.AssertNear(fx.pm4.MaxMovementSpeedDuringMontage, 600.0)
        T.AssertTrue(fx.pm4.bAllowTriggeringNotifiesMultipleTimes)
        T.AssertFalse(fx.mont4.bEnableRootMotionTranslation)
        T.AssertFalse(fx.mont4.bEnableRootMotionRotation)
        T.AssertFalse(fx.altMont4.bEnableRootMotionTranslation)
        T.AssertFalse(fx.altMont4.bEnableRootMotionRotation)

        -- StopMovementImmediately module triggers neutralized
        T.AssertFalse(fx.stopMove4.Triggers.bHasStateTrigger, "StopMovementImmediately state trigger must be disabled")
        T.AssertNil(fx.stopMove4.Triggers.AnimNotifyClass, "StopMovementImmediately AnimNotifyClass must be cleared")
        T.AssertEq(fx.stopMove4.Triggers.PlayMontageRef.ModuleName:ToString(), "None")

        -- Toggling KeepGroundSmashAnchored = true restores Air_04 movement blocking while leaving Air_01 unlocked
        cfg.KeepGroundSmashAnchored = true
        SpellScanner.ScanAndPatchSpells(cfg, "test", nil, {}, {}, function() end)
        T.AssertTrue(fx.pm4.bShouldBlockMovement, "Air_04 should re-anchor when KeepGroundSmashAnchored=true")
        T.AssertNear(fx.pm4.MaxMovementSpeedDuringMontage, 0.0)
        T.AssertTrue(fx.mont4.bEnableRootMotionTranslation)
        T.AssertTrue(fx.stopMove4.Triggers.bHasStateTrigger, "StopMovementImmediately should restore when anchored")
        T.AssertNotNil(fx.stopMove4.Triggers.AnimNotifyClass)
        T.AssertEq(fx.stopMove4.Triggers.PlayMontageRef.ModuleName:ToString(), "PlayMontage")
        T.AssertFalse(fx.pm1.bShouldBlockMovement, "Air_01 must remain unlocked")
    end)

    T.Test("FixAir4thVerticalAim patches Transform, Movement, and PlayMontage from Air_01 reference and restores cleanly", function()
        Mock.Reset()
        SpellScanner.ClearSnapshots()
        local fx = BuildMockAirSpells()
        Mock.RegisterClassInstance("DominionSpellData", fx.air1)
        Mock.RegisterClassInstance("DominionSpellData", fx.air4)

        local cfg = ConfigManager.CreateDefaultConfig()
        local logs = {}
        SpellScanner.ScanAndPatchSpells(cfg, "test", nil, {}, {}, function(m) table.insert(logs, m) end)

        -- Transform fixes
        T.AssertEq(fx.tf4.Triggers.StateTrigger, 0, "Transform StateTrigger must change FinishedCasting(1) -> Immediate(0)")
        T.AssertEq(fx.tf4.RotationRelativeSpace, 2, "Transform RotationRelativeSpace must be TracedPlayerCameraForward(2)")
        T.AssertNear(fx.tf4.CameraTraceDistance, 5000.0)
        T.AssertEq(fx.tf4.PositionRelativeSpace, 0, "PositionRelativeSpace stays CasterForward(0)")
        T.AssertNear(fx.tf4.PositionOffset.X, 60.0)
        T.AssertNear(fx.tf4.PositionOffset.Y, 0.0)
        T.AssertNear(fx.tf4.PositionOffset.Z, 50.0)

        -- Movement fixes
        T.AssertEq(fx.mv4.Triggers.StateTrigger, 0, "Movement StateTrigger must change FinishedCasting(1) -> Immediate(0)")
        T.AssertEq(fx.mv4.PitchRelativeSpace, 2, "Movement PitchRelativeSpace must be TracedPlayerCameraForward(2)")
        T.AssertEq(fx.mv4.YawRelativeSpace, 2, "Movement YawRelativeSpace must be TracedPlayerCameraForward(2)")
        T.AssertNear(fx.mv4.CameraTraceDistance, 5000.0)
        T.AssertNear(fx.mv4.CameraTraceIgnoreDistance, 150.0)
        T.AssertNear(fx.mv4.DistanceToAimStraightForTarget, 400.0)

        -- PlayMontage rotation alignment
        T.AssertTrue(fx.pm4.bShouldRotateToCameraForward, "Air_04 PlayMontage should match Air_01 bShouldRotateToCameraForward")

        -- Toggling FixAir4thVerticalAim = false restores vanilla properties
        cfg.FixAir4thVerticalAim = false
        SpellScanner.ScanAndPatchSpells(cfg, "test", nil, {}, {}, function(m) table.insert(logs, m) end)

        T.AssertEq(fx.tf4.Triggers.StateTrigger, 1)
        T.AssertEq(fx.tf4.RotationRelativeSpace, 0)
        T.AssertNear(fx.tf4.CameraTraceDistance, 0.0)
        T.AssertNear(fx.tf4.PositionOffset.X, 0.0)
        T.AssertNear(fx.tf4.PositionOffset.Z, 0.0)
        T.AssertEq(fx.mv4.Triggers.StateTrigger, 1)
        T.AssertEq(fx.mv4.PitchRelativeSpace, 0)
        T.AssertEq(fx.mv4.YawRelativeSpace, 0)
        T.AssertNear(fx.mv4.CameraTraceDistance, 0.0)
        T.AssertFalse(fx.pm4.bShouldRotateToCameraForward)
    end)

    T.Test("Finisher speed clamp works independently of KeepGroundSmashAnchored and custom clamp does not mark isSmash", function()
        Mock.Reset()
        local lastSetRate = nil
        local activeMont = Mock.MakeUObject("AnimMontage /Game/Anims/AM_Air_04.AM_Air_04", { RateScale = 1.0 })
        local animInst = Mock.MakeUObject("AnimInstance /Game/Anims/ABP_Player.ABP_Player")
        function animInst:GetCurrentActiveMontage() return activeMont end
        function animInst:Montage_SetPlayRate(_, rate) lastSetRate = rate end
        local mesh = Mock.MakeUObject("SkeletalMeshComponent /Game/Player:Mesh")
        function mesh:GetAnimInstance() return animInst end
        local pawn = Mock.MakeUObject("BP_PlayerCharacter_C /Game/Player", { Mesh = mesh })

        local cfg = ConfigManager.CreateDefaultConfig()
        cfg.KeepGroundSmashAnchored = false
        cfg.EnableFinisherSpeedClamp = true
        cfg.MaxFinisherSpeedClamp = 2.0

        CombatEngine.ApplyMontageRateToInstance(cfg, pawn, activeMont, 3.5, true)
        T.AssertNear(lastSetRate, 2.0, 1e-4, "Finisher speed clamp must apply even when KeepGroundSmashAnchored=false")

        cfg.EnableFinisherSpeedClamp = false
        CombatEngine.ApplyMontageRateToInstance(cfg, pawn, activeMont, 3.5, true)
        T.AssertNear(lastSetRate, 3.5, 1e-4, "Disabling EnableFinisherSpeedClamp must allow uncapped speed")

        -- Custom spell with clamp=true (FlamesOfZamorak) has isClamped=true but isSmash=false
        local zamSpell = Mock.MakeUObject("DominionSpellData /Game/Spells/Specials/DA_ZamorakStaff_Special.DA_ZamorakStaff_Special")
        local spellRegistry = {
            ["da_zamorakstaff_special"] = {
                spellObj = zamSpell,
                shortName = "DA_ZamorakStaff_Special",
                fullName = zamSpell:GetFullName(),
                categoryTag = "Fire",
                isSmash = false
            }
        }
        local f = io.open(MOD_ROOT .. "/custom_spells.json", "r")
        local raw = f:read("*a")
        f:close()
        local defs = CustomSpells.ParseDefinitions(raw)
        local entries = CustomSpells.BuildCustomRegistryEntries(
            defs, spellRegistry, {}, {},
            function(o) return o:GetFullName() end,
            function(s) return s:match("%.([^%.]+)$") or s end
        )
        T.AssertTrue(entries["flamesofzamorak"].isClamped)
        T.AssertFalse(entries["flamesofzamorak"].isSmash)
        T.AssertTrue(CombatEngine.IsNotifyClampedEntry(entries["flamesofzamorak"]))
    end)

    T.Test("ConfigManager persists KeepGroundSmashAnchored, EnableFinisherSpeedClamp, and FixAir4thVerticalAim", function()
        local base = os.getenv("TEMP") or os.getenv("TMP") or "."
        local prefix = base .. "/arcanewilds_air4cfg_"
        local paths = {
            CONFIG_PATH             = prefix .. "config.txt",
            COMBO_RULES_JSON_PATH   = prefix .. "combo_rules.json",
            SPELL_NAMES_PATH        = prefix .. "spell_names.txt",
            CUSTOM_SPELLS_JSON_PATH = prefix .. "custom_spells.json",
            QUICK_CAST_PATH         = prefix .. "quick_cast.txt"
        }
        for _, p in pairs(paths) do pcall(os.remove, p) end

        local okRun, errRun = pcall(function()
            local cfgOut = ConfigManager.CreateDefaultConfig()
            cfgOut.KeepGroundSmashAnchored = true
            cfgOut.EnableFinisherSpeedClamp = false
            cfgOut.FixAir4thVerticalAim = false
            ConfigManager.SaveConfigFile(paths, cfgOut)

            local cfgIn = ConfigManager.CreateDefaultConfig()
            local state = {
                BaseSpellRegistry = {}, SpellRegistry = {}, SpellChains = {},
                CustomSpellDefs = {}, ParsedMacros = {}, NameMapByCat = {},
                GlobalNameMap = {}, DiscoveredLookup = {}
            }
            ConfigManager.LoadConfigFile(paths, cfgIn, state, function() end, false)
            T.AssertTrue(cfgIn.KeepGroundSmashAnchored)
            T.AssertFalse(cfgIn.EnableFinisherSpeedClamp)
            T.AssertFalse(cfgIn.FixAir4thVerticalAim)
        end)

        for _, p in pairs(paths) do pcall(os.remove, p) end
        if not okRun then error(errRun) end
    end)
end)
