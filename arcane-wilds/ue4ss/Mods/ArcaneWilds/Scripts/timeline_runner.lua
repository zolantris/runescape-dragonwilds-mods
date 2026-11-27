-- ArcaneWilds - Spell Animation & Effects Timeline Runner
-- Executes simultaneous (slot-layered & parallel) and synchronous (chained & crossfaded)
-- player montages, weapon/actor/target animations, Niagara VFX, SFX, Spells, Multi-Hit pulses,
-- Decals, and Camera Shakes with full lifecycle cleanup and combo macro integration.

local TimelineRunner = {}

local TimelineInstanceCounter = 0

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

-- Resolve animation asset (AnimMontage or AnimSequenceBase) with caching.
local function ResolveAnimAsset(assetName, customSpells, safeGetNameFn)
    if not assetName or assetName == "" then return nil, false end
    local obj = nil
    if customSpells and customSpells.FindObjectFast then
        obj = customSpells.FindObjectFast(assetName)
    end
    if not IsValidUObject(obj) and assetName:find("/", 1, true) then
        pcall(function() obj = StaticFindObject(assetName) end)
    end
    if not IsValidUObject(obj) and customSpells and customSpells.FindAssetByKeywordOnDemand then
        obj = customSpells.FindAssetByKeywordOnDemand("AnimMontage", assetName, safeGetNameFn)
        if not IsValidUObject(obj) then
            obj = customSpells.FindAssetByKeywordOnDemand("AnimSequence", assetName, safeGetNameFn)
        end
    end
    if not IsValidUObject(obj) then return nil, false end

    local fullName = SafeObjName(obj):lower()
    local isMontage = fullName:find("animmontage", 1, true) ~= nil or HasUFunc(obj, "GetFirstAnimReference")
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
        if IsValidUObject(ai) and ai ~= pawn then
            local fLow = SafeObjName(ai):lower()
            if fLow ~= "" and fLow ~= pawnLow and not fLow:find("bp_playercharacter", 1, true) and not seen[fLow] then
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

-- Resolve the NPC or world point the player is aiming at (crosshair ray vs ADominionAICharacter).
-- Never returns the player's own feet; falls back to `forward:<fallbackDist>` if no enemy is aimed at.
local function ResolveAimTarget(pawn, maxRange, coneDeg, fallbackDist)
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

    local range = tonumber(maxRange) or 2500.0
    local rSq = range * range
    local cosCone = math.cos(math.rad((tonumber(coneDeg) or 32.0) * 0.5))
    local pitchRad = math.rad(camRot.Pitch or 0.0)
    local yawRad   = math.rad(camRot.Yaw or 0.0)
    local fwdX = math.cos(pitchRad) * math.cos(yawRad)
    local fwdY = math.cos(pitchRad) * math.sin(yawRad)
    local fwdZ = math.sin(pitchRad)

    local bestActor, bestLoc, bestScore = nil, nil, -1.0
    local pawnLow = SafeObjName(pawn):lower()
    pcall(function()
        local aiList = FindAllOf("DominionAICharacter")
        if aiList then
            for _, ai in ipairs(aiList) do
                if IsValidUObject(ai) and ai ~= pawn then
                    local fLow = SafeObjName(ai):lower()
                    if fLow ~= "" and fLow ~= pawnLow and not fLow:find("bp_playercharacter", 1, true) then
                        local aLoc = nil
                        pcall(function() aLoc = ai:K2_GetActorLocation() end)
                        if aLoc then
                            local dx = (aLoc.X or 0) - pLoc.X
                            local dy = (aLoc.Y or 0) - pLoc.Y
                            local dz = (aLoc.Z or 0) - pLoc.Z
                            local distSq = dx * dx + dy * dy + dz * dz
                            if distSq > 100.0 and distSq <= rSq then
                                local cdx = (aLoc.X or 0) - camLoc.X
                                local cdy = (aLoc.Y or 0) - camLoc.Y
                                local cdz = ((aLoc.Z or 0) + 60.0) - camLoc.Z
                                local cLen = math.sqrt(cdx * cdx + cdy * cdy + cdz * cdz)
                                if cLen > 1e-3 then
                                    local dot = (cdx * fwdX + cdy * fwdY + cdz * fwdZ) / cLen
                                    if dot >= cosCone then
                                        -- Strongly prefer closest alignment to crosshair, with mild preference for nearer enemies
                                        local score = dot * 100.0 - (math.sqrt(distSq) / range) * 15.0
                                        if score > bestScore then
                                            bestScore = score
                                            bestActor = ai
                                            bestLoc = MakeVec(aLoc.X, aLoc.Y, aLoc.Z)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)

    if bestLoc then
        return bestLoc, pRot, bestActor
    end
    local fDist = tonumber(fallbackDist) or 700.0
    return LocalOffsetToWorld(pLoc, MakeRot(0.0, camRot.Yaw, 0.0), MakeVec(fDist, 0.0, 0.0)), pRot, nil
