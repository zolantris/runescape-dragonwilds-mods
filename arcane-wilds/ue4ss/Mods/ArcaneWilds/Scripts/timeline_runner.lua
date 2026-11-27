-- ArcaneWilds - Spell Animation & Effects Timeline Runner
-- Executes simultaneous (slot-layered & parallel) and synchronous (chained & crossfaded)
-- player montages, weapon/actor/target animations, Niagara VFX, SFX, Spells, Multi-Hit pulses,
-- Decals, and Camera Shakes with full lifecycle cleanup and combo macro integration.

local TimelineRunner = {}

local TimelineInstanceCounter = 0
local CachedUeClasses = {}
local CachedSkillDataByName = {}
local LoggedMismatchWarnings = {}
local UncappedNiagaraSystems = {}
local NormalizeUeAssetPath
local ApplyNiagaraScaleAndParams
local UncapNiagaraAssetAndComponent

local function IsValidUObject(obj)
    if not obj then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

local function SafeObjName(obj)
    if not obj then return "nil" end
    local ok, n = pcall(function() return obj:GetFullName() end)
    return (ok and n) or tostring(obj)
end

local function HasUFunc(obj, name)
    if not IsValidUObject(obj) or not name then return false end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok or fn == nil then return false end
    local t = type(fn)
    if t == "function" then return true end
    if t == "userdata" then
        local okV, valid = pcall(function() return fn:IsValid() end)
        return (not okV) or (valid == true)
    end
    return false
end

local function GetCachedClass(classPath)
    local cached = CachedUeClasses[classPath]
    if cached ~= nil then
        if cached == false then return nil end
        if IsValidUObject(cached) then return cached end
        CachedUeClasses[classPath] = nil
    end
    local cls = nil
    pcall(function() cls = StaticFindObject(classPath) end)
    CachedUeClasses[classPath] = IsValidUObject(cls) and cls or false
    return IsValidUObject(cls) and cls or nil
end

local function ObjectIsClass(obj, classPath)
    if not IsValidUObject(obj) then return false end
    local cls = GetCachedClass(classPath)
    if not IsValidUObject(cls) then return false end
    local res = false
    pcall(function()
        if HasUFunc(obj, "IsA") then
            res = (obj:IsA(cls) == true)
        else
            local gp = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            if IsValidUObject(gp) and HasUFunc(gp, "ObjectIsA") then
                res = (gp:ObjectIsA(obj, cls) == true)
            end
        end
    end)
    return res
end

local function ClassIsSubclassOf(testClassObj, parentClassPath)
    if not IsValidUObject(testClassObj) then return false end
    -- Must actually be a UClass (not an instance or CDO!)
    if not ObjectIsClass(testClassObj, "/Script/CoreUObject.Class") then
        return false
    end
    local parentCls = GetCachedClass(parentClassPath)
    if not IsValidUObject(parentCls) then return false end
    local res = false
    pcall(function()
        local mathLib = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
        if IsValidUObject(mathLib) and HasUFunc(mathLib, "ClassIsChildOf") then
            res = (mathLib:ClassIsChildOf(testClassObj, parentCls) == true)
        end
    end)
    return res
end

local function LogMismatchOnce(key, msg)
    if LoggedMismatchWarnings[key] then return end
    LoggedMismatchWarnings[key] = true
    pcall(function() print("[ArcaneWilds][ERROR] " .. tostring(msg) .. "\n") end)
end

-- Strict runtime asset type guard: rejects wrong UE asset types (e.g. SoundWave in Anim=, AnimMontage in VFX=,
-- non-Actor in Actor=) cleanly with a one-time log error and ZERO UE5/UE4SS crash risk.
local function ValidateCueAssetType(obj, expectedKind, spellName, cueIdx, rawAsset)
    if not IsValidUObject(obj) then return false end
    local full = SafeObjName(obj)
    if full:lower():find("default__", 1, true) then
        LogMismatchOnce(tostring(spellName) .. ":" .. tostring(cueIdx) .. ":" .. tostring(rawAsset),
            string.format("CustomSpell [%s] Cue #%d (%s): '%s' resolved to a CDO (%s); skipping safely.",
                tostring(spellName), tonumber(cueIdx) or 0, tostring(expectedKind), tostring(rawAsset), full))
        return false
    end

    local ok = false
    local expectedDesc = expectedKind
    if expectedKind == "anim" then
        expectedDesc = "AnimMontage or AnimSequenceBase"
        ok = ObjectIsClass(obj, "/Script/Engine.AnimMontage") or ObjectIsClass(obj, "/Script/Engine.AnimSequenceBase")
    elseif expectedKind == "vfx" then
        expectedDesc = "NiagaraSystem"
        ok = ObjectIsClass(obj, "/Script/Niagara.NiagaraSystem")
    elseif expectedKind == "sfx" then
        expectedDesc = "SoundBase (SoundWave/SoundCue/MetaSound)"
        ok = ObjectIsClass(obj, "/Script/Engine.SoundBase")
    elseif expectedKind == "spell" then
        expectedDesc = "DominionSpellData"
        ok = ObjectIsClass(obj, "/Script/Dominion.DominionSpellData")
    elseif expectedKind == "decal" then
        expectedDesc = "MaterialInterface"
        ok = ObjectIsClass(obj, "/Script/Engine.MaterialInterface")
    elseif expectedKind == "actor" then
        expectedDesc = "Actor Class (SubclassOf<AActor>)"
        ok = ClassIsSubclassOf(obj, "/Script/Engine.Actor")
    elseif expectedKind == "shake" then
        expectedDesc = "CameraShakeBase Class (SubclassOf<UCameraShakeBase>)"
        ok = ClassIsSubclassOf(obj, "/Script/Engine.CameraShakeBase")
    end

    if not ok then
        local actualClass = full:match("^([^%s]+)") or "Unknown"
        LogMismatchOnce(tostring(spellName) .. ":" .. tostring(cueIdx) .. ":" .. tostring(rawAsset),
            string.format("CustomSpell [%s] Cue #%d (%s): incompatible asset '%s' -> got %s, expected %s! Skipping safely.",
                tostring(spellName), tonumber(cueIdx) or 0, tostring(expectedKind), tostring(rawAsset), actualClass, expectedDesc))
        return false
    end
    return true
end

function TimelineRunner.ClearValidationCache()
    LoggedMismatchWarnings = {}
    UncappedNiagaraSystems = {}
end

local function MakeVec(x, y, z)
    return { X = tonumber(x) or 0.0, Y = tonumber(y) or 0.0, Z = tonumber(z) or 0.0 }
end

local function MakeRot(p, y, r)
    return { Pitch = tonumber(p) or 0.0, Yaw = tonumber(y) or 0.0, Roll = tonumber(r) or 0.0 }
end

local function AddRot(baseRot, deltaRot)
    return MakeRot(
        (baseRot and baseRot.Pitch or 0.0) + (deltaRot and deltaRot.Pitch or 0.0),
        (baseRot and baseRot.Yaw or 0.0)   + (deltaRot and deltaRot.Yaw or 0.0),
        (baseRot and baseRot.Roll or 0.0)  + (deltaRot and deltaRot.Roll or 0.0)
    )
end

-- Transform a caster-local offset (X=forward, Y=right, Z=up) by actor yaw into world space.
local function LocalOffsetToWorld(originLoc, originRot, localOff)
    local ox = originLoc and originLoc.X or 0.0
    local oy = originLoc and originLoc.Y or 0.0
    local oz = originLoc and originLoc.Z or 0.0
    if not localOff then return MakeVec(ox, oy, oz) end

    local fwd = localOff.X or 0.0
    local rgt = localOff.Y or 0.0
    local up  = localOff.Z or 0.0
    if fwd == 0.0 and rgt == 0.0 and up == 0.0 then
        return MakeVec(ox, oy, oz)
    end

    local yawRad = math.rad(originRot and originRot.Yaw or 0.0)
    local cosY = math.cos(yawRad)
    local sinY = math.sin(yawRad)
    -- UE coordinate system: X=Forward, Y=Right, Z=Up (Yaw rotates X towards Y)
    local wx = ox + (fwd * cosY - rgt * sinY)
    local wy = oy + (fwd * sinY + rgt * cosY)
    local wz = oz + up
    return MakeVec(wx, wy, wz)
end

local function GetActorLocAndRot(actor)
    if not IsValidUObject(actor) then
        return MakeVec(0, 0, 0), MakeRot(0, 0, 0)
    end
    local loc, rot = nil, nil
    pcall(function() loc = actor:K2_GetActorLocation() end)
    pcall(function() rot = actor:K2_GetActorRotation() end)
    return MakeVec(loc and loc.X, loc and loc.Y, loc and loc.Z),
           MakeRot(rot and rot.Pitch, rot and rot.Yaw, rot and rot.Roll)
end

local function ResolvePlayerAnimManager(pawn)
    if not IsValidUObject(pawn) then return nil end
    local mgr = nil
    pcall(function() mgr = pawn.PlayerAnimationManager end)
    if IsValidUObject(mgr) then return mgr end
    pcall(function()
        local cls = StaticFindObject("/Script/Dominion.PlayerAnimationManager")
        if IsValidUObject(cls) and HasUFunc(pawn, "GetComponentByClass") then
            mgr = pawn:GetComponentByClass(cls)
        end
    end)
    return IsValidUObject(mgr) and mgr or nil
end

local function ResolveHeldEquipmentMesh(pawn, hand)
    if not IsValidUObject(pawn) then return nil, nil end
    local equipComp = nil
    pcall(function() equipComp = pawn.PlayerEquipmentComponent end)
    if not IsValidUObject(equipComp) then
        pcall(function()
            local cls = StaticFindObject("/Script/Dominion.PlayerEquipmentComponent")
            if IsValidUObject(cls) and HasUFunc(pawn, "GetComponentByClass") then
                equipComp = pawn:GetComponentByClass(cls)
            end
        end)
    end
    if not IsValidUObject(equipComp) then return nil, nil end

    local equipActor = nil
    local isLeft = (hand == "weapon_left" or hand == "left")
    pcall(function()
        if isLeft then
            if HasUFunc(equipComp, "GetHeldEquipmentActorLeft") then
                equipActor = equipComp:GetHeldEquipmentActorLeft()
            else
                equipActor = equipComp.HeldEquipmentActorLeft
            end
        else
            if HasUFunc(equipComp, "GetHeldEquipmentActorRight") then
                equipActor = equipComp:GetHeldEquipmentActorRight()
            else
                equipActor = equipComp.HeldEquipmentActorRight
            end
        end
    end)
    if not IsValidUObject(equipActor) then return nil, nil end

    local mesh = nil
    pcall(function()
        if HasUFunc(equipActor, "GetMesh") then
            mesh = equipActor:GetMesh()
        else
            mesh = equipActor.MeshComponent
        end
    end)
    if not IsValidUObject(mesh) then
        pcall(function()
            local skCls = StaticFindObject("/Script/Engine.SkeletalMeshComponent")
            if IsValidUObject(skCls) and HasUFunc(equipActor, "GetComponentByClass") then
                mesh = equipActor:GetComponentByClass(skCls)
            end
        end)
    end
    return IsValidUObject(mesh) and mesh or nil, equipActor
end

local function ResolveActorSkeletalMesh(actor)
    if not IsValidUObject(actor) then return nil end
    local mesh = nil
    pcall(function() mesh = actor.Mesh end)
    if IsValidUObject(mesh) then return mesh end
    pcall(function()
        if HasUFunc(actor, "GetMesh") then mesh = actor:GetMesh() end
    end)
    if IsValidUObject(mesh) then return mesh end
    pcall(function()
        local skCls = StaticFindObject("/Script/Engine.SkeletalMeshComponent")
        if IsValidUObject(skCls) and HasUFunc(actor, "GetComponentByClass") then
            mesh = actor:GetComponentByClass(skCls)
        end
    end)
    return IsValidUObject(mesh) and mesh or nil
end

-- Map human-friendly slot aliases to Dragonwilds's live PlayerAnimationManager FNames.
local SLOT_ALIAS_PROPS = {
    rightarm = "RightArmSlotName",
    right_arm = "RightArmSlotName",
    rarm = "RightArmSlotName",
    leftarm = "LeftArmSlotName",
    left_arm = "LeftArmSlotName",
    larm = "LeftArmSlotName",
    spine = "SpineSlotName",
    upperbody = "SpineSlotName",
    upper_body = "SpineSlotName",
    torso = "SpineSlotName",
    legs = "LegSlotName",
    leg = "LegSlotName",
    lowerbody = "LegSlotName",
    lower_body = "LegSlotName",
    pelvis = "PelvisSlotName",
    head = "HeadSlotName",
    curves = "CurvesSlotName"
}

local function ResolveSlotFName(pawn, slotStr)
    if not slotStr or slotStr == "" or slotStr:lower() == "auto" then
        return nil
    end
    local low = slotStr:lower()
    if low == "fullbody" or low == "full_body" or low == "default" or low == "defaultslot" then
        return FName("DefaultSlot")
    end
    local propName = SLOT_ALIAS_PROPS[low]
    if propName then
        local mgr = ResolvePlayerAnimManager(pawn)
        if IsValidUObject(mgr) then
            local ok, fn = pcall(function() return mgr[propName] end)
            if ok and fn ~= nil then
                local okStr, sVal = pcall(function() return fn:ToString() end)
                if okStr and sVal and sVal ~= "" and sVal ~= "None" then
                    return fn
                end
            end
        end
    end
    return FName(slotStr)
end

-- Resolve animation asset (AnimMontage or AnimSequenceBase) with caching & path normalization.
local function ResolveAnimAsset(assetName, customSpells, safeGetNameFn)
    if not assetName or assetName == "" then return nil, false end
    local cleaned = NormalizeUeAssetPath(assetName)
    local obj = nil
    if customSpells and customSpells.FindObjectFast then
        obj = customSpells.FindObjectFast(cleaned)
    end
    if not IsValidUObject(obj) and cleaned:find("/", 1, true) then
        pcall(function() obj = StaticFindObject(cleaned) end)
        if not IsValidUObject(obj) and type(LoadAsset) == "function" then
            pcall(function() LoadAsset(cleaned) end)
            pcall(function() obj = StaticFindObject(cleaned) end)
        end
    end
    if not IsValidUObject(obj) and customSpells and customSpells.FindAssetByKeywordOnDemand then
        local kw = cleaned:match("%.([^%.]+)$") or cleaned:match("/([^/]+)$") or cleaned
        obj = customSpells.FindAssetByKeywordOnDemand("AnimMontage", kw, safeGetNameFn)
        if not IsValidUObject(obj) then
            obj = customSpells.FindAssetByKeywordOnDemand("AnimSequence", kw, safeGetNameFn)
        end
    end
    if not IsValidUObject(obj) then return nil, false end

    local isMontage = ObjectIsClass(obj, "/Script/Engine.AnimMontage")
    return obj, isMontage
end

-- Guard against UE5 AnimGraph crashes caused by playing an animation authored for a different USkeleton.
local function IsSkeletonCompatible(animInst, animObj, debugLogFn)
    if not IsValidUObject(animInst) or not IsValidUObject(animObj) then return false end
    local instSkel, animSkel = nil, nil
    pcall(function() instSkel = animInst.CurrentSkeleton end)
    pcall(function() animSkel = animObj.Skeleton end)
    if IsValidUObject(instSkel) and IsValidUObject(animSkel) then
        local instName = SafeObjName(instSkel)
        local animName = SafeObjName(animSkel)
        if instName ~= "" and animName ~= "" and instName ~= animName then
            if debugLogFn then
                debugLogFn(string.format("BLOCKED incompatible animation [%s]: animSkeleton=%s != meshSkeleton=%s",
                    SafeObjName(animObj), animName, instName))
            end
            return false
        end
    end
    return true
end

