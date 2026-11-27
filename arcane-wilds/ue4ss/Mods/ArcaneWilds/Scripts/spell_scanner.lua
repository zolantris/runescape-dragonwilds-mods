-- Arcane Wilds - Direct Asset Discovery, Montage Indexing & Sequence Chain Builder

local SpellScanner = {}

local ESPELL_STATE_TRIGGER_IMMEDIATE = 0
local ESPELL_STATE_TRIGGER_FINISHED_CASTING = 1
local ERELATIVE_SPACE_CASTER_FORWARD = 0
local ERELATIVE_SPACE_TRACED_CAMERA_FORWARD = 2

local _MovementSnapshots = {}
local _AimSnapshots = {}
local _LastAimPatchState = {}

function SpellScanner.ClearSnapshots()
    _MovementSnapshots = {}
    _AimSnapshots = {}
    _LastAimPatchState = {}
end

local function SafeFNameToString(fn)
    if fn == nil then return "" end
    if type(fn) == "string" then return fn end
    local ok, s = pcall(function() return fn:ToString() end)
    if ok and type(s) == "string" then return s end
    return tostring(fn)
end

local function ReadVec3(v)
    if not v then return nil, nil, nil end
    local x, y, z = nil, nil, nil
    pcall(function()
        x = tonumber(v.X)
        y = tonumber(v.Y)
        z = tonumber(v.Z)
    end)
    return x, y, z
end

local function WriteVec3(ownerObj, propName, x, y, z)
    local written = false
    pcall(function()
        local cur = ownerObj[propName]
        if cur ~= nil then
            cur.X = x
            cur.Y = y
            cur.Z = z
            written = true
        end
    end)
    if not written then
        pcall(function()
            ownerObj[propName] = { X = x, Y = y, Z = z }
        end)
    end
end

local function SnapshotAndPatchMontageRootMotion(montage, unlock)
    if not montage then return end
    local okV, valid = pcall(function() return montage:IsValid() end)
    if not okV or not valid then return end
    local key = "mont:" .. SpellScanner.SafeGetName(montage)
    local snap = _MovementSnapshots[key]
    if not snap then
        snap = {}
        pcall(function() snap.bEnableRootMotionTranslation = montage.bEnableRootMotionTranslation end)
        pcall(function() snap.bEnableRootMotionRotation = montage.bEnableRootMotionRotation end)
        _MovementSnapshots[key] = snap
    end
    if unlock then
        pcall(function() montage.bEnableRootMotionTranslation = false end)
        pcall(function() montage.bEnableRootMotionRotation = false end)
    else
        if snap.bEnableRootMotionTranslation ~= nil then
            pcall(function() montage.bEnableRootMotionTranslation = snap.bEnableRootMotionTranslation end)
        end
        if snap.bEnableRootMotionRotation ~= nil then
            pcall(function() montage.bEnableRootMotionRotation = snap.bEnableRootMotionRotation end)
        end
    end
end

local function PatchPlayMontageMovement(modObj, unlock, maxMoveSpeed)
    local key = "play:" .. SpellScanner.SafeGetName(modObj)
    local snap = _MovementSnapshots[key]
    if not snap then
        snap = {}
        pcall(function() snap.bShouldBlockMovement = modObj.bShouldBlockMovement end)
        pcall(function() snap.bBlockMovement = modObj.bBlockMovement end)
        pcall(function() snap.MaxMovementSpeedDuringMontage = modObj.MaxMovementSpeedDuringMontage end)
        pcall(function() snap.MaxMovementSpeed = modObj.MaxMovementSpeed end)
        _MovementSnapshots[key] = snap
    end

    pcall(function() modObj.bAllowTriggeringNotifiesMultipleTimes = true end)

    local spd = tonumber(maxMoveSpeed) or 600.0
    if unlock then
        pcall(function() modObj.bShouldBlockMovement = false end)
        pcall(function() modObj.bBlockMovement = false end)
        pcall(function() modObj.MaxMovementSpeedDuringMontage = spd end)
        pcall(function() modObj.MaxMovementSpeed = spd end)
    else
        if snap.bShouldBlockMovement ~= nil then
            pcall(function() modObj.bShouldBlockMovement = snap.bShouldBlockMovement end)
        end
        if snap.bBlockMovement ~= nil then
            pcall(function() modObj.bBlockMovement = snap.bBlockMovement end)
        end
        if snap.MaxMovementSpeedDuringMontage ~= nil then
            pcall(function() modObj.MaxMovementSpeedDuringMontage = snap.MaxMovementSpeedDuringMontage end)
        end
        if snap.MaxMovementSpeed ~= nil then
            pcall(function() modObj.MaxMovementSpeed = snap.MaxMovementSpeed end)
        end
    end

    local m, altM = nil, nil
    pcall(function() m = modObj.Montage end)
    pcall(function() altM = modObj.AlternativeMontage end)
    if m then SnapshotAndPatchMontageRootMotion(m, unlock) end
    if altM then SnapshotAndPatchMontageRootMotion(altM, unlock) end
    pcall(function()
        local heldMap = modObj.HeldEquipmentCategoryToMontage
        if heldMap and type(heldMap.ForEach) == "function" then
            heldMap:ForEach(function(_, valWrapper)
                local hm = nil
                pcall(function() hm = valWrapper:get() end)
                if hm then SnapshotAndPatchMontageRootMotion(hm, unlock) end
            end)
        end
    end)
    return m
