-- ArcaneWilds v1.70.0 - Equipment, Ancient Magicks State & Rune Consumption
-- Detects equipped weapon/runes/Ancient Magicks toggles and deducts runes on swapped casts.

local SpellScanner = require("spell_scanner")

local EquipmentRunes = {}

-- ELoadoutSlot (UHTHeaderDump/Dominion/Public/ELoadoutSlot.h)
local LOADOUT_SLOT_MAGIC_AMMO_1 = 6
local LOADOUT_SLOT_HELD_RIGHT   = 7
local LOADOUT_SLOT_HELD_LEFT    = 8

-- EHeldEquipmentAmmoType (UHTHeaderDump/Dominion/Public/EHeldEquipmentAmmoType.h)
local AMMO_TYPE_RUNES = 5

-- EMagicAmmoVfxElement (UHTHeaderDump/Dominion/Public/EMagicAmmoVfxElement.h)
local MAGIC_AMMO_VFX_TO_ELEM = {
    [1] = "Air",
    [2] = "Fire",
    [3] = "Water",
    [4] = "Earth"
}

function EquipmentRunes.DiscoverRuneItemAssets(state)
    local pools = {}
    local magicAmmos = nil
    pcall(function() magicAmmos = FindAllOf("MagicAmmoData") end)
    if magicAmmos and #magicAmmos > 0 then
        table.insert(pools, magicAmmos)
    end
    local items = nil
    pcall(function() items = FindAllOf("ItemData") end)
    if items and #items > 0 then
        table.insert(pools, items)
    end
    for _, list in ipairs(pools) do
        for _, item in ipairs(list) do
            if item and item:IsValid() then
                local full = SpellScanner.SafeGetName(item):lower()
                local short = SpellScanner.ExtractShortObjectName(full):lower()
                if full:find("rune") or short:find("rune") then
                    if short:find("fire") then state.RuneItemDataCache["fire"] = item
                    elseif short:find("water") then state.RuneItemDataCache["water"] = item
                    elseif short:find("air") or short:find("wind") then state.RuneItemDataCache["air"] = item
                    elseif short:find("earth") then state.RuneItemDataCache["earth"] = item
                    elseif short:find("blood") then state.RuneItemDataCache["blood"] = item
                    elseif short:find("ice") or short:find("frost") then state.RuneItemDataCache["ice"] = item
                    elseif short:find("smoke") then state.RuneItemDataCache["smoke"] = item
                    elseif short:find("shadow") then state.RuneItemDataCache["shadow"] = item
                    elseif short:find("death") then state.RuneItemDataCache["death"] = item
                    elseif short:find("chaos") then state.RuneItemDataCache["chaos"] = item
                    elseif short:find("nature") then state.RuneItemDataCache["nature"] = item
                    elseif short:find("law") then state.RuneItemDataCache["law"] = item
                    end
                end
            end
        end
    end
end

function EquipmentRunes.GetActiveAncientMagicksToggle(pawn, combatMagic)
    local activeHam = nil
    pcall(function()
        local subsys = FindFirstOf("CombatSpellDataSubsystem")
        if subsys and subsys:IsValid() then
            local toggleProps = { "ActiveBarrageSpell", "SelectedBarrage", "CurrentAncientSpell", "ActiveSpell", "ToggledSpell" }
            for _, prop in ipairs(toggleProps) do
                local val = nil
                pcall(function() val = subsys[prop] end)
                if val and type(val) == "userdata" and val:IsValid() then
                    local sName = SpellScanner.ExtractShortObjectName(SpellScanner.SafeGetName(val))
                    if sName:lower():find("^ham_") then
                        activeHam = sName
                        break
                    end
                end
            end
        end
    end)

    if not activeHam and pawn and pawn:IsValid() then
        pcall(function()
            local asc = pawn.AbilitySystemComponent
            if asc and asc:IsValid() then
                if combatMagic and combatMagic:IsValid() and combatMagic.CurrentSpellActor and combatMagic.CurrentSpellActor:IsValid() then
                    local d = combatMagic.CurrentSpellActor.Data
                    if d and d:IsValid() then
                        local sName = SpellScanner.ExtractShortObjectName(SpellScanner.SafeGetName(d))
                        if sName:lower():find("^ham_") then
                            activeHam = sName
                        end
                    end
                end
            end
        end)
    end

    return activeHam
