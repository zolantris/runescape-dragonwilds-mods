-- ArcaneWilds v1.70.0 - Equipment, Ancient Magicks State & Rune Consumption
-- Detects equipped weapon/runes/Ancient Magicks toggles and deducts runes on swapped casts.

local SpellScanner = require("spell_scanner")

local EquipmentRunes = {}

function EquipmentRunes.DiscoverRuneItemAssets(state)
    local items = FindAllOf("DominionItemData") or FindAllOf("ItemData")
    if not items then return end
    for _, item in ipairs(items) do
        if item and item:IsValid() then
            local full = SpellScanner.SafeGetName(item):lower()
            local short = SpellScanner.ExtractShortObjectName(full):lower()
            if full:find("rune") or short:find("rune") or full:find("magicammo") then
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

function EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, state, debugLogFn)
    if not pawn or not pawn:IsValid() then
        return state.LastKnownEquippedElement
    end

    local detectedElem = nil
    local weaponSuffix = state.LastKnownWeaponSuffix
    local hasExplicitRuneEquipped = false

    pcall(function()
        local equipComp = pawn.PlayerEquipmentComponent
        if equipComp and equipComp:IsValid() then
            local weaponProps = { "RightHandEquipment", "HeldRightEquipment", "MainHandEquipment" }
            for _, prop in ipairs(weaponProps) do
                local wObj = nil
                pcall(function() wObj = equipComp[prop] end)
                if wObj and wObj:IsValid() then
                    local wName = SpellScanner.SafeGetName(wObj):lower()
                    pcall(function()
                        if wObj.ItemData and wObj.ItemData:IsValid() then
                            wName = wName .. " " .. SpellScanner.SafeGetName(wObj.ItemData):lower()
                        end
                    end)
                    if wName:find("wand") then
                        weaponSuffix = "_Wand"
                    elseif wName:find("staff") then
                        weaponSuffix = ""
                    end
                end
            end

            local ammoProps = { "EquippedMagicAmmo", "MagicAmmo", "CurrentMagicAmmo" }
            for _, prop in ipairs(ammoProps) do
                local itemObj = nil
                pcall(function() itemObj = equipComp[prop] end)
                if itemObj and itemObj:IsValid() then
                    local itemName = SpellScanner.SafeGetName(itemObj)
                    local itemDataObj = nil
                    pcall(function() itemDataObj = itemObj.ItemData end)
                    if itemDataObj and itemDataObj:IsValid() then
                        itemName = itemName .. " " .. SpellScanner.SafeGetName(itemDataObj)
                    end
                    local elem = SpellScanner.ClassifyEquippedName(itemName)
                    if elem then
                        detectedElem = elem
                        hasExplicitRuneEquipped = true
                        if itemDataObj and itemDataObj:IsValid() then
                            state.RuneItemDataCache[elem:lower()] = itemDataObj
                        end
                        break
                    end
                end
            end
        end
    end)

    if not detectedElem then
        pcall(function()
            local pc = pawn.Controller
            if pc and pc:IsValid() and pc.LoadoutComponent and pc.LoadoutComponent:IsValid() then
                local loadout = pc.LoadoutComponent
                local loadoutProps = { "MagicAmmo1", "MagicAmmo", "HeldRight", "EquippedItems" }
                for _, prop in ipairs(loadoutProps) do
                    local val = nil
                    pcall(function() val = loadout[prop] end)
                    if val and type(val) == "userdata" and val:IsValid() then
                        local itemName = SpellScanner.SafeGetName(val)
                        local itemDataObj = nil
                        pcall(function() itemDataObj = val.ItemData end)
                        if itemDataObj and itemDataObj:IsValid() then
                            itemName = itemName .. " " .. SpellScanner.SafeGetName(itemDataObj)
                        end
                        if itemName:lower():find("wand") then
                            weaponSuffix = "_Wand"
                        elseif itemName:lower():find("staff") then
                            weaponSuffix = ""
                        end
                        local elem = SpellScanner.ClassifyEquippedName(itemName)
                        if elem then
                            detectedElem = elem
                            hasExplicitRuneEquipped = true
                            if itemDataObj and itemDataObj:IsValid() then
                                state.RuneItemDataCache[elem:lower()] = itemDataObj
                            end
                            break
                        end
                    end
                end
            end
        end)
    end

    local activeHam = EquipmentRunes.GetActiveAncientMagicksToggle(pawn, combatMagic)
    if activeHam and not hasExplicitRuneEquipped then
        detectedElem = activeHam
    elseif activeHam and hasExplicitRuneEquipped then
        if combatMagic and combatMagic:IsValid() and not state.ActiveMacro then
            pcall(function()
                if combatMagic.LastChainedSpell and combatMagic.LastChainedSpell:IsValid() then
                    local chainedName = SpellScanner.SafeGetName(combatMagic.LastChainedSpell):lower()
                    if chainedName:find("ham_") or chainedName:find("ancientstaff") then
                        combatMagic.LastChainedSpell = nil
                        debugLogFn("Cleared stale Ancient Magicks LastChainedSpell after rune swap to " .. tostring(detectedElem))
                    end
                end
            end)
        end
    end

    if not detectedElem and combatMagic and combatMagic:IsValid() and not state.ActiveMacro then
        pcall(function()
            if combatMagic.LastChainedSpell and combatMagic.LastChainedSpell:IsValid() then
                local full = SpellScanner.SafeGetName(combatMagic.LastChainedSpell)
                local cat = SpellScanner.ClassifySpellAsset(full, SpellScanner.ExtractShortObjectName(full))
                if cat and not cat:lower():find("^ham_") then
                    detectedElem = cat:gsub("_Wand$", ""):gsub("_Hold$", "")
                    weaponSuffix = cat:find("_Wand$") and "_Wand" or ""
                end
            end
        end)
        if not detectedElem then
            pcall(function()
                if combatMagic.CurrentSpellActor and combatMagic.CurrentSpellActor:IsValid() then
                    local spellData = combatMagic.CurrentSpellActor.Data
                    if spellData and spellData:IsValid() then
                        local full = SpellScanner.SafeGetName(spellData)
                        local cat = SpellScanner.ClassifySpellAsset(full, SpellScanner.ExtractShortObjectName(full))
                        if cat and not cat:lower():find("^ham_") then
                            detectedElem = cat:gsub("_Wand$", ""):gsub("_Hold$", "")
                            weaponSuffix = cat:find("_Wand$") and "_Wand" or ""
                        end
                    end
                end
            end)
        end
    end

    state.LastKnownWeaponSuffix = weaponSuffix
    if detectedElem then
        local isBaseFour = (detectedElem == "Fire" or detectedElem == "Water" or detectedElem == "Air" or detectedElem == "Earth")
        local fullCat = isBaseFour and (detectedElem .. weaponSuffix) or detectedElem

        if not state.ActiveMacro and not state.PendingAnchorReturn and state.LastKnownEquippedElement and state.LastKnownEquippedElement ~= fullCat then
            debugLogFn("Equipped element changed: " .. tostring(state.LastKnownEquippedElement) .. " -> " .. tostring(fullCat))
            state.AnchorElement = fullCat
            state.PendingAnchorReturn = false
            state.LastObservedChainedSpell = nil
            if combatMagic and combatMagic:IsValid() then
                pcall(function() combatMagic.LastChainedSpell = nil end)
            end
        end

        state.LastKnownEquippedElement = fullCat
        return fullCat
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

return EquipmentRunes