end

local function PatchStopMovementModule(modObj, unlock)
    local key = "stopmove:" .. SpellScanner.SafeGetName(modObj)
    local snap = _MovementSnapshots[key]
    if not snap then
        snap = {}
        pcall(function()
            local trig = modObj.Triggers
            if trig then
                snap.bHasStateTrigger = trig.bHasStateTrigger
                snap.StateTrigger = trig.StateTrigger
                snap.AnimNotifyClass = trig.AnimNotifyClass
                if trig.PlayMontageRef then
                    snap.PlayMontageRefName = SafeFNameToString(trig.PlayMontageRef.ModuleName)
                end
                if trig.CollisionRef then
                    snap.CollisionRefName = SafeFNameToString(trig.CollisionRef.ModuleName)
                end
            end
        end)
        _MovementSnapshots[key] = snap
    end

    pcall(function()
        local trig = modObj.Triggers
        if not trig then return end
        if unlock then
            trig.bHasStateTrigger = false
            pcall(function() trig.AnimNotifyClass = nil end)
            if trig.PlayMontageRef then
                pcall(function() trig.PlayMontageRef.ModuleName = FName("None") end)
            end
            if trig.CollisionRef then
                pcall(function() trig.CollisionRef.ModuleName = FName("None") end)
            end
        else
            if snap.bHasStateTrigger ~= nil then
                trig.bHasStateTrigger = snap.bHasStateTrigger
            end
            if snap.StateTrigger ~= nil then
                trig.StateTrigger = snap.StateTrigger
            end
            if snap.AnimNotifyClass ~= nil then
                pcall(function() trig.AnimNotifyClass = snap.AnimNotifyClass end)
            end
            if trig.PlayMontageRef and snap.PlayMontageRefName and snap.PlayMontageRefName ~= "" then
                pcall(function() trig.PlayMontageRef.ModuleName = FName(snap.PlayMontageRefName) end)
            end
            if trig.CollisionRef and snap.CollisionRefName and snap.CollisionRefName ~= "" then
                pcall(function() trig.CollisionRef.ModuleName = FName(snap.CollisionRefName) end)
            end
        end
    end)
end

function SpellScanner.SafeGetName(obj)
    if not obj then return "" end
    local ok, isValid = pcall(function() return obj:IsValid() end)
    if not ok or not isValid then return "" end
    local okF, full = pcall(function() return obj:GetFullName() end)
    if okF and type(full) == "string" and full ~= "" then
        return full
    end
    local okN, fname = pcall(function() return obj:GetFName():ToString() end)
    if okN and type(fname) == "string" then
        return fname
    end
    return ""
end

function SpellScanner.ExtractShortObjectName(fullName)
    if not fullName or fullName == "" then return "" end
    local afterColon = fullName:match(":([^:]+)$") or fullName
    local afterDot = afterColon:match("%.([^%.]+)$") or afterColon
    local afterSlash = afterDot:match("/([^/]+)$") or afterDot
    return (afterSlash:gsub("^%s*(.-)%s*$", "%1"))
end

function SpellScanner.ClassifySpellAsset(fullName, shortName)
    if not fullName or fullName == "" then return nil, nil, false end
    local lowerFull = fullName:lower()
    local lowerShort = (shortName or SpellScanner.ExtractShortObjectName(fullName)):lower()

    if lowerFull:find("/spells/fishing/") or lowerFull:find("/spells/farming/")
        or lowerFull:find("/spells/weapons/") then
        return nil, nil, false
    end

    local isSpecialSpell = lowerFull:find("/spells/specials/") ~= nil or lowerShort:find("_special") ~= nil
    local isModded = lowerFull:find("/game/mods/") ~= nil or lowerShort:find("^da_conjurer") ~= nil
        or lowerShort:find("ham_") ~= nil or lowerShort:find("ancientstaff") ~= nil
    local isPlayerCombat = lowerFull:find("/spells/combat/") ~= nil

    if not isPlayerCombat and not isModded and not isSpecialSpell then
        return nil, nil, false
    end

    local stepDigits = lowerShort:match("_(%d%d?)_new$") or lowerShort:match("_(%d%d?)$")
    local stepIdx = 0
    if stepDigits then
        stepIdx = math.max(0, math.min(3, (tonumber(stepDigits) or 1) - 1))
    end

    local isHold = lowerShort:find("_hold") ~= nil or lowerShort:find("secondary_") ~= nil
    local isWand = lowerShort:find("_wand") ~= nil

    local baseElem = nil
    if lowerFull:find("/combat/fire/") or lowerShort:find("_fire") then
        baseElem = "Fire"
    elseif lowerFull:find("/combat/water/") or lowerShort:find("_water") then
        baseElem = "Water"
    elseif lowerFull:find("/combat/air/") or lowerShort:find("_air") then
        baseElem = "Air"
    elseif lowerFull:find("/combat/earth/") or lowerShort:find("_earth") then
        baseElem = "Earth"
    end

    if isPlayerCombat and baseElem then
        if isHold then
            return baseElem .. "_Hold", 0, false
        elseif isWand then
            return baseElem .. "_Wand", stepIdx, false
        else
            return baseElem, stepIdx, false
        end
    end

    local conjElem = shortName:match("^[Dd][Aa]_([Cc]onjurer[%a]+)_%d+")
    if conjElem then
        return conjElem, stepIdx, true
    end

    if lowerShort:find("ham_") then
        local hamTag = shortName:match("[Hh][Aa][Mm]_([%w_]+)")
        if hamTag then
            hamTag = hamTag:gsub("_%d+$", ""):gsub("_[Nn][Ee][Ww]$", "")
            return hamTag, stepIdx, true
        end
    end

    if lowerShort:find("ancientstaff") then
        local ancTag = shortName:match("[Aa]ncient[Ss]taff[_%-]?([%w_]+)")
        if ancTag and ancTag ~= "" then
            ancTag = ancTag:gsub("_%d+$", ""):gsub("_[Nn][Ee][Ww]$", "")
            return "AncientStaff_" .. ancTag, stepIdx, true
        end
        return "AncientStaff", stepIdx, true
    end

    if isSpecialSpell then
        local specTag = shortName:match("^[Dd][Aa]_([%w_]+)_Special") or shortName:gsub("^[Dd][Aa]_", ""):gsub("_[Ss]pecial.*$", "")
        if not specTag or specTag == "" then specTag = "Special" end
        return "Special_" .. specTag, 0, true
    end

    return nil, nil, false