-- Play an AnimMontage or AnimSequence on any USkeletalMeshComponent with optional slot routing.
-- Returns: (playedMontageObj, animInst, durationSec, isDynamic)
local function PlayAnimOnMesh(mesh, pawnForSlots, animObj, isMontage, cueParams, playRate, leaderInst, leaderMont, debugLogFn)
    if not IsValidUObject(mesh) or not IsValidUObject(animObj) then
        return nil, nil, 0.0, false
    end
    local animInst = nil
    pcall(function() animInst = mesh:GetAnimInstance() end)

    local startTime = math.max(0.0, tonumber(cueParams.start) or 0.0)
    local blendIn   = math.max(0.0, tonumber(cueParams.blendIn) or 0.10)
    local blendOut  = math.max(0.0, tonumber(cueParams.blendOut) or 0.15)
    local loopCount = math.max(1, math.floor(tonumber(cueParams.loop) or 1))
    local stopAll   = (cueParams.stopAll == true)
    local slotStr   = cueParams.slot

    -- Fallback for skeletal meshes without an AnimBP (SingleNode prop/weapon meshes)
    if not IsValidUObject(animInst) then
        local seqToPlay = animObj
        if isMontage and HasUFunc(animObj, "GetFirstAnimReference") then
            pcall(function()
                local ref = animObj:GetFirstAnimReference()
                if IsValidUObject(ref) then seqToPlay = ref end
            end)
        end
        if HasUFunc(mesh, "PlayAnimation") then
            pcall(function() mesh:PlayAnimation(seqToPlay, loopCount > 1) end)
            pcall(function() mesh:SetPlayRate(playRate) end)
            local seqLen = 0.0
            pcall(function() seqLen = tonumber(seqToPlay.SequenceLength) or 0.0 end)
            return nil, nil, (seqLen > 0 and (seqLen / math.max(0.1, playRate)) or 0.5), false
        end
        return nil, nil, 0.0, false
    end

    -- Skeleton compatibility guard: never play an incompatible skeleton montage on an AnimInstance
    if not IsSkeletonCompatible(animInst, animObj, debugLogFn) then
        return nil, nil, 0.0, false
    end

    local playedMont = nil
    local durSec = 0.0
    local isDynamic = false

    local wantsExplicitSlot = (slotStr ~= nil and slotStr ~= "" and slotStr:lower() ~= "auto")
    if wantsExplicitSlot or not isMontage then
        local slotFName = ResolveSlotFName(pawnForSlots, slotStr) or FName("DefaultSlot")
        local seqAsset = animObj
        if isMontage and HasUFunc(animObj, "GetFirstAnimReference") then
            pcall(function()
                local firstRef = animObj:GetFirstAnimReference()
                if IsValidUObject(firstRef) then seqAsset = firstRef end
            end)
        end
        if IsValidUObject(seqAsset) and IsSkeletonCompatible(animInst, seqAsset, debugLogFn)
            and HasUFunc(animInst, "PlaySlotAnimationAsDynamicMontage") then
            local okDyn, resDyn = pcall(function()
                return animInst:PlaySlotAnimationAsDynamicMontage(
                    seqAsset, slotFName, blendIn, blendOut, playRate, loopCount, -1.0, startTime)
            end)
            if okDyn and IsValidUObject(resDyn) then
                playedMont = resDyn
                isDynamic = true
                local rawLen = 0.0
                pcall(function() rawLen = tonumber(seqAsset.SequenceLength) or tonumber(resDyn.SequenceLength) or 0.0 end)
                if rawLen > 0 then
                    durSec = math.max(0.05, ((rawLen * loopCount) - startTime) / math.max(0.1, playRate))
                end
            end
        end
    end

    -- Native Montage_Play path (preserves full authored AnimNotifies, sections, and slot tracks)
    -- NOTE: Never mutate animObj.RateScale here; pass playRate directly to Montage_Play so shared
    -- UAnimMontage assets are not modified while parallel AnimThread evaluates.
    if not IsValidUObject(playedMont) and isMontage and HasUFunc(animInst, "Montage_Play") then
        local okPlay, resLen = pcall(function()
            -- ReturnValueType = 1 (EMontagePlayReturnType::Duration -> exact scaled seconds)
            return animInst:Montage_Play(animObj, playRate, 1, startTime, stopAll)
        end)
        if okPlay then
            playedMont = animObj
            isDynamic = false
            durSec = tonumber(resLen) or 0.0
            if durSec <= 0.0 then
                pcall(function()
                    local sl = tonumber(animObj.SequenceLength) or 0.0
                    if sl > 0 then durSec = math.max(0.05, (sl - startTime) / math.max(0.1, playRate)) end
                end)
            end
            if cueParams.section and cueParams.section ~= "" and HasUFunc(animInst, "Montage_JumpToSection") then
                pcall(function() animInst:Montage_JumpToSection(FName(cueParams.section), animObj) end)
            end
        end
    end

    -- Optional montage leader sync (e.g. syncing weapon or upper-body layer to main montage)
    if IsValidUObject(playedMont) and IsValidUObject(leaderInst) and IsValidUObject(leaderMont)
        and HasUFunc(animInst, "MontageSync_Follow") then
        pcall(function() animInst:MontageSync_Follow(playedMont, leaderInst, leaderMont) end)
    end

    if durSec <= 0.0 then durSec = 0.65 / math.max(0.1, playRate) end
    return playedMont, animInst, durSec, isDynamic
end

local IsEnemyAliveAndTargetable

-- Gather nearby enemy ADominionAICharacter targets within radius (and optional forward cone).
local function FindNearbyEnemyTargets(pawn, centerLoc, centerRot, radius, coneDeg, maxTargets)
    local results = {}
    if not IsValidUObject(pawn) or not centerLoc then return results end
    local rad = tonumber(radius) or 400.0
    local rSq = rad * rad
    local cosHalfCone = nil
    local fwdX, fwdY = 1.0, 0.0
    if coneDeg and coneDeg > 0 and coneDeg < 360 then
        cosHalfCone = math.cos(math.rad(coneDeg * 0.5))
        local yawRad = math.rad(centerRot and centerRot.Yaw or 0.0)
        fwdX = math.cos(yawRad)
        fwdY = math.sin(yawRad)
    end

    local seen = {}
    local pawnLow = SafeObjName(pawn):lower()
    local candidates = {}
    pcall(function()
        local aiList = FindAllOf("DominionAICharacter")
        if aiList then
            for _, a in ipairs(aiList) do table.insert(candidates, a) end
        end
    end)

    for _, ai in ipairs(candidates) do
        if IsEnemyAliveAndTargetable(ai, pawn, pawnLow) then
            local fLow = SafeObjName(ai):lower()
            if not seen[fLow] then
                seen[fLow] = true
                local aLoc = nil
                pcall(function() aLoc = ai:K2_GetActorLocation() end)
                if aLoc then
                    local dx = (aLoc.X or 0) - centerLoc.X
                    local dy = (aLoc.Y or 0) - centerLoc.Y
                    local dz = (aLoc.Z or 0) - centerLoc.Z
                    local distSq = dx * dx + dy * dy + dz * dz
                    if distSq <= rSq then
                        local passCone = true
                        if cosHalfCone then
                            local hLen = math.sqrt(dx * dx + dy * dy)
                            if hLen > 1e-3 then
                                local dot = (dx / hLen) * fwdX + (dy / hLen) * fwdY
                                passCone = (dot >= cosHalfCone)
                            end
                        end
                        if passCone then
                            table.insert(results, { actor = ai, loc = MakeVec(aLoc.X, aLoc.Y, aLoc.Z), distSq = distSq })
                        end
                    end
                end
            end
        end
    end

    table.sort(results, function(a, b) return a.distSq < b.distSq end)
    if maxTargets and #results > maxTargets then
        while #results > maxTargets do table.remove(results) end
    end
    return results
end

-- Normalize Live View / catalog paths so any of these work seamlessly:
--   "/Game/.../NS_Windstep_Launch.NS_Windstep_Launch"
--   "NiagaraSystem /Game/.../NS_Windstep_Launch.NS_Windstep_Launch:Swirls_Ground_3"
--   "/Game/.../NS_Windstep_Launch" -> "/Game/.../NS_Windstep_Launch.NS_Windstep_Launch"
NormalizeUeAssetPath = function(raw)
    if not raw or raw == "" then return "" end
    local s = (tostring(raw):gsub("^%s*(.-)%s*$", "%1"))
    -- Strip optional leading UE class name (e.g. "NiagaraSystem /Game/...")
    local afterSpace = s:match("^[^/%s]+%s+(/.*)$")
    if afterSpace then s = afterSpace end
    if not s:find("/", 1, true) then
        -- Strip any ":SubObject" suffix even on short names like "NS_Foo.NS_Foo:Emitter"
        s = s:match("^([^:]+)") or s
        return s
    end
    -- Strip inner sub-object (e.g. ":Swirls_Ground_3" inside a NiagaraSystem)
    s = s:match("^([^:]+)") or s
    -- If package path omits ".AssetName", append it automatically
    local lastSeg = s:match("/([^/]+)$")
    if lastSeg and not lastSeg:find(".", 1, true) then
        s = s .. "." .. lastSeg
    end
    return s
end

local function IsNonZeroWorldLoc(v)
    if not v then return false end
    local x, y, z = tonumber(v.X) or 0.0, tonumber(v.Y) or 0.0, tonumber(v.Z) or 0.0
    return (math.abs(x) + math.abs(y) + math.abs(z)) > 5.0
end

-- Check that an actor is an actual alive, targetable AI enemy placed in the world
-- (rejects ore nodes, mining rocks, static meshes, players, and dead/pooled actors at 0,0,0).
IsEnemyAliveAndTargetable = function(ai, pawn, pawnLow)
    if not IsValidUObject(ai) or ai == pawn then return false end
    local fLow = SafeObjName(ai):lower()
    if fLow == "" or fLow == pawnLow or fLow:find("bp_playercharacter", 1, true) then
        return false
    end
    -- Reject non-enemy world actors (e.g. UEnemyTargetorComponent hovering over rocks/ore nodes/props)
    if HasUFunc(ai, "IsA") and GetCachedClass("/Script/Dominion.DominionAICharacter") then
        if not ObjectIsClass(ai, "/Script/Dominion.DominionAICharacter") then
            return false
        end
    else
        local looksLikeEnemy = fLow:find("dominionaicharacter", 1, true) ~= nil
            or fLow:find("bp_ai_", 1, true) ~= nil
            or HasUFunc(ai, "GetAiHealthComponent")
        if not looksLikeEnemy then
            return false
        end
    end
    local aLoc = nil
    pcall(function() aLoc = ai:K2_GetActorLocation() end)
    if not IsNonZeroWorldLoc(aLoc) then return false end
    local targetable = true
    pcall(function()
        if ai.bIsTargetable == false then targetable = false end
    end)
    if not targetable then return false end
    local alive = true
    pcall(function()
        local hComp = nil
        if HasUFunc(ai, "GetAiHealthComponent") then
            pcall(function() hComp = ai:GetAiHealthComponent() end)
        end
        if not IsValidUObject(hComp) then
            pcall(function() hComp = ai.HealthComponent end)
        end
        if not IsValidUObject(hComp) then
            pcall(function() hComp = ai.AiHealthComponent end)
        end
        if IsValidUObject(hComp) then
            local hp = nil
            if HasUFunc(hComp, "GetAuthoritativeHealth") then
                hp = tonumber(hComp:GetAuthoritativeHealth())
            elseif HasUFunc(hComp, "GetLocalHealth") then
                hp = tonumber(hComp:GetLocalHealth())
            end
            if hp ~= nil and hp <= 0.01 then alive = false end
        end
    end)
    return alive
end

-- Get player camera / aim origin & rotation for pointing direction checks.
local function GetPlayerAimOriginAndRot(pawn)
    local pLoc, pRot = GetActorLocAndRot(pawn)
    local camLoc = pLoc
    local camRot = pRot
    pcall(function()
        local pc = pawn.Controller
        if IsValidUObject(pc) and pc.PlayerCameraManager and pc.PlayerCameraManager:IsValid() then
            local cl = pc.PlayerCameraManager:GetCameraLocation()
            local cr = pc.PlayerCameraManager:GetCameraRotation()
            if cl then camLoc = MakeVec(cl.X, cl.Y, cl.Z) end
            if cr then camRot = MakeRot(cr.Pitch, cr.Yaw, cr.Roll) end
        elseif IsValidUObject(pc) and HasUFunc(pc, "GetControlRotation") then
            local cr = pc:GetControlRotation()
            if cr then camRot = MakeRot(cr.Pitch, cr.Yaw, cr.Roll) end
        end
    end)
    return pLoc, pRot, camLoc, camRot
end

-- Determine whether Dragonwilds's camera lock-on is CURRENTLY active.
-- NOTE: ULockOnTargetingComponent::LockOnCameraActor is lazily spawned on the 1st lock-on
-- and kept alive permanently after unlock or target death, so IsValid(LockOnCameraActor)
-- alone is NOT sufficient! We verify live widget visibility and/or active camera ViewTarget.
local function IsLockOnCurrentlyActive(pawn, lockComp, lockCamActor)
    if not IsValidUObject(lockComp) or not IsValidUObject(lockCamActor) then
        return false
    end

    -- 1. Check TargetingWidgetInstance (visible lock-on reticle icon while locked onto a live target)
    local widgetChecked = false
    local widgetVisible = false
    pcall(function()
        local w = lockComp.TargetingWidgetInstance
        if IsValidUObject(w) then
            local inVp = true
            local hasVp = false
            if HasUFunc(w, "IsInViewport") then
                hasVp = true
                inVp = (w:IsInViewport() == true)
            end
            if HasUFunc(w, "GetVisibility") then
                widgetChecked = true
                local vis = tonumber(w:GetVisibility())
                -- UE5 ESlateVisibility: 0=Visible, 1=Collapsed, 2=Hidden, 3=HitTestInvisible, 4=SelfHitTestInvisible
                widgetVisible = inVp and (vis == 0 or vis == 3 or vis == 4)
            elseif HasUFunc(w, "IsVisible") then
                widgetChecked = true
                widgetVisible = inVp and (w:IsVisible() == true)
            elseif hasVp then
                widgetChecked = true
                widgetVisible = inVp
            end
        end
    end)
    if widgetVisible then
        return true
    end

    -- 2. Check PlayerController / PlayerCameraManager active ViewTarget == lockCamActor
    local viewTargetChecked = false
    local viewTargetMatches = false
    pcall(function()
        local pc = pawn and pawn.Controller or nil
        if not IsValidUObject(pc) then
            pc = lockComp.PlayerController
        end
        if IsValidUObject(pc) then
            if HasUFunc(pc, "GetViewTarget") then
                local vt = pc:GetViewTarget()
                if IsValidUObject(vt) then
                    viewTargetChecked = true
                    if vt == lockCamActor then viewTargetMatches = true end
                end
            end
            local pcm = pc.PlayerCameraManager
            if IsValidUObject(pcm) then
                local curVt = pcm.ViewTarget and pcm.ViewTarget.Target or nil
                local pendVt = pcm.PendingViewTarget and pcm.PendingViewTarget.Target or nil
                if IsValidUObject(curVt) or IsValidUObject(pendVt) then
                    viewTargetChecked = true
                    if curVt == lockCamActor or pendVt == lockCamActor then
                        viewTargetMatches = true
                    end
                end
            end
        end
    end)
    if viewTargetMatches then
        return true
    end
    if widgetChecked or viewTargetChecked then
        -- At least one authoritative lock-on state signal was inspected and confirmed NOT locked on.
        return false
    end

    -- 3. Fallback: check camera component active flag if neither widget nor ViewTarget API is present
    local camActive = false
    pcall(function()
        local c = lockCamActor.Camera
        if IsValidUObject(c) and HasUFunc(c, "IsActive") then
            camActive = (c:IsActive() == true)
        end
    end)
    return camActive
end

-- Priority Tier 1: Detect the enemy the player is actively locked onto (via ULockOnTargetingComponent)
-- OR actively looking directly at with Dragonwilds's native reticle (UEnemyTargetorComponent).
local function ResolveLockedOnEnemy(pawn, maxLockDist)
    if not IsValidUObject(pawn) then return nil, nil end
    local pawnLow = SafeObjName(pawn):lower()
    local pLoc, pRot, camLoc, camRot = GetPlayerAimOriginAndRot(pawn)
    local lockRange = tonumber(maxLockDist) or 3000.0
    local lockRangeSq = lockRange * lockRange

    -- 1A. Check ULockOnTargetingComponent ONLY when lock-on is currently active
    local lockComp = nil
    pcall(function()
        if HasUFunc(pawn, "GetLockOnTargetingComponent") then
            lockComp = pawn:GetLockOnTargetingComponent()
        else
            lockComp = pawn.LockOnTargetingComponent
        end
    end)
    if IsValidUObject(lockComp) then
        local lockCamActor = nil
        pcall(function() lockCamActor = lockComp.LockOnCameraActor end)
        if IsValidUObject(lockCamActor) and IsLockOnCurrentlyActive(pawn, lockComp, lockCamActor) then
            -- Check if LockOnCameraActor is attached directly to the target actor
            local attActor = nil
            pcall(function() attActor = lockCamActor.AttachedToActor end)
            if IsEnemyAliveAndTargetable(attActor, pawn, pawnLow) then
                local aLoc = select(1, GetActorLocAndRot(attActor))
                return attActor, aLoc
            end
            -- Otherwise the active lock-on camera is aimed dead-center at the locked enemy: match tightest enemy along lock-on ray!
            local lcLoc, lcRot = camLoc, camRot
            pcall(function()
                local c = lockCamActor.Camera
                if IsValidUObject(c) and HasUFunc(c, "K2_GetComponentLocation") and HasUFunc(c, "K2_GetComponentRotation") then
                    local cl = c:K2_GetComponentLocation()
                    local cr = c:K2_GetComponentRotation()
                    if cl then lcLoc = MakeVec(cl.X, cl.Y, cl.Z) end
                    if cr then lcRot = MakeRot(cr.Pitch, cr.Yaw, cr.Roll) end
                end
            end)
            local lRange = lockRange
            pcall(function()
                local md = tonumber(lockComp.MaxTargetDistance)
                if md and md > 100.0 then lRange = md end
            end)
            local lRangeSq = lRange * lRange
            local pRad = math.rad(lcRot.Pitch or 0.0)
            local yRad = math.rad(lcRot.Yaw or 0.0)
            local fx = math.cos(pRad) * math.cos(yRad)
            local fy = math.cos(pRad) * math.sin(yRad)
            local fz = math.sin(pRad)
            local bestActor, bestLoc, bestDot = nil, nil, math.cos(math.rad(18.0))
            pcall(function()
                local aiList = FindAllOf("DominionAICharacter")
                if aiList then
                    for _, ai in ipairs(aiList) do
                        if IsEnemyAliveAndTargetable(ai, pawn, pawnLow) then
                            local aLoc = select(1, GetActorLocAndRot(ai))
                            local pdx, pdy, pdz = aLoc.X - pLoc.X, aLoc.Y - pLoc.Y, aLoc.Z - pLoc.Z
                            if (pdx * pdx + pdy * pdy + pdz * pdz) <= lRangeSq then
                                local cdx, cdy, cdz = aLoc.X - lcLoc.X, aLoc.Y - lcLoc.Y, (aLoc.Z + 60.0) - lcLoc.Z
                                local cLen = math.sqrt(cdx * cdx + cdy * cdy + cdz * cdz)
                                if cLen > 1e-3 then
                                    local dot = (cdx * fx + cdy * fy + cdz * fz) / cLen
                                    if dot > bestDot then
                                        bestDot = dot
                                        bestActor = ai
                                        bestLoc = aLoc
                                    end
                                end
                            end
                        end
                    end
                end
            end)
            if IsValidUObject(bestActor) and bestLoc then
                return bestActor, bestLoc
            end
        end
    end

    -- 1B. Check UEnemyTargetorComponent (native crosshair/reticle target when looking directly at an enemy)
    local targetor = nil
    pcall(function()
        if HasUFunc(pawn, "GetEnemyTargetor") then
            targetor = pawn:GetEnemyTargetor()
        else
            targetor = pawn.TargetorComponent
        end
    end)
    if IsValidUObject(targetor) then
        local curActor = nil
        pcall(function() curActor = targetor.CurrentWorldActor end)
        if not IsEnemyAliveAndTargetable(curActor, pawn, pawnLow) then
            pcall(function()
                local ct = targetor.CurrentTargetable
                if IsValidUObject(ct) and HasUFunc(ct, "GetOwner") then
                    curActor = ct:GetOwner()
                end
            end)
        end
        if IsEnemyAliveAndTargetable(curActor, pawn, pawnLow) then
            local aLoc = select(1, GetActorLocAndRot(curActor))
            local dx, dy, dz = aLoc.X - pLoc.X, aLoc.Y - pLoc.Y, aLoc.Z - pLoc.Z
            if (dx * dx + dy * dy + dz * dz) <= lockRangeSq then
                return curActor, aLoc
            end
        end
    end

    return nil, nil
