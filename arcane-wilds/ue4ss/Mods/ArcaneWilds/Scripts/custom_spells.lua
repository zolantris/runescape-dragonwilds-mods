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


local LazyKeywordCache = {}

local WEATHER_KEYWORDS = { "lightning", "storm", "thunder", "rain", "weather", "bolt", "tempest", "gale" }

local function MatchesWeatherOrKeyword(fullLower, kwLower)
    if fullLower:find(kwLower, 1, true) then return true end
    if kwLower == "lightning" or kwLower == "storm" or kwLower == "rain" or kwLower == "weather" then
        for _, w in ipairs(WEATHER_KEYWORDS) do
            if fullLower:find(w, 1, true) then return true end
        end
    end
    return false
end

local function FindAssetByKeywordOnDemand(className, keywordStr, safeGetNameFn)
    if not keywordStr or keywordStr == "" then return nil end
    if keywordStr:find("/", 1, true) then
        local obj = nil
        pcall(function() obj = StaticFindObject(keywordStr) end)
        if obj and obj:IsValid() then return obj end
    end
    local cacheKey = className .. ":" .. keywordStr:lower()
    if LazyKeywordCache[cacheKey] ~= nil then
        local cached = LazyKeywordCache[cacheKey]
        if cached == false then return nil end
        if cached and cached:IsValid() then return cached end
        LazyKeywordCache[cacheKey] = nil
    end

    local kw = keywordStr:lower()
    local bestObj = nil
    if className == "AnimMontage" then
        local directMontPaths = {
            "/Game/Art/Animation/PlayerM/Greatsword/AM_PlayerM_Attack_2H_Greatsword_Secondary.AM_PlayerM_Attack_2H_Greatsword_Secondary",
            "/Game/Art/Animation/PlayerM/Greatsword/A_PlayerM_Attack_Greatsword_Secondary.A_PlayerM_Attack_Greatsword_Secondary"
        }
        for _, p in ipairs(directMontPaths) do
            if p:lower():find(kw, 1, true) or kw:find("greatsword", 1, true) or kw:find("secondary", 1, true) or kw:find("saradomin", 1, true) then
                pcall(function()
                    local dObj = StaticFindObject(p)
                    if dObj and dObj:IsValid() then bestObj = dObj end
                end)
                if bestObj then break end
            end
        end
    end
    pcall(function()
        local all = FindAllOf(className)
        if all then
            for _, item in ipairs(all) do
                if item and item:IsValid() then
                    local full = safeGetNameFn(item):lower()
                    if MatchesWeatherOrKeyword(full, kw) and not full:find("default__") then
                        bestObj = item
                        if full:find("lightning") or full:find("storm") or full:find("thunder") or full:find("strike") then
                            break
                        end
                    end
                end
            end
        end
    end)
    LazyKeywordCache[cacheKey] = bestObj or false
    return bestObj
end