end

function SpellScanner.ClassifyEquippedName(nameStr)
    if not nameStr or nameStr == "" then return nil end
    local lower = nameStr:lower()
    if lower:find("conjurer") then
        local cTag = nameStr:match("[Cc]onjurer[%a]+")
        if cTag then return cTag end
    end
    if lower:find("ham_") then
        local hamTag = nameStr:match("[Hh][Aa][Mm]_([%w_]+)")
        if hamTag then
            return hamTag:gsub("_%d+$", ""):gsub("_[Nn][Ee][Ww]$", "")
        end
    end
    if lower:find("ancientstaff") then
        return "AncientStaff"
    end
    if lower:find("fire") or lower:find("flame") then return "Fire" end
    if lower:find("water") or lower:find("ice") then return "Water" end
    if lower:find("air") or lower:find("wind") then return "Air" end
    if lower:find("earth") then return "Earth" end
    return nil
end

local function ShouldUnlockCategory(catLower, isModded, cfg)
    if isModded then return cfg.UnlockModdedCombat end
    if catLower:find("^air") then return cfg.UnlockAir end
    if catLower:find("^fire") then return cfg.UnlockFire end
    if catLower:find("^water") then return cfg.UnlockWater end
    if catLower:find("^earth") then return cfg.UnlockEarth end
    return cfg.UnlockModdedCombat
end

local function ExtractCostItemsFromModule(modObj, costList)
    if not modObj or not modObj:IsValid() then return end
    local modFull = SpellScanner.SafeGetName(modObj)
    local modLower = modFull:lower()
    if not (modLower:find("costitems") or modLower:find("costrune") or modLower:find("costammo") or modLower:find("spellmodule_cost")) then
        return
    end
    -- Skip pure stamina/special charge modules
    if modLower:find("coststamina") or modLower:find("costspecialcharge") or modLower:find("costmana") then
        return
    end

    -- Inspect common array/struct properties on Dominion SpellModule_CostItems / CostRunes
    local arrayProps = { "Items", "RequiredItems", "CostItems", "Runes", "ItemCosts", "Costs" }
    for _, prop in ipairs(arrayProps) do
        pcall(function()
            local arr = modObj[prop]
            if arr and type(arr) == "userdata" then
                arr:ForEach(function(_, elemWrapper)
                    local elem = nil
                    pcall(function() elem = elemWrapper:get() end)
                    if elem then
                        local itemData = nil
                        local qty = 1
                        pcall(function() itemData = elem.ItemData or elem.Item or elem.RuneData or elem.Data end)
                        pcall(function() qty = tonumber(elem.Quantity or elem.Count or elem.Amount or 1) or 1 end)
                        if itemData and itemData:IsValid() then
                            table.insert(costList, {
                                itemData = itemData,
                                itemName = SpellScanner.ExtractShortObjectName(SpellScanner.SafeGetName(itemData)),
                                count = math.max(1, math.floor(qty))
                            })
                        end
                    end
                end)
            end
        end)
    end

    -- Also check single ItemData / Item property directly on the module
    pcall(function()
        local singleItem = modObj.ItemData or modObj.RequiredItem or modObj.RuneItem
        if singleItem and singleItem:IsValid() then
            local qty = tonumber(modObj.Quantity or modObj.Count or modObj.Amount or 1) or 1
            table.insert(costList, {
                itemData = singleItem,
                itemName = SpellScanner.ExtractShortObjectName(SpellScanner.SafeGetName(singleItem)),
                count = math.max(1, math.floor(qty))
            })
        end
    end)
end

function SpellScanner.UnlockSpellMovement(spellObj, maxMoveSpeed)
    if not spellObj then return end
    local okV, valid = pcall(function() return spellObj:IsValid() end)
    if not okV or not valid then return end
    local spd = tonumber(maxMoveSpeed) or 600.0
    pcall(function()
        local mods = spellObj.Modules
        if mods and mods.Modules then
            mods.Modules:ForEach(function(_, elemWrapper)
                local modObj = nil
                pcall(function() modObj = elemWrapper:get().Module end)
                if modObj and modObj:IsValid() then
                    local modFull = SpellScanner.SafeGetName(modObj)
                    if modFull:find("SpellModule_PlayMontage") or modFull:find("SpellModule_PlayStagedMontage") then
                        PatchPlayMontageMovement(modObj, true, spd)
                    elseif modFull:find("SpellModule_StopMovementImmediately") then
                        PatchStopMovementModule(modObj, true)
                    end
                end
            end)
        end
    end)
