-- Arcane Wilds v1.70.1 - Custom Spell Scaffolding Module
-- Parses custom_spells.txt definitions (e.g., FlamesOfZamorak, StormOfArmadyl) and resolves
-- base DominionSpellData + optional VFX/SFX/Montage overrides safely without heavy FindAllOf scans.

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
                        elseif key == "impactaoe" or key == "impactspell" or key == "aoespell" or key == "projectileaoe" then
                            current.impactAoE = val
                        elseif key == "impactvfx" or key == "impactniagara" then
                            current.impactVfx = val
                        elseif key == "impactsfx" or key == "impactsound" then
                            current.impactSfx = val
                        end
                    end
                end
            end
        end
    end

    return defs
end

-- Fast O(1) lookup via StaticFindObject (never call FindAllOf on NiagaraSystem/SoundWave/AnimMontage
-- during startup, as enumerating thousands of audio/VFX/animation assets stalls world load!).
local function FindObjectFast(nameStr, safeGetNameFn, extractShortFn)
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

    local found = nil
    if nameStr:find("/", 1, true) then
        pcall(function()
            local obj = StaticFindObject(nameStr)
            if obj and obj:IsValid() then found = obj end
        end)
    end

    if found and found:IsValid() then
        local full = safeGetNameFn(found)
        local short = extractShortFn(full)
        ObjectLookupCache[targetLower] = { obj = found, full = full, short = short }
        return found, full, short
    end

    ObjectLookupCache[targetLower] = false
    return nil, nil, nil
end

local function ExtractMontageFromSpellModules(spellObj, safeGetNameFn, extractShortFn)
    local montObj, montShort = nil, nil
    if not spellObj or not spellObj:IsValid() then return nil, nil end
    pcall(function()
        local mods = spellObj.Modules
        if mods and mods.Modules then
            mods.Modules:ForEach(function(_, elemWrapper)
                if montObj then return end
                local modObj = nil
                pcall(function() modObj = elemWrapper:get().Module end)
                if modObj and modObj:IsValid() and safeGetNameFn(modObj):find("SpellModule_PlayMontage") then
                    local m = nil
                    pcall(function() m = modObj.Montage end)
                    if m and m:IsValid() then
                        montObj = m
                        montShort = extractShortFn(safeGetNameFn(m))
                    end
                end
            end)
        end
    end)
    return montObj, montShort
end

function CustomSpells.BuildCustomRegistryEntries(defs, spellRegistry, spellChains, runeCache, safeGetNameFn, extractShortFn)
    local customEntries = {}
    if not defs or next(defs) == nil then return customEntries end

    for keyLower, def in pairs(defs) do
        local baseKey = def.baseSpell and def.baseSpell:lower() or nil
        local baseEntry = baseKey and spellRegistry[baseKey] or nil

        -- Also allow matching by short name if BaseSpell was given as a full path
        if not baseEntry and def.baseSpell then
            local shortKey = extractShortFn(def.baseSpell):lower()
            baseEntry = spellRegistry[shortKey]
        end

        local resolvedBaseSpellObj = baseEntry and baseEntry.spellObj or nil
        if not resolvedBaseSpellObj and def.baseSpell then
            local candidatePaths = {}
            if def.baseSpell:find("/", 1, true) then
                table.insert(candidatePaths, def.baseSpell)
            else
                -- Probe standard Dominion special asset path directly via O(1) StaticFindObject
                local stripSpec = def.baseSpell:gsub("^[Dd][Aa]_", ""):gsub("_[Ss]pecial$", "")
                table.insert(candidatePaths, "/Game/Gameplay/Character/Player/Spells/Specials/" .. stripSpec .. "/" .. def.baseSpell .. "." .. def.baseSpell)
                table.insert(candidatePaths, "/Game/Gameplay/Character/Player/Spells/Specials/" .. def.baseSpell .. "." .. def.baseSpell)
            end
            for _, p in ipairs(candidatePaths) do
                local foundObj = FindObjectFast(p, safeGetNameFn, extractShortFn)
                if foundObj then
                    resolvedBaseSpellObj = foundObj
                    break
                end
            end
        end

        if resolvedBaseSpellObj and resolvedBaseSpellObj:IsValid() then
            -- Check spellRegistry first for VFX/SFX if referencing another spell (e.g. HAM_IceBarrage),
            -- otherwise use fast StaticFindObject if a full object path is provided.
            local vfxObj, vfxShort = nil, nil
            if def.vfx and def.vfx ~= "" then
                local regVfx = spellRegistry[def.vfx:lower()]
                if regVfx and regVfx.spellObj and regVfx.spellObj:IsValid() then
                    vfxObj = regVfx.spellObj
                    vfxShort = regVfx.shortName
                else
                    vfxObj, _, vfxShort = FindObjectFast(def.vfx, safeGetNameFn, extractShortFn)
                end
            end

            local sfxObj, _, sfxShort = FindObjectFast(def.sfx, safeGetNameFn, extractShortFn)
            local montObj, _, montShort = FindObjectFast(def.montage, safeGetNameFn, extractShortFn)
            if not montObj then
                montObj, montShort = ExtractMontageFromSpellModules(resolvedBaseSpellObj, safeGetNameFn, extractShortFn)
            end

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

            local resolvedFull = baseEntry and baseEntry.fullName or safeGetNameFn(resolvedBaseSpellObj)
            local isSpecialBase = resolvedFull:lower():find("/spells/specials/") ~= nil
                or resolvedFull:lower():find("_special") ~= nil
                or (baseEntry and baseEntry.isSpecialSpell) or false

            local entry = {
                spellObj = resolvedBaseSpellObj,
                montageObj = effectiveMontage,
                costItems = mergedCosts,
                prevSpellObj = baseEntry and baseEntry.prevSpellObj or nil,
                categoryTag = effectiveCategory,
                stepIndex = baseEntry and baseEntry.stepIndex or 0,
                shortName = def.name,
                fullName = resolvedFull,
                montageName = effectiveMontageName,
                isSmash = def.clamp or (baseEntry and baseEntry.isSmash) or false,
                isSpecialSpell = isSpecialBase,
                isCustomSpell = true,
                customDef = def,
                customVfxObj = vfxObj,
                customVfxName = vfxShort or def.vfx,
                customSfxObj = sfxObj,
                customSfxName = sfxShort or def.sfx,
                customOverrideSpeed = def.speed
            }

            if def.impactAoE and def.impactAoE ~= "" then
                entry.impactAoEName = def.impactAoE
            end
            if def.impactVfx and def.impactVfx ~= "" then
                entry.impactVfxObj, _, entry.impactVfxName = FindObjectFast(def.impactVfx, safeGetNameFn, extractShortFn)
            end
            if def.impactSfx and def.impactSfx ~= "" then
                entry.impactSfxObj, _, entry.impactSfxName = FindObjectFast(def.impactSfx, safeGetNameFn, extractShortFn)
            end

            customEntries[keyLower] = entry
        end
    end

    return customEntries