end

-- Apply transform scale AND common/explicit Niagara User Parameters so both local-space
-- and world-space Niagara VFX (such as sky lightning bolts) scale cleanly.
local function ApplyNiagaraScaleAndParams(comp, scale, cueParams, isAttached)
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
local function ComputeTargetTransforms(tlInst, pawn, cueParams)
    local targetStr = (cueParams.target or "player"):lower()
    local baseLoc, baseRot = GetActorLocAndRot(pawn)
    local attachComp = nil

    if targetStr == "impact" then
        if tlInst.impactLoc then
            baseLoc = tlInst.impactLoc
        else
            local aimLoc, aimRot = ResolveAimTarget(pawn, cueParams.range or 2500.0, cueParams.cone or 32.0, 700.0)
            baseLoc, baseRot = aimLoc, aimRot
        end
    elseif targetStr == "aim" or targetStr == "crosshair" or targetStr == "look" or targetStr == "aimed_enemy" then
        local aimLoc, aimRot = ResolveAimTarget(pawn, cueParams.range or 2500.0, cueParams.cone or 32.0, 700.0)
        baseLoc, baseRot = aimLoc, aimRot
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
            local aimLoc, aimRot = ResolveAimTarget(pawn, cueParams.range or 2500.0, cueParams.cone or 32.0, 700.0)
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
            if debugLogFn then debugLogFn("Timeline [" .. tlInst.spellName .. "] Anim asset not found: " .. tostring(cue.asset)) end
            cueState.expectedDur = 0.0
            return
        end

        local baseRate = tonumber(p.rate) or 1.0
        local effectiveRate = scaleSpeed and (baseRate * stageSpeed) or baseRate
        local assetLow = tostring(cue.asset or ""):lower()
        local isHeavyWeaponMont = assetLow:find("greatsword", 1, true) ~= nil or assetLow:find("godsword", 1, true) ~= nil or assetLow:find("special", 1, true) ~= nil
        if isHeavyWeaponMont and p.unsafeRate ~= "true" then
            -- Keep Greatsword/Special AnimNotifyState windows safe from notify-skipping
            effectiveRate = math.min(effectiveRate, 1.35)
        elseif tlInst.entry and tlInst.entry.isSmash and config and config.KeepGroundSmashAnchored then
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
            if customSpells and customSpells.FindObjectFast then
                vfxObj = customSpells.FindObjectFast(cue.asset)
            end
            if not IsValidUObject(vfxObj) and customSpells and customSpells.FindAssetByKeywordOnDemand then
                vfxObj = customSpells.FindAssetByKeywordOnDemand("NiagaraSystem", cue.asset, safeGetNameFn)
            end
        end
        if not IsValidUObject(vfxObj) then
            if debugLogFn then debugLogFn("Timeline [" .. tlInst.spellName .. "] VFX asset not found: " .. tostring(cue.asset)) end
            cueState.expectedDur = 0.0
            return
        end

        local nsLib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
        if not IsValidUObject(nsLib) then return end

        local scale = p.scale or MakeVec(1.0, 1.0, 1.0)
        local transforms, defaultAttachComp = ComputeTargetTransforms(tlInst, pawn, p)
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
            if customSpells and customSpells.FindObjectFast then
                sfxObj = customSpells.FindObjectFast(cue.asset)
            end
            if not IsValidUObject(sfxObj) and customSpells and customSpells.FindAssetByKeywordOnDemand then
                sfxObj = customSpells.FindAssetByKeywordOnDemand("SoundBase", cue.asset, safeGetNameFn)
                    or customSpells.FindAssetByKeywordOnDemand("SoundWave", cue.asset, safeGetNameFn)
            end
        end
        if not IsValidUObject(sfxObj) then
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
            if debugLogFn then debugLogFn("Timeline [" .. tlInst.spellName .. "] Actor class not found: " .. tostring(cue.asset)) end
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
        if IsValidUObject(spObj) then
            pcall(function()
                local bpLib = StaticFindObject("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
                if IsValidUObject(bpLib) and HasUFunc(bpLib, "TriggerModularAbilityForPlayer") then
                    bpLib:TriggerModularAbilityForPlayer(pawn, spObj)
                end
            end)
            if debugLogFn then
                debugLogFn(string.format("Timeline [%s] Spell #%d triggered: %s", tlInst.spellName, cue.index, tostring(cue.asset)))
            end
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
            cueState.trackedProjectile = nil
            -- Snapshot existing projectiles so we only latch onto the newly spawned one
            cueState.preExistingProj = {}
            pcall(function()
                local projs = FindAllOf("DominionSpellProjectile")
                if projs then
                    for _, pr in ipairs(projs) do
                        if IsValidUObject(pr) then cueState.preExistingProj[SafeObjName(pr)] = true end
                    end
                end
            end)
            cueState.expectedDur = cueState.impactTimeout
        else
            cueState.expectedDur = (p.dur ~= nil) and (scaleSpeed and (p.dur / stageSpeed) or p.dur) or 0.0
        end

    elseif cType == "hit" then
        local transforms = ComputeTargetTransforms(tlInst, pawn, p)
        local centerTf = transforms[1] or { loc = select(1, GetActorLocAndRot(pawn)), rot = select(2, GetActorLocAndRot(pawn)) }
        tlInst.lastHitCenter = centerTf.loc
        if customSpells and customSpells.ExecuteHitPulse then
            local _, hitList = customSpells.ExecuteHitPulse(pawn, centerTf.loc, centerTf.rot, p, tlInst.entry, safeGetNameFn, debugLogFn)
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
        if not IsValidUObject(matObj) then return end
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
        if not IsValidUObject(shakeClass) then return end
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
            if cs and cs.status == "active" then
                pcall(function() CleanupCueHandles(cue, cs, true, pawn) end)
                cs.status = "done"
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
        elseif item.kind == "poll_spell_impact" then
                local cs = item.cueState
                local tl = item.tlInst
                if cs.status == "active" then
                    local age = item.now - (cs.startedAt or item.now)
                    -- 1. Track newly spawned DominionSpellProjectile in flight
                    if not IsValidUObject(cs.trackedProjectile) then
                        pcall(function()
                            local projs = FindAllOf("DominionSpellProjectile")
                            if projs then
                                for _, pr in ipairs(projs) do
                                    if IsValidUObject(pr) and not (cs.preExistingProj and cs.preExistingProj[SafeObjName(pr)]) then
                                        cs.trackedProjectile = pr
                                        cs.sawSpellActor = true
                                        break
                                    end
                                end
                            end
                        end)
                    end

                    local activeObj = nil
                    if IsValidUObject(cs.trackedProjectile) then
                        activeObj = cs.trackedProjectile
                    elseif IsValidUObject(combatMagic) then
                        pcall(function()
                            local sa = combatMagic.CurrentSpellActor
                            if IsValidUObject(sa) then
                                activeObj = sa
                                cs.sawSpellActor = true
                                -- Also check DominionSpellActor::GetTargetInfo().Location
                                if HasUFunc(sa, "GetTargetInfo") then
                                    local ti = sa:GetTargetInfo()
                                    if ti and ti.Location then
                                        local lx, ly, lz = tonumber(ti.Location.X) or 0, tonumber(ti.Location.Y) or 0, tonumber(ti.Location.Z) or 0
                                        if math.abs(lx) + math.abs(ly) + math.abs(lz) > 1.0 then
                                            cs.spellTargetInfoLoc = MakeVec(lx, ly, lz)
                                        end
                                    end
                                end
                            end
                        end)
                    end

                    local stillFlying = false
                    if IsValidUObject(activeObj) then
                        stillFlying = true
                        pcall(function()
                            local aLoc = activeObj:K2_GetActorLocation()
                            if aLoc then
                                local orig = cs.castOriginLoc or MakeVec(0, 0, 0)
                                local dx = (aLoc.X or 0) - orig.X
                                local dy = (aLoc.Y or 0) - orig.Y
                                local dz = (aLoc.Z or 0) - orig.Z
                                if (dx * dx + dy * dy + dz * dz) > 2500.0 then -- > 50cm away from player
                                    cs.lastTrackedLoc = MakeVec(aLoc.X, aLoc.Y, aLoc.Z)
                                end
                            end
                        end)
                    end

                    local impacted = item.forceFinish or (cs.sawSpellActor and not stillFlying and age >= 0.12) or (not cs.sawSpellActor and age >= 0.45)
                    if impacted then
                        local finalLoc = cs.lastTrackedLoc or cs.spellTargetInfoLoc
                        -- If projectile never moved away from player, snap to aimed enemy/crosshair instead of player's feet!
                        if not finalLoc then
                            finalLoc = select(1, ResolveAimTarget(pawn, 2500.0, 32.0, 700.0))
                        else
                            -- Snap cleanly onto any nearby enemy within 250cm of impact so lightning frames the NPC!
                            local nearEnemies = FindNearbyEnemyTargets(pawn, finalLoc, MakeRot(0, 0, 0), 250.0, nil, 1)
                            if nearEnemies and nearEnemies[1] then
                                finalLoc = nearEnemies[1].loc
                            end
                        end
                        tl.impactLoc = finalLoc
                        cs.trackingImpact = false
                        cs.status = "done"
                        cs.endedAt = item.now
                        if debugLogFn and finalLoc then
                            debugLogFn(string.format("Timeline [%s] Spell #%d impacted at [%.0f, %.0f, %.0f] (age=%.2fs)",
                                tl.spellName, item.cue.index, finalLoc.X, finalLoc.Y, finalLoc.Z, age))
                        end
                    end
                end
            end
        end
    end

    if type(ExecuteInGameThread) == "function" then
        pcall(function() ExecuteInGameThread(runBatchOnGameThread) end)
    else
        runBatchOnGameThread()
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

-- Export all currently loaded NiagaraSystems, ParticleSystems, SpellVFXActors, and Lightning classes
-- to detected_vfx.txt so authors can copy exact /Game/... paths without fighting UE4SS Live View.
function TimelineRunner.ExportLoadedVfxFile(outPath, logFn)
    if not outPath or outPath == "" then return end

    local lines = {
        "=== ArcaneWilds Loaded VFX & Spell Effect Asset Dump ===",
        "Generated via SHIFT + DebugHotkey. Copy any /Game/... path directly into custom_spells.txt VFX= or Actor= lines!",
        "UE4SS Live View Tip: Search 'NiagaraSystem' or 'NS_' or 'SpellVFXActor' in the Instances/Search box.",
        ""
    }

    local function ExtractObjectPath(fullName)
        if not fullName or fullName == "" then return "" end
        -- Convert "NiagaraSystem /Game/Foo/NS_Bar.NS_Bar" -> "/Game/Foo/NS_Bar.NS_Bar"
        return (fullName:match("^[^%s]+%s+(.+)$") or fullName)
    end

    -- 1. Highlight LightningSubsystem & ALightning VFX specifically
    table.insert(lines, "=== LIGHTNING SUBSYSTEM ASSETS ===")
    local foundSub = false
    pcall(function()
        local sub = FindFirstOf("LightningSubsystem")
        if IsValidUObject(sub) then
            local cls = sub.LoadedLightningClass
            if IsValidUObject(cls) then
                foundSub = true
                table.insert(lines, "  LoadedLightningClass: " .. ExtractObjectPath(SafeObjName(cls)))
                pcall(function()
                    local cdo = cls:GetDefaultObject()
                    if IsValidUObject(cdo) then
                        if IsValidUObject(cdo.TriggerDamageVFX) and IsValidUObject(cdo.TriggerDamageVFX.Asset) then
                            table.insert(lines, "  TriggerDamageVFX    : " .. ExtractObjectPath(SafeObjName(cdo.TriggerDamageVFX.Asset)))
                        end
                        if IsValidUObject(cdo.TelegraphDamageVFX) and IsValidUObject(cdo.TelegraphDamageVFX.Asset) then
                            table.insert(lines, "  TelegraphDamageVFX  : " .. ExtractObjectPath(SafeObjName(cdo.TelegraphDamageVFX.Asset)))
                        end
                        if IsValidUObject(cdo.TriggerDamageSound) then
                            table.insert(lines, "  TriggerDamageSound  : " .. ExtractObjectPath(SafeObjName(cdo.TriggerDamageSound)))
                        end
                    end
                end)
            end
        end
    end)
    if not foundSub then
        table.insert(lines, "  (LightningSubsystem.LoadedLightningClass not loaded yet — cast/visit storm or check Niagara list below)")
    end
    table.insert(lines, "")

    -- 2. All loaded NiagaraSystems (split into Combat/Elemental/Lightning highlights vs All)
    local highlightVfx, otherVfx = {}, {}
    local seen = {}
    pcall(function()
        local allNs = FindAllOf("NiagaraSystem")
        if allNs then
            for _, ns in ipairs(allNs) do
                if IsValidUObject(ns) then
                    local path = ExtractObjectPath(SafeObjName(ns))
                    local low = path:lower()
                    if path ~= "" and not low:find("default__", 1, true) and not seen[low] then
                        seen[low] = true
                        if low:find("lightning", 1, true) or low:find("storm", 1, true) or low:find("thunder", 1, true)
                            or low:find("spell", 1, true) or low:find("magic", 1, true) or low:find("fire", 1, true)
                            or low:find("flame", 1, true) or low:find("water", 1, true) or low:find("ice", 1, true)
                            or low:find("air", 1, true) or low:find("wind", 1, true) or low:find("earth", 1, true)
                            or low:find("godsword", 1, true) or low:find("special", 1, true) or low:find("impact", 1, true)
                            or low:find("hit", 1, true) or low:find("aoe", 1, true) or low:find("explosion", 1, true) then
                            table.insert(highlightVfx, path)
                        else
                            table.insert(otherVfx, path)
                        end
                    end
                end
            end
        end
    end)
    table.sort(highlightVfx)
    table.sort(otherVfx)

    table.insert(lines, string.format("=== COMBAT / ELEMENTAL / LIGHTNING NIAGARA VFX (%d) ===", #highlightVfx))
    for _, p in ipairs(highlightVfx) do table.insert(lines, "  " .. p) end
    table.insert(lines, "")

    -- 3. SpellVFXActor classes
    local vfxActors = {}
    pcall(function()
        local allVfxA = FindAllOf("SpellVFXActor")
        if allVfxA then
            for _, a in ipairs(allVfxA) do
                if IsValidUObject(a) then
                    local path = ExtractObjectPath(SafeObjName(a))
                    if path ~= "" then table.insert(vfxActors, path) end
                end
            end
        end
    end)
    table.sort(vfxActors)
    table.insert(lines, string.format("=== LOADED SPELL VFX ACTORS (%d) ===", #vfxActors))
    for _, p in ipairs(vfxActors) do table.insert(lines, "  " .. p) end
    table.insert(lines, "")

    table.insert(lines, string.format("=== OTHER LOADED NIAGARA SYSTEMS (%d) ===", #otherVfx))
    for _, p in ipairs(otherVfx) do table.insert(lines, "  " .. p) end
    table.insert(lines, "")

    local f = io.open(outPath, "w")
    if f then
        f:write(table.concat(lines, "\n"))
        f:close()
        if logFn then
            logFn(string.format("Exported %d combat/lightning VFX + %d other NiagaraSystems to detected_vfx.txt", #highlightVfx, #otherVfx))
        end
    end
end

return TimelineRunner