end

local function PatchSpellModules(spellObj, cfg, chainEntry, idx, lowerName)
    local shouldUnlock = chainEntry and ShouldUnlockCategory(chainEntry.tag:lower(), chainEntry.isModded, cfg) or (cfg.UnlockModdedCombat ~= false)
    local isSmash = (idx == 3 and chainEntry and (chainEntry.tag:lower():find("^air") or lowerName:find("slam") or lowerName:find("smash")))
    local effectiveUnlock = shouldUnlock and not (isSmash and cfg.KeepGroundSmashAnchored == true)
    local foundMontage = nil
    local foundMontageName = nil
    local costItems = {}

    pcall(function()
        local mods = spellObj.Modules
        if mods and mods.Modules then
            mods.Modules:ForEach(function(_, elemWrapper)
                local modObj = nil
                pcall(function() modObj = elemWrapper:get().Module end)
                if modObj and modObj:IsValid() then
                    local modFull = SpellScanner.SafeGetName(modObj)
                    if modFull:find("SpellModule_PlayMontage") or modFull:find("SpellModule_PlayStagedMontage") then
                        local montage = PatchPlayMontageMovement(modObj, effectiveUnlock, cfg.MaxMoveSpeed)
                        if montage and montage:IsValid() then
                            foundMontage = montage
                            foundMontageName = SpellScanner.ExtractShortObjectName(SpellScanner.SafeGetName(montage))
                            if chainEntry then
                                chainEntry.montages[idx] = montage
                                chainEntry.montageNames[idx] = foundMontageName
                            end
                        end
                    elseif modFull:find("SpellModule_StopMovementImmediately") then
                        PatchStopMovementModule(modObj, effectiveUnlock)
                    else
                        ExtractCostItemsFromModule(modObj, costItems)
                    end
                end
            end)
        end
    end)

    return foundMontage, foundMontageName, costItems
end

local function CollectAirReferenceAimConfig(chain)
    local ref = {
        transformRotSpace = ERELATIVE_SPACE_TRACED_CAMERA_FORWARD,
        transformTraceDist = 5000.0,
        movePitchSpace = ERELATIVE_SPACE_TRACED_CAMERA_FORWARD,
        moveYawSpace = ERELATIVE_SPACE_TRACED_CAMERA_FORWARD,
        moveTraceDist = 5000.0,
        moveIgnoreDist = nil,
        moveAimStraightDist = nil,
        rotateToCameraForward = false
    }
    if not chain or not chain.steps then return ref end

    local gotTransformRot = false
    local gotTransformTrace = false
    local gotMovePitch = false
    local gotMoveYaw = false
    local gotMoveTrace = false

    for idx = 0, 2 do
        local sp = chain.steps[idx]
        if sp then
            local okV, valid = pcall(function() return sp:IsValid() end)
            if okV and valid then
                pcall(function()
                    local mods = sp.Modules
                    if not (mods and mods.Modules) then return end
                    mods.Modules:ForEach(function(_, elemWrapper)
                        local modObj = nil
                        pcall(function() modObj = elemWrapper:get().Module end)
                        if not (modObj and modObj:IsValid()) then return end
                        local modFull = SpellScanner.SafeGetName(modObj)
                        if modFull:find("SpellModule_Transform") then
                            pcall(function()
                                local rs = tonumber(modObj.RotationRelativeSpace)
                                if not gotTransformRot and rs and rs ~= ERELATIVE_SPACE_CASTER_FORWARD then
                                    ref.transformRotSpace = rs
                                    gotTransformRot = true
                                end
                                local td = tonumber(modObj.CameraTraceDistance)
                                if not gotTransformTrace and td and td >= 100.0 then
                                    ref.transformTraceDist = td
                                    gotTransformTrace = true
                                end
                            end)
                        elseif modFull:find("SpellModule_Movement") then
                            pcall(function()
                                local ps = tonumber(modObj.PitchRelativeSpace)
                                if not gotMovePitch and ps and ps ~= ERELATIVE_SPACE_CASTER_FORWARD then
                                    ref.movePitchSpace = ps
                                    gotMovePitch = true
                                end
                                local ys = tonumber(modObj.YawRelativeSpace)
                                if not gotMoveYaw and ys and ys ~= ERELATIVE_SPACE_CASTER_FORWARD then
                                    ref.moveYawSpace = ys
                                    gotMoveYaw = true
                                end
                                local td = tonumber(modObj.CameraTraceDistance)
                                if not gotMoveTrace and td and td >= 100.0 then
                                    ref.moveTraceDist = td
                                    gotMoveTrace = true
                                end
                                local ig = tonumber(modObj.CameraTraceIgnoreDistance)
                                if ref.moveIgnoreDist == nil and ig and ig > 0.0 then
                                    ref.moveIgnoreDist = ig
                                end
                                local as = tonumber(modObj.DistanceToAimStraightForTarget)
                                if ref.moveAimStraightDist == nil and as and as > 0.0 then
                                    ref.moveAimStraightDist = as
                                end
                            end)
                        elseif modFull:find("SpellModule_PlayMontage") or modFull:find("SpellModule_PlayStagedMontage") then
                            pcall(function()
                                if modObj.bShouldRotateToCameraForward == true then
                                    ref.rotateToCameraForward = true
                                end
                            end)
                        end
                    end)
                end)
            end
        end
    end

    return ref