end


local function IsValidUObj(obj)
    if not obj or type(obj) ~= "userdata" then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

local function ResolveLoadoutComponent(pawn)
    local pc = nil
    if IsValidUObj(pawn) then
        pcall(function()
            if IsValidUObj(pawn.Controller) then pc = pawn.Controller end
        end)
    end
    if not IsValidUObj(pc) then
        pcall(function() pc = FindFirstOf("DominionPlayerController") end)
    end
    if IsValidUObj(pc) then
        local loadout = nil
        pcall(function()
            if pc.GetLoadout then loadout = pc:GetLoadout() end
        end)
        if IsValidUObj(loadout) then return loadout end
        pcall(function() loadout = pc.LoadoutComponent end)
        if IsValidUObj(loadout) then return loadout end
    end
    local fallback = nil
    pcall(function() fallback = FindFirstOf("LoadoutComponent") end)
    if IsValidUObj(fallback) then return fallback end
    return nil
end

local function ExtractItemDataFromItem(itemObj)
    if not IsValidUObj(itemObj) then return nil end
    local dataObj = nil
    pcall(function()
        if itemObj.BP_GetMagicAmmoData then
            local d = itemObj:BP_GetMagicAmmoData()
            if IsValidUObj(d) then dataObj = d end
        end
    end)
    if IsValidUObj(dataObj) then return dataObj end
    pcall(function()
        if itemObj.BP_GetItemData then
            local d = itemObj:BP_GetItemData()
            if IsValidUObj(d) then dataObj = d end
        end
    end)
    if IsValidUObj(dataObj) then return dataObj end
    pcall(function()
        if IsValidUObj(itemObj.ItemData) then dataObj = itemObj.ItemData end
    end)
    if IsValidUObj(dataObj) then return dataObj end
    return nil
end

local function ReadGameplayTagString(tag)
    if not tag then return "" end
    local out = ""
    pcall(function()
        if tag.TagName then
            if type(tag.TagName) == "userdata" and tag.TagName.ToString then
                out = tag.TagName:ToString() or ""
            else
                out = tostring(tag.TagName or "")
            end
        end
    end)
    if out == "None" then return "" end
    return out
end

local function InspectHeldWeaponData(heldData, handCategoryTagStr)
    if not IsValidUObj(heldData) then
        return false, false, nil
    end

    local fullName = SpellScanner.SafeGetName(heldData)
    local shortName = SpellScanner.ExtractShortObjectName(fullName)
    local lowerName = fullName:lower()

    local catTagStr = tostring(handCategoryTagStr or "")
    pcall(function()
        local itemCat = ReadGameplayTagString(heldData.Category)
        if itemCat ~= "" then
            catTagStr = catTagStr .. " " .. itemCat
        end
    end)
    local catTagLower = catTagStr:lower()

    local ammoType = nil
    pcall(function() ammoType = tonumber(heldData.AmmoType) end)

    local hasMagicAttackCollection = false
    pcall(function()
        local mac = heldData.MagicAttackCollection
        if IsValidUObj(mac) then
            hasMagicAttackCollection = true
        end
    end)

    local isMagicWeapon = false
    if ammoType == AMMO_TYPE_RUNES or hasMagicAttackCollection then
        isMagicWeapon = true
    elseif ammoType ~= 2 and ammoType ~= 3 and ammoType ~= 4 then
        -- Fallback for modded staves/wands without standard AmmoType
        if lowerName:find("staff") or lowerName:find("wand")
            or lowerName:find("sceptre") or lowerName:find("scepter")
            or lowerName:find("grimoire") or lowerName:find("ancientstaff")
            or lowerName:find("conjurer")
            or catTagLower:find("staff") or catTagLower:find("wand") or catTagLower:find("magic") then
            isMagicWeapon = true
        end
    end

    local isWand = (lowerName:find("wand") ~= nil) or (catTagLower:find("wand") ~= nil)
    return isMagicWeapon, isWand, shortName