function CustomSpells.ClearCache()
    LazyKeywordCache = {}
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
                            if val and (val:lower() == "none" or val:lower() == "nil" or val:lower() == "false") then
                                current.baseSpell = nil
                                current.suppressBaseSpell = true
                            else
                                current.baseSpell = val
                            end
                        elseif key == "suppressbasespell" or key == "nobasespell" then
                            current.suppressBaseSpell = ParseBool(val, false)
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
                        elseif key == "impactlightning" or key == "lightning" or key == "stormvfx" then
                            current.impactLightning = val
                        elseif key == "impactvfx" or key == "impactniagara" then
                            current.impactVfx = val
                        elseif key == "impactsfx" or key == "impactsound" then
                            current.impactSfx = val
                        elseif key == "impactdamagemin" or key == "damagemin" or key == "rollmin" then
                            current.impactDamageMin = tonumber(val)
                        elseif key == "impactdamagemax" or key == "damagemax" or key == "rollmax" then
                            current.impactDamageMax = tonumber(val)
                        elseif key == "impactradius" or key == "damageradius" or key == "radius" then
                            current.impactRadius = tonumber(val)
                        elseif key == "spawnactor" or key == "actor" or key == "bpactor" then
                            current.spawnActor = val
                        elseif key == "allowunsafespawn" or key == "forcespawnactor" then
                            current.allowUnsafeSpawn = ParseBool(val, false)
                        elseif key == "safemontage" or key == "skipmontage" then
                            current.skipMontage = ParseBool(val, false)
                        elseif key == "spinhitbox" or key == "radiushitbox" or key == "areahitbox" or key == "hitbox" then
                            current.spinHitbox = ParseBool(val, false)
                        elseif key == "hitradius" or key == "spinradius" or key == "arearadius" then
                            current.hitRadius = tonumber(val)
                        elseif key == "hitdamagemin" or key == "spindamagemin" or key == "areadamagemin" then
                            current.hitDamageMin = tonumber(val)
                        elseif key == "hitdamagemax" or key == "spindamagemax" or key == "areadamagemax" then
                            current.hitDamageMax = tonumber(val)
                        elseif key == "hitdelaysec" or key == "spindelaysec" or key == "hitdelay" then
                            current.hitDelaySec = tonumber(val)
                        elseif key == "hitvfx" or key == "spinvfx" or key == "areavfx" then
                            current.hitVfx = val
                        elseif key == "hitsfx" or key == "spinsfx" or key == "areasfx" then
                            current.hitSfx = val
                        elseif key == "damagespell" or key == "aoespell" or key == "spindamagespell" or key == "extraaoe" or key == "secondaryaoe" then
                            current.damageSpell = val
                        elseif key == "extraaoedelaysec" or key == "aoedelaysec" or key == "damagespelldelaysec" then
                            current.extraAoEDelaySec = tonumber(val)
                        elseif key == "damagemode" or key == "hitmode" then
                            current.damageMode = val and val:lower() or nil
                        elseif key == "suppressdirecthealth" or key == "skipdirecthealth" or key == "nodirecthealth" then
                            current.suppressDirectHealth = ParseBool(val, false)
                        elseif key == "damagege" or key == "gameplayeffect" or key == "hitge" then
                            current.damageGE = val
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

        if (not resolvedBaseSpellObj or not resolvedBaseSpellObj:IsValid()) and def.category and not def.suppressBaseSpell then
            local catL = def.category:lower()
            for _, regEntry in pairs(spellRegistry) do
                if regEntry and regEntry.spellObj and regEntry.spellObj:IsValid()
                    and (regEntry.categoryTag or ""):lower():find("^" .. catL) then
                    resolvedBaseSpellObj = regEntry.spellObj
                    baseEntry = regEntry
                    break
                end
            end
        end

        local montObj, _, montShort = FindObjectFast(def.montage, safeGetNameFn, extractShortFn)
        if not montObj and def.montage and def.montage ~= "" then
            montObj = FindAssetByKeywordOnDemand("AnimMontage", def.montage, safeGetNameFn)
            if montObj and montObj:IsValid() then
                montShort = extractShortFn(safeGetNameFn(montObj))
            end
        end

        local hasActorOrEffect = (def.spawnActor and def.spawnActor ~= "") or (def.vfx and def.vfx ~= "") or (def.sfx and def.sfx ~= "") or (def.impactDamageMin ~= nil)
        if (resolvedBaseSpellObj and resolvedBaseSpellObj:IsValid()) or (montObj and montObj:IsValid()) or (def.suppressBaseSpell and hasActorOrEffect) then
            if (not resolvedBaseSpellObj or not resolvedBaseSpellObj:IsValid()) and def.suppressBaseSpell then
                -- Never pull a DominionSpellData asset (e.g. DA_Spell_Primary_Water_Wand_03) when BaseSpell=none.
                -- Use montObj if available, or fall back to First PlayerController / Character / StaticFindObject
                -- so entry.spellObj is truthy without ever referencing a Water/Wand spell asset.
                if montObj and montObj:IsValid() then
                    resolvedBaseSpellObj = montObj
                else
                    pcall(function()
                        local pcObj = FindFirstOf("PlayerController")
                        if pcObj and pcObj:IsValid() then resolvedBaseSpellObj = pcObj end
                    end)
                end
            end
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
            if not montObj and not def.suppressBaseSpell then
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

            local resolvedFull = def.suppressBaseSpell
                and (montObj and montObj:IsValid() and safeGetNameFn(montObj) or ("CustomSuppressBase/" .. def.name))
                or (baseEntry and baseEntry.fullName or safeGetNameFn(resolvedBaseSpellObj))
            local isSpecialBase = resolvedFull:lower():find("/spells/specials/") ~= nil
                or resolvedFull:lower():find("_special") ~= nil
                or (def.montage and def.montage:lower():find("special") ~= nil)
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
                suppressBaseSpell = def.suppressBaseSpell or false,
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
            if def.impactLightning and def.impactLightning ~= "" then
                entry.impactLightningName = def.impactLightning
                entry.impactLightningObj = FindObjectFast(def.impactLightning, safeGetNameFn, extractShortFn)
            end
            if def.impactVfx and def.impactVfx ~= "" then
                entry.impactVfxName = def.impactVfx
                entry.impactVfxObj = FindObjectFast(def.impactVfx, safeGetNameFn, extractShortFn)
            end
            if def.impactSfx and def.impactSfx ~= "" then
                entry.impactSfxName = def.impactSfx
                entry.impactSfxObj = FindObjectFast(def.impactSfx, safeGetNameFn, extractShortFn)
            end
            if def.impactDamageMin or def.impactDamageMax then
                entry.impactDamageMin = def.impactDamageMin or def.impactDamageMax or 100
                entry.impactDamageMax = def.impactDamageMax or def.impactDamageMin or 180
                entry.impactRadius = def.impactRadius or 350.0
            end
            if def.spinHitbox or def.hitDamageMin or def.hitDamageMax or def.hitRadius then
                entry.spinHitbox = true
                entry.hitDamageMin = def.hitDamageMin or def.hitDamageMax or 65
                entry.hitDamageMax = def.hitDamageMax or def.hitDamageMin or 135
                entry.hitRadius = def.hitRadius or def.impactRadius or 400.0
                entry.hitDelaySec = tonumber(def.hitDelaySec) or 0.0
                if def.hitVfx and def.hitVfx ~= "" then
                    entry.hitVfxObj = FindAssetByKeywordOnDemand("NiagaraSystem", def.hitVfx, safeGetNameFn)
                end
                if def.hitSfx and def.hitSfx ~= "" then
                    entry.hitSfxObj = FindAssetByKeywordOnDemand("SoundBase", def.hitSfx, safeGetNameFn)
                        or FindAssetByKeywordOnDemand("SoundWave", def.hitSfx, safeGetNameFn)
                end
            end

            customEntries[keyLower] = entry
        end
    end

    return customEntries