end

-- Incorporates the "Staff 4th Air Combo Vertical Aim Fix" at runtime on DA_Spell_Primary_Air_04
-- (and Air_Wand_04 if present): fixes FinishedCasting -> Immediate trigger timing, upgrades
-- CasterForward rotation/pitch space to TracedPlayerCameraForward (matching Air hits 1-3), and
-- raises ground-level PositionOffset to torso height (60, 0, 50) so sloped shots never clip the floor.
function SpellScanner.PatchAir4thVerticalAim(spellObj, refChain, enableFix, logFn)
    if not spellObj then return false end
    local okV, valid = pcall(function() return spellObj:IsValid() end)
    if not okV or not valid then return false end

    local refCfg = CollectAirReferenceAimConfig(refChain)
    local shouldEnable = (enableFix ~= false)
    local patchedCount = 0

    pcall(function()
        local mods = spellObj.Modules
        if not (mods and mods.Modules) then return end
        mods.Modules:ForEach(function(_, elemWrapper)
            local modObj = nil
            pcall(function() modObj = elemWrapper:get().Module end)
            if not (modObj and modObj:IsValid()) then return end
            local modFull = SpellScanner.SafeGetName(modObj)

            if modFull:find("SpellModule_Transform") then
                local key = "aim_tf:" .. modFull
                local snap = _AimSnapshots[key]
                if not snap then
                    snap = {}
                    pcall(function()
                        if modObj.Triggers then
                            snap.bHasStateTrigger = modObj.Triggers.bHasStateTrigger
                            snap.StateTrigger = tonumber(modObj.Triggers.StateTrigger)
                        end
                    end)
                    pcall(function() snap.PositionRelativeSpace = tonumber(modObj.PositionRelativeSpace) end)
                    pcall(function() snap.RotationRelativeSpace = tonumber(modObj.RotationRelativeSpace) end)
                    pcall(function() snap.CameraTraceDistance = tonumber(modObj.CameraTraceDistance) end)
                    snap.posX, snap.posY, snap.posZ = ReadVec3(modObj.PositionOffset)
                    _AimSnapshots[key] = snap
                end

                if shouldEnable then
                    pcall(function()
                        if modObj.Triggers and snap.bHasStateTrigger == true
                            and snap.StateTrigger == ESPELL_STATE_TRIGGER_FINISHED_CASTING then
                            modObj.Triggers.StateTrigger = ESPELL_STATE_TRIGGER_IMMEDIATE
                            patchedCount = patchedCount + 1
                        end
                    end)
                    pcall(function()
                        if snap.RotationRelativeSpace == nil or snap.RotationRelativeSpace == ERELATIVE_SPACE_CASTER_FORWARD then
                            modObj.RotationRelativeSpace = refCfg.transformRotSpace
                            patchedCount = patchedCount + 1
                        end
                    end)
                    pcall(function()
                        if (snap.CameraTraceDistance or 0.0) < 100.0 then
                            modObj.CameraTraceDistance = refCfg.transformTraceDist
                            patchedCount = patchedCount + 1
                        end
                    end)
                    pcall(function()
                        if snap.posZ ~= nil and snap.posZ < 45.0 then
                            local newX = (snap.posX and snap.posX > 1.0) and snap.posX or 60.0
                            local newY = snap.posY or 0.0
                            local newZ = math.max(snap.posZ, 50.0)
                            modObj.PositionRelativeSpace = ERELATIVE_SPACE_CASTER_FORWARD
                            WriteVec3(modObj, "PositionOffset", newX, newY, newZ)
                            patchedCount = patchedCount + 1
                        end
                    end)
                else
                    pcall(function()
                        if modObj.Triggers and snap.StateTrigger ~= nil then
                            modObj.Triggers.StateTrigger = snap.StateTrigger
                        end
                    end)
                    if snap.PositionRelativeSpace ~= nil then
                        pcall(function() modObj.PositionRelativeSpace = snap.PositionRelativeSpace end)
                    end
                    if snap.RotationRelativeSpace ~= nil then
                        pcall(function() modObj.RotationRelativeSpace = snap.RotationRelativeSpace end)
                    end
                    if snap.CameraTraceDistance ~= nil then
                        pcall(function() modObj.CameraTraceDistance = snap.CameraTraceDistance end)
                    end
                    if snap.posX ~= nil and snap.posY ~= nil and snap.posZ ~= nil then
                        WriteVec3(modObj, "PositionOffset", snap.posX, snap.posY, snap.posZ)
                    end
                end
            elseif modFull:find("SpellModule_Movement") then
                local key = "aim_mv:" .. modFull
                local snap = _AimSnapshots[key]
                if not snap then
                    snap = {}
                    pcall(function()
                        if modObj.Triggers then
                            snap.bHasStateTrigger = modObj.Triggers.bHasStateTrigger
                            snap.StateTrigger = tonumber(modObj.Triggers.StateTrigger)
                        end
                    end)
                    pcall(function() snap.PitchRelativeSpace = tonumber(modObj.PitchRelativeSpace) end)
                    pcall(function() snap.YawRelativeSpace = tonumber(modObj.YawRelativeSpace) end)
                    pcall(function() snap.CameraTraceDistance = tonumber(modObj.CameraTraceDistance) end)
                    pcall(function() snap.CameraTraceIgnoreDistance = tonumber(modObj.CameraTraceIgnoreDistance) end)
                    pcall(function() snap.DistanceToAimStraightForTarget = tonumber(modObj.DistanceToAimStraightForTarget) end)
                    _AimSnapshots[key] = snap
                end

                if shouldEnable then
                    pcall(function()
                        if modObj.Triggers and snap.bHasStateTrigger == true
                            and snap.StateTrigger == ESPELL_STATE_TRIGGER_FINISHED_CASTING then
                            modObj.Triggers.StateTrigger = ESPELL_STATE_TRIGGER_IMMEDIATE
                            patchedCount = patchedCount + 1
                        end
                    end)
                    pcall(function()
                        if snap.PitchRelativeSpace == nil or snap.PitchRelativeSpace == ERELATIVE_SPACE_CASTER_FORWARD then
                            modObj.PitchRelativeSpace = refCfg.movePitchSpace
                            patchedCount = patchedCount + 1
                        end
                    end)
                    pcall(function()
                        if snap.YawRelativeSpace == nil or snap.YawRelativeSpace == ERELATIVE_SPACE_CASTER_FORWARD then
                            modObj.YawRelativeSpace = refCfg.moveYawSpace
                            patchedCount = patchedCount + 1
                        end
                    end)
                    pcall(function()
                        if (snap.CameraTraceDistance or 0.0) < 100.0 then
                            modObj.CameraTraceDistance = refCfg.moveTraceDist
                            patchedCount = patchedCount + 1
                        end
                    end)
                    pcall(function()
                        if (snap.CameraTraceIgnoreDistance or 0.0) <= 0.0 and refCfg.moveIgnoreDist and refCfg.moveIgnoreDist > 0.0 then
                            modObj.CameraTraceIgnoreDistance = refCfg.moveIgnoreDist
                        end
                    end)
                    pcall(function()
                        if (snap.DistanceToAimStraightForTarget or 0.0) <= 0.0 and refCfg.moveAimStraightDist and refCfg.moveAimStraightDist > 0.0 then
                            modObj.DistanceToAimStraightForTarget = refCfg.moveAimStraightDist
                        end
                    end)
                else
                    pcall(function()
                        if modObj.Triggers and snap.StateTrigger ~= nil then
                            modObj.Triggers.StateTrigger = snap.StateTrigger
                        end
                    end)
                    if snap.PitchRelativeSpace ~= nil then
                        pcall(function() modObj.PitchRelativeSpace = snap.PitchRelativeSpace end)
                    end
                    if snap.YawRelativeSpace ~= nil then
                        pcall(function() modObj.YawRelativeSpace = snap.YawRelativeSpace end)
                    end
                    if snap.CameraTraceDistance ~= nil then
                        pcall(function() modObj.CameraTraceDistance = snap.CameraTraceDistance end)
                    end
                    if snap.CameraTraceIgnoreDistance ~= nil then
                        pcall(function() modObj.CameraTraceIgnoreDistance = snap.CameraTraceIgnoreDistance end)
                    end
                    if snap.DistanceToAimStraightForTarget ~= nil then
                        pcall(function() modObj.DistanceToAimStraightForTarget = snap.DistanceToAimStraightForTarget end)
                    end
                end
            elseif modFull:find("SpellModule_PlayMontage") or modFull:find("SpellModule_PlayStagedMontage") then
                local key = "aim_pm:" .. modFull
                local snap = _AimSnapshots[key]
                if not snap then
                    snap = {}
                    pcall(function() snap.bShouldRotateToCameraForward = modObj.bShouldRotateToCameraForward end)
                    _AimSnapshots[key] = snap
                end
                if shouldEnable and refCfg.rotateToCameraForward == true and snap.bShouldRotateToCameraForward == false then
                    pcall(function()
                        modObj.bShouldRotateToCameraForward = true
                        patchedCount = patchedCount + 1
                    end)
                elseif not shouldEnable and snap.bShouldRotateToCameraForward ~= nil then
                    pcall(function() modObj.bShouldRotateToCameraForward = snap.bShouldRotateToCameraForward end)
                end
            end
        end)
    end)

    local spellKey = SpellScanner.SafeGetName(spellObj)
    if _LastAimPatchState[spellKey] ~= shouldEnable then
        _LastAimPatchState[spellKey] = shouldEnable
        if logFn then
            local shortName = SpellScanner.ExtractShortObjectName(spellKey)
            if shouldEnable then
                logFn(string.format("Applied Air 4th Vertical Aim Fix to %s (%d property update(s))", shortName, patchedCount))
            else
                logFn(string.format("Restored vanilla Air 4th aim settings on %s", shortName))
            end
        end
    end

    return patchedCount > 0