end

function EquipmentRunes.GetEquippedMagicWeaponInfo(pawn, loadout)
    local info = {
        hasMagicWeapon = false,
        weaponSuffix = "",
        weaponName = nil,
        heldData = nil,
        hand = nil,
        checked = false
    }
    if not IsValidUObj(pawn) then return info end

    local equipComp = nil
    pcall(function()
        if pawn.GetPlayerEquipmentComponent then
            equipComp = pawn:GetPlayerEquipmentComponent()
        end
    end)
    if not IsValidUObj(equipComp) then
        pcall(function() equipComp = pawn.PlayerEquipmentComponent end)
    end

    local rData, lData = nil, nil
    local rTagStr, lTagStr = "", ""

    if IsValidUObj(equipComp) then
        info.checked = true
        pcall(function()
            if equipComp.GetHeldEquipmentDataRight then
                local d = equipComp:GetHeldEquipmentDataRight()
                if IsValidUObj(d) then rData = d end
            end
        end)
        if not IsValidUObj(rData) then
            pcall(function()
                local actor = equipComp.HeldEquipmentActorRight
                if IsValidUObj(actor) then
                    local d = (actor.GetHeldEquipmentData and actor:GetHeldEquipmentData()) or actor.HeldEquipmentData
                    if IsValidUObj(d) then rData = d end
                end
            end)
        end
        pcall(function()
            if equipComp.GetRightHandEquipmentCategory then
                rTagStr = ReadGameplayTagString(equipComp:GetRightHandEquipmentCategory())
            end
        end)

        pcall(function()
            if equipComp.GetHeldEquipmentDataLeft then
                local d = equipComp:GetHeldEquipmentDataLeft()
                if IsValidUObj(d) then lData = d end
            end
        end)
        if not IsValidUObj(lData) then
            pcall(function()
                local actor = equipComp.HeldEquipmentActorLeft
                if IsValidUObj(actor) then
                    local d = (actor.GetHeldEquipmentData and actor:GetHeldEquipmentData()) or actor.HeldEquipmentData
                    if IsValidUObj(d) then lData = d end
                end
            end)
        end
        pcall(function()
            if equipComp.GetLeftHandEquipmentCategory then
                lTagStr = ReadGameplayTagString(equipComp:GetLeftHandEquipmentCategory())
            end
        end)
    end

    if IsValidUObj(loadout) then
        info.checked = true
        if not IsValidUObj(rData) then
            pcall(function()
                local eq = loadout:GetEquipmentFromSlot(LOADOUT_SLOT_HELD_RIGHT)
                local d = ExtractItemDataFromItem(eq)
                if IsValidUObj(d) then rData = d end
            end)
        end
        if not IsValidUObj(lData) then
            pcall(function()
                local eq = loadout:GetEquipmentFromSlot(LOADOUT_SLOT_HELD_LEFT)
                local d = ExtractItemDataFromItem(eq)
                if IsValidUObj(d) then lData = d end
            end)
        end
    end

    local rIsMagic, rIsWand, rName = InspectHeldWeaponData(rData, rTagStr)
    if rIsMagic then
        info.hasMagicWeapon = true
        info.weaponSuffix = rIsWand and "_Wand" or ""
        info.weaponName = rName
        info.heldData = rData
        info.hand = "Right"
        return info
    end

    local lIsMagic, lIsWand, lName = InspectHeldWeaponData(lData, lTagStr)
    if lIsMagic then
        info.hasMagicWeapon = true
        info.weaponSuffix = lIsWand and "_Wand" or ""
        info.weaponName = lName
        info.heldData = lData
        info.hand = "Left"
        return info
    end

    info.weaponName = rName or lName
    info.heldData = rData or lData
    return info