end

local function ResolveImpactEntryOrSpell(state, nameStr, extractShortFn)
    if not nameStr or nameStr == "" then return nil, nil end
    local key = nameStr:lower()
    local reg = state.SpellRegistry and state.SpellRegistry[key] or nil
    if not reg then
        local sk = extractShortFn(nameStr):lower()
        reg = state.SpellRegistry and state.SpellRegistry[sk] or nil
    end
    if reg and reg.spellObj and reg.spellObj:IsValid() then
        return reg.spellObj, reg
    end
    if nameStr:find("/", 1, true) then
        local obj = nil
        pcall(function() obj = StaticFindObject(nameStr) end)
        if obj and obj:IsValid() then return obj, nil end
    end
    return nil, nil
end

-- Arm a pending impact AoE when a projectile spell (like Wind bolt DA_Spell_Primary_Air_01) is fired
-- with `ImpactAoE` / `ImpactLightning` / `ImpactDamageMin..Max` set in custom_spells.txt.
function CustomSpells.ArmProjectileImpactAoE(state, pawn, entry, safeGetNameFn, extractShortFn)
    if not state or not entry then return end
    local hasImpactSpec = (entry.impactAoEName and entry.impactAoEName ~= "")
        or (entry.impactLightningName and entry.impactLightningName ~= "")
        or (entry.impactVfxName and entry.impactVfxName ~= "")
        or (entry.impactDamageMin ~= nil)
    if not hasImpactSpec then return end

    local aoeSpellObj, aoeEntry = ResolveImpactEntryOrSpell(state, entry.impactAoEName, extractShortFn)

    -- Resolve storm lightning VFX/SFX (supports full path or lazy keyword like "lightning")
    local lightningVfx = entry.impactLightningObj
    if (not lightningVfx or not lightningVfx:IsValid()) and entry.impactLightningName then
        lightningVfx = FindAssetByKeywordOnDemand("NiagaraSystem", entry.impactLightningName, safeGetNameFn)
        if lightningVfx then entry.impactLightningObj = lightningVfx end
    end

    local vfxObj = entry.impactVfxObj or (aoeEntry and aoeEntry.customVfxObj)
    if (not vfxObj or not vfxObj:IsValid()) and entry.impactVfxName then
        vfxObj = FindAssetByKeywordOnDemand("NiagaraSystem", entry.impactVfxName, safeGetNameFn)
        if vfxObj then entry.impactVfxObj = vfxObj end
    end

    local sfxObj = entry.impactSfxObj or (aoeEntry and aoeEntry.customSfxObj)
    if (not sfxObj or not sfxObj:IsValid()) and entry.impactSfxName then
        sfxObj = FindAssetByKeywordOnDemand("SoundBase", entry.impactSfxName, safeGetNameFn)
            or FindAssetByKeywordOnDemand("SoundWave", entry.impactSfxName, safeGetNameFn)
        if sfxObj then entry.impactSfxObj = sfxObj end
    end

    local startLoc = nil
    if pawn and pawn:IsValid() then
        pcall(function() startLoc = pawn:K2_GetActorLocation() end)
    end

    state.PendingImpactAoE = {
        spellName = entry.shortName,
        aoeSpellObj = aoeSpellObj,
        aoeName = entry.impactAoEName,
        lightningVfxObj = lightningVfx,
        vfxObj = vfxObj,
        sfxObj = sfxObj,
        damageMin = entry.impactDamageMin,
        damageMax = entry.impactDamageMax,
        damageRadius = entry.impactRadius or 350.0,
        lastKnownLoc = startLoc,
        armedAt = os.clock(),
        sawActor = false
    }
end