end

function SpellScanner.DumpSpellModules(spellObj, label, logFn)
    if not logFn then return end
    if not spellObj then
        logFn("SpellModules [" .. tostring(label) .. "]: <nil>")
        return
    end
    local okV, valid = pcall(function() return spellObj:IsValid() end)
    if not okV or not valid then
        logFn("SpellModules [" .. tostring(label) .. "]: <invalid>")
        return
    end
    local shortName = SpellScanner.ExtractShortObjectName(SpellScanner.SafeGetName(spellObj))
    logFn("=== SpellModules Dump: " .. tostring(label or shortName) .. " (" .. shortName .. ") ===")
    pcall(function()
        local mods = spellObj.Modules
        if not (mods and mods.Modules) then
            logFn("  (no Modules array)")
            return
        end
        mods.Modules:ForEach(function(i, elemWrapper)
            local modObj = nil
            pcall(function() modObj = elemWrapper:get().Module end)
            if not (modObj and modObj:IsValid()) then return end
            local full = SpellScanner.SafeGetName(modObj)
            local modShort = SpellScanner.ExtractShortObjectName(full)
            local modName = ""
            local trigStr = ""
            pcall(function() modName = SafeFNameToString(modObj.ModuleName) end)
            pcall(function()
                if modObj.Triggers then
                    trigStr = string.format("hasState=%s state=%s",
                        tostring(modObj.Triggers.bHasStateTrigger), tostring(modObj.Triggers.StateTrigger))
                end
            end)
            local extra = ""
            if full:find("SpellModule_PlayMontage") or full:find("SpellModule_PlayStagedMontage") then
                pcall(function()
                    extra = string.format("blockMove=%s maxSpd=%s rotCam=%s strafe=%s",
                        tostring(modObj.bShouldBlockMovement), tostring(modObj.MaxMovementSpeedDuringMontage),
                        tostring(modObj.bShouldRotateToCameraForward), tostring(modObj.bShouldEnableStrafing))
                end)
            elseif full:find("SpellModule_Transform") then
                pcall(function()
                    local px, py, pz = ReadVec3(modObj.PositionOffset)
                    extra = string.format("pos=(%s,%s,%s) posSpace=%s rotSpace=%s traceDist=%s",
                        tostring(px), tostring(py), tostring(pz),
                        tostring(modObj.PositionRelativeSpace), tostring(modObj.RotationRelativeSpace),
                        tostring(modObj.CameraTraceDistance))
                end)
            elseif full:find("SpellModule_Movement") then
                pcall(function()
                    extra = string.format("spd=%s pitchSpace=%s yawSpace=%s traceDist=%s targetDir=%s",
                        tostring(modObj.Speed), tostring(modObj.PitchRelativeSpace),
                        tostring(modObj.YawRelativeSpace), tostring(modObj.CameraTraceDistance),
                        tostring(modObj.bShouldUseSpellTargetDirection))
                end)
            end
            logFn(string.format("  [%d] %s (Name=%s | %s%s)",
                tonumber(i) or 0, modShort, modName, trigStr, (extra ~= "" and (" | " .. extra) or "")))
        end)
    end)
