-- Regression tests for:
--   1. Montage play-rate squaring fix (RateScale stays 1.0 while Montage_SetPlayRate drives speed)
--   2. Parallel overlapping timelines (StormOfArmadyl multi-cast without cancelling previous gusts/bolts)
--   3. UE5 Niagara scalability/instance-culling bypass on spawned VFX
--   4. Live Lock-On detection (rejecting stale LockOnCameraActor after unlock/death),
--      reticle look-at targeting, and RequireLockOnForChainSpells toggle.

local T = require("test_harness")
local Mock = require("ue4ss_mock")
local CombatEngine = require("combat_engine")
local ConfigManager = require("config_manager")
local CustomSpells = require("custom_spells")
local SpellScanner = require("spell_scanner")
local TimelineParser = require("timeline_parser")
local TimelineRunner = require("timeline_runner")

local function ReadFile(path)
    local f, err = io.open(path, "r")
    T.AssertNotNil(f, "failed to open " .. tostring(path) .. ": " .. tostring(err))
    local raw = f:read("*a")
    f:close()
    return raw
end

local function MakeVector(x, y, z)
    return { X = x or 0.0, Y = y or 0.0, Z = z or 0.0 }
end

local function MakeRot(p, y, r)
    return { Pitch = p or 0.0, Yaw = y or 0.0, Roll = r or 0.0 }
end

local function RegisterCoreUeClasses()
    local classPaths = {
        "/Script/CoreUObject.Class",
        "/Script/Engine.AnimMontage",
        "/Script/Engine.AnimSequenceBase",
        "/Script/Niagara.NiagaraSystem",
        "/Script/Engine.SoundBase",
        "/Script/Dominion.DominionSpellData",
        "/Script/Engine.MaterialInterface",
        "/Script/Engine.Actor",
        "/Script/Engine.CameraShakeBase"
    }
    local classes = {}
    for _, cp in ipairs(classPaths) do
        local cls = Mock.MakeUObject("Class " .. cp)
        Mock.RegisterPath(cp, cls)
        classes[cp] = cls
    end
    return classes
end

local function MakeTypedObject(fullName, classPath, props)
    local obj = Mock.MakeUObject(fullName, props)
    obj._classPath = classPath
    function obj:IsA(cls)
        return cls ~= nil and cls._fullName == ("Class " .. self._classPath)
    end
    return obj
end

local function MakeMockEnemy(name, loc, hp)
    local healthComp = Mock.MakeUObject("AiHealthComponent " .. name .. ":Health", {
        _hp = hp or 200.0
    })
    function healthComp:GetAuthoritativeHealth()
        return self._hp
    end
    function healthComp:DecreaseHealth(amount)
        self._hp = math.max(0.0, self._hp - amount)
    end

    local enemy = Mock.MakeUObject("DominionAICharacter " .. name, {
        bIsTargetable = true,
        HealthComponent = healthComp,
        _loc = loc or MakeVector(400, 0, 0),
        _rot = MakeRot(0, 180, 0)
    })
    function enemy:K2_GetActorLocation() return self._loc end
    function enemy:K2_GetActorRotation() return self._rot end
    function enemy:GetAiHealthComponent() return self.HealthComponent end
    return enemy
end

local function MakeMockPawn(loc, yaw, camRot)
    local pcm = Mock.MakeUObject("PlayerCameraManager /Game/Maps/Main.PCM", {
        _camLoc = loc or MakeVector(0, 0, 120),
        _camRot = camRot or MakeRot(0, yaw or 0, 0),
        ViewTarget = { Target = nil },
        PendingViewTarget = { Target = nil }
    })
    function pcm:GetCameraLocation() return self._camLoc end
    function pcm:GetCameraRotation() return self._camRot end

    local pc = Mock.MakeUObject("DominionPlayerController /Game/Maps/Main.PC", {
        PlayerCameraManager = pcm,
        _viewTarget = nil
    })
    function pc:GetViewTarget() return self._viewTarget end
    function pc:GetControlRotation() return pcm._camRot end
    function pc:LineOfSightTo() return true end

    local pawn = Mock.MakeUObject("BP_PlayerCharacter_C /Game/Maps/Main.Player", {
        Controller = pc,
        _loc = loc or MakeVector(0, 0, 0),
        _rot = MakeRot(0, yaw or 0, 0)
    })
    function pawn:K2_GetActorLocation() return self._loc end
    function pawn:K2_GetActorRotation() return self._rot end
    pc._viewTarget = pawn
    pcm.ViewTarget.Target = pawn
    return pawn, pc, pcm
end

