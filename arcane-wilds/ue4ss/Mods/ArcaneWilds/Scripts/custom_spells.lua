-- Arcane Wilds v1.70.0 - Custom Spell Scaffolding Module
-- Parses custom_spells.txt definitions (e.g., FlamesOfZamorak, StormOfArmadyl) and resolves
-- base DominionSpellData + optional VFX/SFX/Montage overrides safely without scanning all UObjects.

local CustomSpells = {}
local ObjectLookupCache = {}

local function Trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function ParseBool(v, defaultVal)
    if v == nil then return defaultVal end
    local l = Trim(tostring(v)):lower()
    if l == "true" or l == "1" or l == "yes" or l == "on" then return true end
    if l == "false" or l == "0" or l == "no" or l == "off" then return false end
    return defaultVal
end

function CustomSpells.ClearCache()
    ObjectLookupCache = {}
end

function CustomSpells.ParseDefinitions(rawText)
    local defs = {}
    if not rawText or rawText == "" then
        return defs
    end

    local current = nil
    for line in rawText:gmatch("[^\r\n]+") do
        local clean = Trim(line)
        if clean ~= "" and not clean:match("^#") and not clean:match("^;") then
            local hashPos = clean:find("#", 1, true)
            if hashPos then
                clean = Trim(clean:sub(1, hashPos - 1))
            end
            if clean ~= "" then
                local sectionName = clean:match("^%[([^%[%]]+)%]$")
                if sectionName then
                    local nameTrimmed = Trim(sectionName)
                    if nameTrimmed ~= "" then
                        current = {
                            name = nameTrimmed,
                            nameLower = nameTrimmed:lower(),
                            baseSpell = nil,
                            category = nil,
                            vfx = nil,
                            sfx = nil,
                            montage = nil,
                            speed = nil,
                            clamp = false,
                            runeCost = nil,
                            runeCount = 1
                        }
                        defs[current.nameLower] = current
                    end
                elseif current then
                    local k, v = clean:match("^([%w_]+)%s*=%s*(.+)$")
                    if k and v then
                        local key = Trim(k):lower()
                        local val = Trim(v)
                        if val == "" then val = nil end
                        if key == "basespell" or key == "spell" or key == "base" then
                            current.baseSpell = val
                        elseif key == "category" or key == "element" then
                            current.category = val
                        elseif key == "vfx" or key == "niagara" or key == "effect" then
                            current.vfx = val
                        elseif key == "sfx" or key == "sound" or key == "audio" then
                            current.sfx = val
                        elseif key == "montage" or key == "anim" then
                            current.montage = val
                        elseif key == "speed" or key == "playrate" then
                            current.speed = val and tonumber(val) or nil
                        elseif key == "clamp" or key == "clamped" then
                            current.clamp = ParseBool(val, false)
                        elseif key == "runecost" or key == "rune" then
                            current.runeCost = val and val:lower() or nil
                        elseif key == "runecount" or key == "count" then
                            current.runeCount = math.max(1, math.floor(tonumber(val) or 1))
                        end
                    end
                end
            end
        end
    end

    return defs
end

-- Search ONLY specific lightweight asset classes (NEVER FindAllOf("Object") or "BlueprintGeneratedClass",
-- which enumerates hundreds of thousands of engine UObjects and freezes startup!).
local function FindAssetInClass(clsName, targetLower, safeGetNameFn, extractShortFn)
    local ok, objs = pcall(function() return FindAllOf(clsName) end)
    if not ok or not objs then return nil, nil, nil end
    for _, obj in ipairs(objs) do
        if obj and obj:IsValid() then
            local full = safeGetNameFn(obj)
            if full ~= "" then
                local short = extractShortFn(full)
                local sLower = short:lower()
                if sLower == targetLower or full:lower():find(targetLower, 1, true) then
                    return obj, full, short
                end
            end
        end
    end
    return nil, nil, nil
end

local function FindObjectByNameOrHint(nameStr, preferredClasses, safeGetNameFn, extractShortFn)
    if not nameStr or nameStr == "" then return nil, nil, nil end
    local targetLower = nameStr:lower()

    local cached = ObjectLookupCache[targetLower]
    if cached ~= nil then
        if cached == false then return nil, nil, nil end
        if cached.obj and cached.obj:IsValid() then
            return cached.obj, cached.full, cached.short
        end
        ObjectLookupCache[targetLower] = nil
    end

    for _, clsName in ipairs(preferredClasses) do
        local obj, full, short = FindAssetInClass(clsName, targetLower, safeGetNameFn, extractShortFn)
        if obj then
            ObjectLookupCache[targetLower] = { obj = obj, full = full, short = short }
            return obj, full, short
        end
    end

    -- Cache negative result so startup doesn't re-scan missing assets on every config poll
    ObjectLookupCache[targetLower] = false
    return nil, nil, nil