end

-- Unified 3-Tier Enemy Targeting:
--   Tier 1: Actively locked-on enemy (ULockOnTargetingComponent / UEnemyTargetorComponent)
--   Tier 2: Closest alive enemy the player is pointing directly at within `maxRange` (default config.AutoTargetMaxDistance = 700)
--   Tier 3: Point `maxRange` ahead along the player's pointing direction (never strikes player's own feet)
local function ResolveAimTarget(pawn, maxRange, coneDeg, fallbackDist, config, entry, debugLogFn)
    local pLoc, pRot, camLoc, camRot = GetPlayerAimOriginAndRot(pawn)
    local cfgDist = tonumber(config and config.AutoTargetMaxDistance) or 700.0
    local cfgCone = tonumber(config and config.AutoTargetConeDeg) or 45.0
    local spellDist = tonumber(entry and entry.customDef and entry.customDef.autoTargetRange)
    local spellCone = tonumber(entry and entry.customDef and entry.customDef.autoTargetCone)

    local effMaxDist = tonumber(maxRange) or spellDist or cfgDist
    local effConeDeg = tonumber(coneDeg) or spellCone or cfgCone

    -- Tier 1: Locked-on enemy always takes priority!
    local lockedActor, lockedLoc = ResolveLockedOnEnemy(pawn, math.max(3000.0, effMaxDist))
    if IsValidUObject(lockedActor) and lockedLoc then
        if debugLogFn then
            local dx, dy, dz = lockedLoc.X - pLoc.X, lockedLoc.Y - pLoc.Y, lockedLoc.Z - pLoc.Z
            debugLogFn(string.format("AutoTarget [LOCKED]: %s dist=%.0fcm", SafeObjName(lockedActor), math.sqrt(dx*dx+dy*dy+dz*dz)))
        end
        return lockedLoc, pRot, lockedActor, "locked"
    end

    -- Tier 2: Closest alive enemy the player is pointing directly at within effMaxDist & effConeDeg
    local rSq = effMaxDist * effMaxDist
    local cosHalfCone = math.cos(math.rad(effConeDeg * 0.5))
    -- Use camera yaw (horizontal pointing direction) so aiming slightly up/down in 3rd person still hits enemies ahead cleanly
    local aimYawRad = math.rad(camRot.Yaw or pRot.Yaw or 0.0)
    local fwdX = math.cos(aimYawRad)
    local fwdY = math.sin(aimYawRad)

    local bestActor, bestLoc, bestDistSq = nil, nil, math.huge
    local pawnLow = SafeObjName(pawn):lower()
    pcall(function()
        local aiList = FindAllOf("DominionAICharacter")
        if aiList then
            for _, ai in ipairs(aiList) do
                if IsEnemyAliveAndTargetable(ai, pawn, pawnLow) then
                    local aLoc = select(1, GetActorLocAndRot(ai))
                    local dx = aLoc.X - pLoc.X
                    local dy = aLoc.Y - pLoc.Y
                    local dz = aLoc.Z - pLoc.Z
                    local distSq = dx * dx + dy * dy + dz * dz
                    if distSq > 64.0 and distSq <= rSq then
                        local hLen = math.sqrt(dx * dx + dy * dy)
                        if hLen > 1e-3 then
                            local dot = (dx / hLen) * fwdX + (dy / hLen) * fwdY
                            if dot >= cosHalfCone and distSq < bestDistSq then
                                bestDistSq = distSq
                                bestActor = ai
                                bestLoc = aLoc
                            end
                        end
                    end
                end
            end
        end
    end)

    if IsValidUObject(bestActor) and bestLoc then
        if debugLogFn then
            debugLogFn(string.format("AutoTarget [AIMED-CLOSEST]: %s dist=%.0fcm (max=%.0fcm, cone=%.0fdeg)",
                SafeObjName(bestActor), math.sqrt(bestDistSq), effMaxDist, effConeDeg))
        end
        return bestLoc, pRot, bestActor, "aimed"
    end

    -- Tier 3: Empty space ahead along pointing direction at effMaxDist
    local fDist = tonumber(fallbackDist) or effMaxDist
    local fallbackLoc = LocalOffsetToWorld(pLoc, MakeRot(0.0, camRot.Yaw or pRot.Yaw or 0.0, 0.0), MakeVec(fDist, 0.0, 0.0))
    if debugLogFn then
        debugLogFn(string.format("AutoTarget [EMPTY-FORWARD]: dist=%.0fcm (no locked/pointed enemy within %.0fcm)", fDist, effMaxDist))
    end
    return fallbackLoc, pRot, nil, "forward"
end

-- ESkill enum values from UHTHeaderDump/Dominion/Public/ESkill.h
local ESKILL_NAME_TO_BYTE = {
    agility = 1, artisan = 2, attack = 3, construction = 4, cooking = 5,
    defence = 6, defense = 6, herblore = 7, magic = 8, mining = 9,
    ranged = 10, runecrafting = 11, thieving = 12, woodcutting = 13,
    farming = 14, utility = 15, fishing = 16
}

-- Read the player's live skill level (e.g. Magic = 1..99) from USkillComponent.
local function GetPlayerSkillLevel(pawn, skillName)
    local sLow = tostring(skillName or "magic"):lower()
    local targetByte = ESKILL_NAME_TO_BYTE[sLow] or 8
    local skillComp = nil
    pcall(function()
        local pc = IsValidUObject(pawn) and pawn.Controller or nil
        if not IsValidUObject(pc) then
            pc = FindFirstOf("DominionPlayerController") or FindFirstOf("PlayerController")
        end
        if IsValidUObject(pc) then
            if HasUFunc(pc, "GetPlayerSkillComponent") then
                skillComp = pc:GetPlayerSkillComponent()
            end
            if not IsValidUObject(skillComp) then
                skillComp = pc.SkillComponent
            end
        end
        if not IsValidUObject(skillComp) and IsValidUObject(pawn) and HasUFunc(pawn, "GetSkillComponent") then
            skillComp = pawn:GetSkillComponent()
        end
        if not IsValidUObject(skillComp) then
            skillComp = FindFirstOf("SkillComponent")
        end
    end)
    if not IsValidUObject(skillComp) then return 1 end

    local skillData = CachedSkillDataByName[sLow]
    if not IsValidUObject(skillData) then
        skillData = nil
        pcall(function()
            local arr = skillComp.Skills
            if arr and type(arr) == "userdata" then
                arr:ForEach(function(_, wrap)
                    if skillData then return end
                    pcall(function()
                        local fs = wrap:get()
                        local sd = fs and fs.SkillData
                        if IsValidUObject(sd) then
                            local matched = false
                            if HasUFunc(sd, "GetSkillType") then
                                local okT, st = pcall(function() return sd:GetSkillType() end)
                                if okT and tonumber(st) == targetByte then matched = true end
                            end
                            if not matched and SafeObjName(sd):lower():find(sLow, 1, true) then
                                matched = true
                            end
                            if matched then
                                skillData = sd
                            end
                        end
                    end)
                end)
            end
        end)
        if IsValidUObject(skillData) then
            CachedSkillDataByName[sLow] = skillData
        end
    end

    if IsValidUObject(skillData) and HasUFunc(skillComp, "GetSkillLevel") then
        local okL, lvl = pcall(function() return tonumber(skillComp:GetSkillLevel(skillData)) end)
        if okL and lvl and lvl >= 1 then
            return math.floor(lvl)
        end
    end
    return 1
end

-- Native UE5 Line-of-Sight check via AController::LineOfSightTo (crash-proof primitive/pointer args only).
local function HasLineOfSightToActor(pawn, targetActor)
    if not IsValidUObject(pawn) or not IsValidUObject(targetActor) then return false end
    local pc = nil
    pcall(function() pc = pawn.Controller end)
    if not IsValidUObject(pc) then
        pcall(function() pc = FindFirstOf("DominionPlayerController") or FindFirstOf("PlayerController") end)
    end
    if not IsValidUObject(pc) or not HasUFunc(pc, "LineOfSightTo") then
        return true
    end
    local pLoc, _, camLoc = GetPlayerAimOriginAndRot(pawn)
    local eyeLoc = MakeVec(pLoc.X, pLoc.Y, pLoc.Z + 120.0)
    local visible = false
    pcall(function()
        visible = (pc:LineOfSightTo(targetActor, eyeLoc, false) == true)
    end)
    if not visible then
        pcall(function()
            visible = (pc:LineOfSightTo(targetActor, MakeVec(pLoc.X, pLoc.Y, pLoc.Z + 155.0), true) == true)
        end)
    end
    if not visible and IsNonZeroWorldLoc(camLoc) then
        pcall(function()
            visible = (pc:LineOfSightTo(targetActor, camLoc, false) == true)
        end)
    end
    return visible
end

-- Pick the next target for a ChainStrike barrage:
-- Prefers alive, LOS-visible enemies with the LOWEST hit count (other unhit enemies first),
-- wrapping back to already-hit / primary enemy when no other enemies remain!
local function PickNextChainStrikeTarget(pawn, csChain)
    local pawnLow = SafeObjName(pawn):lower()
    -- Strike #1 always targets primaryActor if alive
    if csChain.firedStrikes == 0 then
        if IsEnemyAliveAndTargetable(csChain.primaryActor, pawn, pawnLow) then
            if (not csChain.requireLos) or HasLineOfSightToActor(pawn, csChain.primaryActor) then
                return csChain.primaryActor, select(1, GetActorLocAndRot(csChain.primaryActor))
            end
        end
    end

    -- Refresh anchor location around primary target if still alive, else last struck position
    local anchorLoc = csChain.lastAnchorLoc
    if IsEnemyAliveAndTargetable(csChain.primaryActor, pawn, pawnLow) then
        anchorLoc = select(1, GetActorLocAndRot(csChain.primaryActor))
    end
    if not IsNonZeroWorldLoc(anchorLoc) then return nil, nil end

    local nearby = FindNearbyEnemyTargets(pawn, anchorLoc, MakeRot(0, 0, 0), csChain.chainRadius, nil, nil)
    local candidates = {}
    local seen = {}

    local function considerActor(actor, loc)
        if not IsEnemyAliveAndTargetable(actor, pawn, pawnLow) then return end
        local key = SafeObjName(actor):lower()
        if seen[key] then return end
        if csChain.requireLos and not HasLineOfSightToActor(pawn, actor) then return end
        seen[key] = true
        local dx = loc.X - anchorLoc.X
        local dy = loc.Y - anchorLoc.Y
        local dz = loc.Z - anchorLoc.Z
        local isPrimary = (actor == csChain.primaryActor)
        table.insert(candidates, {
            actor = actor,
            key = key,
            loc = loc,
            hits = csChain.hitCounts[key] or 0,
            distSq = dx * dx + dy * dy + dz * dz,
            isPrimary = isPrimary
        })
    end

    if IsEnemyAliveAndTargetable(csChain.primaryActor, pawn, pawnLow) then
        considerActor(csChain.primaryActor, select(1, GetActorLocAndRot(csChain.primaryActor)))
    end
    for _, e in ipairs(nearby) do
        considerActor(e.actor, e.loc)
    end

    if #candidates == 0 then return nil, nil end

    if csChain.preferUnique then
        table.sort(candidates, function(a, b)
            if a.hits ~= b.hits then return a.hits < b.hits end
            if a.hits > 0 and a.isPrimary ~= b.isPrimary then return a.isPrimary end
            return a.distSq < b.distSq
        end)
    else
        table.sort(candidates, function(a, b)
            if a.isPrimary ~= b.isPrimary then return a.isPrimary end
            return a.distSq < b.distSq
        end)
    end

    return candidates[1].actor, candidates[1].loc
end

-- Execute one individual thunderbolt strike from a ChainStrike cue.
local function FireSingleChainStrike(tlInst, cue, cueState, pawn, customSpells, debugLogFn, now)
    local ch = cueState.chainState
    if not ch then return false end
    local targetActor, targetLoc = PickNextChainStrikeTarget(pawn, ch)
    if not IsValidUObject(targetActor) or not IsNonZeroWorldLoc(targetLoc) then
        return false
    end

    local tKey = SafeObjName(targetActor):lower()
    ch.hitCounts[tKey] = (ch.hitCounts[tKey] or 0) + 1
    ch.firedStrikes = ch.firedStrikes + 1
    ch.lastAnchorLoc = targetLoc

    local p = ch.params or {}
    local minD = tonumber(p.dmgMin) or 65
    local maxD = tonumber(p.dmgMax) or minD
    local lo, hi = math.floor(minD), math.max(math.floor(minD), math.floor(maxD))
    pcall(function()
        local okPS, PS = pcall(require, "progression_scaling")
        if okPS and PS and PS.ComputeDamageMultiplier and PS.ScaleDamageRange then
            local mult = PS.ComputeDamageMultiplier(tlInst.config, nil, pawn, tlInst.entry, p)
            lo, hi = PS.ScaleDamageRange(minD, maxD, mult)
        end
    end)
    local rolledDmg = (hi > lo) and math.random(lo, hi) or lo

    -- Build lightweight effective entry for ApplyDominionBlueprintDamage
    local effDef = {}
    if tlInst.entry and tlInst.entry.customDef then
        for k, v in pairs(tlInst.entry.customDef) do effDef[k] = v end
    end
    if p.damageClass and p.damageClass ~= "" then effDef.damageClass = p.damageClass:lower() end
    if p.force ~= nil then effDef.damageForce = tonumber(p.force) end
    if p.ge and p.ge ~= "" then effDef.damageGE = p.ge end
    local effEntry = { shortName = tlInst.spellName, customDef = effDef }

    local instLoc = select(1, GetActorLocAndRot(pawn))
    local applied, trace = false, ""
    if customSpells and customSpells.ApplyDominionBlueprintDamage then
        applied, trace = customSpells.ApplyDominionBlueprintDamage(targetActor, pawn, rolledDmg, targetLoc, instLoc, effEntry, debugLogFn)
    end

    -- Spawn scaled lightning / strike VFX directly on the struck enemy
    if IsValidUObject(ch.vfxObj) then
        UncapNiagaraAssetAndComponent(ch.vfxObj, nil)
        local nsLib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
        if IsValidUObject(nsLib) and HasUFunc(nsLib, "SpawnSystemAtLocation") then
            local strikeLoc = LocalOffsetToWorld(targetLoc, MakeRot(0, 0, 0), p.offset)
            local okV, comp = pcall(function()
                return nsLib:SpawnSystemAtLocation(pawn, ch.vfxObj, strikeLoc, MakeRot(0, math.random(0, 359), 0), ch.vfxScale, true, true, 0, false)
            end)
            if okV and IsValidUObject(comp) then
                UncapNiagaraAssetAndComponent(ch.vfxObj, comp)
                ApplyNiagaraScaleAndParams(comp, ch.vfxScale, p, false)
                cueState.vfxComps = cueState.vfxComps or {}
                table.insert(cueState.vfxComps, comp)
                table.insert(ch.spawnedVfx, { comp = comp, expireAt = now + ch.vfxDur })
            end
        end
    end

    -- Play thunder / strike SFX at the struck enemy with slight pitch jitter
    if IsValidUObject(ch.sfxObj) then
        local gpStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        if IsValidUObject(gpStatics) then
            local vol = tonumber(p.vol) or 0.95
            local basePitch = tonumber(p.pitch) or 1.0
            local pitch = basePitch * (0.94 + math.random() * 0.14)
            if HasUFunc(gpStatics, "SpawnSoundAtLocation") then
                pcall(function() gpStatics:SpawnSoundAtLocation(pawn, ch.sfxObj, targetLoc, MakeRot(0, 0, 0), vol, pitch, 0.0, nil, nil, true) end)
            elseif HasUFunc(gpStatics, "PlaySoundAtLocation") then
                pcall(function() gpStatics:PlaySoundAtLocation(pawn, ch.sfxObj, targetLoc) end)
            end
        end
    end

    if debugLogFn then
        debugLogFn(string.format("Timeline [%s] ChainStrike %d/%d -> %s (hits=%d, dmg=%d, applied=%s)",
            tlInst.spellName, ch.firedStrikes, ch.totalStrikes, SafeObjName(targetActor), ch.hitCounts[tKey], rolledDmg, tostring(applied)))
    end
    return true
end