end

function EquipmentRunes.GetEquippedMagicRuneInfo(pawn, loadout, state)
    if not IsValidUObj(loadout) then
        return nil, nil, 0, nil
    end

    local ammoItem = nil
    pcall(function()
        if loadout.GetEquipmentFromSlot then
            local eq = loadout:GetEquipmentFromSlot(LOADOUT_SLOT_MAGIC_AMMO_1)
            if IsValidUObj(eq) then ammoItem = eq end
        end
    end)

    if not IsValidUObj(ammoItem) then
        pcall(function()
            if loadout.GetSlotIndexForSlot and loadout.GetItemFromSlot then
                local slotIdx = tonumber(loadout:GetSlotIndexForSlot(LOADOUT_SLOT_MAGIC_AMMO_1))
                if slotIdx and slotIdx >= 0 then
                    local it = loadout:GetItemFromSlot(slotIdx)
                    if IsValidUObj(it) then ammoItem = it end
                end
            end
        end)
    end

    if not IsValidUObj(ammoItem) then
        pcall(function()
            if loadout.GetSlotIndexForSlot and loadout.ItemSlots and loadout.ItemSlots.ForEach then
                local slotIdx = tonumber(loadout:GetSlotIndexForSlot(LOADOUT_SLOT_MAGIC_AMMO_1))
                if slotIdx and slotIdx >= 0 then
                    loadout.ItemSlots:ForEach(function(luaIdx, elemWrapper)
                        if IsValidUObj(ammoItem) then return end
                        if (luaIdx - 1) == slotIdx then
                            local it = nil
                            pcall(function() it = elemWrapper:get() end)
                            if IsValidUObj(it) then ammoItem = it end
                        end
                    end)
                end
            end
        end)
    end

    if not IsValidUObj(ammoItem) then
        return nil, nil, 0, nil
    end

    local stackCount = nil
    pcall(function()
        if ammoItem.GetStackSize then
            stackCount = tonumber(ammoItem:GetStackSize())
        end
    end)
    if stackCount == nil then
        pcall(function() stackCount = tonumber(ammoItem.Count) end)
    end
    if stackCount ~= nil and stackCount <= 0 then
        return nil, nil, 0, nil
    end

    local ammoData = ExtractItemDataFromItem(ammoItem)
    local fullStr = SpellScanner.SafeGetName(ammoItem)
    if IsValidUObj(ammoData) then
        fullStr = fullStr .. " " .. SpellScanner.SafeGetName(ammoData)
    end
    local lowerStr = fullStr:lower()
    local shortName = SpellScanner.ExtractShortObjectName(SpellScanner.SafeGetName(ammoData or ammoItem))

    local elem = nil
    -- Check specific modded rune/ammo tags first (e.g. Conjurer / Ancient Magicks)
    if lowerStr:find("conjurer") or lowerStr:find("ham_") or lowerStr:find("ancientstaff") then
        elem = SpellScanner.ClassifyEquippedName(fullStr)
    end

    -- Authoritative C++ enum on UMagicAmmoData (EMagicAmmoVfxElement: 1=Air, 2=Fire, 3=Water, 4=Earth)
    if not elem and IsValidUObj(ammoData) then
        local vfxEnum = nil
        pcall(function()
            if ammoData.GetAmmoFVXElementValue then
                vfxEnum = tonumber(ammoData:GetAmmoFVXElementValue())
            end
        end)
        if vfxEnum == nil or vfxEnum == 0 then
            pcall(function() vfxEnum = tonumber(ammoData.AmmoVfxElementValue) end)
        end
        if vfxEnum and MAGIC_AMMO_VFX_TO_ELEM[vfxEnum] then
            elem = MAGIC_AMMO_VFX_TO_ELEM[vfxEnum]
        end
    end

    -- Fallback: classify by rune asset name (e.g. ITEM_Rune_Fire -> Fire)
    if not elem then
        elem = SpellScanner.ClassifyEquippedName(fullStr)
    end

    if elem and state and state.RuneItemDataCache and IsValidUObj(ammoData) then
        state.RuneItemDataCache[elem:lower()] = ammoData
    end

    return elem, ammoData, stackCount or 1, shortName