local function ApplyRolledImpactDamage(pawn, loc, minDmg, maxDmg, radius)
    if not loc or not minDmg then return end
    local lo = math.floor(tonumber(minDmg) or 100)
    local hi = math.max(lo, math.floor(tonumber(maxDmg) or lo))
    local rolledDmg = (hi > lo) and math.random(lo, hi) or lo
    local rad = tonumber(radius) or 350.0

    local pc = nil
    pcall(function()
        if pawn and pawn:IsValid() then pc = pawn.Controller end
    end)

    -- 1. Try GameplayStatics:ApplyRadialDamage at the impact location (ignores self pawn)
    local appliedRadial = false
    pcall(function()
        local gpStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        if gpStatics and gpStatics:IsValid() and gpStatics.ApplyRadialDamage then
            local ignoreList = {}
            if pawn and pawn:IsValid() then table.insert(ignoreList, pawn) end
            appliedRadial = gpStatics:ApplyRadialDamage(
                pawn, rolledDmg, loc, rad, nil, ignoreList, pawn, pc, true, 0)
        end
    end)

    -- 2. Also scan nearby Character/AI pawns within radius and apply direct damage fallback
    --    if radial damage didn't connect or if targets use custom Dominion health/damage receivers.
    if not appliedRadial then
        pcall(function()
            local gpStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            local chars = FindAllOf("Character")
            if chars then
                for _, ch in ipairs(chars) do
                    if ch and ch:IsValid() and ch ~= pawn then
                        local cLoc = nil
                        pcall(function() cLoc = ch:K2_GetActorLocation() end)
                        if cLoc then
                            local dx = (cLoc.X or 0) - (loc.X or 0)
                            local dy = (cLoc.Y or 0) - (loc.Y or 0)
                            local dz = (cLoc.Z or 0) - (loc.Z or 0)
                            local distSq = dx * dx + dy * dy + dz * dz
                            if distSq <= (rad * rad) then
                                if gpStatics and gpStatics:IsValid() and gpStatics.ApplyDamage then
                                    pcall(function()
                                        gpStatics:ApplyDamage(ch, rolledDmg, pc, pawn, nil)
                                    end)
                                end
                            end
                        end
                    end
                end
            end
        end)
    end
end