-- Inspect a live ADominionSpellActor's SpellInstance.Graph for:
--   1. Exact USpellModule_CollisionRuntime CollisionPoint (where the spell ACTUALLY hit!)
--   2. Active USpellModule_SpawnActorRuntime.Actor (the actual flying Air Bolt / projectile actor!)
local function InspectSpellActorCollisionAndProjectile(spellActor)
    if not IsValidUObject(spellActor) then return nil, nil end
    local hitPoint = nil
    local spawnedProj = nil

    local function scanModuleArray(arr)
        if not arr or type(arr) ~= "userdata" then return end
        pcall(function()
            arr:ForEach(function(_, elemWrapper)
                local mod = nil
                pcall(function() mod = elemWrapper:get() end)
                if not IsValidUObject(mod) then return end
                local mName = SafeObjName(mod):lower()
                -- Check USpellModule_CollisionRuntime::CollisionList for exact collision point
                if not hitPoint and mName:find("collisionruntime", 1, true) then
                    pcall(function()
                        local cList = mod.CollisionList
                        if cList and type(cList) == "userdata" then
                            cList:ForEach(function(_, cWrap)
                                if hitPoint then return end
                                pcall(function()
                                    local info = cWrap:get()
                                    if info then
                                        local ev = info.CollisionEvent
                                        local pt = ev and ev.CollisionPoint
                                        if pt then
                                            local px, py, pz = tonumber(pt.X) or 0, tonumber(pt.Y) or 0, tonumber(pt.Z) or 0
                                            if (info.bCollisionOccurred == true) or (math.abs(px) + math.abs(py) + math.abs(pz) > 1.0) then
                                                hitPoint = MakeVec(px, py, pz)
                                            end
                                        end
                                    end
                                end)
                            end)
                        end
                    end)
                end
                -- Check USpellModule_SpawnActorRuntime::Actor for the live flying projectile actor
                if not spawnedProj and mName:find("spawnactor", 1, true) then
                    pcall(function()
                        local a = mod.Actor
                        if IsValidUObject(a) then spawnedProj = a end
                    end)
                end
            end)
        end)
    end

    pcall(function()
        local inst = spellActor.SpellInstance
        if IsValidUObject(inst) and inst.Graph then
            scanModuleArray(inst.Graph.ReplicatedRuntimeModules)
            scanModuleArray(inst.Graph.NonReplicatedRuntimeModules)
        end
    end)

    return hitPoint, spawnedProj
end

-- Bypass UE5 Niagara scalability/instance-count culling so rapid-fire & overlapping VFX
-- (e.g. multiple StormOfArmadyl gusts or SaradominStrike bolts) always render anywhere on the map.
UncapNiagaraAssetAndComponent = function(vfxObj, comp)
    if IsValidUObject(vfxObj) then
        local key = SafeObjName(vfxObj)
        if key ~= "" and not UncappedNiagaraSystems[key] then
            UncappedNiagaraSystems[key] = true
            pcall(function() vfxObj.bOverrideAllowCullingForLocalPlayers = true end)
            pcall(function() vfxObj.bAllowCullingForLocalPlayersOverride = false end)
            pcall(function()
                local et = vfxObj.EffectType
                if IsValidUObject(et) then
                    pcall(function() et.bAllowCullingForLocalPlayers = false end)
                    pcall(function()
                        local sArr = et.SystemScalabilitySettings and et.SystemScalabilitySettings.Settings
                        if sArr and type(sArr) == "userdata" then
                            sArr:ForEach(function(_, wrap)
                                pcall(function()
                                    local s = wrap:get()
                                    if s then
                                        s.bCullMaxInstanceCount = false
                                        s.bCullPerSystemMaxInstanceCount = false
                                    end
                                end)
                            end)
                        end
                    end)
                end
            end)
        end
    end
    if IsValidUObject(comp) then
        pcall(function() comp.bAllowScalability = false end)
        pcall(function()
            if HasUFunc(comp, "SetForceLocalPlayerEffect") then
                comp:SetForceLocalPlayerEffect(true)
            end
        end)
        pcall(function()
            if HasUFunc(comp, "SetForceSolo") then
                comp:SetForceSolo(true)
            end
        end)
    end
end