end

-- Arm a pending impact AoE when a projectile spell (like a normal Fire bolt/explosion) is fired
-- with `ImpactAoE = DA_ZamorakStaff_Special` set in custom_spells.txt.
function CustomSpells.ArmProjectileImpactAoE(state, pawn, entry, safeGetNameFn, extractShortFn)
    if not state or not entry or not entry.impactAoEName or entry.impactAoEName == "" then
        return
    end
    local targetKey = entry.impactAoEName:lower()
    local aoeEntry = state.SpellRegistry and state.SpellRegistry[targetKey] or nil
    if not aoeEntry then
        local shortK = extractShortFn(entry.impactAoEName):lower()
        aoeEntry = state.SpellRegistry and state.SpellRegistry[shortK] or nil
    end

    local startLoc = nil
    if pawn and pawn:IsValid() then
        pcall(function() startLoc = pawn:K2_GetActorLocation() end)
    end

    state.PendingImpactAoE = {
        aoeSpellObj = aoeEntry and aoeEntry.spellObj or nil,
        aoeName = entry.impactAoEName,
        vfxObj = entry.impactVfxObj or (aoeEntry and aoeEntry.customVfxObj),
        sfxObj = entry.impactSfxObj or (aoeEntry and aoeEntry.customSfxObj),
        lastKnownLoc = startLoc,
        armedAt = os.clock(),
        sawActor = false
    }
end

local function FireImpactAtLocation(pawn, pending, loc)
    if not pending then return end
    if pending.aoeSpellObj and pending.aoeSpellObj:IsValid() and pawn and pawn:IsValid() then
        pcall(function()
            local bpLib = StaticFindObject("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
            if bpLib and bpLib:IsValid() and bpLib.TriggerModularAbilityForPlayer then
                bpLib:TriggerModularAbilityForPlayer(pawn, pending.aoeSpellObj)
            end
        end)
    end
    if loc then
        if pending.sfxObj and pending.sfxObj:IsValid() then
            pcall(function()
                local gpStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
                if gpStatics and gpStatics:IsValid() and gpStatics.PlaySoundAtLocation then
                    gpStatics:PlaySoundAtLocation(pawn, pending.sfxObj, loc)
                end
            end)
        end
        if pending.vfxObj and pending.vfxObj:IsValid() then
            pcall(function()
                local nsFuncLib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
                if nsFuncLib and nsFuncLib:IsValid() and nsFuncLib.SpawnSystemAtLocation then
                    nsFuncLib:SpawnSystemAtLocation(pawn, pending.vfxObj, loc)
                end
            end)
        end
    end
end

-- Called on tick: tracks the flying projectile/spell actor location and triggers the AoE at the impact point
-- once the projectile actor detaches/impacts (or after flight completes).
function CustomSpells.TickProjectileImpactAoE(state, pawn, combatMagic)
    local p = state.PendingImpactAoE
    if not p then return end

    local now = os.clock()
    local age = now - (p.armedAt or now)

    local activeActor = nil
    if combatMagic and combatMagic:IsValid() then
        pcall(function()
            local a = combatMagic.CurrentSpellActor
            if a and a:IsValid() then activeActor = a end
        end)
    end

    if activeActor then
        p.sawActor = true
        pcall(function()
            local actorLoc = activeActor:K2_GetActorLocation()
            if actorLoc then p.lastKnownLoc = actorLoc end
        end)
        if age < 3.5 then
            return
        end
    end

    -- Projectile has impacted/cleared (or flight window elapsed): fire AoE at the tracked impact spot
    if p.sawActor or age >= 0.45 then
        local targetLoc = p.lastKnownLoc
        state.PendingImpactAoE = nil
        if pawn and pawn:IsValid() then
            FireImpactAtLocation(pawn, p, targetLoc)
        end
    elseif age >= 4.0 then
        state.PendingImpactAoE = nil
    end
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