end

function EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, state, debugLogFn)
    if not IsValidUObj(pawn) then
        return nil
    end

    local loadout = ResolveLoadoutComponent(pawn)
    local weaponInfo = EquipmentRunes.GetEquippedMagicWeaponInfo(pawn, loadout)
    state.HasMagicWeaponEquipped = weaponInfo.hasMagicWeapon
    state.LastKnownWeaponName = weaponInfo.weaponName
    state.LastKnownWeaponSuffix = weaponInfo.weaponSuffix or ""

    -- Must have a magic weapon (staff / wand) equipped to enable magic combos.
    if weaponInfo.checked and not weaponInfo.hasMagicWeapon then
        if state.LastKnownEquippedElement ~= nil or state.AnchorElement ~= nil then
            if debugLogFn then
                debugLogFn("No staff/wand equipped (holding: " .. tostring(weaponInfo.weaponName or "None") .. ") -> Cleared equipped magic element")
            end
            state.LastKnownEquippedElement = nil
            state.AnchorElement = nil
            state.LastKnownRuneName = nil
            if not state.ActiveMacro then
                state.PendingAnchorReturn = false
                state.LastObservedChainedSpell = nil
            end
        end
        return nil
    end

    -- Detect the player's actually equipped elemental rune from LoadoutComponent (ELoadoutSlot::MagicAmmo1).
    local detectedElem, _, _, runeShortName = nil, nil, 0, nil
    if IsValidUObj(loadout) then
        detectedElem, _, _, runeShortName = EquipmentRunes.GetEquippedMagicRuneInfo(pawn, loadout, state)
    end
    state.LastKnownRuneName = runeShortName
    local hasExplicitRuneEquipped = (detectedElem ~= nil)

    local activeHam = EquipmentRunes.GetActiveAncientMagicksToggle(pawn, combatMagic)
    if activeHam and not hasExplicitRuneEquipped then
        detectedElem = activeHam
    elseif activeHam and hasExplicitRuneEquipped then
        if IsValidUObj(combatMagic) and not state.ActiveMacro then
            pcall(function()
                if IsValidUObj(combatMagic.LastChainedSpell) then
                    local chainedName = SpellScanner.SafeGetName(combatMagic.LastChainedSpell):lower()
                    if chainedName:find("ham_") or chainedName:find("ancientstaff") then
                        combatMagic.LastChainedSpell = nil
                        if debugLogFn then
                            debugLogFn("Cleared stale Ancient Magicks LastChainedSpell after rune swap to " .. tostring(detectedElem))
                        end
                    end
                end
            end)
        end
    end

    if detectedElem then
        local isBaseFour = (detectedElem == "Fire" or detectedElem == "Water" or detectedElem == "Air" or detectedElem == "Earth")
        local fullCat = isBaseFour and (detectedElem .. (weaponInfo.weaponSuffix or "")) or detectedElem

        local changedFromLast = (state.LastKnownEquippedElement ~= nil and state.LastKnownEquippedElement ~= fullCat)
        if not state.ActiveMacro then
            if state.LastKnownEquippedElement ~= fullCat or state.AnchorElement ~= fullCat then
                if debugLogFn then
                    debugLogFn(string.format("Equipped element synced: %s -> %s (Weapon=%s, Rune=%s)",
                        tostring(state.LastKnownEquippedElement), tostring(fullCat),
                        tostring(weaponInfo.weaponName or "Unknown"), tostring(runeShortName or activeHam or "None")))
                end
                state.AnchorElement = fullCat
                state.PendingAnchorReturn = false
                state.LastObservedChainedSpell = nil
                if IsValidUObj(combatMagic) then
                    pcall(function() combatMagic.LastChainedSpell = nil end)
                end
            end
        elseif changedFromLast then
            if debugLogFn then
                debugLogFn("Rune/weapon swapped mid-state -> Clearing stale macro & syncing to [" .. tostring(fullCat) .. "]")
            end
            state.ActiveMacro = nil
            state.StageIndex = 1
            state.StepInStage = 1
            state.PendingAnchorReturn = false
            state.StepInFlight = false
            state.InFlightSpellObj = nil
            state.LastObservedChainedSpell = nil
            state.AnchorElement = fullCat
            if IsValidUObj(combatMagic) then
                pcall(function() combatMagic.LastChainedSpell = nil end)
            end
        end

        state.LastKnownEquippedElement = fullCat
        return fullCat
    end

    -- If loadout was valid and MagicAmmo1 has no elemental rune equipped (and no Ancient Magicks toggle),
    -- do NOT fall back to stale LastKnownEquippedElement or active/previous spell actors.
    if IsValidUObj(loadout) then
        if state.LastKnownEquippedElement ~= nil or state.AnchorElement ~= nil then
            if debugLogFn then
                debugLogFn("No elemental runes equipped in MagicAmmo1 -> Cleared equipped magic element")
            end
            state.LastKnownEquippedElement = nil
            state.AnchorElement = nil
            state.PendingAnchorReturn = false
            state.LastObservedChainedSpell = nil
        end
        return nil
    end

    return state.LastKnownEquippedElement