end

function CustomSpells.BuildCustomRegistryEntries(defs, spellRegistry, spellChains, runeCache, safeGetNameFn, extractShortFn)
    local customEntries = {}
    if not defs or next(defs) == nil then return customEntries end

    for keyLower, def in pairs(defs) do
        local baseKey = def.baseSpell and def.baseSpell:lower() or nil
        local baseEntry = baseKey and spellRegistry[baseKey] or nil

        local resolvedBaseSpellObj = baseEntry and baseEntry.spellObj or nil
        if not resolvedBaseSpellObj and def.baseSpell then
            local foundObj = FindObjectByNameOrHint(def.baseSpell, { "DominionSpellData" }, safeGetNameFn, extractShortFn)
            if foundObj then
                resolvedBaseSpellObj = foundObj
            end
        end

        if resolvedBaseSpellObj and resolvedBaseSpellObj:IsValid() then
            local vfxObj, _, vfxShort = FindObjectByNameOrHint(
                def.vfx, { "NiagaraSystem", "DominionSpellData" }, safeGetNameFn, extractShortFn)
            local sfxObj, _, sfxShort = FindObjectByNameOrHint(
                def.sfx, { "SoundWave", "SoundCue" }, safeGetNameFn, extractShortFn)
            local montObj, _, montShort = FindObjectByNameOrHint(
                def.montage, { "AnimMontage" }, safeGetNameFn, extractShortFn)

            local effectiveMontage = (montObj and montObj:IsValid() and montObj) or (baseEntry and baseEntry.montageObj) or nil
            local effectiveMontageName = montShort or (baseEntry and baseEntry.montageName) or nil
            local effectiveCategory = def.category or (baseEntry and baseEntry.categoryTag) or "Custom"

            local mergedCosts = {}
            if def.runeCost and runeCache and runeCache[def.runeCost] then
                local rObj = runeCache[def.runeCost]
                table.insert(mergedCosts, {
                    itemData = rObj,
                    itemName = extractShortFn(safeGetNameFn(rObj)),
                    count = def.runeCount or 1
                })
            elseif baseEntry and baseEntry.costItems then
                for _, c in ipairs(baseEntry.costItems) do
                    table.insert(mergedCosts, c)
                end
            end

            local entry = {
                spellObj = resolvedBaseSpellObj,
                montageObj = effectiveMontage,
                costItems = mergedCosts,
                prevSpellObj = baseEntry and baseEntry.prevSpellObj or nil,
                categoryTag = effectiveCategory,
                stepIndex = baseEntry and baseEntry.stepIndex or 0,
                shortName = def.name,
                fullName = baseEntry and baseEntry.fullName or safeGetNameFn(resolvedBaseSpellObj),
                montageName = effectiveMontageName,
                isSmash = def.clamp or (baseEntry and baseEntry.isSmash) or false,
                isCustomSpell = true,
                customDef = def,
                customVfxObj = vfxObj,
                customVfxName = vfxShort or def.vfx,
                customSfxObj = sfxObj,
                customSfxName = sfxShort or def.sfx,
                customOverrideSpeed = def.speed
            }

            customEntries[keyLower] = entry
        end
    end

    return customEntries
end

function CustomSpells.TriggerCustomPresentation(pawn, entry, safeGetNameFn)
    if not entry or not entry.isCustomSpell then return end
    if pawn and pawn:IsValid() then
        if entry.customSfxObj and entry.customSfxObj:IsValid() then
            pcall(function()
                local gpStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
                if gpStatics and gpStatics:IsValid() and gpStatics.PlaySoundAtLocation then
                    local loc = pawn:K2_GetActorLocation()
                    gpStatics:PlaySoundAtLocation(pawn, entry.customSfxObj, loc)
                end
            end)
        end
        if entry.customVfxObj and entry.customVfxObj:IsValid() then
            pcall(function()
                local nsFuncLib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
                if nsFuncLib and nsFuncLib:IsValid() and nsFuncLib.SpawnSystemAtLocation then
                    local loc = pawn:K2_GetActorLocation()
                    nsFuncLib:SpawnSystemAtLocation(pawn, entry.customVfxObj, loc)
                end
            end)
        end
    end
end

return CustomSpells
