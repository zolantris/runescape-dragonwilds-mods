-- Arcane Wilds - Direct Asset Discovery, Montage Indexing & Sequence Chain Builder

local SpellScanner = {}

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
                        pcall(function() modObj.bShouldBlockMovement = false end)
                        pcall(function() modObj.bBlockMovement = false end)
                        pcall(function() modObj.MaxMovementSpeedDuringMontage = spd end)
                        pcall(function() modObj.MaxMovementSpeed = spd end)
                        pcall(function() modObj.bAllowTriggeringNotifiesMultipleTimes = true end)
                        local m = nil
                        pcall(function() m = modObj.Montage end)
                        if m and m:IsValid() then
                            pcall(function() m.bEnableRootMotionTranslation = false end)
                            pcall(function() m.bEnableRootMotionRotation = false end)
                        end
                    end
                end
            end)
        end
    end)
end

local function PatchSpellModules(spellObj, cfg, chainEntry, idx, lowerName)
    local shouldUnlock = chainEntry and ShouldUnlockCategory(chainEntry.tag:lower(), chainEntry.isModded, cfg) or (cfg.UnlockModdedCombat ~= false)
    local isSmash = (idx == 3 and chainEntry and (chainEntry.tag:lower():find("^air") or lowerName:find("slam") or lowerName:find("smash")))
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
                        local montage = nil
                        pcall(function() montage = modObj.Montage end)
                        if montage and montage:IsValid() then
                            foundMontage = montage
                            foundMontageName = SpellScanner.ExtractShortObjectName(SpellScanner.SafeGetName(montage))
                            if chainEntry then
                                chainEntry.montages[idx] = montage
                                chainEntry.montageNames[idx] = foundMontageName
                            end
                        end
                        if shouldUnlock and not (isSmash and cfg.KeepGroundSmashAnchored) then
                            pcall(function() modObj.bShouldBlockMovement = false end)
                            pcall(function() modObj.bBlockMovement = false end)
                            pcall(function() modObj.MaxMovementSpeedDuringMontage = cfg.MaxMoveSpeed end)
                            pcall(function() modObj.MaxMovementSpeed = cfg.MaxMoveSpeed end)
                            pcall(function() modObj.bAllowTriggeringNotifiesMultipleTimes = true end)
                            if montage and montage:IsValid() then
                                pcall(function() montage.bEnableRootMotionTranslation = false end)
                                pcall(function() montage.bEnableRootMotionRotation = false end)
                            end
                        else
                            pcall(function() modObj.bAllowTriggeringNotifiesMultipleTimes = true end)
                        end
                    else
                        ExtractCostItemsFromModule(modObj, costItems)
                    end
                end
            end)
        end
    end)

    return foundMontage, foundMontageName, costItems
end

-- Returns:
--   newChains: [catLower] = { tag, isModded, chainName, steps[0..3], stepNames[0..3], montages[0..3], montageNames[0..3] }
--   orderedChains: sorted list of chains
--   spellRegistry: [assetNameLower] = { spellObj, montageObj, prevSpellObj, categoryTag, shortName, fullName, montageName, isSmash }
--   discoveredLookup: [shortNameOrMontageLower] = canonicalShortName (for direct rule resolution)
--   compactSummary: string
function SpellScanner.ScanAndPatchSpells(cfg, modVersion, detectedPath, nameMapByCat, globalNameMap)
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
