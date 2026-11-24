-- Arcane Wilds v1.67.0 - Custom Spell Scaffolding Module
-- Parses custom_spells.txt definitions (e.g., FlamesOfZamorak, StormOfArmadyl) and resolves
-- base DominionSpellData + optional VFX/SFX/Montage overrides at runtime.

local CustomSpells = {}

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

-- Find a live UObject by short name or full path (supports NiagaraSystem, SoundWave/SoundCue, AnimMontage, etc.)
local function FindObjectByNameOrHint(nameStr, safeGetNameFn, extractShortFn)
    if not nameStr or nameStr == "" then return nil end
    local targetLower = nameStr:lower()

    -- First check loaded candidate classes in Unreal object space
    local classesToSearch = {
        "NiagaraSystem",
        "SoundWave",
        "SoundCue",
        "AnimMontage",
        "DominionSpellData",
        "BlueprintGeneratedClass",
        "Object"
    }

    for _, clsName in ipairs(classesToSearch) do
        local ok, objs = pcall(function() return FindAllOf(clsName) end)
        if ok and objs then
            for _, obj in ipairs(objs) do
                if obj then
                    local full = safeGetNameFn(obj)
                    if full ~= "" then
                        local short = extractShortFn(full):lower()
                        local fLower = full:lower()
                        if short == targetLower or fLower:find(targetLower, 1, true) then
                            return obj, full, extractShortFn(full)
                        end
                    end
                end
            end
        end
    end

    return nil, nil, nil
end

-- Build resolved custom spell entries on top of spellRegistry and register them so combo_rules.txt
-- and spell_names.txt can reference custom spells directly.
function CustomSpells.BuildCustomRegistryEntries(defs, spellRegistry, spellChains, runeCache, safeGetNameFn, extractShortFn)
    local customEntries = {}
    if not defs then return customEntries end

    for keyLower, def in pairs(defs) do
        local baseKey = def.baseSpell and def.baseSpell:lower() or nil
        local baseEntry = baseKey and spellRegistry[baseKey] or nil

        -- Fallback: if baseSpell wasn't in spellRegistry directly, try finding it via FindObjectByNameOrHint
        local resolvedBaseSpellObj = baseEntry and baseEntry.spellObj or nil
        if not resolvedBaseSpellObj and def.baseSpell then
            local foundObj = FindObjectByNameOrHint(def.baseSpell, safeGetNameFn, extractShortFn)
            if foundObj then
                resolvedBaseSpellObj = foundObj
            end
        end

        if resolvedBaseSpellObj then
            local vfxObj, vfxFull, vfxShort = FindObjectByNameOrHint(def.vfx, safeGetNameFn, extractShortFn)
            local sfxObj, sfxFull, sfxShort = FindObjectByNameOrHint(def.sfx, safeGetNameFn, extractShortFn)
            local montObj, montFull, montShort = FindObjectByNameOrHint(def.montage, safeGetNameFn, extractShortFn)

            local effectiveMontage = (montObj and montObj:IsValid() and montObj) or (baseEntry and baseEntry.montageObj) or nil
            local effectiveMontageName = montShort or (baseEntry and baseEntry.montageName) or nil
            local effectiveCategory = def.category or (baseEntry and baseEntry.categoryTag) or "Custom"

            -- Build merged costItems if custom RuneCost / RuneCount is specified
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

-- Trigger optional custom SFX / VFX hooks when a custom spell fires
function CustomSpells.TriggerCustomPresentation(pawn, entry, safeGetNameFn)
    if not entry or not entry.isCustomSpell then return end
    if pawn and pawn:IsValid() then
        if entry.customSfxObj then
            pcall(function()
                local gpStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
                if gpStatics and gpStatics:IsValid() and gpStatics.PlaySoundAtLocation then
                    local loc = pawn:K2_GetActorLocation()
                    gpStatics:PlaySoundAtLocation(pawn, entry.customSfxObj, loc)
                end
            end)
        end
        if entry.customVfxObj then
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