end

function EquipmentRunes.ConsumeItemsFromInventory(pawn, itemData, count)
    if not pawn or not pawn:IsValid() or not itemData or not itemData:IsValid() then
        return false
    end
    local qty = math.max(1, math.floor(count or 1))
    local consumed = false

    local invTargets = {}
    pcall(function()
        if pawn.InventoryComponent and pawn.InventoryComponent:IsValid() then
            table.insert(invTargets, pawn.InventoryComponent)
        end
    end)
    pcall(function()
        local pc = pawn.Controller
        if pc and pc:IsValid() and pc.InventoryComponent and pc.InventoryComponent:IsValid() then
            table.insert(invTargets, pc.InventoryComponent)
        end
    end)
    pcall(function()
        if pawn.PlayerEquipmentComponent and pawn.PlayerEquipmentComponent:IsValid() then
            table.insert(invTargets, pawn.PlayerEquipmentComponent)
        end
    end)

    for _, inv in ipairs(invTargets) do
        local methodNames = { "RemoveItem", "ConsumeItem", "RemoveItemsByData", "Server_RemoveItem" }
        for _, mName in ipairs(methodNames) do
            if not consumed and inv[mName] then
                local ok, res = pcall(function()
                    return inv[mName](inv, itemData, qty)
                end)
                if ok and (res == nil or res == true) then
                    consumed = true
                    break
                end
            end
        end
        if consumed then break end
    end

    if not consumed then
        pcall(function()
            local bpLib = StaticFindObject("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
            if bpLib and bpLib:IsValid() then
                if bpLib.RemoveItemFromPlayer then
                    local ok, res = pcall(function() return bpLib:RemoveItemFromPlayer(pawn, itemData, qty) end)
                    if ok and (res == nil or res == true) then consumed = true end
                elseif bpLib.ConsumeItemForPlayer then
                    local ok, res = pcall(function() return bpLib:ConsumeItemForPlayer(pawn, itemData, qty) end)
                    if ok and (res == nil or res == true) then consumed = true end
                end
            end
        end)
    end

    return consumed
end

function EquipmentRunes.ConsumeRunesForSpellEntry(config, state, pawn, entry, debugLogFn)
    if not config.ConsumeRunesOnSwappedCasts or not pawn or not pawn:IsValid() or not entry then
        return true
    end

    if entry.costItems and #entry.costItems > 0 then
        for _, cost in ipairs(entry.costItems) do
            if cost.itemData and cost.itemData:IsValid() then
                local ok = EquipmentRunes.ConsumeItemsFromInventory(pawn, cost.itemData, cost.count)
                debugLogFn(string.format("Rune/Cost consume [%s]: %s x%d -> %s",
                    tostring(entry.shortName), tostring(cost.itemName), cost.count, tostring(ok)))
            end
        end
        return true
    end

    local catLower = (entry.categoryTag or ""):lower():gsub("_wand$", ""):gsub("_hold$", "")
    local runeItem = state.RuneItemDataCache[catLower]
    if not runeItem or not runeItem:IsValid() then
        EquipmentRunes.DiscoverRuneItemAssets(state)
        runeItem = state.RuneItemDataCache[catLower]
    end

    if runeItem and runeItem:IsValid() then
        local ok = EquipmentRunes.ConsumeItemsFromInventory(pawn, runeItem, 1)
        debugLogFn(string.format("Swapped element rune consume [%s]: %s x1 -> %s",
            tostring(entry.shortName), SpellScanner.ExtractShortObjectName(SpellScanner.SafeGetName(runeItem)), tostring(ok)))
    end
    return true
end


local function HandleEquipmentOrRuneChange(pawn, combatMagic, state, debugLogFn, label)
    if state and state.Enabled == false then return end
    if not IsValidUObj(pawn) or not state then return end

    local cm = combatMagic
    if not IsValidUObj(cm) then
        pcall(function() cm = pawn.PlayerCombatMagicComponent end)
    end

    local prevElem = state.LastKnownEquippedElement
    local prevMagic = state.HasMagicWeaponEquipped
    local newElem = EquipmentRunes.DetectEquippedCategory(pawn, cm, state, debugLogFn or function() end)
    local changed = (prevElem ~= newElem) or (prevMagic ~= state.HasMagicWeaponEquipped)

    -- Only interrupt an active combo if the equipped weapon/element actually changed (not when rune count merely decrements on cast).
    if changed then
        state.ActiveMacro = nil
        state.StageIndex = 1
        state.StepInStage = 1
        state.PendingAnchorReturn = false
        state.StepInFlight = false
        state.InFlightSpellObj = nil
        state.SpecialPostPauseUntil = 0
        state.AnimPadUntil = 0
        state._LastTriggeredSpellPtr = nil
        state.LastObservedChainedSpell = nil
        pcall(function()
            local cs = require("custom_spells")
            if cs and cs.StopForcedMontage then cs.StopForcedMontage(state, pawn) end
        end)
        if IsValidUObj(cm) then
            pcall(function() cm.LastChainedSpell = nil end)
        end
        if debugLogFn and label then
            debugLogFn("Hook fired [" .. label .. "] -> Synced equipped element [" .. tostring(prevElem) .. " -> " .. tostring(newElem) .. "]")
        end
    end
end

local function OnEquipmentChangedCallback(selfParam, state, combatMagic, debugLogFn, label)
    if state and state.Enabled == false then return end
    local selfObj = selfParam
    pcall(function()
        if selfParam and type(selfParam) == "userdata" and selfParam.get then
            local unwrapped = selfParam:get()
            if unwrapped ~= nil then selfObj = unwrapped end
        end
    end)
    if not IsValidUObj(selfObj) then return end

    local pawn = nil
    pcall(function()
        local cmCheck = selfObj.PlayerCombatMagicComponent
        if IsValidUObj(cmCheck) then pawn = selfObj end
    end)
    if not IsValidUObj(pawn) then
        pcall(function()
            if selfObj.GetOwner then
                local owner = selfObj:GetOwner()
                if IsValidUObj(owner) then pawn = owner end
            end
        end)
    end
    if not IsValidUObj(pawn) then
        pcall(function()
            local p = selfObj.Pawn
            if IsValidUObj(p) then pawn = p end
        end)
    end
    if IsValidUObj(pawn) then
        HandleEquipmentOrRuneChange(pawn, combatMagic, state, debugLogFn, label)
    end
end

function EquipmentRunes.EnsureEquipmentDelegates(pawn, combatMagic, state, debugLogFn)
    if not IsValidUObj(pawn) or not state then return end

    pcall(function()
        local eqComp = nil
        if pawn.GetPlayerEquipmentComponent then
            eqComp = pawn:GetPlayerEquipmentComponent()
        end
        if not IsValidUObj(eqComp) then eqComp = pawn.PlayerEquipmentComponent end
        if IsValidUObj(eqComp) and state._BoundEquipCompPtr ~= tostring(eqComp) then
            state._BoundEquipCompPtr = tostring(eqComp)
            if eqComp.BP_OnHeldEquipmentChanged and eqComp.BP_OnHeldEquipmentChanged.Add then
                eqComp.BP_OnHeldEquipmentChanged:Add(function()
                    local ownerPawn = nil
                    pcall(function() ownerPawn = eqComp:GetOwner() end)
                    HandleEquipmentOrRuneChange(ownerPawn or pawn, combatMagic, state, debugLogFn, "BP_OnHeldEquipmentChanged")
                end)
            end
        end
    end)

    pcall(function()
        local loadout = ResolveLoadoutComponent(pawn)
        if IsValidUObj(loadout) and state._BoundLoadoutCompPtr ~= tostring(loadout) then
            state._BoundLoadoutCompPtr = tostring(loadout)
            if loadout.OnMagicAmmo1Changed and loadout.OnMagicAmmo1Changed.Add then
                loadout.OnMagicAmmo1Changed:Add(function()
                    HandleEquipmentOrRuneChange(pawn, combatMagic, state, debugLogFn, "OnMagicAmmo1Changed")
                end)
            end
            if loadout.OnHeldRightItemChanged and loadout.OnHeldRightItemChanged.Add then
                loadout.OnHeldRightItemChanged:Add(function()
                    HandleEquipmentOrRuneChange(pawn, combatMagic, state, debugLogFn, "OnHeldRightItemChanged")
                end)
            end
            if loadout.OnHeldLeftItemChanged and loadout.OnHeldLeftItemChanged.Add then
                loadout.OnHeldLeftItemChanged:Add(function()
                    HandleEquipmentOrRuneChange(pawn, combatMagic, state, debugLogFn, "OnHeldLeftItemChanged")
                end)
            end
        end
    end)
end

function EquipmentRunes.InstallEquipmentSwapHooks(state, combatMagic, logFn, debugLogFn)
    if state._InstalledEquipmentHooks then return end
    state._InstalledEquipmentHooks = true

    -- Hook real change events only (never pure getters like GetHeldEquipmentDataRight!)
    local hookTargets = {
        "/Script/Dominion.DominionPlayerCharacter:OnMagicAmmoItemChanged",
        "/Script/Dominion.DominionPlayerCharacter:OnHeldRightItemChanged",
        "/Script/Dominion.DominionPlayerCharacter:OnHeldLeftItemChanged",
        "/Script/Dominion.PlayerEquipmentComponent:OnRep_HeldEquipmentActorRight",
        "/Script/Dominion.PlayerEquipmentComponent:OnRep_HeldEquipmentActorLeft"
    }

    for _, fnPath in ipairs(hookTargets) do
        local okReg, errReg = pcall(function()
            RegisterHook(fnPath, function(selfObj)
                OnEquipmentChangedCallback(selfObj, state, combatMagic, debugLogFn, fnPath)
            end)
        end)
        if logFn then
            logFn("RegisterHook [" .. fnPath .. "] -> " .. tostring(okReg) .. (errReg and (" (" .. tostring(errReg) .. ")") or ""))
        end
    end
end

return EquipmentRunes