T.Suite("overlap_and_lockon", function()
    T.Test("ApplyMontageRateToInstance drives PlayRate without squaring RateScale", function()
        Mock.Reset()
        local lastSetRate = nil
        local activeMont = Mock.MakeUObject("AnimMontage /Game/Anims/AM_Air_02.AM_Air_02", {
            RateScale = 2.2
        })
        local animInst = Mock.MakeUObject("AnimInstance /Game/Anims/ABP_Player.ABP_Player")
        function animInst:GetCurrentActiveMontage() return activeMont end
        function animInst:Montage_SetPlayRate(m, rate)
            T.AssertEq(m, activeMont)
            lastSetRate = rate
        end
        local mesh = Mock.MakeUObject("SkeletalMeshComponent /Game/Player:Mesh")
        function mesh:GetAnimInstance() return animInst end
        local pawn = Mock.MakeUObject("BP_PlayerCharacter_C /Game/Player", { Mesh = mesh })

        local config = ConfigManager.CreateDefaultConfig()
        CombatEngine.ApplyMontageRateToInstance(config, pawn, activeMont, 2.2, false)

        T.AssertNear(activeMont.RateScale, 1.0, 1e-4, "RateScale must stay 1.0 so UE5 does not multiply RateScale * PlayRate")
        T.AssertNear(lastSetRate, 2.2, 1e-4, "Montage_SetPlayRate should receive exact 2.2x rate")

        -- Clamped finisher respects MaxFinisherSpeedClamp while keeping RateScale == 1.0
        config.MaxFinisherSpeedClamp = 1.75
        CombatEngine.ApplyMontageRateToInstance(config, pawn, activeMont, 3.0, true)
        T.AssertNear(activeMont.RateScale, 1.0, 1e-4)
        T.AssertNear(lastSetRate, 1.75, 1e-4)
    end)

    T.Test("UnlockSpellMovement enables bAllowTriggeringNotifiesMultipleTimes on montage modules", function()
        Mock.Reset()
        local mont = Mock.MakeUObject("AnimMontage /Game/Anims/AM_Air_01.AM_Air_01", {
            bEnableRootMotionTranslation = true,
            bEnableRootMotionRotation = true
        })
        local modObj = Mock.MakeUObject("SpellModule_PlayMontage /Game/Spells/DA_Air.DA_Air:Mod", {
            Montage = mont,
            bShouldBlockMovement = true,
            MaxMovementSpeedDuringMontage = 0.0,
            bAllowTriggeringNotifiesMultipleTimes = false
        })
        local arr = {}
        function arr:ForEach(cb)
            cb(1, { get = function() return { Module = modObj } end })
        end
        local spellObj = Mock.MakeUObject("DominionSpellData /Game/Spells/DA_Air.DA_Air", {
            Modules = { Modules = arr }
        })

        SpellScanner.UnlockSpellMovement(spellObj, 600.0)
        T.AssertFalse(modObj.bShouldBlockMovement)
        T.AssertNear(modObj.MaxMovementSpeedDuringMontage, 600.0)
        T.AssertTrue(modObj.bAllowTriggeringNotifiesMultipleTimes)
        T.AssertFalse(mont.bEnableRootMotionTranslation)
    end)

    T.Test("StormOfArmadyl and SaradominStrike default to parallel overlapPolicy in custom_spells.json", function()
        local raw = ReadFile(MOD_ROOT .. "/custom_spells.json")
        local defs, err = CustomSpells.ParseDefinitions(raw)
        T.AssertNil(err)
        T.AssertEq(defs["stormofarmadyl"].overlapPolicy, "parallel")
        T.AssertEq(defs["saradominstrike"].overlapPolicy, "parallel")
    end)

    T.Test("parallel StormOfArmadyl casts keep independent timelines, uncap Niagara culling, and both spawn gusts", function()
        Mock.Reset()
        TimelineRunner.ClearValidationCache()
        RegisterCoreUeClasses()

        local pawn = MakeMockPawn(MakeVector(0, 0, 0), 0)
        local enemy1 = MakeMockEnemy("Goblin_1", MakeVector(500, 0, 0), 300)
        local enemy2 = MakeMockEnemy("Goblin_2", MakeVector(500, 100, 0), 300)
        Mock.RegisterClassInstance("DominionAICharacter", enemy1)
        Mock.RegisterClassInstance("DominionAICharacter", enemy2)

        -- Mock NiagaraSystem with EffectType scalability limits
        local scalSetting = { bCullMaxInstanceCount = true, bCullPerSystemMaxInstanceCount = true }
        local scalArr = {}
        function scalArr:ForEach(cb)
            cb(1, { get = function() return scalSetting end })
        end
        -- Make scalArr look like userdata? Note: in Lua mock it's a table, so also verify top-level flags on asset & component
        local effectType = Mock.MakeUObject("NiagaraEffectType /Game/VFX/ET_Spell.ET_Spell", {
            bAllowCullingForLocalPlayers = true,
            SystemScalabilitySettings = { Settings = scalArr }
        })
        local vfxPath = "/Game/Art/VFX/Library/Spells/Windstep/NS_Windstep_Launch.NS_Windstep_Launch"
        local gustVfx = MakeTypedObject("NiagaraSystem " .. vfxPath, "/Script/Niagara.NiagaraSystem", {
            EffectType = effectType,
            bOverrideAllowCullingForLocalPlayers = false,
            bAllowCullingForLocalPlayersOverride = true
        })
        Mock.RegisterPath(vfxPath, gustVfx)

        -- Mock NiagaraFunctionLibrary collecting spawned components
        local spawnedComps = {}
        local nsLib = Mock.MakeUObject("NiagaraFunctionLibrary /Script/Niagara.Default__NiagaraFunctionLibrary")
        function nsLib:SpawnSystemAtLocation(_, sysAsset, loc)
            local comp = Mock.MakeUObject("NiagaraComponent /Temp/Gust_" .. tostring(#spawnedComps + 1), {
                Asset = sysAsset,
                _loc = loc,
                bAllowScalability = true,
                _forceLocal = false,
                _forceSolo = false,
                _destroyed = false
            })
            function comp:SetForceLocalPlayerEffect(b) self._forceLocal = b end
            function comp:SetForceSolo(b) self._forceSolo = b end
            function comp:SetWorldScale3D() end
            function comp:SetVariableFloat() end
            function comp:SetVariableVec3() end
            function comp:Deactivate() self._deactivated = true end
            function comp:K2_DestroyComponent() self._destroyed = true end
            table.insert(spawnedComps, comp)
            return comp
        end
        Mock.RegisterPath("/Script/Niagara.Default__NiagaraFunctionLibrary", nsLib)

        -- Mock Air Bolt DominionSpellData & DominionRuntimeBlueprintLibrary
        local airBolt = MakeTypedObject("DominionSpellData /Game/Spells/DA_Spell_Primary_Air_01.DA_Spell_Primary_Air_01", "/Script/Dominion.DominionSpellData")
        local combatMagic = Mock.MakeUObject("PlayerCombatMagicComponent /Game/Player:CombatMagic", {
            CurrentSpellActor = nil
        })

        local triggerCount = 0
        local spellActor1 = Mock.MakeUObject("DominionSpellActor /Game/Maps/Main.SpellActor_1", {
            _loc = MakeVector(250, 0, 50)
        })
        function spellActor1:K2_GetActorLocation() return self._loc end

        local bpLib = Mock.MakeUObject("DominionRuntimeBlueprintLibrary /Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
        function bpLib:TriggerModularAbilityForPlayer(_, _)
            triggerCount = triggerCount + 1
            -- Cast #1 spawns SpellActor_1; Cast #2 fires while SpellActor_1 is STILL active (simulating engine single-slot gate)
            if triggerCount == 1 then
                combatMagic.CurrentSpellActor = spellActor1
            end
        end
        Mock.RegisterPath("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary", bpLib)

        -- Build StormOfArmadyl entry from real custom_spells.json
        local defs = CustomSpells.ParseDefinitions(ReadFile(MOD_ROOT .. "/custom_spells.json"))
        local tl, warnings = TimelineParser.BuildTimeline(defs["stormofarmadyl"])
        T.AssertEq(#warnings, 0)
        local entry = {
            shortName = "StormOfArmadyl",
            isCustomSpell = true,
            suppressBaseSpell = true,
            hasTimeline = true,
            timeline = tl,
            customDef = defs["stormofarmadyl"],
            customOverrideSpeed = 1.6
        }

        local hitPulseCount = 0
        local mockCustomSpells = {
            FindObjectFast = function(p) return Mock.ObjectsByPath[p] end,
            ExecuteHitPulse = function()
                hitPulseCount = hitPulseCount + 1
                return 1, {}
            end
        }

        local state = {
            ActiveTimelines = {},
            SpellRegistry = {
                ["da_spell_primary_air_01"] = { spellObj = airBolt, suppressBaseSpell = false }
            }
        }
        local config = ConfigManager.CreateDefaultConfig()

        -- Fire Cast #1 at t0
        local tl1 = TimelineRunner.StartSpellTimeline(config, state, pawn, combatMagic, entry, 2.2, mockCustomSpells)
        T.AssertNotNil(tl1)
        T.AssertEq(#state.ActiveTimelines, 1)
        T.AssertEq(tl1.cueStates[1].trackedSpellActor, spellActor1, "Cast #1 should claim SpellActor_1")

        -- Fire Cast #2 while Cast #1 is STILL flying! Must NOT cancel Cast #1 and must NOT steal SpellActor_1!
        local tl2 = TimelineRunner.StartSpellTimeline(config, state, pawn, combatMagic, entry, 2.2, mockCustomSpells)
        T.AssertNotNil(tl2)
        T.AssertEq(#state.ActiveTimelines, 2, "Both StormOfArmadyl casts must coexist in parallel")
        T.AssertFalse(tl1.finished, "Cast #1 must NOT be cancelled by Cast #2")
        T.AssertNil(tl2.cueStates[1].trackedSpellActor, "Cast #2 must NOT hijack Cast #1's SpellActor_1")

        -- Cast #1's bolt finishes flying (SpellActor_1 clears at t + 0.25s)
        local t0 = tl1.startedAt
        spellActor1._valid = false
        combatMagic.CurrentSpellActor = nil
        TimelineRunner.Tick(t0 + 0.25, config, state, pawn, combatMagic, mockCustomSpells)
        -- Second tick promotes >bolt hit + & gust VFX for Cast #1
        TimelineRunner.Tick(t0 + 0.26, config, state, pawn, combatMagic, mockCustomSpells)

        T.AssertEq(hitPulseCount, 1, "Cast #1 hit pulse should fire on impact")
        T.AssertEq(#spawnedComps, 1, "Cast #1 upward gust VFX should spawn")

        -- Cast #2 reaches fallback impact window (age >= 0.40s) and fires its OWN hit + gust VFX!
        TimelineRunner.Tick(tl2.startedAt + 0.45, config, state, pawn, combatMagic, mockCustomSpells)
        TimelineRunner.Tick(tl2.startedAt + 0.46, config, state, pawn, combatMagic, mockCustomSpells)

        T.AssertEq(hitPulseCount, 2, "Cast #2 hit pulse must also fire independently")
        T.AssertEq(#spawnedComps, 2, "Both overlapping StormOfArmadyl casts must spawn their upward gust VFX")
        T.AssertFalse(spawnedComps[1]._destroyed, "Cast #1 gust VFX must NOT be destroyed by Cast #2")

        -- Verify Niagara culling bypass flags were applied on both spawned gust components & asset
        for i, comp in ipairs(spawnedComps) do
            T.AssertFalse(comp.bAllowScalability, "Gust #" .. i .. " must have bAllowScalability=false")
            T.AssertTrue(comp._forceLocal, "Gust #" .. i .. " must call SetForceLocalPlayerEffect(true)")
            T.AssertTrue(comp._forceSolo, "Gust #" .. i .. " must call SetForceSolo(true)")
        end
        T.AssertTrue(gustVfx.bOverrideAllowCullingForLocalPlayers)
        T.AssertFalse(gustVfx.bAllowCullingForLocalPlayersOverride)
        T.AssertFalse(effectType.bAllowCullingForLocalPlayers)
    end)

    T.Test("Lock-on detection rejects stale LockOnCameraActor after target death/unlock, accepts active lock and reticle look-at", function()
        Mock.Reset()
        local pawn, pc, pcm = MakeMockPawn(MakeVector(0, 0, 0), 0, MakeRot(0, 0, 0))
        local enemyAhead = MakeMockEnemy("Bandit_1", MakeVector(400, 0, 0), 150)
        local deadEnemy = MakeMockEnemy("DeadBandit", MakeVector(300, 0, 0), 0)
        Mock.RegisterClassInstance("DominionAICharacter", enemyAhead)
        Mock.RegisterClassInstance("DominionAICharacter", deadEnemy)

        -- Case 1: Fresh player before ever locking on, not looking at enemy with reticle -> nil
        local lockComp = Mock.MakeUObject("LockOnTargetingComponent /Game/Player:LockOn", {
            LockOnCameraActor = nil,
            TargetingWidgetInstance = nil,
            PlayerController = pc,
            MaxTargetDistance = 3000.0
        })
        local targetor = Mock.MakeUObject("EnemyTargetorComponent /Game/Player:Targetor", {
            CurrentWorldActor = nil,
            CurrentTargetable = nil
        })
        pawn.LockOnTargetingComponent = lockComp
        pawn.TargetorComponent = targetor

        local found = TimelineRunner.ResolveLockedOnEnemy(pawn, 3000.0)
        T.AssertNil(found, "Should not report a lock before locking on or hovering enemy with reticle")

        -- Case 2: Looking directly at an alive enemy via UEnemyTargetorComponent (before ever pressing lock-on!) -> counts as lock!
        targetor.CurrentWorldActor = enemyAhead
        local lookFound = TimelineRunner.ResolveLockedOnEnemy(pawn, 3000.0)
        T.AssertEq(lookFound, enemyAhead, "Looking directly at an alive enemy via reticle should count as a lock")

        -- Dead enemy in reticle must NOT count
        targetor.CurrentWorldActor = deadEnemy
        T.AssertNil(TimelineRunner.ResolveLockedOnEnemy(pawn, 3000.0), "Dead enemy in reticle must not count as a lock")
        targetor.CurrentWorldActor = nil

        -- Case 3: Active hard lock-on (LockOnCameraActor spawned, TargetingWidget visible, ViewTarget == LockOnCameraActor)
        local lockCamComp = Mock.MakeUObject("CameraComponent /Game/LockCam:Camera")
        function lockCamComp:K2_GetComponentLocation() return MakeVector(0, 0, 120) end
        function lockCamComp:K2_GetComponentRotation() return MakeRot(0, 0, 0) end
        function lockCamComp:IsActive() return true end

        local lockCamActor = Mock.MakeUObject("LockOnTargetCameraActor /Game/LockCam", {
            AttachedToActor = pawn, -- attached to player, just like live Dragonwilds!
            Camera = lockCamComp
        })
        local widget = Mock.MakeUObject("UserWidget /Game/UI/LockReticle", {
            _vis = 0, -- Visible
            _inVp = true
        })
        function widget:GetVisibility() return self._vis end
        function widget:IsInViewport() return self._inVp end

        lockComp.LockOnCameraActor = lockCamActor
        lockComp.TargetingWidgetInstance = widget
        pc._viewTarget = lockCamActor
        pcm.ViewTarget.Target = lockCamActor

        T.AssertTrue(TimelineRunner.IsLockOnCurrentlyActive(pawn, lockComp, lockCamActor))
        local hardLocked = TimelineRunner.ResolveLockedOnEnemy(pawn, 3000.0)
        T.AssertEq(hardLocked, enemyAhead, "Active hard lock-on should resolve locked enemy")

        -- Case 4 (THE BUG): Target died or player unlocked!
        -- LockOnCameraActor REMAINS valid in the world, but widget is Collapsed (1) and ViewTarget returned to pawn!
        widget._vis = 1 -- Collapsed
        pc._viewTarget = pawn
        pcm.ViewTarget.Target = pawn

        T.AssertFalse(TimelineRunner.IsLockOnCurrentlyActive(pawn, lockComp, lockCamActor),
            "Stale LockOnCameraActor with collapsed widget & player ViewTarget must NOT report active lock-on")
        local afterUnlock = TimelineRunner.ResolveLockedOnEnemy(pawn, 3000.0)
        T.AssertNil(afterUnlock,
            "After target dies / unlock, stale LockOnCameraActor must NOT keep attacking nearby enemies!")
    end)

    T.Test("SaradominStrike respects requireLock and RequireLockOnForChainSpells config toggle", function()
        Mock.Reset()
        TimelineRunner.ClearValidationCache()
        RegisterCoreUeClasses()

        local pawn, pc, pcm = MakeMockPawn(MakeVector(0, 0, 0), 0, MakeRot(0, 0, 0))
        local enemy = MakeMockEnemy("Goblin_Aimed", MakeVector(450, 0, 0), 200)
        Mock.RegisterClassInstance("DominionAICharacter", enemy)

        -- Stale LockOnCameraActor (not locked on) & empty reticle targetor
        local lockCamActor = Mock.MakeUObject("LockOnTargetCameraActor /Game/LockCam_Stale", {
            AttachedToActor = pawn
        })
        local hiddenWidget = Mock.MakeUObject("UserWidget /Game/UI/LockReticle_Hidden")
        function hiddenWidget:GetVisibility() return 2 end -- Hidden
        function hiddenWidget:IsInViewport() return false end

        pawn.LockOnTargetingComponent = Mock.MakeUObject("LockOnTargetingComponent /Game/Player:LockOn", {
            LockOnCameraActor = lockCamActor,
            TargetingWidgetInstance = hiddenWidget,
            PlayerController = pc
        })
        pawn.TargetorComponent = Mock.MakeUObject("EnemyTargetorComponent /Game/Player:Targetor", {
            CurrentWorldActor = nil
        })

        local defs = CustomSpells.ParseDefinitions(ReadFile(MOD_ROOT .. "/custom_spells.json"))
        -- Explicitly test a cue with requireLock = true so we verify RequireLockOnForChainSpells gating independently
        local tl = TimelineParser.BuildTimeline(defs["saradominstrike"])
        tl.cues[1].params.requireLock = true
        local entry = {
            shortName = "SaradominStrike",
            isCustomSpell = true,
            suppressBaseSpell = true,
            hasTimeline = true,
            timeline = tl,
            customDef = defs["saradominstrike"]
        }

        local damageCalls = 0
        local mockCustomSpells = {
            ApplyDominionBlueprintDamage = function()
                damageCalls = damageCalls + 1
                return true, "ok"
            end
        }

        -- 1. With RequireLockOnForChainSpells = true (default) and requireLock = true -> MUST NOT FIRE!
        local cfgStrict = ConfigManager.CreateDefaultConfig()
        T.AssertTrue(cfgStrict.RequireLockOnForChainSpells)
        local state1 = { ActiveTimelines = {} }
        local resStrict = TimelineRunner.StartSpellTimeline(cfgStrict, state1, pawn, nil, entry, 1.0, mockCustomSpells)
        T.AssertNil(resStrict, "SaradominStrike should abort when RequireLockOnForChainSpells=true, cue.requireLock=true, and not locked/looking")
        T.AssertEq(damageCalls, 0)

        -- 2. With RequireLockOnForChainSpells = false -> fires via crosshair auto-target without lock-on!
        local cfgFree = ConfigManager.CreateDefaultConfig()
        cfgFree.RequireLockOnForChainSpells = false
        local state2 = { ActiveTimelines = {} }
        local resFree = TimelineRunner.StartSpellTimeline(cfgFree, state2, pawn, nil, entry, 1.0, mockCustomSpells)
        T.AssertNotNil(resFree, "SaradominStrike should fire when RequireLockOnForChainSpells=false")
        T.AssertEq(damageCalls, 1, "First chainstrike bolt should hit aimed enemy immediately")

        -- 3. With RequireLockOnForChainSpells = true BUT cue.requireLock = false (parsed from JSON boolean false!) -> MUST FIRE!
        tl.cues[1].params.requireLock = false
        local state3 = { ActiveTimelines = {} }
        local resCueFree = TimelineRunner.StartSpellTimeline(cfgStrict, state3, pawn, nil, entry, 1.0, mockCustomSpells)
        T.AssertNotNil(resCueFree, "SaradominStrike with cue.requireLock=false should fire even when RequireLockOnForChainSpells=true")
        T.AssertEq(damageCalls, 2)
    end)

    T.Test("ConfigManager persists and reloads RequireLockOnForChainSpells", function()
        local base = os.getenv("TEMP") or os.getenv("TMP") or "."
        local prefix = base .. "/arcanewilds_lockopt_"
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
            cfgOut.RequireLockOnForChainSpells = false
            ConfigManager.SaveConfigFile(paths, cfgOut)

            local cfgIn = ConfigManager.CreateDefaultConfig()
            T.AssertTrue(cfgIn.RequireLockOnForChainSpells)
            local state = {
                BaseSpellRegistry = {}, SpellRegistry = {}, SpellChains = {},
                CustomSpellDefs = {}, ParsedMacros = {}, NameMapByCat = {},
                GlobalNameMap = {}, DiscoveredLookup = {}
            }
            ConfigManager.LoadConfigFile(paths, cfgIn, state, function() end, false)
            T.AssertFalse(cfgIn.RequireLockOnForChainSpells, "RequireLockOnForChainSpells=false must round-trip via config.txt")
        end)

        for _, p in pairs(paths) do pcall(os.remove, p) end
        if not okRun then error(errRun) end
    end)

    T.Test("ResolveLockedOnEnemy ignores ore nodes, mining rocks, and static meshes under reticle", function()
        Mock.Reset()
        local pawn = MakeMockPawn(MakeVector(0, 0, 0), 0)
        local oreNode = Mock.MakeUObject("BP_OreNode_Stone_C /Game/Maps/World.OreNode_1", {
            bIsTargetable = true
        })
        function oreNode:K2_GetActorLocation() return MakeVector(250, 0, 0) end
        local staticRock = Mock.MakeUObject("StaticMeshActor /Game/Maps/World.Rock_1", {
            bIsTargetable = true
        })
        function staticRock:K2_GetActorLocation() return MakeVector(250, 0, 0) end

        local targetor = Mock.MakeUObject("EnemyTargetorComponent /Game/Player:Targetor", {
            CurrentWorldActor = oreNode
        })
        pawn.TargetorComponent = targetor

        T.AssertNil(TimelineRunner.ResolveLockedOnEnemy(pawn, 3000.0), "Ore node must not be treated as a locked enemy")
        targetor.CurrentWorldActor = staticRock
        T.AssertNil(TimelineRunner.ResolveLockedOnEnemy(pawn, 3000.0), "StaticMeshActor must not be treated as a locked enemy")
    end)

    T.Test("dead player guard blocks spell triggers and RecoverFromDeathOrRespawn clears stuck CastingTag", function()
        Mock.Reset()
        local pawn = MakeMockPawn(MakeVector(0, 0, 0), 0)
        local healthComp = Mock.MakeUObject("PlayerHealthComponent /Game/Player:Health", {
            _dead = true,
            _hp = 0.0
        })
        function healthComp:IsDead() return self._dead end
        function healthComp:GetAuthoritativeHealth() return self._hp end
        pawn.HealthComponent = healthComp

        T.AssertTrue(CombatEngine.IsPlayerDead(pawn), "Dead pawn must be detected via IsDead/HP")

        local triggeredNative = 0
        local removedTag = nil
        local bpLib = Mock.MakeUObject("DominionRuntimeBlueprintLibrary /Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
        function bpLib:TriggerModularAbilityForPlayer() triggeredNative = triggeredNative + 1 end
        function bpLib:RemoveTagFromPlayerCharacter(_, tag) removedTag = tag end
        Mock.RegisterPath("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary", bpLib)

        local spellObj = Mock.MakeUObject("DominionSpellData /Game/Spells/DA_Spell_Primary_Air_01.DA_Spell_Primary_Air_01")
        local entry = { shortName = "DA_Spell_Primary_Air_01", spellObj = spellObj }
        local config = ConfigManager.CreateDefaultConfig()
        local state = { ActiveTimelines = {}, ModifierHeld = true, PendingAnchorReturn = true }

        local okCast = CombatEngine.TriggerSpellEntryForPlayer(config, state, pawn, entry, nil, nil)
        T.AssertFalse(okCast, "Must NEVER trigger abilities on a dead pawn")
        T.AssertEq(triggeredNative, 0)

        -- Respawn recovery cancels stuck spell actor and clears CastingTag
        local cancelCalled = false
        local clearedLocalTag = nil
        local castingTag = { TagName = FName("State.SpellCasting") }
        local tagsComp = Mock.MakeUObject("GameplayTagsComponent /Game/Player:Tags")
        function tagsComp:ClearLocalTag(t) clearedLocalTag = t end
        local stuckSpellActor = Mock.MakeUObject("DominionSpellActor /Game/Maps/Main.StuckSpell")
        local combatMagic = Mock.MakeUObject("PlayerCombatMagicComponent /Game/Player:CombatMagic", {
            CurrentSpellActor = stuckSpellActor,
            CastingTag = castingTag,
            GameplayTagsComponent = tagsComp
        })
        function combatMagic:Server_CancelSpell() cancelCalled = true end

        healthComp._dead = false
        healthComp._hp = 100.0
        T.AssertFalse(CombatEngine.IsPlayerDead(pawn))

        CombatEngine.RecoverFromDeathOrRespawn(config, state, combatMagic, pawn, nil, nil, "player-respawned")
        T.AssertTrue(cancelCalled, "Server_CancelSpell should clear stuck CurrentSpellActor")
        T.AssertEq(removedTag, castingTag, "RemoveTagFromPlayerCharacter should remove stuck CastingTag")
        T.AssertEq(clearedLocalTag, castingTag, "GameplayTagsComponent:ClearLocalTag should clear local CastingTag")
        T.AssertFalse(state.ModifierHeld)
        T.AssertFalse(state.PendingAnchorReturn)
    end)

    T.Test("TriggerSpellEntryForPlayer returns false when SaradominStrike aborts with no locked target", function()
        Mock.Reset()
        TimelineRunner.ClearValidationCache()
        RegisterCoreUeClasses()

        local pawn, pc = MakeMockPawn(MakeVector(0, 0, 0), 0)
        pawn.HealthComponent = Mock.MakeUObject("PlayerHealthComponent /Game/Player:Health", {
            IsDead = function() return false end,
            GetAuthoritativeHealth = function() return 100.0 end
        })
        pawn.LockOnTargetingComponent = Mock.MakeUObject("LockOnTargetingComponent /Game/Player:LockOn", {
            LockOnCameraActor = nil,
            PlayerController = pc
        })
        pawn.TargetorComponent = Mock.MakeUObject("EnemyTargetorComponent /Game/Player:Targetor", {
            CurrentWorldActor = nil
        })

        local defs = CustomSpells.ParseDefinitions(ReadFile(MOD_ROOT .. "/custom_spells.json"))
        local tl = TimelineParser.BuildTimeline(defs["saradominstrike"])
        tl.cues[1].params.requireLock = true
        local entry = {
            shortName = "SaradominStrike",
            isCustomSpell = true,
            suppressBaseSpell = true,
            hasTimeline = true,
            timeline = tl,
            customDef = defs["saradominstrike"],
            requiredMagicLevel = 0
        }

        local config = ConfigManager.CreateDefaultConfig()
        config.EnforceSpellLevelRequirements = false
        local state = { ActiveTimelines = {} }

        local ok = CombatEngine.TriggerSpellEntryForPlayer(config, state, pawn, entry, nil, nil)
        T.AssertFalse(ok, "Aborted SaradominStrike (no locked target) must return false and not trigger rune consumption / anchor return")
    end)

    T.Test("TimelineParser.ParseJsonCue preserves JSON boolean false for requireLock, los, preferUnique, scaleWithSpeed, trackImpact", function()
        local cue, warn = TimelineParser.ParseJsonCue({
            type = "chainstrike",
            at = "@0.00",
            asset = "lightning",
            requireLock = false,
            los = false,
            preferUnique = false,
            scaleWithSpeed = false,
            trackImpact = false,
            interrupt = false,
            stun = 1.5,
            root = 3.0,
            pushback = 850,
            launchZ = 240,
            slow = { multiplier = 0.4, duration = 2.5 }
        })
        T.AssertNil(warn)
        T.AssertNotNil(cue)
        T.AssertFalse(cue.params.requireLock, "JSON false for requireLock must stay false (not default to true!)")
        T.AssertFalse(cue.params.los, "JSON false for los must stay false")
        T.AssertFalse(cue.params.preferUnique, "JSON false for preferUnique must stay false")
        T.AssertFalse(cue.params.scaleWithSpeed, "JSON false for scaleWithSpeed must stay false")
        T.AssertFalse(cue.params.trackImpact, "JSON false for trackImpact must stay false")
        T.AssertFalse(cue.params.interrupt, "JSON false for interrupt must stay false")
        T.AssertNear(cue.params.stun, 1.5)
        T.AssertNear(cue.params.root, 3.0)
        T.AssertNear(cue.params.pushback, 850)
        T.AssertNear(cue.params.launchZ, 240)
        T.AssertNear(cue.params.slowMultiplier, 0.4)
        T.AssertNear(cue.params.slowDuration, 2.5)
    end)

    T.Test("ResolveAimTarget uses 3D crosshair ray priority over closer off-axis enemy", function()
        Mock.Reset()
        local pawn = MakeMockPawn(MakeVector(0, 0, 0), 0, MakeRot(0, 0, 0))
        -- Close enemy off to the side (~20 degrees off crosshair at 5m)
        local offAxisClose = MakeMockEnemy("Cow_OffAxis", MakeVector(470, 175, 0), 200)
        -- Further enemy dead-center under crosshair at 20m (2000cm)
        local deadCenterFar = MakeMockEnemy("Cow_DeadCenter", MakeVector(2000, 0, 0), 200)
        Mock.RegisterClassInstance("DominionAICharacter", offAxisClose)
        Mock.RegisterClassInstance("DominionAICharacter", deadCenterFar)

        local cfg = ConfigManager.CreateDefaultConfig()
        T.AssertNear(cfg.AutoTargetMaxDistance, 2500.0, 1e-4, "Default AutoTargetMaxDistance should be 2500cm (25m)")

        local _, _, chosen, mode = TimelineRunner.ResolveAimTarget(pawn, nil, 60, nil, cfg, nil)
        T.AssertEq(mode, "aimed")
        T.AssertEq(chosen, deadCenterFar, "Crosshair-ray targeting should prefer enemy dead-center under crosshair over closer off-axis enemy")
    end)

    T.Test("ApplyCrowdControl and TickCrowdControl handle Stun, Root, Pushback, Slow, and expiry cleanly", function()
        Mock.Reset()
        CustomSpells.ClearAllCrowdControl()

        local pawn = MakeMockPawn(MakeVector(0, 0, 0), 0)
        local stoppedMontage = false
        local animInst = Mock.MakeUObject("AnimInstance /Game/AI/ABP_Enemy")
        function animInst:Montage_Stop() stoppedMontage = true end
        local mesh = Mock.MakeUObject("SkeletalMeshComponent /Game/AI/Enemy:Mesh")
        function mesh:GetAnimInstance() return animInst end

        local moveStopped = false
        local runSpeedOverride = nil
        local runSpeedReset = false
        local mc = Mock.MakeUObject("AiMovementComponent /Game/AI/Enemy:MoveComp", { MaxWalkSpeed = 400.0 })
        function mc:StopMovementImmediately() moveStopped = true end
        function mc:GetRunSpeed() return 500.0 end
        function mc:OverrideMaxRunSpeed(spd) runSpeedOverride = spd end
        function mc:ResetOverrideRunSpeed() runSpeedReset = true; runSpeedOverride = nil end

        local enemy = MakeMockEnemy("Goblin_CC", MakeVector(500, 0, 0), 300)
        enemy.Mesh = mesh
        enemy.CharacterMovement = mc
        enemy._moveDisabled = false
        enemy._atkDisabled = false
        enemy._lastLocker = nil
        enemy._launchVel = nil
        function enemy:SetMovementDisabled(b, locker) self._moveDisabled = b; self._lastLocker = locker end
        function enemy:SetAttacksDisabled(b, locker) self._atkDisabled = b; self._lastLocker = locker end
        function enemy:LaunchCharacter(vel, xyO, zO) self._launchVel = vel; self._launchXY = xyO; self._launchZ = zO end

        local t0 = 100.0
        local ok, summary = CustomSpells.ApplyCrowdControl(
            enemy, pawn, MakeVector(0, 0, 0), MakeVector(500, 0, 0),
            { stun = 1.0, root = 3.0, pushback = 800, launchZ = 220, slowMultiplier = 0.4, slowDuration = 2.0 },
            nil, t0
        )
        T.AssertTrue(ok, "ApplyCrowdControl should report applied effects: " .. tostring(summary))
        T.AssertTrue(stoppedMontage, "Stun should interrupt active enemy montage")
        T.AssertTrue(moveStopped, "CC should call StopMovementImmediately")
        T.AssertTrue(enemy._moveDisabled, "Stun/Root should lock movement")
        T.AssertTrue(enemy._atkDisabled, "Stun should lock attacks")
        T.AssertEq(enemy._lastLocker, pawn, "Locker should be instigator pawn UObject")
        T.AssertNotNil(enemy._launchVel, "Pushback should invoke LaunchCharacter")
        T.AssertNear(enemy._launchVel.X, 800.0, 1e-2, "Pushback should launch radially away (+X)")
        T.AssertNear(enemy._launchVel.Y, 0.0, 1e-2)
        T.AssertNear(enemy._launchVel.Z, 220.0, 1e-2)
        T.AssertNear(runSpeedOverride, 200.0, 1e-2, "Slow 0.4x of 500 run speed should override to 200")

        -- At t0 + 1.1s: Stun (1.0s) expired -> attacks unlock, but Root (3.0s) keeps movement locked and Slow (2.0s) still active!
        CustomSpells.TickCrowdControl(t0 + 1.1)
        T.AssertFalse(enemy._atkDisabled, "Attacks should unlock after 1.0s stun expires")
        T.AssertTrue(enemy._moveDisabled, "Movement must remain locked until 3.0s root expires")
        T.AssertFalse(runSpeedReset, "Slow should still be active at 1.1s")

        -- At t0 + 2.1s: Slow (2.0s) expired -> run speed restored, Root still active!
        CustomSpells.TickCrowdControl(t0 + 2.1)
        T.AssertTrue(runSpeedReset, "Slow should reset run speed after 2.0s")
        T.AssertTrue(enemy._moveDisabled, "Root must remain active until 3.0s")

        -- At t0 + 3.1s: Root (3.0s) expired -> movement unlocked!
        CustomSpells.TickCrowdControl(t0 + 3.1)
        T.AssertFalse(enemy._moveDisabled, "Movement should unlock after 3.0s root expires")

        CustomSpells.ClearAllCrowdControl()
    end)
end)