-- Apply transform scale AND common/explicit Niagara User Parameters so both local-space
-- and world-space Niagara VFX (such as sky lightning bolts) scale cleanly.
ApplyNiagaraScaleAndParams = function(comp, scale, cueParams, isAttached)
    if not IsValidUObject(comp) then return end
    local sx = scale and scale.X or 1.0
    local sy = scale and scale.Y or 1.0
    local sz = scale and scale.Z or 1.0
    local avgScale = (sx + sy + sz) / 3.0

    if sx ~= 1.0 or sy ~= 1.0 or sz ~= 1.0 then
        pcall(function()
            if isAttached and HasUFunc(comp, "SetRelativeScale3D") then
                comp:SetRelativeScale3D(scale)
            elseif HasUFunc(comp, "SetWorldScale3D") then
                comp:SetWorldScale3D(scale)
            elseif HasUFunc(comp, "SetRelativeScale3D") then
                comp:SetRelativeScale3D(scale)
            end
        end)
        -- Also drive common Niagara User scale parameters (safe no-op if the asset doesn't expose them)
        local scaleParams = { "Scale", "User.Scale", "Size", "Radius", "Width", "BoltScale", "BoltWidth", "BeamWidth", "ScaleMultiplier" }
        for _, pName in ipairs(scaleParams) do
            pcall(function()
                if HasUFunc(comp, "SetVariableFloat") then
                    comp:SetVariableFloat(FName(pName), avgScale)
                end
            end)
        end
        pcall(function()
            if HasUFunc(comp, "SetVariableVec3") then
                comp:SetVariableVec3(FName("Scale"), scale)
                comp:SetVariableVec3(FName("User.Scale"), scale)
            end
        end)
    end

    if cueParams and cueParams.vfxFloats then
        for _, pf in ipairs(cueParams.vfxFloats) do
            pcall(function()
                if HasUFunc(comp, "SetVariableFloat") then
                    comp:SetVariableFloat(FName(pf.name), pf.value)
                end
            end)
        end
    end
    if cueParams and cueParams.vfxVecs then
        for _, pv in ipairs(cueParams.vfxVecs) do
            pcall(function()
                if HasUFunc(comp, "SetVariableVec3") then
                    comp:SetVariableVec3(FName(pv.name), pv.value)
                end
            end)
        end
    end
end

-- Resolve spawn/effect transforms supporting target modes + spatial patterns (point/ring/line/arc).
local function ComputeTargetTransforms(tlInst, pawn, cueParams, debugLogFn)
    local targetStr = (cueParams.target or "player"):lower()
    local baseLoc, baseRot = GetActorLocAndRot(pawn)
    local attachComp = nil

    if targetStr == "impact" then
        if tlInst.impactActor and IsValidUObject(tlInst.impactActor) then
            -- Track the struck/locked enemy's live location if still valid
            local fresh = select(1, GetActorLocAndRot(tlInst.impactActor))
            baseLoc = fresh
        elseif tlInst.impactLoc then
            baseLoc = tlInst.impactLoc
        else
            local aimLoc, aimRot, aimActor = ResolveAimTarget(pawn, cueParams.range, cueParams.cone, nil, tlInst.config, tlInst.entry, debugLogFn)
            baseLoc, baseRot = aimLoc, aimRot
            if IsValidUObject(aimActor) then tlInst.impactActor = aimActor end
            tlInst.impactLoc = aimLoc
        end
    elseif targetStr == "lock" or targetStr == "locked" or targetStr == "lockon" or targetStr == "auto_target"
        or targetStr == "aim" or targetStr == "crosshair" or targetStr == "look" or targetStr == "aimed_enemy" then
        -- Reuse a locked/aimed enemy latched earlier in this same timeline cast if still alive, else resolve fresh!
        local pawnLow = SafeObjName(pawn):lower()
        if IsEnemyAliveAndTargetable(tlInst.lockedTargetActor, pawn, pawnLow) then
            baseLoc = select(1, GetActorLocAndRot(tlInst.lockedTargetActor))
        else
            local aimLoc, aimRot, aimActor = ResolveAimTarget(pawn, cueParams.range, cueParams.cone, nil, tlInst.config, tlInst.entry, debugLogFn)
            baseLoc, baseRot = aimLoc, aimRot
            if IsValidUObject(aimActor) then tlInst.lockedTargetActor = aimActor end
        end
    elseif targetStr == "hit_targets" or targetStr == "hit_area" then
        if tlInst.lastHitTargets and #tlInst.lastHitTargets > 0 then
            local list = {}
            for _, h in ipairs(tlInst.lastHitTargets) do
                local hLoc = h.loc
                if IsValidUObject(h.actor) then
                    pcall(function()
                        local fresh = h.actor:K2_GetActorLocation()
                        if fresh then hLoc = MakeVec(fresh.X, fresh.Y, fresh.Z) end
                    end)
                end
                if hLoc then
                    local loc = LocalOffsetToWorld(hLoc, baseRot, cueParams.offset)
                    local rot = AddRot(baseRot, cueParams.rot)
                    table.insert(list, { loc = loc, rot = rot, actor = h.actor, comp = ResolveActorSkeletalMesh(h.actor) })
                end
            end
            if #list > 0 then return list, nil end
        end
        if tlInst.lastHitCenter then
            baseLoc = tlInst.lastHitCenter
        elseif tlInst.impactLoc then
            baseLoc = tlInst.impactLoc
        else
            local aimLoc, aimRot = ResolveAimTarget(pawn, cueParams.range, cueParams.cone, nil, tlInst.config, tlInst.entry, debugLogFn)
            baseLoc, baseRot = aimLoc, aimRot
        end
    elseif targetStr:find("^forward:") then
        local dist = tonumber(targetStr:match("^forward:([%-%d%.]+)$")) or 250.0
        baseLoc = LocalOffsetToWorld(baseLoc, baseRot, MakeVec(dist, 0.0, 0.0))
    elseif targetStr == "weapon_right" or targetStr == "weapon" then
        local wMesh, wActor = ResolveHeldEquipmentMesh(pawn, "weapon_right")
        if IsValidUObject(wMesh) then
            attachComp = wMesh
            baseLoc, baseRot = GetActorLocAndRot(wActor)
        end
    elseif targetStr == "weapon_left" then
        local wMesh, wActor = ResolveHeldEquipmentMesh(pawn, "weapon_left")
        if IsValidUObject(wMesh) then
            attachComp = wMesh
            baseLoc, baseRot = GetActorLocAndRot(wActor)
        end
    elseif targetStr:find("^actor:") then
        local aid = targetStr:sub(7)
        local spawned = tlInst.actorsById and tlInst.actorsById[aid]
        if IsValidUObject(spawned) then
            baseLoc, baseRot = GetActorLocAndRot(spawned)
            attachComp = ResolveActorSkeletalMesh(spawned)
            if not IsValidUObject(attachComp) then
                pcall(function() attachComp = spawned.RootComponent end)
            end
        end
    elseif targetStr == "targets" or targetStr == "nearest_enemy" then
        local maxT = (targetStr == "nearest_enemy") and 1 or cueParams.maxTargets
        local enemies = FindNearbyEnemyTargets(pawn, baseLoc, baseRot, cueParams.radius or cueParams.range or 1500.0, cueParams.cone, maxT)
        local list = {}
        for _, e in ipairs(enemies) do
            local loc = LocalOffsetToWorld(e.loc, baseRot, cueParams.offset)
            local rot = AddRot(baseRot, cueParams.rot)
            table.insert(list, { loc = loc, rot = rot, actor = e.actor, comp = ResolveActorSkeletalMesh(e.actor) })
        end
        return list, nil
    elseif targetStr == "player" then
        pcall(function() attachComp = pawn.Mesh end)
    end

    local anchorLoc = LocalOffsetToWorld(baseLoc, baseRot, cueParams.offset)
    local anchorRot = AddRot(baseRot, cueParams.rot)
    local pat = cueParams.pattern

    if not pat or pat.kind == "point" or (pat.count or 1) <= 1 then
        return { { loc = anchorLoc, rot = anchorRot, comp = attachComp } }, attachComp
    end

    local transforms = {}
    if pat.kind == "ring" or pat.kind == "arc" then
        local n = math.max(1, pat.count or 6)
        local r = pat.radius or 200.0
        local arcDeg = pat.arcDeg or 360.0
        local startDeg = (pat.kind == "arc") and (-arcDeg * 0.5) or 0.0
        local stepDeg = (pat.kind == "arc" and n > 1) and (arcDeg / (n - 1)) or (360.0 / n)
        for i = 0, n - 1 do
            local deg = startDeg + i * stepDeg
            local rad = math.rad(deg)
            local localPos = MakeVec(math.cos(rad) * r, math.sin(rad) * r, 0.0)
            local wLoc = LocalOffsetToWorld(anchorLoc, anchorRot, localPos)
            local wRot = MakeRot(anchorRot.Pitch, anchorRot.Yaw + deg, anchorRot.Roll)
            table.insert(transforms, { loc = wLoc, rot = wRot })
        end
    elseif pat.kind == "line" then
        local n = math.max(1, pat.count or 4)
        local step = pat.step or 150.0
        for i = 0, n - 1 do
            local wLoc = LocalOffsetToWorld(anchorLoc, anchorRot, MakeVec(i * step, 0.0, 0.0))
            table.insert(transforms, { loc = wLoc, rot = anchorRot })
        end
    end
    return transforms, nil
end

-- Execute a single cue on the Game Thread and populate cueState handles for duration/cleanup.
local function ExecuteCueOnGameThread(tlInst, cue, cueState, config, state, pawn, combatMagic, customSpells, safeGetNameFn, debugLogFn)
    local p = cue.params or {}
    local cType = cue.type

    local stageSpeed = tlInst.stageSpeed or 1.0
    local scaleSpeed = (tlInst.timeline.scaleWithSpeed ~= false) and (p.scaleWithSpeed ~= false)

    if cType == "anim" then
        local animObj, isMontage = ResolveAnimAsset(cue.asset, customSpells, safeGetNameFn)
        if not IsValidUObject(animObj) then
            LogMismatchOnce(tlInst.spellName .. ":" .. tostring(cue.index) .. ":missing:" .. tostring(cue.asset),
                string.format("CustomSpell [%s] Cue #%d (anim): asset '%s' not found; skipping safely.", tlInst.spellName, cue.index, tostring(cue.asset)))
            cueState.expectedDur = 0.0
            return
        end
        if not ValidateCueAssetType(animObj, "anim", tlInst.spellName, cue.index, cue.asset) then
            cueState.expectedDur = 0.0
            return
        end
        isMontage = ObjectIsClass(animObj, "/Script/Engine.AnimMontage")

        local baseRate = tonumber(p.rate) or 1.0
        local effectiveRate = scaleSpeed and (baseRate * stageSpeed) or baseRate
        local assetLow = tostring(cue.asset or ""):lower()
        local isHeavyWeaponMont = assetLow:find("greatsword", 1, true) ~= nil or assetLow:find("godsword", 1, true) ~= nil or assetLow:find("special", 1, true) ~= nil
        if isHeavyWeaponMont and p.unsafeRate ~= "true" then
            -- Keep Greatsword/Special AnimNotifyState windows safe from notify-skipping
            effectiveRate = math.min(effectiveRate, 1.35)
        elseif tlInst.entry and (tlInst.entry.isClamped or tlInst.entry.isSmash) and (config and config.EnableFinisherSpeedClamp ~= false) then
            local clampMax = math.max(1.0, tonumber(config.MaxFinisherSpeedClamp) or 5.0)
            effectiveRate = math.min(effectiveRate, clampMax)
        else
            effectiveRate = math.min(effectiveRate, 3.0)
        end
        effectiveRate = math.max(0.20, effectiveRate)

        -- Resolve optional leader montage for MontageSync_Follow (re-fetching fresh AnimInstance)
        local leaderInst, leaderMont = nil, nil
        if cue.syncToIndex and tlInst.cueStates[cue.syncToIndex] then
            local lState = tlInst.cueStates[cue.syncToIndex]
            if not lState.isDynamicMontage and IsValidUObject(lState.montageObj) then
                pcall(function()
                    local pm = pawn.Mesh
                    if IsValidUObject(pm) then leaderInst = pm:GetAnimInstance() end
                end)
                leaderMont = lState.montageObj
            end
        end

        local targetStr = (p.target or "player"):lower()
        if targetStr == "player" then
            local mesh = nil
            pcall(function() mesh = pawn.Mesh end)
            local mObj, _, durSec, isDyn = PlayAnimOnMesh(mesh, pawn, animObj, isMontage, p, effectiveRate, leaderInst, leaderMont, debugLogFn)
            cueState.montageObj = (not isDyn) and mObj or nil
            cueState.isDynamicMontage = isDyn
            cueState.targetKind = "player"
            cueState.expectedDur = (p.dur ~= nil) and (scaleSpeed and (p.dur / stageSpeed) or p.dur) or durSec
            if state and not isDyn and IsValidUObject(mObj) then
                state.LastForcedMontageObj = mObj
            end
            if debugLogFn then
                debugLogFn(string.format("Timeline [%s] Anim #%d (%s, slot=%s, rate=%.2fx, dur=%.2fs, dyn=%s)",
                    tlInst.spellName, cue.index, tostring(cue.asset), tostring(p.slot or "auto"), effectiveRate, cueState.expectedDur, tostring(isDyn)))
            end

        elseif targetStr == "weapon_right" or targetStr == "weapon_left" or targetStr == "weapon" then
            local wMesh = ResolveHeldEquipmentMesh(pawn, targetStr)
            if IsValidUObject(wMesh) then
                local mObj, _, durSec, isDyn = PlayAnimOnMesh(wMesh, nil, animObj, isMontage, p, effectiveRate, leaderInst, leaderMont, debugLogFn)
                cueState.montageObj = (not isDyn) and mObj or nil
                cueState.isDynamicMontage = isDyn
                cueState.targetKind = targetStr
                cueState.expectedDur = (p.dur ~= nil) and (scaleSpeed and (p.dur / stageSpeed) or p.dur) or durSec
                if debugLogFn then
                    debugLogFn(string.format("Timeline [%s] WeaponAnim #%d (%s on %s, rate=%.2fx)",
                        tlInst.spellName, cue.index, tostring(cue.asset), targetStr, effectiveRate))
                end
            else
                cueState.expectedDur = 0.0
            end

        elseif targetStr:find("^actor:") then
            local aid = targetStr:sub(7)
            local targetActor = tlInst.actorsById and tlInst.actorsById[aid]
            local aMesh = ResolveActorSkeletalMesh(targetActor)
            if IsValidUObject(aMesh) then
                local mObj, _, durSec, isDyn = PlayAnimOnMesh(aMesh, nil, animObj, isMontage, p, effectiveRate, leaderInst, leaderMont, debugLogFn)
                cueState.montageObj = (not isDyn) and mObj or nil
                cueState.isDynamicMontage = isDyn
                cueState.targetKind = targetStr
                cueState.expectedDur = (p.dur ~= nil) and (scaleSpeed and (p.dur / stageSpeed) or p.dur) or durSec
                if debugLogFn then
                    debugLogFn(string.format("Timeline [%s] ActorAnim #%d (%s on actor:%s)",
                        tlInst.spellName, cue.index, tostring(cue.asset), aid))
                end
            else
                cueState.expectedDur = 0.0
            end

        elseif targetStr == "targets" or targetStr == "nearest_enemy" then
            local pLoc, pRot = GetActorLocAndRot(pawn)
            local centerLoc = LocalOffsetToWorld(pLoc, pRot, p.offset)
            local maxT = (targetStr == "nearest_enemy") and 1 or p.maxTargets
            local enemies = FindNearbyEnemyTargets(pawn, centerLoc, pRot, p.radius or 450.0, p.cone, maxT)
            local playedCount = 0
            local maxDur = 0.0
            for _, e in ipairs(enemies) do
                local eMesh = ResolveActorSkeletalMesh(e.actor)
                if IsValidUObject(eMesh) then
                    local _, _, durSec = PlayAnimOnMesh(eMesh, nil, animObj, isMontage, p, effectiveRate, nil, nil, debugLogFn)
                    playedCount = playedCount + 1
                    if durSec > maxDur then maxDur = durSec end
                end
            end
            cueState.expectedDur = (p.dur ~= nil) and (scaleSpeed and (p.dur / stageSpeed) or p.dur) or maxDur
            if debugLogFn then
                debugLogFn(string.format("Timeline [%s] TargetAnim #%d (%s on %d enemies)",
                    tlInst.spellName, cue.index, tostring(cue.asset), playedCount))
            end
        end

    elseif cType == "vfx" then
        local vfxObj = nil
        if cue.asset and cue.asset ~= "" then
            local cleaned = NormalizeUeAssetPath(cue.asset)
            local lookupPath = (state and state.VfxPathLookup and state.VfxPathLookup[cleaned:lower()]) or cleaned
            lookupPath = NormalizeUeAssetPath(lookupPath)
            if customSpells and customSpells.FindObjectFast then
                vfxObj = customSpells.FindObjectFast(lookupPath)
            end
            if not IsValidUObject(vfxObj) and lookupPath:find("/", 1, true) then
                pcall(function() vfxObj = StaticFindObject(lookupPath) end)
                if not IsValidUObject(vfxObj) and type(LoadAsset) == "function" then
                    pcall(function() LoadAsset(lookupPath) end)
                    pcall(function() vfxObj = StaticFindObject(lookupPath) end)
                end
            end
            if not IsValidUObject(vfxObj) and customSpells and customSpells.FindAssetByKeywordOnDemand then
                local kwSearch = cleaned:match("%.([^%.]+)$") or cleaned:match("/([^/]+)$") or cleaned
                vfxObj = customSpells.FindAssetByKeywordOnDemand("NiagaraSystem", kwSearch, safeGetNameFn)
            end
        end
        if not IsValidUObject(vfxObj) then
            LogMismatchOnce(tlInst.spellName .. ":" .. tostring(cue.index) .. ":missing:" .. tostring(cue.asset),
                string.format("CustomSpell [%s] Cue #%d (vfx): NiagaraSystem '%s' not found; skipping safely.", tlInst.spellName, cue.index, tostring(cue.asset)))
            cueState.expectedDur = 0.0
            return
        end
        if not ValidateCueAssetType(vfxObj, "vfx", tlInst.spellName, cue.index, cue.asset) then
            cueState.expectedDur = 0.0
            return
        end

        local nsLib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
        if not IsValidUObject(nsLib) then return end
        UncapNiagaraAssetAndComponent(vfxObj, nil)

        local scale = p.scale or MakeVec(1.0, 1.0, 1.0)
        local transforms, defaultAttachComp = ComputeTargetTransforms(tlInst, pawn, p, debugLogFn)
        local wantsAttach = (p.attach ~= nil and p.attach:lower() ~= "world") or (p.socket ~= nil and p.socket ~= "")
        cueState.vfxComps = {}

        if wantsAttach and #transforms == 1 then
            local attachComp = defaultAttachComp
            local attLow = (p.attach or p.target or "player"):lower()
            if attLow == "weapon_right" or attLow == "weapon" then
                attachComp = ResolveHeldEquipmentMesh(pawn, "weapon_right") or attachComp
            elseif attLow == "weapon_left" then
                attachComp = ResolveHeldEquipmentMesh(pawn, "weapon_left") or attachComp
            elseif attLow:find("^actor:") then
                local a = tlInst.actorsById and tlInst.actorsById[attLow:sub(7)]
                attachComp = ResolveActorSkeletalMesh(a) or (IsValidUObject(a) and a.RootComponent) or attachComp
            elseif attLow == "player" then
                pcall(function() attachComp = pawn.Mesh end)
            end
            if IsValidUObject(attachComp) and HasUFunc(nsLib, "SpawnSystemAttached") then
                local sockName = FName(p.socket or "None")
                local relLoc = p.offset or MakeVec(0, 0, 0)
                local relRot = p.rot or MakeRot(0, 0, 0)
                local okV, comp = pcall(function()
                    return nsLib:SpawnSystemAttached(vfxObj, attachComp, sockName, relLoc, relRot, 0, true, true, 0, false)
                end)
                if okV and IsValidUObject(comp) then
                    UncapNiagaraAssetAndComponent(vfxObj, comp)
                    ApplyNiagaraScaleAndParams(comp, scale, p, true)
                    table.insert(cueState.vfxComps, comp)
                elseif debugLogFn then
                    debugLogFn("Timeline [" .. tlInst.spellName .. "] SpawnSystemAttached failed: " .. tostring(comp))
                end
            end
        end

        if #cueState.vfxComps == 0 and HasUFunc(nsLib, "SpawnSystemAtLocation") then
            for _, tf in ipairs(transforms) do
                local okV, comp = pcall(function()
                    return nsLib:SpawnSystemAtLocation(pawn, vfxObj, tf.loc, tf.rot, scale, true, true, 0, false)
                end)
                if okV and IsValidUObject(comp) then
                    UncapNiagaraAssetAndComponent(vfxObj, comp)
                    ApplyNiagaraScaleAndParams(comp, scale, p, false)
                    table.insert(cueState.vfxComps, comp)
                elseif debugLogFn then
                    debugLogFn("Timeline [" .. tlInst.spellName .. "] SpawnSystemAtLocation failed: " .. tostring(comp))
                end
            end
        end

        if debugLogFn then
            local firstLoc = transforms[1] and transforms[1].loc or MakeVec(0, 0, 0)
            debugLogFn(string.format("Timeline [%s] VFX #%d -> %s (spawned=%d, target=%s, loc=[%.0f,%.0f,%.0f], scale=[%.2f,%.2f,%.2f])",
                tlInst.spellName, cue.index, SafeObjName(vfxObj), #cueState.vfxComps, tostring(p.target or "player"),
                firstLoc.X, firstLoc.Y, firstLoc.Z, scale.X, scale.Y, scale.Z))
        end

        cueState.expectedDur = (p.dur ~= nil) and (scaleSpeed and (p.dur / stageSpeed) or p.dur) or 0.0

    elseif cType == "sfx" then
        local sfxObj = nil
        if cue.asset and cue.asset ~= "" then
            local cleaned = NormalizeUeAssetPath(cue.asset)
            if customSpells and customSpells.FindObjectFast then
                sfxObj = customSpells.FindObjectFast(cleaned)
            end
            if not IsValidUObject(sfxObj) and cleaned:find("/", 1, true) then
                pcall(function() sfxObj = StaticFindObject(cleaned) end)
                if not IsValidUObject(sfxObj) and type(LoadAsset) == "function" then
                    pcall(function() LoadAsset(cleaned) end)
                    pcall(function() sfxObj = StaticFindObject(cleaned) end)
                end
            end
            if not IsValidUObject(sfxObj) and customSpells and customSpells.FindAssetByKeywordOnDemand then
                sfxObj = customSpells.FindAssetByKeywordOnDemand("SoundBase", cue.asset, safeGetNameFn)
                    or customSpells.FindAssetByKeywordOnDemand("SoundWave", cue.asset, safeGetNameFn)
            end
        end
        if not IsValidUObject(sfxObj) then
            LogMismatchOnce(tlInst.spellName .. ":" .. tostring(cue.index) .. ":missing:" .. tostring(cue.asset),
                string.format("CustomSpell [%s] Cue #%d (sfx): SoundBase '%s' not found; skipping safely.", tlInst.spellName, cue.index, tostring(cue.asset)))
            cueState.expectedDur = 0.0
            return
        end
        if not ValidateCueAssetType(sfxObj, "sfx", tlInst.spellName, cue.index, cue.asset) then
            cueState.expectedDur = 0.0
            return
        end

        local gpStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        if not IsValidUObject(gpStatics) then return end

        local vol   = tonumber(p.vol) or 1.0
        local pitch = tonumber(p.pitch) or 1.0
        local start = tonumber(p.start) or 0.0
        local targetLow = (p.target or "player"):lower()
        cueState.audioComps = {}

        if targetLow == "2d" then
            if HasUFunc(gpStatics, "SpawnSound2D") then
                local okS, comp = pcall(function()
                    return gpStatics:SpawnSound2D(pawn, sfxObj, vol, pitch, start, nil, false, true)
                end)
                if okS and IsValidUObject(comp) then table.insert(cueState.audioComps, comp) end
            elseif HasUFunc(gpStatics, "PlaySound2D") then
                pcall(function() gpStatics:PlaySound2D(pawn, sfxObj, vol, pitch, start, nil, pawn, false) end)
            end
        else
            local transforms, attachComp = ComputeTargetTransforms(tlInst, pawn, p)
            if (p.socket or p.attach) and IsValidUObject(attachComp) and HasUFunc(gpStatics, "SpawnSoundAttached") then
                local okS, comp = pcall(function()
                    return gpStatics:SpawnSoundAttached(sfxObj, attachComp, FName(p.socket or "None"),
                        p.offset or MakeVec(0, 0, 0), p.rot or MakeRot(0, 0, 0), 0, true, vol, pitch, start, nil, nil, true)
                end)
                if okS and IsValidUObject(comp) then table.insert(cueState.audioComps, comp) end
            elseif #transforms > 0 then
                for _, tf in ipairs(transforms) do
                    if HasUFunc(gpStatics, "SpawnSoundAtLocation") then
                        local okS, comp = pcall(function()
                            return gpStatics:SpawnSoundAtLocation(pawn, sfxObj, tf.loc, tf.rot, vol, pitch, start, nil, nil, true)
                        end)
                        if okS and IsValidUObject(comp) then table.insert(cueState.audioComps, comp) end
                    elseif HasUFunc(gpStatics, "PlaySoundAtLocation") then
                        pcall(function() gpStatics:PlaySoundAtLocation(pawn, sfxObj, tf.loc) end)
                    end
                end
            end
        end
        cueState.expectedDur = (p.dur ~= nil) and (scaleSpeed and (p.dur / stageSpeed) or p.dur) or 0.0

    elseif cType == "actor" then
        if not cue.asset or cue.asset == "" then return end
        local actorClass = nil
        if customSpells and customSpells.FindObjectFast then
            actorClass = customSpells.FindObjectFast(cue.asset)
        end
        if not IsValidUObject(actorClass) and customSpells and customSpells.FindAssetByKeywordOnDemand then
            actorClass = customSpells.FindAssetByKeywordOnDemand("BlueprintGeneratedClass", cue.asset, safeGetNameFn)
                or customSpells.FindAssetByKeywordOnDemand("Class", cue.asset, safeGetNameFn)
        end
        if not IsValidUObject(actorClass) then
            LogMismatchOnce(tlInst.spellName .. ":" .. tostring(cue.index) .. ":missing:" .. tostring(cue.asset),
                string.format("CustomSpell [%s] Cue #%d (actor): Actor class '%s' not found; skipping safely.", tlInst.spellName, cue.index, tostring(cue.asset)))
            return
        end
        if not ValidateCueAssetType(actorClass, "actor", tlInst.spellName, cue.index, cue.asset) then
            return
        end

        local transforms = ComputeTargetTransforms(tlInst, pawn, p)
        local scale = p.scale or MakeVec(1.0, 1.0, 1.0)
        local allowUnsafe = (p.allowUnsafeSpawn == true) or (tlInst.entry and tlInst.entry.customDef and tlInst.entry.customDef.allowUnsafeSpawn == true)
        local bridgeCDO = customSpells and customSpells.GetDamageBridgeCDO and customSpells.GetDamageBridgeCDO(tlInst.entry) or nil
        cueState.spawnedActors = {}

        for idxTf, tf in ipairs(transforms) do
            local spawned = nil
            -- Tier 1: Crash-safe Blueprint Bridge SpawnActorSafe (no FTransform Lua marshalling)
            if IsValidUObject(bridgeCDO) and HasUFunc(bridgeCDO, "SpawnActorSafe") then
                local okB, resB = pcall(function()
                    return bridgeCDO:SpawnActorSafe(pawn, actorClass, tf.loc, tf.rot, scale, pawn)
                end)
                if okB and IsValidUObject(resB) then
                    spawned = resB
                end
            end
            -- Tier 2: Guarded Lua fallback (requires AllowUnsafeSpawn=true)
            if not IsValidUObject(spawned) and allowUnsafe then
                pcall(function()
                    local gpStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
                    if IsValidUObject(gpStatics) and HasUFunc(gpStatics, "BeginDeferredActorSpawnFromClass") and HasUFunc(gpStatics, "FinishSpawningActor") then
                        local xform = { Translation = tf.loc, Rotation = tf.rot, Scale3D = scale }
                        local a = gpStatics:BeginDeferredActorSpawnFromClass(pawn, actorClass, xform, 0, pawn)
                        if IsValidUObject(a) then
                            gpStatics:FinishSpawningActor(a, xform)
                            spawned = a
                        end
                    end
                end)
            end

            if IsValidUObject(spawned) then
                table.insert(cueState.spawnedActors, spawned)
                if idxTf == 1 and cue.idLower and cue.idLower ~= "" then
                    tlInst.actorsById[cue.idLower] = spawned
                end
                -- Optional attachment to player / weapon / another spawned actor
                if p.attach and p.attach:lower() ~= "world" then
                    local attComp = nil
                    local attLow = p.attach:lower()
                    if attLow == "player" then
                        pcall(function() attComp = pawn.Mesh end)
                    elseif attLow == "weapon_right" or attLow == "weapon" then
                        attComp = ResolveHeldEquipmentMesh(pawn, "weapon_right")
                    elseif attLow == "weapon_left" then
                        attComp = ResolveHeldEquipmentMesh(pawn, "weapon_left")
                    elseif attLow:find("^actor:") then
                        local parentA = tlInst.actorsById[attLow:sub(7)]
                        attComp = ResolveActorSkeletalMesh(parentA) or (IsValidUObject(parentA) and parentA.RootComponent)
                    end
                    if IsValidUObject(attComp) and HasUFunc(spawned, "K2_AttachToComponent") then
                        pcall(function()
                            spawned:K2_AttachToComponent(attComp, FName(p.socket or "None"), 1, 1, 1, false)
                        end)
                    end
                end
            end
        end
        cueState.expectedDur = (p.dur ~= nil) and (scaleSpeed and (p.dur / stageSpeed) or p.dur) or 0.0

    elseif cType == "spell" then
        if not cue.asset or cue.asset == "" then return end
        local spObj = nil
        local reg = state and state.SpellRegistry and state.SpellRegistry[cue.asset:lower()]
        if reg and IsValidUObject(reg.spellObj) and not reg.suppressBaseSpell then
            spObj = reg.spellObj
        end
        if not IsValidUObject(spObj) and customSpells and customSpells.FindObjectFast then
            spObj = customSpells.FindObjectFast(cue.asset)
        end
        if not IsValidUObject(spObj) and customSpells and customSpells.FindAssetByKeywordOnDemand then
            spObj = customSpells.FindAssetByKeywordOnDemand("DominionSpellData", cue.asset, safeGetNameFn)
        end

        -- Snapshot existing SpellActor & projectiles BEFORE triggering so parallel overlapping timelines
        -- never hijack an older cast's SpellActor or projectile!
        local preSpellActor = nil
        if IsValidUObject(combatMagic) then
            pcall(function()
                local sa = combatMagic.CurrentSpellActor
                if IsValidUObject(sa) then preSpellActor = sa end
            end)
        end
        local preExistingProj = {}
        pcall(function()
            local projs = FindAllOf("DominionSpellProjectile")
            if projs then
                for _, pr in ipairs(projs) do
                    if IsValidUObject(pr) then preExistingProj[SafeObjName(pr)] = true end
                end
            end
        end)

        if IsValidUObject(spObj) and ValidateCueAssetType(spObj, "spell", tlInst.spellName, cue.index, cue.asset) then
            pcall(function()
                local bpLib = StaticFindObject("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
                if IsValidUObject(bpLib) and HasUFunc(bpLib, "TriggerModularAbilityForPlayer") then
                    bpLib:TriggerModularAbilityForPlayer(pawn, spObj)
                end
            end)
            if debugLogFn then
                debugLogFn(string.format("Timeline [%s] Spell #%d triggered: %s", tlInst.spellName, cue.index, tostring(cue.asset)))
            end
        elseif not IsValidUObject(spObj) then
            LogMismatchOnce(tlInst.spellName .. ":" .. tostring(cue.index) .. ":missing:" .. tostring(cue.asset),
                string.format("CustomSpell [%s] Cue #%d (spell): DominionSpellData '%s' not found; skipping safely.", tlInst.spellName, cue.index, tostring(cue.asset)))
        end

        -- Enable projectile/spell impact tracking if requested explicitly OR if any later cue uses target=impact or waits on >thisSpell
        local needsImpactTrack = (p.trackImpact == true)
        if not needsImpactTrack and tlInst.timeline and tlInst.timeline.cues then
            for j = cue.index + 1, #tlInst.timeline.cues do
                local later = tlInst.timeline.cues[j]
                local lTarget = (later.params and later.params.target or ""):lower()
                if lTarget == "impact" or (later.anchorIndex == cue.index and later.timing and later.timing.mode == "after_end") then
                    needsImpactTrack = true
                    break
                end
            end
        end

        if needsImpactTrack then
            local pLoc = select(1, GetActorLocAndRot(pawn))
            cueState.trackingImpact = true
            cueState.impactTimeout = tonumber(p.impactTimeout) or 2.2
            cueState.castOriginLoc = pLoc
            cueState.lastTrackedLoc = nil
            cueState.sawSpellActor = false
            cueState.trackedSpellActor = nil
            cueState.trackedProjectile = nil
            cueState.preExistingSpellActor = preSpellActor
            cueState.preExistingProj = preExistingProj

            -- If TriggerModularAbilityForPlayer spawned a brand-new SpellActor synchronously, claim it immediately
            if IsValidUObject(combatMagic) then
                pcall(function()
                    local sa = combatMagic.CurrentSpellActor
                    if IsValidUObject(sa) and sa ~= preSpellActor then
                        state._ClaimedSpellActors = state._ClaimedSpellActors or {}
                        local saKey = SafeObjName(sa)
                        if not state._ClaimedSpellActors[saKey] then
                            state._ClaimedSpellActors[saKey] = tlInst.instanceId
                            cueState.trackedSpellActor = sa
                            cueState.trackedSpellActorKey = saKey
                            cueState.sawSpellActor = true
                        end
                    end
                end)
            end
            cueState.expectedDur = cueState.impactTimeout
        else
            cueState.expectedDur = (p.dur ~= nil) and (scaleSpeed and (p.dur / stageSpeed) or p.dur) or 0.0
        end

    elseif cType == "hit" then
        local transforms = ComputeTargetTransforms(tlInst, pawn, p, debugLogFn)
        local centerTf = transforms[1] or { loc = select(1, GetActorLocAndRot(pawn)), rot = select(2, GetActorLocAndRot(pawn)) }
        tlInst.lastHitCenter = centerTf.loc
        if customSpells and customSpells.ExecuteHitPulse then
            local _, hitList = customSpells.ExecuteHitPulse(pawn, centerTf.loc, centerTf.rot, p, tlInst.entry, safeGetNameFn, debugLogFn, tlInst.config)
            tlInst.lastHitTargets = hitList or {}
        end
        cueState.expectedDur = (p.dur ~= nil) and (scaleSpeed and (p.dur / stageSpeed) or p.dur) or 0.0

    elseif cType == "decal" then
        if not cue.asset or cue.asset == "" then return end
        local matObj = nil
        if customSpells and customSpells.FindObjectFast then
            matObj = customSpells.FindObjectFast(cue.asset)
        end
        if not IsValidUObject(matObj) and customSpells and customSpells.FindAssetByKeywordOnDemand then
            matObj = customSpells.FindAssetByKeywordOnDemand("MaterialInterface", cue.asset, safeGetNameFn)
        end
        if not IsValidUObject(matObj) or not ValidateCueAssetType(matObj, "decal", tlInst.spellName, cue.index, cue.asset) then return end
        local gpStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        if not IsValidUObject(gpStatics) or not HasUFunc(gpStatics, "SpawnDecalAtLocation") then return end

        local size = p.size or MakeVec(128.0, 256.0, 256.0)
        local lifeSpan = tonumber(p.dur) or 4.0
        local transforms = ComputeTargetTransforms(tlInst, pawn, p)
        cueState.decalComps = {}
        for _, tf in ipairs(transforms) do
            -- Default Pitch = -90 projects decal straight down onto the ground
            local decalRot = p.rot and tf.rot or MakeRot(-90.0, tf.rot.Yaw or 0.0, 0.0)
            local okD, comp = pcall(function()
                return gpStatics:SpawnDecalAtLocation(pawn, matObj, size, tf.loc, decalRot, lifeSpan)
            end)
            if okD and IsValidUObject(comp) then table.insert(cueState.decalComps, comp) end
        end
        cueState.expectedDur = (p.dur ~= nil) and (scaleSpeed and (p.dur / stageSpeed) or p.dur) or 0.0

    elseif cType == "shake" then
        if not cue.asset or cue.asset == "" then return end
        local shakeClass = nil
        if customSpells and customSpells.FindObjectFast then
            shakeClass = customSpells.FindObjectFast(cue.asset)
        end
        if not IsValidUObject(shakeClass) and customSpells and customSpells.FindAssetByKeywordOnDemand then
            shakeClass = customSpells.FindAssetByKeywordOnDemand("BlueprintGeneratedClass", cue.asset, safeGetNameFn)
                or customSpells.FindAssetByKeywordOnDemand("Class", cue.asset, safeGetNameFn)
        end
        if not IsValidUObject(shakeClass) or not ValidateCueAssetType(shakeClass, "shake", tlInst.spellName, cue.index, cue.asset) then return end
        local gpStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        if IsValidUObject(gpStatics) and HasUFunc(gpStatics, "PlayWorldCameraShake") then
            local transforms = ComputeTargetTransforms(tlInst, pawn, p)
            local loc = (transforms[1] and transforms[1].loc) or select(1, GetActorLocAndRot(pawn))
            pcall(function()
                gpStatics:PlayWorldCameraShake(pawn, shakeClass, loc,
                    tonumber(p.innerRadius) or 0.0,
                    tonumber(p.outerRadius) or 1200.0,
                    tonumber(p.falloff) or 1.0,
                    false)
            end)
        end
        cueState.expectedDur = 0.0

    elseif cType == "chainstrike" then
        -- Respect global config toggle (RequireLockOnForChainSpells=false disables lock requirement)
        -- as well as per-cue requireLock in custom_spells.json.
        local cfgRequireLock = (tlInst.config == nil) or (tlInst.config.RequireLockOnForChainSpells ~= false)
        local requireLock = cfgRequireLock and (p.requireLock ~= false)
        local requireLos  = (p.los ~= false)

        -- 1. Resolve primary target (strictly locked-on when requireLock=true)
        local primaryActor, primaryLoc = ResolveLockedOnEnemy(pawn, math.max(3000.0, tonumber(p.range) or 3000.0))
        if not IsValidUObject(primaryActor) and not requireLock then
            local aimLoc, _, aimActor = ResolveAimTarget(pawn, p.range, p.cone, nil, tlInst.config, tlInst.entry, debugLogFn)
            if IsValidUObject(aimActor) then
                primaryActor = aimActor
                primaryLoc = aimLoc
            end
        end

        if not IsValidUObject(primaryActor) or not IsNonZeroWorldLoc(primaryLoc) then
            if debugLogFn then
                debugLogFn(string.format("Timeline [%s] ChainStrike #%d skipped (no %s enemy found)",
                    tlInst.spellName, cue.index, requireLock and "locked-on" or "targeted"))
            end
            if #tlInst.timeline.cues == 1 then tlInst.abortedNoTarget = true end
            cueState.expectedDur = 0.0
            return
        end

        if requireLos and not HasLineOfSightToActor(pawn, primaryActor) then
            if debugLogFn then
                debugLogFn(string.format("Timeline [%s] ChainStrike #%d blocked (no Line of Sight to %s)",
                    tlInst.spellName, cue.index, SafeObjName(primaryActor)))
            end
            if #tlInst.timeline.cues == 1 then tlInst.abortedNoTarget = true end
            cueState.expectedDur = 0.0
            return
        end

        -- 2. Compute strike count from live player skill level (e.g. +1 per 10 Magic levels)
        local skillName = p.skill or "magic"
        local skillLvl = GetPlayerSkillLevel(pawn, skillName)
        local baseStrikes = math.max(1, math.floor(tonumber(p.baseStrikes) or 1))
        local levelsPer = math.max(1, math.floor(tonumber(p.levelsPerStrike) or 10))
        local maxStrikes = math.max(baseStrikes, math.floor(tonumber(p.maxStrikes) or 10))
        local totalStrikes = math.min(maxStrikes, baseStrikes + math.floor(skillLvl / levelsPer))
        local interval = math.max(0.02, tonumber(p.interval) or 0.15)
        if scaleSpeed and stageSpeed > 0.1 then
            interval = interval / stageSpeed
        end

        -- 3. Resolve & type-validate VFX and SFX once for the entire barrage
        local vfxAsset = cue.asset or p.vfx or "lightning"
        local vfxObj = nil
        if vfxAsset and vfxAsset ~= "" then
            local cleaned = NormalizeUeAssetPath(vfxAsset)
            local lookupPath = (state and state.VfxPathLookup and state.VfxPathLookup[cleaned:lower()]) or cleaned
            lookupPath = NormalizeUeAssetPath(lookupPath)
            if customSpells and customSpells.FindObjectFast then vfxObj = customSpells.FindObjectFast(lookupPath) end
            if not IsValidUObject(vfxObj) and lookupPath:find("/", 1, true) then
                pcall(function() vfxObj = StaticFindObject(lookupPath) end)
                if not IsValidUObject(vfxObj) and type(LoadAsset) == "function" then
                    pcall(function() LoadAsset(lookupPath) end)
                    pcall(function() vfxObj = StaticFindObject(lookupPath) end)
                end
            end
            if not IsValidUObject(vfxObj) and customSpells and customSpells.FindAssetByKeywordOnDemand then
                local kwSearch = cleaned:match("%.([^%.]+)$") or cleaned:match("/([^/]+)$") or cleaned
                vfxObj = customSpells.FindAssetByKeywordOnDemand("NiagaraSystem", kwSearch, safeGetNameFn)
            end
            if IsValidUObject(vfxObj) and not ValidateCueAssetType(vfxObj, "vfx", tlInst.spellName, cue.index, vfxAsset) then
                vfxObj = nil
            end
        end

        local sfxObj = nil
        if p.sfx and p.sfx ~= "" then
            local cleanedSfx = NormalizeUeAssetPath(p.sfx)
            if customSpells and customSpells.FindObjectFast then sfxObj = customSpells.FindObjectFast(cleanedSfx) end
            if not IsValidUObject(sfxObj) and cleanedSfx:find("/", 1, true) then
                pcall(function() sfxObj = StaticFindObject(cleanedSfx) end)
                if not IsValidUObject(sfxObj) and type(LoadAsset) == "function" then
                    pcall(function() LoadAsset(cleanedSfx) end)
                    pcall(function() sfxObj = StaticFindObject(cleanedSfx) end)
                end
            end
            if not IsValidUObject(sfxObj) and customSpells and customSpells.FindAssetByKeywordOnDemand then
                sfxObj = customSpells.FindAssetByKeywordOnDemand("SoundBase", p.sfx, safeGetNameFn)
                    or customSpells.FindAssetByKeywordOnDemand("SoundWave", p.sfx, safeGetNameFn)
            end
            if IsValidUObject(sfxObj) and not ValidateCueAssetType(sfxObj, "sfx", tlInst.spellName, cue.index, p.sfx) then
                sfxObj = nil
            end
        end

        local now = os.clock()
        local vfxDur = tonumber(p.dur) or 0.90
        cueState.chainState = {
            primaryActor = primaryActor,
            lastAnchorLoc = primaryLoc,
            totalStrikes = totalStrikes,
            firedStrikes = 0,
            interval = interval,
            nextStrikeAt = now,
            chainRadius = tonumber(p.chainRadius) or 650.0,
            requireLos = requireLos,
            preferUnique = (p.preferUnique ~= false),
            hitCounts = {},
            vfxObj = vfxObj,
            sfxObj = sfxObj,
            vfxScale = p.scale or MakeVec(0.35, 0.35, 0.45),
            vfxDur = vfxDur,
            params = p,
            spawnedVfx = {}
        }

        if debugLogFn then
            debugLogFn(string.format("Timeline [%s] ChainStrike #%d engaged: %s Lv=%d -> %d strikes (every %.2fs, chainRadius=%.0f, primary=%s)",
                tlInst.spellName, cue.index, skillName, skillLvl, totalStrikes, interval, cueState.chainState.chainRadius, SafeObjName(primaryActor)))
        end

        -- Fire Strike #1 immediately on cast!
        local firedFirst = FireSingleChainStrike(tlInst, cue, cueState, pawn, customSpells, debugLogFn, now)
        if firedFirst then
            cueState.chainState.nextStrikeAt = now + interval
            cueState.expectedDur = math.max(0.15, (totalStrikes - 1) * interval + vfxDur)
        else
            cueState.chainState = nil
            cueState.expectedDur = 0.0
        end
    end
end

-- Stop/cleanup handles created by a cue (called on explicit `dur=` expiration or timeline cancellation).
-- Always re-fetches a fresh AnimInstance from `pawn` instead of touching cached UAnimInstance pointers!
local function CleanupCueHandles(cue, cueState, isCancel, pawn)
    if not cueState or cueState.cleaned then return end
    cueState.cleaned = true
    local p = cue and cue.params or {}
    local blendOut = tonumber(p.blendOut) or 0.15

    -- Stop active montage ONLY when explicit dur= was set or timeline was explicitly cancelled
    if (isCancel or p.dur ~= nil) and IsValidUObject(pawn) then
        local freshInst = nil
        pcall(function()
            if cueState.targetKind == "player" or not cueState.targetKind then
                local mesh = pawn.Mesh
                if IsValidUObject(mesh) then freshInst = mesh:GetAnimInstance() end
            elseif cueState.targetKind == "weapon_right" or cueState.targetKind == "weapon_left" or cueState.targetKind == "weapon" then
                local wMesh = ResolveHeldEquipmentMesh(pawn, cueState.targetKind)
                if IsValidUObject(wMesh) then freshInst = wMesh:GetAnimInstance() end
            end
        end)
        if IsValidUObject(freshInst) then
            if cueState.isDynamicMontage and p.slot and p.slot:lower() ~= "auto" and HasUFunc(freshInst, "StopSlotAnimation") then
                local slotFn = ResolveSlotFName(pawn, p.slot)
                if slotFn then pcall(function() freshInst:StopSlotAnimation(blendOut, slotFn) end) end
            elseif IsValidUObject(cueState.montageObj) and HasUFunc(freshInst, "Montage_Stop") then
                pcall(function() freshInst:Montage_Stop(blendOut, cueState.montageObj) end)
            end
        end
    end

    if cueState.vfxComps and (isCancel or p.dur ~= nil) then
        for _, comp in ipairs(cueState.vfxComps) do
            if IsValidUObject(comp) then
                pcall(function()
                    if HasUFunc(comp, "Deactivate") then comp:Deactivate() end
                    if isCancel and HasUFunc(comp, "K2_DestroyComponent") then comp:K2_DestroyComponent(comp) end
                end)
            end
        end
    end

    if cueState.audioComps and (isCancel or p.dur ~= nil) then
        for _, comp in ipairs(cueState.audioComps) do
            if IsValidUObject(comp) then
                pcall(function()
                    if HasUFunc(comp, "FadeOut") then comp:FadeOut(0.15, 0.0)
                    elseif HasUFunc(comp, "Stop") then comp:Stop() end
                end)
            end
        end
    end

    if cueState.spawnedActors and (isCancel or p.dur ~= nil) then
        for _, actor in ipairs(cueState.spawnedActors) do
            if IsValidUObject(actor) and HasUFunc(actor, "K2_DestroyActor") then
                pcall(function() actor:K2_DestroyActor() end)
            end
        end
    end
end

-- Compute whether a pending cue is ready to fire at `now`.
-- Returns (shouldFire, fireAtTime)
local function EvaluateCueFireTime(tlInst, cue, now)
    local t = cue.timing or { mode = "abs", offset = 0.0 }
    local stageSpeed = tlInst.stageSpeed or 1.0
    local scaleSpeed = (tlInst.timeline.scaleWithSpeed ~= false) and ((cue.params and cue.params.scaleWithSpeed) ~= false)
    local rawOff = tonumber(t.offset) or 0.0
    local scaledOff = scaleSpeed and (rawOff / stageSpeed) or rawOff

    if t.mode == "abs" or not cue.anchorIndex then
        local fireAt = tlInst.startedAt + math.max(0.0, scaledOff)
        return (now >= fireAt), fireAt
    end

    local anchorState = tlInst.cueStates[cue.anchorIndex]
    if not anchorState or anchorState.status == "pending" then
        return false, nil
    end

    if t.mode == "sync_start" then
        local fireAt = (anchorState.startedAt or tlInst.startedAt) + scaledOff
        if fireAt < tlInst.startedAt then fireAt = tlInst.startedAt end
        return (now >= fireAt), fireAt
    end

    if t.mode == "after_end" then
        -- Negative crossfade offset (e.g. >-0.12): compute against anchor's startedAt + expectedDur!
        if scaledOff < 0.0 then
            local estEnd = (anchorState.startedAt or tlInst.startedAt) + (anchorState.expectedDur or 0.0)
            local fireAt = math.max(anchorState.startedAt or tlInst.startedAt, estEnd + scaledOff)
            if anchorState.status == "done" then
                return true, anchorState.endedAt or now
            end
            return (now >= fireAt), fireAt
        end

        -- Zero or positive gap (e.g. > or >+0.10): wait until anchor is actually done
        if anchorState.status ~= "done" then
            return false, nil
        end
        local fireAt = (anchorState.endedAt or now) + scaledOff
        return (now >= fireAt), fireAt
    end

    return true, tlInst.startedAt
end

-- Start a new spell timeline instance for `entry`.
function TimelineRunner.StartSpellTimeline(config, state, pawn, combatMagic, entry, stageSpeed, customSpells, safeGetNameFn, debugLogFn)
    if not state or not entry or not entry.timeline or not entry.timeline.cues or #entry.timeline.cues == 0 then
        return nil
    end
    state.ActiveTimelines = state.ActiveTimelines or {}

    local policy = entry.timeline.overlapPolicy or "replace"
    if policy == "ignore" then
        for _, active in ipairs(state.ActiveTimelines) do
            if not active.finished and active.spellKey == entry.shortName:lower() then
                return active
            end
        end
    elseif policy == "replace" then
        TimelineRunner.CancelTimelines(state, pawn, "replaced-by-" .. tostring(entry.shortName), false, entry.shortName:lower())
    end

    TimelineInstanceCounter = TimelineInstanceCounter + 1
    local now = os.clock()
    local effSpeed = math.max(0.25, tonumber(stageSpeed) or tonumber(entry.customOverrideSpeed) or 1.0)
    local cueStates = {}
    for i = 1, #entry.timeline.cues do
        cueStates[i] = {
            status = "pending",
            startedAt = nil,
            endedAt = nil,
            expectedDur = 0.0,
            cleaned = false
        }
    end

    local tlInst = {
        instanceId = TimelineInstanceCounter,
        spellName = tostring(entry.shortName or "CustomSpell"),
        spellKey = tostring(entry.shortName or "custom"):lower(),
        entry = entry,
        config = config,
        timeline = entry.timeline,
        stageSpeed = effSpeed,
        startedAt = now,
        cueStates = cueStates,
        actorsById = {},
        finished = false,
        cancelOnRelease = entry.timeline.cancelOnRelease == true
    }

    table.insert(state.ActiveTimelines, tlInst)
    if debugLogFn then
        debugLogFn(string.format("Started Timeline #%d [%s] (%d cues, speed=%.2fx, policy=%s)",
            tlInst.instanceId, tlInst.spellName, #entry.timeline.cues, effSpeed, policy))
    end

    -- Immediately tick once so @0.00 cues fire on the exact cast frame with zero 16ms delay!
    TimelineRunner.Tick(now, config, state, pawn, combatMagic, customSpells, safeGetNameFn, debugLogFn)
    if tlInst.abortedNoTarget then
        tlInst.finished = true
        return nil
    end
    return tlInst
end

-- Check whether any active timeline for a given spell (or any timeline) is still before its stepAdvanceAt / end.
function TimelineRunner.IsSpellTimelineBusy(state, entry, now)
    if not state or not state.ActiveTimelines or #state.ActiveTimelines == 0 then
        return false
    end
    local key = entry and entry.shortName and entry.shortName:lower() or nil
    for _, tlInst in ipairs(state.ActiveTimelines) do
        if not tlInst.finished and (not key or tlInst.spellKey == key) then
            local elapsed = (now or os.clock()) - (tlInst.startedAt or 0)
            local adv = tlInst.timeline.stepAdvanceAt
            if adv ~= nil then
                local scaledAdv = (tlInst.timeline.scaleWithSpeed ~= false) and (adv / (tlInst.stageSpeed or 1.0)) or adv
                if elapsed < scaledAdv then return true end
            else
                return true
            end
        end
    end
    return false
end

-- Cancel active timelines (optionally only those marked CancelOnRelease, or matching spellKey).
function TimelineRunner.CancelTimelines(state, pawn, reason, onlyCancelable, onlySpellKey)
    if not state or not state.ActiveTimelines or #state.ActiveTimelines == 0 then return end

    local toCleanup = {}
    local kept = {}
    for _, tlInst in ipairs(state.ActiveTimelines) do
        local matchKey = (not onlySpellKey) or (tlInst.spellKey == onlySpellKey)
        local matchCancel = (not onlyCancelable) or (tlInst.cancelOnRelease == true)
        if not tlInst.finished and matchKey and matchCancel then
            tlInst.finished = true
            table.insert(toCleanup, tlInst)
        elseif not tlInst.finished then
            table.insert(kept, tlInst)
        end
    end
    state.ActiveTimelines = kept

    if #toCleanup == 0 then return end
    -- Already running on the serialized Game Thread via main.lua
    for _, tlInst in ipairs(toCleanup) do
        for i, cue in ipairs(tlInst.timeline.cues) do
            local cs = tlInst.cueStates[i]
            if cs then
                if cs.trackedSpellActorKey and state._ClaimedSpellActors and state._ClaimedSpellActors[cs.trackedSpellActorKey] == tlInst.instanceId then
                    state._ClaimedSpellActors[cs.trackedSpellActorKey] = nil
                end
                if cs.trackedProjectileKey and state._ClaimedProjectiles and state._ClaimedProjectiles[cs.trackedProjectileKey] == tlInst.instanceId then
                    state._ClaimedProjectiles[cs.trackedProjectileKey] = nil
                end
                if cs.status == "active" then
                    pcall(function() CleanupCueHandles(cue, cs, true, pawn) end)
                    cs.status = "done"
                end
            end
        end
    end
end

-- Consolidated per-frame scheduler tick: evaluates pending cues, checks active cue completion,
-- and batches all UE API operations into a SINGLE ExecuteInGameThread dispatch per tick.
function TimelineRunner.Tick(now, config, state, pawn, combatMagic, customSpells, safeGetNameFn, debugLogFn)
    if not state or not state.ActiveTimelines or #state.ActiveTimelines == 0 then
        return
    end
    if not IsValidUObject(pawn) then
        TimelineRunner.CancelTimelines(state, nil, "pawn-invalid", false)
        return
    end

    local tNow = now or os.clock()
    local workBatch = {}

    for _, tlInst in ipairs(state.ActiveTimelines) do
        if not tlInst.finished then
            local cues = tlInst.timeline.cues
            local elapsed = tNow - tlInst.startedAt
            local hardDur = tlInst.timeline.explicitDuration
            if hardDur and tlInst.timeline.scaleWithSpeed ~= false then
                hardDur = hardDur / (tlInst.stageSpeed or 1.0)
            end

            if hardDur and elapsed >= hardDur then
                tlInst.finished = true
                table.insert(workBatch, { kind = "finish_timeline", tlInst = tlInst })
            else
                -- Iteratively promote cues that are ready at tNow (so @0 + & chained cues fire on the same tick!)
                local progressed = true
                local guard = 0
                while progressed and guard < 16 do
                    progressed = false
                    guard = guard + 1
                    for i, cue in ipairs(cues) do
                        local cs = tlInst.cueStates[i]
                        if cs.status == "pending" then
                            local shouldFire = EvaluateCueFireTime(tlInst, cue, tNow)
                            if shouldFire then
                                cs.status = "active"
                                cs.startedAt = tNow
                                -- Seed expectedDur with parser estimate so & / >-0.10 cues on the same tick have a baseline
                                local scaleSpeed = (tlInst.timeline.scaleWithSpeed ~= false) and ((cue.params and cue.params.scaleWithSpeed) ~= false)
                                cs.expectedDur = scaleSpeed and ((cue.estimatedDur or 0.0) / (tlInst.stageSpeed or 1.0)) or (cue.estimatedDur or 0.0)
                                table.insert(workBatch, { kind = "fire_cue", tlInst = tlInst, cue = cue, cueState = cs })
                                progressed = true
                            end
                        end
                    end
                end

                -- Check active cues for duration expiry or montage completion
                local allDone = true
                for i, cue in ipairs(cues) do
                    local cs = tlInst.cueStates[i]
                    if cs.status == "pending" then
                        allDone = false
                    elseif cs.status == "active" then
                        local cueElapsed = tNow - (cs.startedAt or tNow)
                        local hasExplicitDur = (cue.params and cue.params.dur ~= nil)
                        if not cs.executed and cueElapsed < 1.5 then
                            allDone = false
                        elseif cue.type == "anim" then
                            if hasExplicitDur and cueElapsed >= (cs.expectedDur or 0.0) then
                                cs.status = "done"
                                cs.endedAt = tNow
                                table.insert(workBatch, { kind = "cleanup_cue", cue = cue, cueState = cs, isCancel = false })
                            elseif not hasExplicitDur then
                                -- For dynamic montages or once expectedDur elapses, advance purely by duration (zero stale pointer risk).
                                if cueElapsed >= math.max(0.08, cs.expectedDur or 0.0) then
                                    cs.status = "done"
                                    cs.endedAt = tNow
                                elseif not cs.isDynamicMontage and IsValidUObject(cs.montageObj) and cueElapsed >= 0.12 then
                                    table.insert(workBatch, { kind = "poll_anim_done", cue = cue, cueState = cs, now = tNow })
                                    allDone = false
                                else
                                    allDone = false
                                end
                            else
                                allDone = false
                            end
                        elseif cue.type == "chainstrike" and cs.chainState then
                            local ch = cs.chainState
                            -- Deactivate any individual strike VFX whose dur elapsed
                            local stillLiveVfx = false
                            if ch.spawnedVfx then
                                for _, sv in ipairs(ch.spawnedVfx) do
                                    if not sv.deactivated then
                                        if tNow >= sv.expireAt then
                                            sv.deactivated = true
                                            if IsValidUObject(sv.comp) then
                                                pcall(function()
                                                    if HasUFunc(sv.comp, "Deactivate") then sv.comp:Deactivate() end
                                                end)
                                            end
                                        else
                                            stillLiveVfx = true
                                        end
                                    end
                                end
                            end
                            if ch.firedStrikes < ch.totalStrikes then
                                if tNow >= ch.nextStrikeAt then
                                    table.insert(workBatch, { kind = "tick_chainstrike", tlInst = tlInst, cue = cue, cueState = cs, now = tNow })
                                end
                                allDone = false
                            elseif stillLiveVfx then
                                allDone = false
                            else
                                cs.chainState = nil
                                cs.status = "done"
                                cs.endedAt = tNow
                            end
                        elseif cue.type == "spell" and cs.trackingImpact then
                            if cueElapsed >= (cs.impactTimeout or 2.2) then
                                table.insert(workBatch, { kind = "poll_spell_impact", tlInst = tlInst, cue = cue, cueState = cs, now = tNow, forceFinish = true })
                            else
                                table.insert(workBatch, { kind = "poll_spell_impact", tlInst = tlInst, cue = cue, cueState = cs, now = tNow, forceFinish = false })
                                allDone = false
                            end
                        else
                            if not hasExplicitDur or cueElapsed >= (cs.expectedDur or 0.0) then
                                cs.status = "done"
                                cs.endedAt = tNow
                                if hasExplicitDur then
                                    table.insert(workBatch, { kind = "cleanup_cue", cue = cue, cueState = cs, isCancel = false })
                                end
                            else
                                allDone = false
                            end
                        end
                    end
                end

                if allDone or elapsed >= 15.0 then
                    tlInst.finished = true
                    if debugLogFn then
                        debugLogFn(string.format("Timeline #%d [%s] completed (%.2fs)", tlInst.instanceId, tlInst.spellName, elapsed))
                    end
                end
            end
        end
    end

    -- Prune finished timelines
    local alive = {}
    for _, tlInst in ipairs(state.ActiveTimelines) do
        if not tlInst.finished then table.insert(alive, tlInst) end
    end
    state.ActiveTimelines = alive

    if #workBatch == 0 then return end

    -- Execute directly on the serialized Game Thread (no nested ExecuteInGameThread spawning!)
    for _, item in ipairs(workBatch) do
        if item.kind == "fire_cue" then
            pcall(function()
                ExecuteCueOnGameThread(item.tlInst, item.cue, item.cueState, config, state, pawn, combatMagic, customSpells, safeGetNameFn, debugLogFn)
            end)
            item.cueState.executed = true
        elseif item.kind == "cleanup_cue" then
            pcall(function()
                CleanupCueHandles(item.cue, item.cueState, item.isCancel, pawn)
            end)
        elseif item.kind == "finish_timeline" then
            for i, cue in ipairs(item.tlInst.timeline.cues) do
                local cs = item.tlInst.cueStates[i]
                if cs and cs.status == "active" then
                    pcall(function() CleanupCueHandles(cue, cs, false, pawn) end)
                    cs.status = "done"
                end
            end
        elseif item.kind == "poll_anim_done" then
            local cs = item.cueState
            if cs.status == "active" and not cs.isDynamicMontage and IsValidUObject(cs.montageObj) then
                local stillPlaying = false
                pcall(function()
                    local mesh = pawn.Mesh
                    if IsValidUObject(mesh) then
                        local freshInst = mesh:GetAnimInstance()
                        if IsValidUObject(freshInst) and HasUFunc(freshInst, "Montage_IsPlaying") then
                            stillPlaying = (freshInst:Montage_IsPlaying(cs.montageObj) == true)
                        end
                    end
                end)
                if not stillPlaying then
                    cs.status = "done"
                    cs.endedAt = item.now
                end
            end
        elseif item.kind == "tick_chainstrike" then
            local cs = item.cueState
            local ch = cs and cs.chainState
            if cs and cs.status == "active" and ch and ch.firedStrikes < ch.totalStrikes then
                local okStrike = FireSingleChainStrike(item.tlInst, item.cue, cs, pawn, customSpells, debugLogFn, item.now)
                if okStrike then
                    ch.nextStrikeAt = item.now + ch.interval
                else
                    -- No valid alive LOS targets remain -> stop queuing further strikes cleanly
                    ch.firedStrikes = ch.totalStrikes
                end
            end
        elseif item.kind == "poll_spell_impact" then
            local cs = item.cueState
            local tl = item.tlInst
            if cs.status == "active" then
                local age = item.now - (cs.startedAt or item.now)
                local exactCollisionPoint = nil

                state._ClaimedSpellActors = state._ClaimedSpellActors or {}
                state._ClaimedProjectiles = state._ClaimedProjectiles or {}

                -- 1. Latch an unclaimed new ADominionSpellActor ONCE (never overwrite with another parallel cast's actor!)
                if not cs.sawSpellActor and IsValidUObject(combatMagic) then
                    pcall(function()
                        local sa = combatMagic.CurrentSpellActor
                        if IsValidUObject(sa) and sa ~= cs.preExistingSpellActor then
                            local saKey = SafeObjName(sa)
                            local owner = state._ClaimedSpellActors[saKey]
                            if not owner or owner == tl.instanceId then
                                state._ClaimedSpellActors[saKey] = tl.instanceId
                                cs.trackedSpellActor = sa
                                cs.trackedSpellActorKey = saKey
                                cs.sawSpellActor = true
                            end
                        end
                    end)
                end

                if IsValidUObject(cs.trackedSpellActor) then
                    local colPt, spawnedBolt = InspectSpellActorCollisionAndProjectile(cs.trackedSpellActor)
                    if colPt then
                        exactCollisionPoint = colPt
                    end
                    if IsValidUObject(spawnedBolt) then
                        local bKey = SafeObjName(spawnedBolt)
                        state._ClaimedProjectiles[bKey] = tl.instanceId
                        cs.trackedProjectile = spawnedBolt
                        cs.trackedProjectileKey = bKey
                        cs.sawSpellActor = true
                    end
                    if not exactCollisionPoint and HasUFunc(cs.trackedSpellActor, "GetTargetInfo") then
                        pcall(function()
                            local ti = cs.trackedSpellActor:GetTargetInfo()
                            if ti and ti.Location then
                                local lx, ly, lz = tonumber(ti.Location.X) or 0, tonumber(ti.Location.Y) or 0, tonumber(ti.Location.Z) or 0
                                if math.abs(lx) + math.abs(ly) + math.abs(lz) > 1.0 then
                                    cs.spellTargetInfoLoc = MakeVec(lx, ly, lz)
                                end
                            end
                        end)
                    end
                end

                -- 2. Watch for a newly spawned UNCLAIMED DominionSpellProjectile as secondary tracker
                if not IsValidUObject(cs.trackedProjectile) then
                    pcall(function()
                        local projs = FindAllOf("DominionSpellProjectile")
                        if projs then
                            for _, pr in ipairs(projs) do
                                if IsValidUObject(pr) then
                                    local pKey = SafeObjName(pr)
                                    local owner = state._ClaimedProjectiles[pKey]
                                    if not (cs.preExistingProj and cs.preExistingProj[pKey]) and (not owner or owner == tl.instanceId) then
                                        state._ClaimedProjectiles[pKey] = tl.instanceId
                                        cs.trackedProjectile = pr
                                        cs.trackedProjectileKey = pKey
                                        cs.sawSpellActor = true
                                        break
                                    end
                                end
                            end
                        end
                    end)
                end

                local activeObj = IsValidUObject(cs.trackedProjectile) and cs.trackedProjectile
                    or (IsValidUObject(cs.trackedSpellActor) and cs.trackedSpellActor or nil)

                local stillFlying = false
                if IsValidUObject(activeObj) then
                    stillFlying = true
                    pcall(function()
                        local aLoc = activeObj:K2_GetActorLocation()
                        if IsNonZeroWorldLoc(aLoc) then
                            local orig = cs.castOriginLoc or MakeVec(0, 0, 0)
                            local dx = (aLoc.X or 0) - orig.X
                            local dy = (aLoc.Y or 0) - orig.Y
                            local dz = (aLoc.Z or 0) - orig.Z
                            local dSq = dx * dx + dy * dy + dz * dz
                            -- Must be > 50cm away from player and within reasonable 80m range (rejects pooled/origin actors!)
                            if dSq > 2500.0 and dSq < 64000000.0 then
                                cs.lastTrackedLoc = MakeVec(aLoc.X, aLoc.Y, aLoc.Z)
                            end
                        end
                    end)
                end

                -- Impacted the instant the Air Spell reports an exact CollisionPoint, OR when the flying projectile clears, OR timeout
                local impacted = (exactCollisionPoint ~= nil)
                    or item.forceFinish
                    or (cs.sawSpellActor and not stillFlying and age >= 0.10)
                    or (not cs.sawSpellActor and age >= 0.40)

                if impacted then
                    if cs.trackedSpellActorKey and state._ClaimedSpellActors[cs.trackedSpellActorKey] == tl.instanceId then
                        state._ClaimedSpellActors[cs.trackedSpellActorKey] = nil
                    end
                    if cs.trackedProjectileKey and state._ClaimedProjectiles[cs.trackedProjectileKey] == tl.instanceId then
                        state._ClaimedProjectiles[cs.trackedProjectileKey] = nil
                    end

                    local finalLoc = (IsNonZeroWorldLoc(exactCollisionPoint) and exactCollisionPoint)
                        or (IsNonZeroWorldLoc(cs.lastTrackedLoc) and cs.lastTrackedLoc)
                        or (IsNonZeroWorldLoc(cs.spellTargetInfoLoc) and cs.spellTargetInfoLoc)
                        or nil
                    local sourceTag = IsNonZeroWorldLoc(exactCollisionPoint) and "SPELL-COLLISION"
                        or (IsNonZeroWorldLoc(cs.lastTrackedLoc) and "PROJECTILE-END" or "TARGET-INFO")
                    local hitEnemy = nil

                    if finalLoc then
                        -- If the Air Spell struck near an alive enemy, snap cleanly onto that enemy's center
                        local nearEnemies = FindNearbyEnemyTargets(pawn, finalLoc, MakeRot(0, 0, 0), 220.0, nil, 1)
                        if nearEnemies and nearEnemies[1] then
                            hitEnemy = nearEnemies[1].actor
                            finalLoc = nearEnemies[1].loc
                        end
                    else
                        -- No collision/flight point recorded -> use Locked-On Enemy -> Closest Pointed Enemy within AutoTargetMaxDistance (700) -> Forward 700
                        local aimLoc, _, aimActor, aimMode = ResolveAimTarget(pawn, item.cue.params and item.cue.params.range, item.cue.params and item.cue.params.cone, nil, tl.config, tl.entry, debugLogFn)
                        finalLoc = aimLoc
                        hitEnemy = aimActor
                        sourceTag = "FALLBACK-" .. tostring(aimMode or "aim"):upper()
                    end

                    tl.impactLoc = finalLoc
                    tl.impactActor = hitEnemy
                    cs.trackingImpact = false
                    cs.status = "done"
                    cs.endedAt = item.now
                    if debugLogFn and finalLoc then
                        debugLogFn(string.format("Timeline [%s] Spell #%d hit [%s] at [%.0f, %.0f, %.0f] (enemy=%s, age=%.2fs)",
                            tl.spellName, item.cue.index, sourceTag, finalLoc.X, finalLoc.Y, finalLoc.Z,
                            hitEnemy and SafeObjName(hitEnemy) or "none", age))
                    end
                end
            end
        end
    end
end

-- Debug Inspector: logs live PlayerAnimationManager body-part slot names, held weapon meshes,
-- and currently playing montage metadata (SequenceLength, SlotAnimTracks, CompositeSections).
function TimelineRunner.InspectPlayerAnimSlotsAndMontages(pawn, logFn)
    if not logFn or not IsValidUObject(pawn) then return end
    logFn("=== Animation Slots, Equipment Meshes & Active Montage Inspector ===")

    local mgr = ResolvePlayerAnimManager(pawn)
    if IsValidUObject(mgr) then
        local slotProps = {
            "LegSlotName", "PelvisSlotName", "SpineSlotName", "HeadSlotName",
            "CurvesSlotName", "RightArmSlotName", "LeftArmSlotName"
        }
        local parts = {}
        for _, sp in ipairs(slotProps) do
            local val = "nil"
            pcall(function()
                local fn = mgr[sp]
                if fn ~= nil then val = fn:ToString() end
            end)
            table.insert(parts, sp .. "=" .. tostring(val))
        end
        logFn("  PlayerAnimationManager Slots: " .. table.concat(parts, " | "))
    else
        logFn("  PlayerAnimationManager: not found on pawn")
    end

    local rMesh, rActor = ResolveHeldEquipmentMesh(pawn, "weapon_right")
    local lMesh, lActor = ResolveHeldEquipmentMesh(pawn, "weapon_left")
    logFn("  Held Weapon Right: actor=" .. SafeObjName(rActor) .. " | mesh=" .. SafeObjName(rMesh))
    logFn("  Held Weapon Left : actor=" .. SafeObjName(lActor) .. " | mesh=" .. SafeObjName(lMesh))

    pcall(function()
        local mesh = pawn.Mesh
        if IsValidUObject(mesh) then
            local animInst = mesh:GetAnimInstance()
            if IsValidUObject(animInst) then
                local curMont = animInst:GetCurrentActiveMontage()
                if IsValidUObject(curMont) then
                    local seqLen = 0.0
                    pcall(function() seqLen = tonumber(curMont.SequenceLength) or 0.0 end)
                    local slots = {}
                    pcall(function()
                        if curMont.SlotAnimTracks then
                            curMont.SlotAnimTracks:ForEach(function(_, elem)
                                pcall(function()
                                    local sn = elem:get().SlotName
                                    if sn ~= nil then table.insert(slots, sn:ToString()) end
                                end)
                            end)
                        end
                    end)
                    local secs = {}
                    pcall(function()
                        if curMont.CompositeSections then
                            curMont.CompositeSections:ForEach(function(_, elem)
                                pcall(function()
                                    local sn = elem:get().SectionName
                                    if sn ~= nil then table.insert(secs, sn:ToString()) end
                                end)
                            end)
                        end
                    end)
                    logFn(string.format("  Active Montage: %s (len=%.2fs, slots=[%s], sections=[%s])",
                        SafeObjName(curMont), seqLen, table.concat(slots, ","), table.concat(secs, ",")))
                else
                    logFn("  Active Montage: None (cast a spell then hit SHIFT+DebugHotkey to inspect)")
                end
            end
        end
    end)
    logFn("  Active Montage inspection complete.")
end

-- Parse an existing detected_vfx.txt or vfx_names.txt (shortName = /Game/... path) into a lookup table.
function TimelineRunner.LoadVfxCatalogFile(filePath, outLookup)
    local map = outLookup or {}
    if not filePath or filePath == "" then return map end
    local f = io.open(filePath, "r")
    if not f then return map end
    for line in f:lines() do
        local clean = (line:gsub("^%s*(.-)%s*$", "%1"))
        if clean ~= "" and not clean:match("^#") and not clean:match("^;") and not clean:match("^%[") and not clean:match("^===") then
            local k, v = clean:match("^([^=]+)=(.+)$")
            if k and v then
                local kl = (k:gsub("^%s*(.-)%s*$", "%1")):lower()
                local vp = (v:gsub("^%s*(.-)%s*$", "%1"))
                if kl ~= "" and vp:find("/", 1, true) then
                    map[kl] = vp
                end
            end
        end
    end
    f:close()
    return map
end

-- Auto-discover & persist all loaded NiagaraSystems, SpellVFXActors, and LightningSubsystem VFX
-- into detected_vfx.txt (merging with previously discovered paths so the catalog grows over time).
-- Returns: (vfxLookupMap[shortLower] = fullPath, totalCount, newlyAddedCount)
function TimelineRunner.ExportLoadedVfxFile(outPath, logFn, existingLookup)
    if not outPath or outPath == "" then return existingLookup or {}, 0, 0 end

    local function ExtractObjectPath(fullName)
        if not fullName or fullName == "" then return "" end
        return (fullName:match("^[^%s]+%s+(.+)$") or fullName)
    end

    local function ExtractShortName(objPath)
        if not objPath or objPath == "" then return "" end
        local afterDot = objPath:match("%.([^%.]+)$") or objPath
        return (afterDot:match("/([^/]+)$") or afterDot)
    end

    -- Load previously saved entries so VFX seen in earlier sessions stay available for LoadAsset!
    local catalogByPath = {}
    local lookup = {}
    if existingLookup then
        for k, v in pairs(existingLookup) do
            lookup[k] = v
            catalogByPath[v:lower()] = { short = k, path = v, kind = "niagara" }
        end
    end
    local prevMap = TimelineRunner.LoadVfxCatalogFile(outPath, {})
    for k, v in pairs(prevMap) do
        lookup[k] = v
        if not catalogByPath[v:lower()] then
            catalogByPath[v:lower()] = { short = ExtractShortName(v), path = v, kind = "niagara" }
        end
    end

    local prevCount = 0
    for _ in pairs(catalogByPath) do prevCount = prevCount + 1 end

    local function registerPath(rawPath, kind)
        if not rawPath or rawPath == "" then return end
        local low = rawPath:lower()
        if low:find("default__", 1, true) or low:find("/engine/", 1, true) or low:find("transient", 1, true) then
            return
        end
        if not rawPath:find("/", 1, true) then return end
        local short = ExtractShortName(rawPath)
        if short == "" then return end
        if not catalogByPath[low] then
            catalogByPath[low] = { short = short, path = rawPath, kind = kind or "niagara" }
        end
        local sLow = short:lower()
        if not lookup[sLow] then
            lookup[sLow] = rawPath
        end
    end

    -- 1. LightningSubsystem & ALightning VFX
    local lightningLines = {}
    pcall(function()
        local sub = FindFirstOf("LightningSubsystem")
        if IsValidUObject(sub) then
            local cls = sub.LoadedLightningClass
            if IsValidUObject(cls) then
                local clsPath = ExtractObjectPath(SafeObjName(cls))
                table.insert(lightningLines, "LoadedLightningClass = " .. clsPath)
                pcall(function()
                    local cdo = cls:GetDefaultObject()
                    if IsValidUObject(cdo) then
                        if IsValidUObject(cdo.TriggerDamageVFX) and IsValidUObject(cdo.TriggerDamageVFX.Asset) then
                            local p = ExtractObjectPath(SafeObjName(cdo.TriggerDamageVFX.Asset))
                            table.insert(lightningLines, "TriggerDamageVFX     = " .. p)
                            registerPath(p, "niagara")
                        end
                        if IsValidUObject(cdo.TelegraphDamageVFX) and IsValidUObject(cdo.TelegraphDamageVFX.Asset) then
                            local p = ExtractObjectPath(SafeObjName(cdo.TelegraphDamageVFX.Asset))
                            table.insert(lightningLines, "TelegraphDamageVFX   = " .. p)
                            registerPath(p, "niagara")
                        end
                        if IsValidUObject(cdo.TriggerDamageSound) then
                            table.insert(lightningLines, "TriggerDamageSound   = " .. ExtractObjectPath(SafeObjName(cdo.TriggerDamageSound)))
                        end
                    end
                end)
            end
        end
    end)

    -- 2. Scan all loaded NiagaraSystem assets
    pcall(function()
        local allNs = FindAllOf("NiagaraSystem")
        if allNs then
            for _, ns in ipairs(allNs) do
                if IsValidUObject(ns) then
                    registerPath(ExtractObjectPath(SafeObjName(ns)), "niagara")
                end
            end
        end
    end)

    -- 3. Scan DominionSpellData modules for SpellVFXActor classes & SpawnActor classes
    pcall(function()
        local spells = FindAllOf("DominionSpellData")
        if spells then
            for _, sp in ipairs(spells) do
                if IsValidUObject(sp) then
                    pcall(function()
                        local mods = sp.Modules
                        if mods and mods.Modules then
                            mods.Modules:ForEach(function(_, elemWrapper)
                                local modObj = nil
                                pcall(function() modObj = elemWrapper:get().Module end)
                                if IsValidUObject(modObj) then
                                    pcall(function()
                                        local vfxCls = modObj.SpellVFXActorClass
                                        if IsValidUObject(vfxCls) then
                                            registerPath(ExtractObjectPath(SafeObjName(vfxCls)), "actor")
                                        end
                                    end)
                                end
                            end)
                        end
                    end)
                end
            end
        end
    end)

    -- 4. Scan any loaded SpellVFXActor instances
    pcall(function()
        local allVfxA = FindAllOf("SpellVFXActor")
        if allVfxA then
            for _, a in ipairs(allVfxA) do
                if IsValidUObject(a) then
                    registerPath(ExtractObjectPath(SafeObjName(a)), "actor")
                end
            end
        end
    end)

    -- Categorize cleanly so modders can browse by element/type and copy short names or full paths
    local buckets = {
        { title = "[Lightning & Storm]",         items = {} },
        { title = "[Fire & Explosion]",          items = {} },
        { title = "[Water & Ice]",               items = {} },
        { title = "[Air & Wind]",                items = {} },
        { title = "[Earth & Nature]",            items = {} },
        { title = "[Combat, Spells & Specials]", items = {} },
        { title = "[Spell VFX Actors]",          items = {} },
        { title = "[Other Niagara VFX]",         items = {} }
    }

    local totalCount = 0
    for _, entry in pairs(catalogByPath) do
        totalCount = totalCount + 1
        local low = entry.path:lower()
        if entry.kind == "actor" then
            table.insert(buckets[7].items, entry)
        elseif low:find("lightning", 1, true) or low:find("storm", 1, true) or low:find("thunder", 1, true) or low:find("electric", 1, true) then
            table.insert(buckets[1].items, entry)
        elseif low:find("fire", 1, true) or low:find("flame", 1, true) or low:find("burn", 1, true) or low:find("meteor", 1, true) or low:find("explos", 1, true) or low:find("zamorak", 1, true) then
            table.insert(buckets[2].items, entry)
        elseif low:find("water", 1, true) or low:find("ice", 1, true) or low:find("frost", 1, true) or low:find("wave", 1, true) or low:find("tsunami", 1, true) then
            table.insert(buckets[3].items, entry)
        elseif low:find("air", 1, true) or low:find("wind", 1, true) or low:find("gust", 1, true) or low:find("vortex", 1, true) then
            table.insert(buckets[4].items, entry)
        elseif low:find("earth", 1, true) or low:find("rock", 1, true) or low:find("stone", 1, true) or low:find("boulder", 1, true) or low:find("vine", 1, true) or low:find("guthix", 1, true) then
            table.insert(buckets[5].items, entry)
        elseif low:find("spell", 1, true) or low:find("magic", 1, true) or low:find("godsword", 1, true) or low:find("saradomin", 1, true) or low:find("special", 1, true) or low:find("hit", 1, true) or low:find("impact", 1, true) or low:find("slash", 1, true) or low:find("aoe", 1, true) then
            table.insert(buckets[6].items, entry)
        else
            table.insert(buckets[8].items, entry)
        end
    end

    local newlyAdded = math.max(0, totalCount - prevCount)

    local lines = {
        "# ==============================================================================",
        "# ArcaneWilds Auto-Detected VFX Catalog (detected_vfx.txt)",
        "# ==============================================================================",
        "# Auto-updated on world load, spell scans, and SHIFT + DebugHotkey!",
        "# Previously discovered VFX are remembered across sessions and auto-loaded on demand.",
        "#",
        "# HOW TO USE IN custom_spells.txt:",
        "#   Copy EITHER the short name (left of '=') OR full /Game/... path (right of '=')!",
        "#   Example:",
        "#     VFX = @0.00 | NS_Lightning_Strike | target=impact | scale=0.35 | dur=1.10",
        "#     VFX = &     | /Game/Path/To/NS_FireBurst.NS_FireBurst | target=hit_targets",
        "# ==============================================================================",
        ""
    }

    if #lightningLines > 0 then
        table.insert(lines, "[LightningSubsystem]")
        for _, ll in ipairs(lightningLines) do table.insert(lines, ll) end
        table.insert(lines, "")
    end

    for _, b in ipairs(buckets) do
        if #b.items > 0 then
            table.sort(b.items, function(a, c) return a.short:lower() < c.short:lower() end)
            table.insert(lines, string.format("%s (%d)", b.title, #b.items))
            for _, item in ipairs(b.items) do
                table.insert(lines, string.format("%-42s = %s", item.short, item.path))
            end
            table.insert(lines, "")
        end
    end

    local f = io.open(outPath, "w")
    if f then
        f:write(table.concat(lines, "\n"))
        f:close()
        if logFn and (newlyAdded > 0 or prevCount == 0) then
            logFn(string.format("Updated detected_vfx.txt (%d VFX indexed, +%d new)", totalCount, newlyAdded))
        end
    end
    return lookup, totalCount, newlyAdded
end

TimelineRunner.IsLockOnCurrentlyActive = IsLockOnCurrentlyActive
TimelineRunner.ResolveLockedOnEnemy = ResolveLockedOnEnemy
TimelineRunner.ResolveAimTarget = ResolveAimTarget
TimelineRunner.UncapNiagaraAssetAndComponent = UncapNiagaraAssetAndComponent

return TimelineRunner