local function FireImpactAtLocation(pawn, pending, loc)
    if not pending then return end

    -- 1. Trigger the ground smash ability/animation (e.g. DA_Spell_Primary_Air_04 / Death From Above)
    if pending.aoeSpellObj and pending.aoeSpellObj:IsValid() and pawn and pawn:IsValid() then
        pcall(function()
            local bpLib = StaticFindObject("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
            if bpLib and bpLib:IsValid() and bpLib.TriggerModularAbilityForPlayer then
                bpLib:TriggerModularAbilityForPlayer(pawn, pending.aoeSpellObj)
            end
        end)
    end

    if loc then
        -- 2. Spawn the storm lightning strike VFX at the target/impact location (even if weather is currently clear)
        if not pending.lightningVfxObj or not pending.lightningVfxObj:IsValid() then
            pending.lightningVfxObj = FindAssetByKeywordOnDemand("NiagaraSystem", pending.lightningName or "lightning", function(o)
                local ok, s = pcall(function() return o:GetFullName() end)
                return (ok and s) or ""
            end)
        end
        if pending.lightningVfxObj and pending.lightningVfxObj:IsValid() then
            pcall(function()
                local nsFuncLib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
                if nsFuncLib and nsFuncLib:IsValid() and nsFuncLib.SpawnSystemAtLocation then
                    nsFuncLib:SpawnSystemAtLocation(pawn, pending.lightningVfxObj, loc)
                end
            end)
        end

        -- 3. Spawn optional secondary impact Niagara VFX & SFX at the impact point
        if pending.vfxObj and pending.vfxObj:IsValid() then
            pcall(function()
                local nsFuncLib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
                if nsFuncLib and nsFuncLib:IsValid() and nsFuncLib.SpawnSystemAtLocation then
                    nsFuncLib:SpawnSystemAtLocation(pawn, pending.vfxObj, loc)
                end
            end)
        end
        if pending.sfxObj and pending.sfxObj:IsValid() then
            pcall(function()
                local gpStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
                if gpStatics and gpStatics:IsValid() and gpStatics.PlaySoundAtLocation then
                    gpStatics:PlaySoundAtLocation(pawn, pending.sfxObj, loc)
                end
            end)
        end

        -- 4. Roll damage on targets hit around the impact location
        if pending.damageMin then
            ApplyRolledImpactDamage(pawn, loc, pending.damageMin, pending.damageMax, pending.damageRadius)
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

function CustomSpells.StopForcedMontage(state, pawn)
    if state then state.LastForcedMontageObj = nil end
end

function CustomSpells.PlayEntryMontageOnPawn(pawn, entry, rate, state)
    if not pawn or not pawn:IsValid() or not entry then return false end
    if entry.customDef and entry.customDef.skipMontage then return false end
    local mont = entry.montageObj
    local okMont = false
    pcall(function()
        if mont and mont:IsValid() then
            okMont = true
        end
    end)
    if not okMont and entry.customDef and entry.customDef.montage and entry.customDef.montage ~= "" then
        local mName = entry.customDef.montage
        local candidatePaths = {
            mName,
            "/Game/Art/Animation/PlayerM/Greatsword/" .. mName .. "." .. mName,
            "/Game/Art/Animation/PlayerM/Greatsword/AM_PlayerM_Attack_2H_Greatsword_Secondary.AM_PlayerM_Attack_2H_Greatsword_Secondary"
        }
        for _, p in ipairs(candidatePaths) do
            local obj = nil
            pcall(function() obj = StaticFindObject(p) end)
            if obj and obj:IsValid() then
                mont = obj
                entry.montageObj = obj
                okMont = true
                break
            end
        end
    end
    if not okMont then return false end

    local rawRate = tonumber(rate) or tonumber(entry.customOverrideSpeed) or 1.0
    local mNameLow = tostring(entry.montageName or (entry.customDef and entry.customDef.montage) or ""):lower()
    local isGreatswordMont = mNameLow:find("greatsword") ~= nil or mNameLow:find("godsword") ~= nil or mNameLow:find("special") ~= nil
    local playRate = isGreatswordMont and math.min(rawRate, 1.35) or math.min(rawRate, 3.0)
    pcall(function() mont.RateScale = playRate end)

    local function runOnGameThread()
        pcall(function()
            if not pawn or not pawn:IsValid() or not mont or not mont:IsValid() then return end
            local mesh = pawn.Mesh
            if mesh and mesh:IsValid() then
                local animInst = mesh:GetAnimInstance()
                if animInst and animInst:IsValid() and animInst.Montage_Play then
                    animInst:Montage_Play(mont, playRate, 0, 0.05, true)
                    if state then state.LastForcedMontageObj = mont end
                end
            end
        end)
    end

    if type(ExecuteInGameThread) == "function" then
        pcall(function() ExecuteInGameThread(runOnGameThread) end)
    else
        runOnGameThread()
    end
    return true
end

local AI_DAMAGE_METHOD_NAMES = {
    "ApplyDamage", "ReceiveDamage", "HandleDamage", "TakeDamage", "InflictDamage",
    "DealDamage", "ProcessDamage", "OnDamageReceived", "ApplyHit", "TriggerHitReaction",
    "ModifyHealth", "AdjustHealth", "SubtractHealth", "ApplyHealthDelta", "ApplyRadialDamage"
}

local function BuildDominionDamageEventPayload(instigatorPawn, dmgAmount, instLoc, victimLoc)
    local amt = tonumber(dmgAmount) or 100.0
    local evt = nil
    pcall(function()
        local structType = StaticFindObject("/Script/Dominion.DominionDamageEvent")
        if structType and structType:IsValid() and type(structType) == "userdata" then
            if NewObject then
                evt = NewObject(structType, nil)
            end
        end
    end)
    if evt then
        pcall(function() evt.Amount = amt end)
        pcall(function() evt.AmountAbsorbedByShield = 0.0 end)
        pcall(function() evt.Instigator = instigatorPawn end)
        pcall(function() evt.Source = instigatorPawn end)
        pcall(function() if instLoc then evt.InstigatorLocation = instLoc end end)
        pcall(function() if victimLoc then evt.VictimLocation = victimLoc end end)
        pcall(function() evt.Force = 260.0 end)
        pcall(function() evt.bIsFatalHit = false end)
        pcall(function() evt.CachedDamageShouldHitReact = true end)
        return evt
    end
    return {
        Amount = amt,
        AmountAbsorbedByShield = 0.0,
        Instigator = instigatorPawn,
        Source = instigatorPawn,
        InstigatorLocation = instLoc or { X = 0, Y = 0, Z = 0 },
        VictimLocation = victimLoc or { X = 0, Y = 0, Z = 0 },
        Force = 260.0,
        bIsFatalHit = false,
        CachedDamageShouldHitReact = true
    }
end

local function MakeFStringArg(strVal)
    local s = tostring(strVal or "")
    local fstr = nil
    pcall(function()
        if type(FString) == "function" then
            fstr = FString(s)
        end
    end)
    return fstr or s
end

local function TryCallOnTargetObj(obj, instigatorPawn, dmgAmount, hitLoc, pcObj, instLoc)
    if not obj then return false, "" end
    local valid = false
    pcall(function() valid = obj:IsValid() end)
    if not valid then return false, "" end

    local calledAny = false
    local callsLog = {}
    local amtNum = tonumber(dmgAmount) or 65.0

    local hpBefore = nil
    pcall(function()
        if obj.GetAuthoritativeHealth then hpBefore = tonumber(obj:GetAuthoritativeHealth()) end
    end)

    -- Single clean health call on HealthComponent: prefer DecreaseHealth once (avoiding
    -- double-calling ModifyAuthoritativeHealth + DecreaseHealth which caused abrupt hp->0.0 deaths
    -- without GUI floaties).
    local ctxArg = MakeFStringArg("ArcaneWilds_Spin")
    local okDec = false
    pcall(function()
        if obj.DecreaseHealth then
            obj:DecreaseHealth(amtNum, ctxArg)
            okDec = true
        end
    end)
    if not okDec then
        pcall(function()
            if obj.DecreaseHealth then
                obj:DecreaseHealth(amtNum, "ArcaneWilds_Spin")
                okDec = true
            end
        end)
    end
    if okDec then
        calledAny = true
        table.insert(callsLog, "DecreaseHealth")
    elseif type(obj.ModifyAuthoritativeHealth) == "function" then
        local okMod = pcall(function() obj:ModifyAuthoritativeHealth(-amtNum) end)
        if okMod then
            calledAny = true
            table.insert(callsLog, "ModifyAuthoritativeHealth")
        end
    end

    local dmgEvt = BuildDominionDamageEventPayload(instigatorPawn, amtNum, instLoc, hitLoc)
    if type(obj.ApplyDamageFromGameplayEffect) == "function" then
        local okEvt = pcall(function()
            obj:ApplyDamageFromGameplayEffect(dmgEvt, true, true)
        end)
        if okEvt then
            calledAny = true
            table.insert(callsLog, "ApplyDamageFromGameplayEffect")
        end
    end
    if type(obj.Multicast_ApplyDamageFromGameplayEffect) == "function" then
        local okMc = pcall(function()
            obj:Multicast_ApplyDamageFromGameplayEffect(dmgEvt, 0)
        end)
        if okMc then
            calledAny = true
            table.insert(callsLog, "Multicast_ApplyDamageFromGameplayEffect")
        end
    end

    for _, fnName in ipairs(AI_DAMAGE_METHOD_NAMES) do
        local okFn, fn = pcall(function() return obj[fnName] end)
        if okFn and type(fn) == "function" then
            local okCall = pcall(function() fn(obj, amtNum, instigatorPawn, hitLoc, pcObj) end)
                or pcall(function() fn(obj, amtNum, instigatorPawn, hitLoc) end)
                or pcall(function() fn(obj, amtNum) end)
            if okCall then
                calledAny = true
                table.insert(callsLog, fnName)
            end
        end
    end

    local hpAfter = nil
    pcall(function()
        if obj.GetAuthoritativeHealth then hpAfter = tonumber(obj:GetAuthoritativeHealth()) end
    end)
    local hpDeltaStr = ""
    if hpBefore ~= nil and hpAfter ~= nil then
        hpDeltaStr = string.format(" hp:%.1f->%.1f", hpBefore, hpAfter)
    end
    return calledAny, table.concat(callsLog, "+") .. hpDeltaStr
end

local function TryInvokeAiDamageComponent(targetActor, instigatorPawn, dmgAmount, hitLoc, pcObj, instLoc)
    if not targetActor or not targetActor:IsValid() or targetActor == instigatorPawn then return false, "none" end
    local invoked = false
    local summaryParts = {}
    local callDetails = {}
    local compProps = {
        "HealthComponent",
        "AiDamageComponent", "BP_AiDamageComponent",
        "AiHitPointsComponent", "BP_AiHitPointsComponent",
        "AiHitReactionsComponent", "BP_AiHitReactionsComponent",
        "GameplayEffectsComponent"
    }
    for _, cProp in ipairs(compProps) do
        local okC, comp = pcall(function() return targetActor[cProp] end)
        if okC and comp and comp:IsValid() then
            local hpTag = ""
            if cProp == "HealthComponent" then
                pcall(function()
                    if comp.GetAuthoritativeHealth then
                        hpTag = string.format("(hp=%.1f)", tonumber(comp:GetAuthoritativeHealth()) or -1)
                    end
                end)
            end
            table.insert(summaryParts, cProp .. hpTag)
            local okCall, detail = TryCallOnTargetObj(comp, instigatorPawn, dmgAmount, hitLoc, pcObj, instLoc)
            if okCall then
                invoked = true
                if detail ~= "" then table.insert(callDetails, cProp .. ":" .. detail) end
            end
            pcall(function()
                local ncc = comp.NativeComponentContainer
                local nativeComp = ncc and ncc.Container
                if nativeComp then
                    local okN, detailN = TryCallOnTargetObj(nativeComp, instigatorPawn, dmgAmount, hitLoc, pcObj, instLoc)
                    if okN then
                        invoked = true
                        if detailN ~= "" then table.insert(callDetails, cProp .. ".Native:" .. detailN) end
                    end
                end
            end)
        end
    end
    local infoStr = (#summaryParts > 0) and table.concat(summaryParts, ",") or "no-damage-comps"
    if #callDetails > 0 then
        infoStr = infoStr .. " calls=[" .. table.concat(callDetails, ";") .. "]"
    end
    return invoked, infoStr
end

local function SafeObjName(obj)
    if not obj then return "nil" end
    local ok, n = pcall(function() return obj:GetFullName() end)
    return (ok and n) or tostring(obj)
end

local function ExecuteAroundPlayerHitbox(pawn, entry, debugLogFn)
    if not pawn or not pawn:IsValid() or not entry then return end
    local function logHb(msg)
        if debugLogFn then
            debugLogFn(msg)
        else
            pcall(function() print("[ArcaneWilds][DEBUG] " .. tostring(msg) .. "\n") end)
        end
    end

    pcall(function()
        local loc = pawn:K2_GetActorLocation()
        if not loc then
            logHb("SpinHitbox skipped: player location nil")
            return
        end
        local rad = tonumber(entry.hitRadius) or tonumber(entry.impactRadius) or 400.0
        local minD = tonumber(entry.hitDamageMin) or tonumber(entry.impactDamageMin) or 65
        local maxD = tonumber(entry.hitDamageMax) or tonumber(entry.impactDamageMax) or minD
        local lo = math.floor(tonumber(minD) or 65)
        local hi = math.max(lo, math.floor(tonumber(maxD) or lo))
        local rolledDmg = (hi > lo) and math.random(lo, hi) or lo

        logHb(string.format("SpinHitbox firing [%s] around player (%.1f,%.1f,%.1f) radius=%.1f dmg=%d",
            tostring(entry.shortName), loc.X or 0, loc.Y or 0, loc.Z or 0, rad, rolledDmg))

        if entry.hitVfxObj and entry.hitVfxObj:IsValid() then
            pcall(function()
                local nsFuncLib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
                if nsFuncLib and nsFuncLib:IsValid() and nsFuncLib.SpawnSystemAtLocation then
                    nsFuncLib:SpawnSystemAtLocation(pawn, entry.hitVfxObj, loc)
                end
            end)
        end
        if entry.hitSfxObj and entry.hitSfxObj:IsValid() then
            pcall(function()
                local gpStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
                if gpStatics and gpStatics:IsValid() and gpStatics.PlaySoundAtLocation then
                    gpStatics:PlaySoundAtLocation(pawn, entry.hitSfxObj, loc)
                end
            end)
        end
        ApplyRolledImpactDamage(pawn, loc, rolledDmg, rolledDmg, rad)

        local rSq = rad * rad
        local hitCount = 0
        local seenNames = {}
        local pawnFullLow = SafeObjName(pawn):lower()
        local candidates = {}
        local chList = FindAllOf("Character")
        if chList then
            for _, c in ipairs(chList) do table.insert(candidates, c) end
        end
        local aiList = FindAllOf("DominionAICharacter")
        if aiList then
            for _, a in ipairs(aiList) do table.insert(candidates, a) end
        end

        local pcObj = nil
        pcall(function() pcObj = pawn.Controller end)

        for _, ai in ipairs(candidates) do
            if ai and ai:IsValid() and ai ~= pawn and ai ~= pcObj then
                local fName = SafeObjName(ai)
                local fLow = fName:lower()
                if fLow ~= "" and fLow ~= pawnFullLow and not fLow:find("bp_playercharacter", 1, true) and not seenNames[fLow] then
                    seenNames[fLow] = true
                    local aLoc = nil
                    pcall(function() aLoc = ai:K2_GetActorLocation() end)
                    if aLoc then
                        local dx = (aLoc.X or 0) - (loc.X or 0)
                        local dy = (aLoc.Y or 0) - (loc.Y or 0)
                        local dz = (aLoc.Z or 0) - (loc.Z or 0)
                        local distSq = dx*dx + dy*dy + dz*dz
                        if distSq <= rSq then
                            hitCount = hitCount + 1
                            local skipDirectHp = (entry.customDef and entry.customDef.suppressDirectHealth == true)
                            local compInvoked, compInfo = false, "skipped-direct-hp"
                            if not skipDirectHp then
                                compInvoked, compInfo = TryInvokeAiDamageComponent(ai, pawn, rolledDmg, aLoc, pcObj, loc)
                            end
                            if entry.customDef and entry.customDef.damageGE and entry.customDef.damageGE ~= "" then
                                pcall(function()
                                    local geName = tostring(entry.customDef.damageGE)
                                    local geObj = StaticFindObject(geName)
                                    if not geObj or not geObj:IsValid() then
                                        geObj = FindAssetByKeywordOnDemand("Class", geName, SafeObjName)
                                            or FindAssetByKeywordOnDemand("BlueprintGeneratedClass", geName, SafeObjName)
                                    end
                                    local gComp = ai.GameplayEffectsComponent
                                    local geMethods = {}
                                    if gComp and gComp:IsValid() then
                                        for _, mName in ipairs({ "ApplyGameplayEffect", "AddGameplayEffect", "TryApplyGameplayEffect", "ApplyEffect", "Server_ApplyGameplayEffect" }) do
                                            if type(gComp[mName]) == "function" then
                                                local okG = pcall(function() gComp[mName](gComp, geObj) end)
                                                    or pcall(function() gComp[mName](gComp, geObj, pawn) end)
                                                table.insert(geMethods, mName .. ":" .. tostring(okG))
                                            end
                                        end
                                    end
                                    logHb(string.format("  GE_TRACE [%s] on %s -> geObj=%s calls=[%s]",
                                        geName, fName, geObj and SafeObjName(geObj) or "NIL", table.concat(geMethods, ",")))
                                end)
                            end
                            logHb(string.format("  Hit candidate #%d: %s dist=%.1f compInvoked=%s comps=[%s]",
                                hitCount, fName, math.sqrt(distSq), tostring(compInvoked), tostring(compInfo)))
                        end
                    end
                end
            end
        end
        if entry.customDef and entry.customDef.damageSpell and entry.customDef.damageSpell ~= "" then
            local function fireExtraAoE()
                pcall(function()
                    if not pawn or not pawn:IsValid() then
                        logHb("AOE_TRACE: skipped (pawn invalid)")
                        return
                    end
                    local specName = tostring(entry.customDef.damageSpell)
                    local spObj = nil
                    local okSfo, resSfo = pcall(function() return StaticFindObject(specName) end)
                    if okSfo and resSfo and resSfo:IsValid() then spObj = resSfo end
                    if not spObj then
                        local okKw, resKw = pcall(function()
                            return FindAssetByKeywordOnDemand("DominionSpellData", specName, SafeObjName)
                        end)
                        if okKw and resKw and resKw:IsValid() then spObj = resKw end
                    end
                    logHb(string.format("AOE_TRACE: spec='%s' resolvedObj=%s", specName, spObj and SafeObjName(spObj) or "NIL"))
                    if spObj and spObj:IsValid() then
                        local modSummary = {}
                        pcall(function()
                            local mods = spObj.Modules
                            if mods and mods.Modules then
                                mods.Modules:ForEach(function(_, elemWrapper)
                                    local okE, el = pcall(function() return elemWrapper:get() end)
                                    local modObj = okE and el and el.Module or nil
                                    if modObj and modObj:IsValid() then
                                        table.insert(modSummary, SafeObjName(modObj))
                                    end
                                end)
                            end
                        end)
                        logHb("AOE_TRACE: spell modules=[" .. table.concat(modSummary, ", ") .. "]")

                        local bpLib = StaticFindObject("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
                        local hasBpLib = (bpLib and bpLib:IsValid()) and true or false
                        local hasTrig = hasBpLib and (type(bpLib.TriggerModularAbilityForPlayer) == "function")
                        if hasTrig then
                            local okTrig, errTrig = pcall(function()
                                bpLib:TriggerModularAbilityForPlayer(pawn, spObj)
                            end)
                            logHb(string.format("AOE_TRACE: TriggerModularAbilityForPlayer ok=%s err=%s", tostring(okTrig), tostring(errTrig or "")))
                        else
                            logHb(string.format("AOE_TRACE: bpLib=%s hasTriggerModularAbilityForPlayer=%s", tostring(hasBpLib), tostring(hasTrig)))
                        end
                    end
                end)
            end
            local aoeDelay = tonumber(entry.customDef.extraAoEDelaySec) or 0.0
            if aoeDelay > 0.0 and type(ExecuteWithDelay) == "function" then
                pcall(function()
                    ExecuteWithDelay(math.max(10, math.floor(aoeDelay * 1000)), function()
                        if type(ExecuteInGameThread) == "function" then
                            ExecuteInGameThread(fireExtraAoE)
                        else
                            fireExtraAoE()
                        end
                    end)
                end)
            else
                fireExtraAoE()
            end
        end
        logHb(string.format("SpinHitbox complete: %d AI/target(s) within %.1f radius (montage=%s)", hitCount, rad, tostring(entry.montageName or "none")))
    end)
end

function CustomSpells.TriggerCustomPresentation(pawn, entry, safeGetNameFn)
    if not entry or not entry.isCustomSpell then return end
    if pawn and pawn:IsValid() then
        if entry.spinHitbox or entry.hitDamageMin then
            local delaySec = tonumber(entry.hitDelaySec) or 0.0
            if delaySec > 0.0 and type(ExecuteWithDelay) == "function" then
                local delayMs = math.max(10, math.floor(delaySec * 1000))
                pcall(function()
                    ExecuteWithDelay(delayMs, function()
                        if type(ExecuteInGameThread) == "function" then
                            ExecuteInGameThread(function() ExecuteAroundPlayerHitbox(pawn, entry) end)
                        else
                            ExecuteAroundPlayerHitbox(pawn, entry)
                        end
                    end)
                end)
            else
                if type(ExecuteInGameThread) == "function" then
                    pcall(function() ExecuteInGameThread(function() ExecuteAroundPlayerHitbox(pawn, entry) end) end)
                else
                    ExecuteAroundPlayerHitbox(pawn, entry)
                end
            end
        end
        if entry.customDef and entry.customDef.spawnActor and entry.customDef.spawnActor ~= "" and entry.customDef.allowUnsafeSpawn == true then
            pcall(function()
                local actorClass = FindAssetByKeywordOnDemand("Class", entry.customDef.spawnActor, safeGetNameFn)
                if actorClass and actorClass:IsValid() then
                    local loc = pawn:K2_GetActorLocation()
                    local rot = pawn:K2_GetActorRotation()
                    local gpStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
                    if gpStatics and gpStatics:IsValid() and gpStatics.BeginDeferredActorSpawnFromClass and gpStatics.FinishSpawningActor then
                        local spawned = gpStatics:BeginDeferredActorSpawnFromClass(pawn, actorClass, { Translation = loc, Rotation = rot, Scale3D = { X = 1, Y = 1, Z = 1 } }, 0, pawn)
                        if spawned and spawned:IsValid() then
                            gpStatics:FinishSpawningActor(spawned, { Translation = loc, Rotation = rot, Scale3D = { X = 1, Y = 1, Z = 1 } })
                        end
                    end
                end
            end)
        end
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