end

-- Returns:
--   newChains: [catLower] = { tag, isModded, chainName, steps[0..3], stepNames[0..3], montages[0..3], montageNames[0..3] }
--   orderedChains: sorted list of chains
--   spellRegistry: [assetNameLower] = { spellObj, montageObj, prevSpellObj, categoryTag, shortName, fullName, montageName, isSmash }
--   discoveredLookup: [shortNameOrMontageLower] = canonicalShortName (for direct rule resolution)
--   compactSummary: string
function SpellScanner.ScanAndPatchSpells(cfg, modVersion, detectedPath, nameMapByCat, globalNameMap, logFn)
    local newChains = {}
    local orderedChains = {}
    local spellRegistry = {}
    local discoveredLookup = {}

    if not cfg.Enabled then
        return newChains, orderedChains, spellRegistry, discoveredLookup, "Disabled"
    end

    local spells = FindAllOf("DominionSpellData")
    if spells then
        for _, sp in ipairs(spells) do
            if sp and sp:IsValid() then
                local full = SpellScanner.SafeGetName(sp)
                local shortName = SpellScanner.ExtractShortObjectName(full)
                local lower = full:lower()
                local category, idx, isModded = SpellScanner.ClassifySpellAsset(full, shortName)

                if category and idx ~= nil then
                    local key = category:lower()
                    if not newChains[key] then
                        newChains[key] = {
                            tag = category,
                            isModded = isModded,
                            chainName = shortName:gsub("_%d%d?.*$", ""),
                            steps = {},
                            stepNames = {},
                            montages = {},
                            montageNames = {}
                        }
                        table.insert(orderedChains, newChains[key])
                    end

                    local isNewVariant = lower:find("_new") ~= nil
                    if not newChains[key].steps[idx] or not isNewVariant then
                        newChains[key].steps[idx] = sp
                        newChains[key].stepNames[idx] = shortName
                    end

                    local isSpecialCat = key:find("^special_") ~= nil
                    local montageObj, montageName, costItems = PatchSpellModules(sp, cfg,
                        (not isSpecialCat and (not isNewVariant or not newChains[key].montages[idx])) and newChains[key] or nil, idx, lower)

                    local isSmash = (idx == 3 and (key:find("^air") or lower:find("slam") or lower:find("smash")))
                    local entry = {
                        spellObj = sp,
                        montageObj = montageObj,
                        costItems = costItems,
                        prevSpellObj = nil,
                        categoryTag = category,
                        stepIndex = idx,
                        shortName = shortName,
                        fullName = full,
                        montageName = montageName,
                        isSmash = isSmash,
                        isSpecialSpell = isSpecialCat
                    }
                    spellRegistry[shortName:lower()] = entry
                    discoveredLookup[shortName:lower()] = shortName
                    if montageName and montageName ~= "" then
                        discoveredLookup[montageName:lower()] = shortName
                    end
                    -- Only register unique mod prefixes (ham_*, da_ancientstaff_*) in global discoveredLookup;
                    -- never strip da_spell_ into generic suffixes that could collide across elements.
                    local modStripped = shortName:lower():gsub("^ham_", ""):gsub("^da_ancientstaff_", "")
                    if modStripped ~= shortName:lower() and modStripped ~= "" and not discoveredLookup[modStripped] then
                        discoveredLookup[modStripped] = shortName
                    end
                end
            end
        end
    end

    -- Wire each spell's direct predecessor (prevSpellObj) so LastChainedSpell priming requires zero index math
    for _, ch in ipairs(orderedChains) do
        for idx = 0, 3 do
            local sName = ch.stepNames[idx]
            if sName and spellRegistry[sName:lower()] then
                spellRegistry[sName:lower()].prevSpellObj = (idx > 0) and ch.steps[idx - 1] or nil
                if not spellRegistry[sName:lower()].montageObj then
                    spellRegistry[sName:lower()].montageObj = ch.montages[idx]
                    spellRegistry[sName:lower()].montageName = ch.montageNames[idx]
                end
            end
        end
    end

    -- Apply Staff 4th Air Combo Vertical Aim Fix (DA_Spell_Primary_Air_04 & Air_Wand_04 if present)
    for _, airKey in ipairs({ "air", "air_wand" }) do
        local airChain = newChains[airKey]
        if airChain and airChain.steps and airChain.steps[3] then
            SpellScanner.PatchAir4thVerticalAim(airChain.steps[3], airChain, cfg.FixAir4thVerticalAim ~= false, logFn)
        end
    end

    if cfg.UnlockUtilitySpells then
        local utilSpells = FindAllOf("UtilitySpellData")
        if utilSpells then
            for _, usp in ipairs(utilSpells) do
                if usp and usp:IsValid() then
                    PatchSpellModules(usp, cfg, nil, 0, SpellScanner.SafeGetName(usp):lower())
                end
            end
        end
    end

    table.sort(orderedChains, function(a, b) return a.tag < b.tag end)

    -- Build reverse lookup from assetShortNameLower -> friendly names defined in spell_names.txt
    local friendlyByAsset = {}
    if nameMapByCat then
        for catLower, map in pairs(nameMapByCat) do
            for friendly, assetShort in pairs(map) do
                local aKey = assetShort:lower()
                friendlyByAsset[aKey] = friendlyByAsset[aKey] or {}
                table.insert(friendlyByAsset[aKey], catLower .. "." .. friendly)
            end
        end
    end
    if globalNameMap then
        for friendly, assetShort in pairs(globalNameMap) do
            local aKey = assetShort:lower()
            friendlyByAsset[aKey] = friendlyByAsset[aKey] or {}
            table.insert(friendlyByAsset[aKey], "*." .. friendly)
        end
    end

    local baseTags, modTags = {}, {}
    local outLines = {
        "=== Arcane Wilds v" .. tostring(modVersion) .. " Discovered Spells & Direct Asset Names ===",
        "Reference ANY friendly name from spell_names.txt OR exact DA_Spell_* / Montage name in combo_rules.txt!",
        "Example: Water@wave,bolt:3.0 -> Fire@bolt,explosion,volcano,meteor:3.0 :5;",
        ""
    }

    for _, ch in ipairs(orderedChains) do
        local kl = ch.tag:lower()
        if not ch.isModded and (kl == "air" or kl == "fire" or kl == "water" or kl == "earth") then
            table.insert(baseTags, ch.tag)
        elseif ch.isModded then
            table.insert(modTags, ch.tag)
        end

        table.insert(outLines, string.format("[%s] (%s)", ch.tag, ch.chainName))
        for i = 0, 3 do
            if ch.steps[i] then
                local sName = ch.stepNames[i] or "?"
                local namesList = friendlyByAsset[sName:lower()]
                local nameSuffix = (namesList and #namesList > 0) and ("  [spell_names: " .. table.concat(namesList, ", ") .. "]") or ""
                local montageInfo = ch.montageNames[i] and ("  (Montage: " .. ch.montageNames[i] .. ")") or ""
                table.insert(outLines, string.format("   %s%s%s", sName, nameSuffix, montageInfo))
            end
        end
        table.insert(outLines, "")
    end

    if detectedPath then
        local df = io.open(detectedPath, "w")
        if df then
            df:write(table.concat(outLines, "\n") .. "\n")
            df:close()
        end
    end

    local summaryParts = {}
    for _, t in ipairs(baseTags) do table.insert(summaryParts, t) end
    table.insert(summaryParts, "+Wands/Hold")
    if #modTags > 0 then
        table.insert(summaryParts, "+" .. tostring(#modTags) .. "mods(" .. table.concat(modTags, ",") .. ")")
    end
    local compactSummary = table.concat(summaryParts, ",")
    return newChains, orderedChains, spellRegistry, discoveredLookup, compactSummary
end

return SpellScanner
