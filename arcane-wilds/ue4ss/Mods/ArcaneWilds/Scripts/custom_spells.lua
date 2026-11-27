-- Arcane Wilds v1.71.0 - Custom Spell Scaffolding & Timeline Integration Module
-- Parses custom_spells.txt definitions (including simultaneous & synchronous animation/effect timelines)
-- and resolves base DominionSpellData + optional VFX/SFX/Montage overrides safely without heavy FindAllOf scans.

local TimelineParser = require("timeline_parser")
local ProgressionScaling = require("progression_scaling")
local Json = require("json")

local CustomSpells = {}
local ObjectLookupCache = {}
local AttackIdCounter = 1000
local CachedDamageFuncLib = nil
local CachedFloatiesSubsystem = nil
local CachedBridgeCDO = nil
local CheckedBridgeAsset = false

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

local WEATHER_KEYWORDS = { "lightning", "storm", "thunder", "strike", "bolt", "tempest", "electric", "spark" }

local function ScoreVfxCandidate(fullLower, kwLower)
    if fullLower:find("default__", 1, true) then return -1 end
    -- Avoid weather ambient rain/fog/cloud/UI systems when looking for lightning/combat VFX
    local penalty = 0
    if fullLower:find("rain", 1, true) or fullLower:find("cloud", 1, true) or fullLower:find("fog", 1, true)
        or fullLower:find("sky", 1, true) or fullLower:find("ambient", 1, true) or fullLower:find("ui_", 1, true) then
        penalty = -50
    end
    if fullLower:find(kwLower, 1, true) then
        local bonus = 100
        if fullLower:find("strike", 1, true) or fullLower:find("impact", 1, true) or fullLower:find("hit", 1, true) then
            bonus = bonus + 30
        end
        if fullLower:find("telegraph", 1, true) then
            bonus = bonus - 20
        end
        return bonus + penalty
    end
    if kwLower == "lightning" or kwLower == "storm" or kwLower == "thunder" then
        for idx, w in ipairs(WEATHER_KEYWORDS) do
            if fullLower:find(w, 1, true) then
                return (60 - idx * 5) + penalty
            end
        end
    end
    return -1
end

local function TryResolveLightningFromSubsystem()
    local foundVfx = nil
    pcall(function()
        local sub = FindFirstOf("LightningSubsystem")
        if sub and sub:IsValid() then
            local cls = sub.LoadedLightningClass
            if cls and cls:IsValid() then
                local cdo = nil
                pcall(function() cdo = cls:GetDefaultObject() end)
                if cdo and cdo:IsValid() then
                    pcall(function()
                        if cdo.TriggerDamageVFX and cdo.TriggerDamageVFX:IsValid() and cdo.TriggerDamageVFX.Asset and cdo.TriggerDamageVFX.Asset:IsValid() then
                            foundVfx = cdo.TriggerDamageVFX.Asset
                        end
                    end)
                end
            end
        end
    end)
    if foundVfx then return foundVfx end
    -- Also inspect any loaded ALightning instances or NiagaraComponents named TriggerDamageVFX
    pcall(function()
        local lights = FindAllOf("Lightning")
        if lights then
            for _, l in ipairs(lights) do
                if l and l:IsValid() then
                    local comp = l.TriggerDamageVFX
                    if comp and comp:IsValid() and comp.Asset and comp.Asset:IsValid() then
                        foundVfx = comp.Asset
                        break
                    end
                end
            end
        end
    end)
    return foundVfx
end

local function FindAssetByKeywordOnDemand(className, keywordStr, safeGetNameFn)
    if not keywordStr or keywordStr == "" then return nil end
    if keywordStr:find("/", 1, true) then
        local obj = nil
        pcall(function() obj = StaticFindObject(keywordStr) end)
        if (not obj or not obj:IsValid()) and type(LoadAsset) == "function" then
            pcall(function() LoadAsset(keywordStr) end)
            pcall(function() obj = StaticFindObject(keywordStr) end)
        end
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
    local bestScore = -1

    if className == "NiagaraSystem" and (kw == "lightning" or kw == "storm" or kw == "thunder") then
        local subVfx = TryResolveLightningFromSubsystem()
        if subVfx and subVfx:IsValid() then
            LazyKeywordCache[cacheKey] = subVfx
            return subVfx
        end
    end

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
    if not bestObj then
        pcall(function()
            local all = FindAllOf(className)
            if all then
                for _, item in ipairs(all) do
                    if item and item:IsValid() then
                        local full = safeGetNameFn(item):lower()
                        local score = ScoreVfxCandidate(full, kw)
                        if score > bestScore then
                            bestScore = score
                            bestObj = item
                        end
                    end
                end
            end
        end)
    end
    LazyKeywordCache[cacheKey] = bestObj or false
    return bestObj
end

function CustomSpells.ClearCache()
    LazyKeywordCache = {}
    ObjectLookupCache = {}
    CachedDamageFuncLib = nil
    CachedFloatiesSubsystem = nil
    CachedBridgeCDO = nil
    CheckedBridgeAsset = false
    ProgressionScaling.ClearCache()
end

local function CreateDefaultSpellDef(nameTrimmed)
    return {
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
        runeCount = 1,
        rawCues = {},
        jsonCues = nil,
        timelineDuration = nil,
        stepAdvanceAt = nil,
        cancelOnRelease = false,
        overlapPolicy = "replace",
        scaleTimelineWithSpeed = true,
        requiredMagicLevel = 0,
        requiredSkill = "Magic",
        unlockedByDefault = true,
        displayName = nil,
        scaleWithStaff = nil,
        damageScaling = nil,
        staffBaselineTier = nil,
        staffTierStep = nil,
        staffBonus = nil
    }
end

local function NormalizeJsonSpellDef(nameStr, raw)
    local nameTrimmed = Trim(tostring(nameStr or ""))
    if nameTrimmed == "" or type(raw) ~= "table" then return nil end
    if raw.enabled == false then return nil end

    local def = CreateDefaultSpellDef(nameTrimmed)

    if raw.displayName ~= nil and Trim(tostring(raw.displayName)) ~= "" then
        def.displayName = Trim(tostring(raw.displayName))
    end
    if raw.category ~= nil and Trim(tostring(raw.category)) ~= "" then
        def.category = Trim(tostring(raw.category))
    end

    if raw.baseSpell ~= nil then
        local bs = Trim(tostring(raw.baseSpell))
        local bsLow = bs:lower()
        if bs == "" or bsLow == "none" or bsLow == "nil" or bsLow == "false" then
            def.baseSpell = nil
            def.suppressBaseSpell = true
        else
            def.baseSpell = bs
        end
    end
    if raw.suppressBaseSpell ~= nil then
        def.suppressBaseSpell = ParseBool(raw.suppressBaseSpell, false)
    end

    if raw.speed ~= nil then def.speed = tonumber(raw.speed) end
    if raw.clamp ~= nil then def.clamp = ParseBool(raw.clamp, false) end

    if type(raw.runeCost) == "table" then
        if raw.runeCost.type ~= nil and Trim(tostring(raw.runeCost.type)) ~= "" then
            def.runeCost = Trim(tostring(raw.runeCost.type)):lower()
        end
        if raw.runeCost.count ~= nil then
            def.runeCount = math.max(1, math.floor(tonumber(raw.runeCost.count) or 1))
        end
    elseif type(raw.runeCost) == "string" and Trim(raw.runeCost) ~= "" then
        def.runeCost = Trim(raw.runeCost):lower()
    end
    if raw.runeCount ~= nil then
        def.runeCount = math.max(1, math.floor(tonumber(raw.runeCount) or 1))
    end

    if raw.timelineDuration ~= nil then
        if type(raw.timelineDuration) == "string" and raw.timelineDuration:lower() == "auto" then
            def.timelineDuration = nil
        else
            def.timelineDuration = tonumber(raw.timelineDuration)
        end
    end
    if raw.stepAdvanceAt ~= nil then def.stepAdvanceAt = tonumber(raw.stepAdvanceAt) end
    if raw.cancelOnRelease ~= nil then def.cancelOnRelease = ParseBool(raw.cancelOnRelease, false) end
    if raw.overlapPolicy ~= nil and Trim(tostring(raw.overlapPolicy)) ~= "" then
        def.overlapPolicy = Trim(tostring(raw.overlapPolicy)):lower()
    end
    if raw.scaleTimelineWithSpeed ~= nil then
        def.scaleTimelineWithSpeed = ParseBool(raw.scaleTimelineWithSpeed, true)
    end

    if type(raw.autoTarget) == "table" then
        if raw.autoTarget.range ~= nil then def.autoTargetRange = tonumber(raw.autoTarget.range) end
        if raw.autoTarget.cone ~= nil then def.autoTargetCone = tonumber(raw.autoTarget.cone) end
    end
    if raw.autoTargetRange ~= nil then def.autoTargetRange = tonumber(raw.autoTargetRange) end
    if raw.autoTargetCone ~= nil then def.autoTargetCone = tonumber(raw.autoTargetCone) end

    if raw.requiredSkill ~= nil and Trim(tostring(raw.requiredSkill)) ~= "" then
        local rs = Trim(tostring(raw.requiredSkill))
        local sk, lvStr = rs:match("^([^:]+):(%d+)$")
        if sk and lvStr then
            def.requiredSkill = Trim(sk)
            def.requiredMagicLevel = math.max(0, math.floor(tonumber(lvStr) or 0))
            if def.requiredMagicLevel > 0 then def.unlockedByDefault = false end
        else
            def.requiredSkill = rs
        end
    end
    if raw.requiredMagicLevel ~= nil then
        local lv = tonumber(raw.requiredMagicLevel)
        if lv then
            def.requiredMagicLevel = math.max(0, math.floor(lv))
            if def.requiredMagicLevel > 0 then def.unlockedByDefault = false end
        end
    end
    if raw.unlockedByDefault ~= nil then
        def.unlockedByDefault = ParseBool(raw.unlockedByDefault, true)
    end

    if raw.scaleWithStaff ~= nil then def.scaleWithStaff = ParseBool(raw.scaleWithStaff, true) end
    if raw.damageScaling ~= nil and Trim(tostring(raw.damageScaling)) ~= "" then
        def.damageScaling = Trim(tostring(raw.damageScaling)):lower()
    end
    if raw.staffBaselineTier ~= nil then def.staffBaselineTier = tonumber(raw.staffBaselineTier) end
    if raw.staffTierStep ~= nil then def.staffTierStep = tonumber(raw.staffTierStep) end
    if raw.staffBonus ~= nil then def.staffBonus = raw.staffBonus end

    -- Optional structured timeline cues
    if type(raw.cues) == "table" and #raw.cues > 0 then
        def.jsonCues = raw.cues
    end

    -- Legacy/flat spell presentation & hitbox properties
    if raw.vfx ~= nil and Trim(tostring(raw.vfx)) ~= "" then def.vfx = Trim(tostring(raw.vfx)) end
    if raw.sfx ~= nil and Trim(tostring(raw.sfx)) ~= "" then def.sfx = Trim(tostring(raw.sfx)) end
    if raw.montage ~= nil and Trim(tostring(raw.montage)) ~= "" then def.montage = Trim(tostring(raw.montage)) end
    if raw.skipMontage ~= nil then def.skipMontage = ParseBool(raw.skipMontage, false) end
    if raw.spawnActor ~= nil and Trim(tostring(raw.spawnActor)) ~= "" then def.spawnActor = Trim(tostring(raw.spawnActor)) end
    if raw.allowUnsafeSpawn ~= nil then def.allowUnsafeSpawn = ParseBool(raw.allowUnsafeSpawn, false) end
    if raw.spinHitbox ~= nil then def.spinHitbox = ParseBool(raw.spinHitbox, false) end
    if raw.hitRadius ~= nil then def.hitRadius = tonumber(raw.hitRadius) end
    if raw.hitDamageMin ~= nil then def.hitDamageMin = tonumber(raw.hitDamageMin) end
    if raw.hitDamageMax ~= nil then def.hitDamageMax = tonumber(raw.hitDamageMax) end
    if raw.hitDelaySec ~= nil then def.hitDelaySec = tonumber(raw.hitDelaySec) end
    if raw.hitVfx ~= nil then def.hitVfx = tostring(raw.hitVfx) end
    if raw.hitSfx ~= nil then def.hitSfx = tostring(raw.hitSfx) end
    if raw.damageSpell ~= nil then def.damageSpell = tostring(raw.damageSpell) end
    if raw.extraAoEDelaySec ~= nil then def.extraAoEDelaySec = tonumber(raw.extraAoEDelaySec) end
    if raw.damageMode ~= nil then def.damageMode = tostring(raw.damageMode):lower() end
    if raw.suppressDirectHealth ~= nil then def.suppressDirectHealth = ParseBool(raw.suppressDirectHealth, false) end
    if raw.damageGE ~= nil then def.damageGE = tostring(raw.damageGE) end
    if raw.damageClass ~= nil then def.damageClass = tostring(raw.damageClass):lower() end
    if raw.damageForce ~= nil then def.damageForce = tonumber(raw.damageForce) end
    if raw.floatieOffsetZ ~= nil then def.floatieOffsetZ = tonumber(raw.floatieOffsetZ) end
    if raw.forceFloatie ~= nil then def.forceDamageFloatie = ParseBool(raw.forceFloatie, false) end
    if raw.bridgeBlueprint ~= nil then def.bridgeBlueprint = tostring(raw.bridgeBlueprint) end
    if raw.impactAoE ~= nil then def.impactAoE = tostring(raw.impactAoE) end
    if raw.impactLightning ~= nil then def.impactLightning = tostring(raw.impactLightning) end
    if raw.impactVfx ~= nil then def.impactVfx = tostring(raw.impactVfx) end
    if raw.impactSfx ~= nil then def.impactSfx = tostring(raw.impactSfx) end
    if raw.impactDamageMin ~= nil then def.impactDamageMin = tonumber(raw.impactDamageMin) end
    if raw.impactDamageMax ~= nil then def.impactDamageMax = tonumber(raw.impactDamageMax) end
    if raw.impactRadius ~= nil then def.impactRadius = tonumber(raw.impactRadius) end

    -- In JSON, "baseSpell": null decodes to nil. If no baseSpell is provided and the spell defines
    -- custom cues or custom presentation/hitbox fields, suppress the native base spell automatically.
    if def.baseSpell == nil and def.suppressBaseSpell == nil then
        local hasCustomBody = (def.jsonCues ~= nil and #def.jsonCues > 0)
            or (def.montage ~= nil)
            or (def.spawnActor ~= nil)
            or (def.spinHitbox == true)
            or (def.hitDamageMin ~= nil)
            or (def.vfx ~= nil)
            or (def.sfx ~= nil)
        if hasCustomBody then
            def.suppressBaseSpell = true
        end
    end

    return def
end

-- Parse custom_spells.json (or JSONC) into normalized CustomSpell definitions.
-- Returns (defs, nil) on success, or (nil, errMsg) on syntax/schema error.
function CustomSpells.ParseJsonDefinitions(rawJson)
    if not rawJson or Trim(rawJson) == "" then
        return {}, nil
    end
    local doc, err = Json.Decode(rawJson)
    if err then
        return nil, err
    end
    if type(doc) ~= "table" then
        return nil, "root JSON value must be an object with a 'spells' map"
    end

    local defs = {}
    local spellsMap = doc.spells
    if type(spellsMap) == "table" then
        if spellsMap[1] ~= nil then
            for _, item in ipairs(spellsMap) do
                if type(item) == "table" and item.name then
                    local def = NormalizeJsonSpellDef(item.name, item)
                    if def then defs[def.nameLower] = def end
                end
            end
        else
            for spellName, rawDef in pairs(spellsMap) do
                if type(spellName) == "string" and spellName:sub(1, 1) ~= "$" then
                    local def = NormalizeJsonSpellDef(spellName, rawDef)
                    if def then defs[def.nameLower] = def end
                end
            end
        end
    elseif doc[1] ~= nil then
        for _, item in ipairs(doc) do
            if type(item) == "table" and item.name then
                local def = NormalizeJsonSpellDef(item.name, item)
                if def then defs[def.nameLower] = def end
            end
        end
    else
        return nil, "missing 'spells' object in custom_spells.json"
    end

    return defs, nil
end

function CustomSpells.ParseDefinitions(rawText)
    local defs = {}
    if not rawText or rawText == "" then
        return defs, nil
    end

    if Json.LooksLikeJson(rawText) then
        return CustomSpells.ParseJsonDefinitions(rawText)
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
                        current = CreateDefaultSpellDef(nameTrimmed)
                        defs[current.nameLower] = current
                    end
                elseif current then
                    local k, v = clean:match("^([%w_]+)%s*=%s*(.+)$")
                    if k and v then
                        local key = Trim(k):lower()
                        local val = Trim(v)
                        if val == "" then val = nil end
                        local isCueLine, cueType, defaultTarget = TimelineParser.ClassifyKey(key, val)
                        if isCueLine and val then
                            table.insert(current.rawCues, {
                                cueType = cueType,
                                rawVal = val,
                                defaultTarget = defaultTarget
                            })
                        elseif key == "timelineduration" or key == "totalduration" then
                            if val and val:lower() == "auto" then
                                current.timelineDuration = nil
                            else
                                current.timelineDuration = val and tonumber(val) or nil
                            end
                        elseif key == "stepadvanceat" or key == "advanceat" or key == "readyat" then
                            current.stepAdvanceAt = val and tonumber(val) or nil
                        elseif key == "cancelonrelease" or key == "stoponrelease" then
                            current.cancelOnRelease = ParseBool(val, false)
                        elseif key == "overlappolicy" or key == "timelineoverlap" then
                            current.overlapPolicy = val and val:lower() or "replace"
                        elseif key == "scaletimelinewithspeed" or key == "scaletimeline" then
                            current.scaleTimelineWithSpeed = ParseBool(val, true)
                        elseif key == "autotargetrange" or key == "autotargetmaxdistance" or key == "targetrange" then
                            current.autoTargetRange = val and tonumber(val) or nil
                        elseif key == "autotargetcone" or key == "autotargetconedeg" then
                            current.autoTargetCone = val and tonumber(val) or nil
                        elseif key == "basespell" or key == "spell" or key == "base" then
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
                        elseif key == "damageclass" or key == "hitclass" then
                            current.damageClass = val and val:lower() or nil
                        elseif key == "damageforce" or key == "hitforce" or key == "knockback" then
                            current.damageForce = tonumber(val)
                        elseif key == "floatieoffsetz" or key == "damageoffsetz" then
                            current.floatieOffsetZ = tonumber(val)
                        elseif key == "forcefloatie" or key == "forcedamagefloatie" then
                            current.forceDamageFloatie = ParseBool(val, false)
                        elseif key == "bridgeblueprint" or key == "damagebridge" then
                            current.bridgeBlueprint = val
                        elseif key == "requiredmagiclevel" or key == "minmagiclevel" or key == "magiclevel"
                            or key == "unlocklevel" or key == "requiredlevel" or key == "minlevel" then
                            local lv = tonumber(val)
                            if lv then
                                current.requiredMagicLevel = math.max(0, math.floor(lv))
                                if current.requiredMagicLevel > 0 then
                                    current.unlockedByDefault = false
                                end
                            end
                        elseif key == "requiredskill" or key == "skillrequirement" or key == "unlockskill" then
                            if val then
                                local sk, lvStr = val:match("^([^:]+):(%d+)$")
                                if sk and lvStr then
                                    current.requiredSkill = Trim(sk)
                                    current.requiredMagicLevel = math.max(0, math.floor(tonumber(lvStr) or 0))
                                    if current.requiredMagicLevel > 0 then
                                        current.unlockedByDefault = false
                                    end
                                else
                                    current.requiredSkill = val
                                end
                            end
                        elseif key == "unlockedbydefault" or key == "availablebydefault" then
                            current.unlockedByDefault = ParseBool(val, true)
                        elseif key == "displayname" or key == "friendlyname" then
                            current.displayName = val
                        elseif key == "scalewithstaff" or key == "staffscaling" or key == "scaledamagewithstaff" then
                            current.scaleWithStaff = ParseBool(val, true)
                        elseif key == "damagescaling" or key == "scalemode" or key == "dmgscale" then
                            current.damageScaling = val and val:lower() or nil
                        elseif key == "staffbaselinetier" or key == "baselinetier" then
                            current.staffBaselineTier = tonumber(val)
                        elseif key == "stafftierstep" or key == "tierstep" then
                            current.staffTierStep = tonumber(val)
                        elseif key == "staffbonus" or key == "staffmultipliers" then
                            current.staffBonus = val
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

        local timeline, tlWarnings = TimelineParser.BuildTimeline(def)
        if tlWarnings and #tlWarnings > 0 then
            for _, w in ipairs(tlWarnings) do
                pcall(function() print("[ArcaneWilds][WARN] CustomSpell [" .. tostring(def.name) .. "]: " .. tostring(w) .. "\n") end)
            end
        end

        local montObj, _, montShort = FindObjectFast(def.montage, safeGetNameFn, extractShortFn)
        if not montObj and def.montage and def.montage ~= "" then
            montObj = FindAssetByKeywordOnDemand("AnimMontage", def.montage, safeGetNameFn)
            if montObj and montObj:IsValid() then
                montShort = extractShortFn(safeGetNameFn(montObj))
            end
        end
        if not montObj and timeline and timeline.cues then
            for _, cue in ipairs(timeline.cues) do
                if cue.type == "anim" and cue.asset and cue.asset ~= "" then
                    local cObj, _, cShort = FindObjectFast(cue.asset, safeGetNameFn, extractShortFn)
                    if cObj and cObj:IsValid() then
                        montObj = cObj
                        montShort = cShort
                    else
                        montShort = extractShortFn(cue.asset)
                    end
                    break
                end
            end
        end

        local hasTimelineCues = (timeline ~= nil and timeline.cues ~= nil and #timeline.cues > 0)
        local hasActorOrEffect = hasTimelineCues or (def.spawnActor and def.spawnActor ~= "") or (def.vfx and def.vfx ~= "") or (def.sfx and def.sfx ~= "") or (def.impactDamageMin ~= nil)
        if (resolvedBaseSpellObj and resolvedBaseSpellObj:IsValid()) or (montObj and montObj:IsValid()) or hasTimelineCues or (def.suppressBaseSpell and hasActorOrEffect) then
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
                customOverrideSpeed = def.speed,
                timeline = timeline,
                hasTimeline = hasTimelineCues,
                stepAdvanceAt = timeline and timeline.stepAdvanceAt or nil,
                requiredMagicLevel = def.requiredMagicLevel or 0,
                requiredSkill = def.requiredSkill or "Magic",
                unlockedByDefault = (def.unlockedByDefault ~= false),
                scaleWithStaff = def.scaleWithStaff,
                damageScaling = def.damageScaling
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
        entry = entry,
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

local function NextAttackId()
    AttackIdCounter = AttackIdCounter + 1
    if AttackIdCounter > 2000000000 then
        AttackIdCounter = 1001
    end
    return AttackIdCounter
end

local function SafeObjName(obj)
    if not obj then return "nil" end
    local ok, n = pcall(function() return obj:GetFullName() end)
    return (ok and n) or tostring(obj)
end

local function IsValidUObject(obj)
    if not obj then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

local function HasUFunc(obj, name)
    if not IsValidUObject(obj) or not name then return false end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok or fn == nil then return false end
    local t = type(fn)
    if t == "function" then return true end
    if t == "userdata" then
        -- In UE4SS Lua, UFunction members on UObjects are callable userdata (not Lua "function")
        local okV, valid = pcall(function() return fn:IsValid() end)
        return (not okV) or (valid == true)
    end
    return false
end

local function MakeVectorTable(v, fallbackZ)
    if type(v) == "table" or type(v) == "userdata" then
        local x, y, z = 0.0, 0.0, fallbackZ or 0.0
        pcall(function() x = tonumber(v.X) or 0.0 end)
        pcall(function() y = tonumber(v.Y) or 0.0 end)
        pcall(function() z = tonumber(v.Z) or (fallbackZ or 0.0) end)
        return { X = x, Y = y, Z = z }
    end
    return { X = 0.0, Y = 0.0, Z = fallbackZ or 0.0 }
end

local function ResolveDamageClassByte(entry)
    local raw = entry and entry.customDef and entry.customDef.damageClass or nil
    if raw then
        local l = tostring(raw):lower()
        if l == "none" or l == "0" then return 0 end
        if l == "melee" or l == "1" or l == "slash" or l == "crush" or l == "stab" then return 1 end
        if l == "magical" or l == "magic" or l == "2" or l == "spell" then return 2 end
        if l == "ranged" or l == "range" or l == "3" then return 3 end
    end
    local sLow = tostring(entry and entry.shortName or ""):lower()
    if sLow:find("sword", 1, true) or sLow:find("greatsword", 1, true) or sLow:find("claws", 1, true) then
        return 1 -- EDamageClass::Melee
    end
    return 2 -- EDamageClass::Magical
end

local function GetDamageFunctionLibrary()
    if IsValidUObject(CachedDamageFuncLib) then
        return CachedDamageFuncLib
    end
    local lib = nil
    pcall(function()
        lib = StaticFindObject("/Script/Dominion.Default__DamageFunctionLibrary")
    end)
    if IsValidUObject(lib) then
        CachedDamageFuncLib = lib
        return lib
    end
    return nil
end

local function GetDamageFloatiesSubsystem()
    if IsValidUObject(CachedFloatiesSubsystem) then
        return CachedFloatiesSubsystem
    end
    local sub = nil
    pcall(function()
        sub = FindFirstOf("DamageFloatiesSubsystem")
    end)
    if IsValidUObject(sub) then
        CachedFloatiesSubsystem = sub
        return sub
    end
    return nil
end

local function GetDamageBridgeCDO(entry)
    if IsValidUObject(CachedBridgeCDO) then
        return CachedBridgeCDO
    end
    if CheckedBridgeAsset and not (entry and entry.customDef and entry.customDef.bridgeBlueprint) then
        return nil
    end
    CheckedBridgeAsset = true

    local candidateCDOs = {}
    if entry and entry.customDef and entry.customDef.bridgeBlueprint and entry.customDef.bridgeBlueprint ~= "" then
        table.insert(candidateCDOs, entry.customDef.bridgeBlueprint)
    end
    table.insert(candidateCDOs, "/Game/Mods/ArcaneWilds/BFL_ArcaneWildsDamage.Default__BFL_ArcaneWildsDamage_C")
    table.insert(candidateCDOs, "/Game/Mods/ArcaneWilds/BP_ArcaneWildsDamageBridge.Default__BP_ArcaneWildsDamageBridge_C")

    for _, path in ipairs(candidateCDOs) do
        local obj = nil
        pcall(function() obj = StaticFindObject(path) end)
        if IsValidUObject(obj) then
            CachedBridgeCDO = obj
            return obj
        end
    end

    -- Try LoadAsset once for the packaged BlueprintFunctionLibrary if the optional .pak is mounted
    if type(LoadAsset) == "function" then
        local loadPaths = {
            "/Game/Mods/ArcaneWilds/BFL_ArcaneWildsDamage.BFL_ArcaneWildsDamage_C",
            "/Game/Mods/ArcaneWilds/BFL_ArcaneWildsDamage",
            "/Game/Mods/ArcaneWilds/BP_ArcaneWildsDamageBridge.BP_ArcaneWildsDamageBridge_C",
            "/Game/Mods/ArcaneWilds/BP_ArcaneWildsDamageBridge"
        }
        for _, lp in ipairs(loadPaths) do
            pcall(function() LoadAsset(lp) end)
        end
        for _, path in ipairs(candidateCDOs) do
            local obj = nil
            pcall(function() obj = StaticFindObject(path) end)
            if IsValidUObject(obj) then
                CachedBridgeCDO = obj
                return obj
            end
        end
    end

    local inst = nil
    pcall(function() inst = FindFirstOf("BP_ArcaneWildsDamageBridge_C") end)
    if IsValidUObject(inst) then
        CachedBridgeCDO = inst
        return inst
    end

    return nil
end

local function DisplayDamageFloatie(amount, loc, logFn)
    local sub = GetDamageFloatiesSubsystem()
    if not sub then
        if logFn then logFn("  FLOATIE: DamageFloatiesSubsystem not found") end
        return false
    end
    local dmgFloat = tonumber(amount) or 0.0
    local vec = MakeVectorTable(loc, 0.0)
    local ok, err = pcall(function()
        sub:DisplayDamage(dmgFloat, vec)
    end)
    if logFn then
        logFn(string.format("  FLOATIE: DisplayDamage(%.1f, [%.1f,%.1f,%.1f]) ok=%s err=%s",
            dmgFloat, vec.X, vec.Y, vec.Z, tostring(ok), tostring(err or "")))
    end
    return ok
end

local function ResolveTargetDamageComponent(targetActor)
    if not IsValidUObject(targetActor) then return nil end
    local comp = nil
    pcall(function()
        if HasUFunc(targetActor, "GetDamageComponent") then
            comp = targetActor:GetDamageComponent()
        end
    end)
    if IsValidUObject(comp) then return comp end

    pcall(function()
        if HasUFunc(targetActor, "GetAiDamageComponent") then
            comp = targetActor:GetAiDamageComponent()
        end
    end)
    if IsValidUObject(comp) then return comp end

    for _, propName in ipairs({ "AiDamageComponent", "BP_AiDamageComponent", "DamageComponent" }) do
        pcall(function() comp = targetActor[propName] end)
        if IsValidUObject(comp) then return comp end
    end

    pcall(function()
        local dmgClass = StaticFindObject("/Script/Dominion.DamageComponent")
        if IsValidUObject(dmgClass) and HasUFunc(targetActor, "GetComponentByClass") then
            comp = targetActor:GetComponentByClass(dmgClass)
        end
    end)
    if IsValidUObject(comp) then return comp end
    return nil
end

local function ResolveTargetHealthComponent(targetActor)
    if not IsValidUObject(targetActor) then return nil end
    local comp = nil
    pcall(function()
        if HasUFunc(targetActor, "GetAiHealthComponent") then
            comp = targetActor:GetAiHealthComponent()
        end
    end)
    if IsValidUObject(comp) then return comp end

    for _, propName in ipairs({ "HealthComponent", "AiHealthComponent" }) do
        pcall(function() comp = targetActor[propName] end)
        if IsValidUObject(comp) then return comp end
    end
    return nil
end

local function ReadActorHealth(healthComp)
    if not IsValidUObject(healthComp) then return nil end
    local hp = nil
    pcall(function()
        if HasUFunc(healthComp, "GetAuthoritativeHealth") then
            hp = tonumber(healthComp:GetAuthoritativeHealth())
        elseif HasUFunc(healthComp, "GetLocalHealth") then
            hp = tonumber(healthComp:GetLocalHealth())
        end
    end)
    return hp
end

local function GetWorldTimeSecondsSafe(actorObj)
    local t = 0.0
    pcall(function()
        local gpStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        if IsValidUObject(gpStatics) and HasUFunc(gpStatics, "GetTimeSeconds") and IsValidUObject(actorObj) then
            t = tonumber(gpStatics:GetTimeSeconds(actorObj)) or 0.0
        end
    end)
    return t
end

local function BuildFullDominionDamageEventTable(instigatorPawn, amtNum, dmgClassByte, instLoc, victimLoc, victimFwd, forceVal, attackId)
    local instVec = MakeVectorTable(instLoc, 0.0)
    local vicVec = MakeVectorTable(victimLoc, 0.0)
    local fwdVec = MakeVectorTable(victimFwd, 0.0)
    if fwdVec.X == 0.0 and fwdVec.Y == 0.0 and fwdVec.Z == 0.0 then
        fwdVec.X = 1.0
    end
    return {
        Amount = amtNum,
        AmountAbsorbedByShield = 0.0,
        DamageClass = dmgClassByte,
        TypeDamagesArray = {
            ArraySize = 1,
            TypeDamages = {
                {
                    StatusEffect = 0, -- EStatusEffectType::None
                    Types = { GameplayTags = {} },
                    Amount = amtNum
                }
            }
        },
        TypeDamagesOutcome = { 0 }, -- ETypeDamageOutcome::Neutral
        Instigator = instigatorPawn,
        Source = instigatorPawn,
        InstigatorLocation = instVec,
        VictimForward = fwdVec,
        VictimLocation = vicVec,
        ModifierMessageTags = {},
        Directionality = 5, -- EReactionDirectionality::Outwards
        Force = forceVal,
        AttackProperties = 0,
        StaminaCostMultiplier = 0.0,
        HitReaction = nil,
        GEHandlesArray = {
            ArraySize = 0,
            Handles = {}
        },
        DamageProperties = 0,
        AttackId = attackId,
        bIsFatalHit = false,
        Seed = 1,
        CachedDamageShouldHitReact = true,
        ID = attackId
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

-- Unified Dominion Blueprint damage pipeline (crash-safe):
--   Tier 1: Cooked IoStore Blueprint bridge (.pak/.utoc/.ucas) BFL_ArcaneWildsDamage::ApplyArcaneWildsDamage
--           (passes ONLY primitives/pointers from Lua; Blueprint VM constructs FTypeDamage/TArray/FDominionDamageEvent natively)
--   Tier 2: Crash-proof HealthComponent::DecreaseHealth + UDamageFloatiesSubsystem::DisplayDamage
--           (passes ONLY primitives: float, FString, FVector; never marshals nested TArray<UStruct> from Lua)
local function ApplyDominionBlueprintDamage(targetActor, instigatorPawn, dmgAmount, hitLoc, instLoc, entry, logFn)
    if not IsValidUObject(targetActor) or targetActor == instigatorPawn then
        return false, "invalid-target"
    end

    local amtNum = tonumber(dmgAmount) or 65.0
    local dmgClassByte = ResolveDamageClassByte(entry)
    local forceVal = tonumber(entry and entry.customDef and entry.customDef.damageForce) or 260.0
    local floatieOffsetZ = tonumber(entry and entry.customDef and entry.customDef.floatieOffsetZ) or 90.0
    local skipDirectHp = (entry and entry.customDef and entry.customDef.suppressDirectHealth == true)
    local forceFloatie = (entry and entry.customDef and entry.customDef.forceDamageFloatie == true)
    local attackId = NextAttackId()

    local healthComp = ResolveTargetHealthComponent(targetActor)
    local damageComp = ResolveTargetDamageComponent(targetActor)
    local hpBefore = ReadActorHealth(healthComp)

    -- Ensure damage floaties are enabled on the target's DamageComponent
    if IsValidUObject(damageComp) then
        pcall(function()
            if damageComp.bShowDamageFloaties == false and HasUFunc(damageComp, "SetCanShowDamageFloaties") then
                damageComp:SetCanShowDamageFloaties(true)
            end
        end)
    end

    local hitVec = MakeVectorTable(hitLoc, 0.0)
    local instVec = MakeVectorTable(instLoc, 0.0)
    local floatieLoc = { X = hitVec.X, Y = hitVec.Y, Z = hitVec.Z + floatieOffsetZ }

    local traceParts = {}
    local damageApplied = false
    local usedNativePipeline = false

    local function DidHealthDrop()
        local hpNow = ReadActorHealth(healthComp)
        if hpBefore ~= nil and hpNow ~= nil then
            return (hpNow < hpBefore - 0.01), hpNow
        end
        return false, hpNow
    end

    -- Tier 1: Cooked IoStore Blueprint bridge (only primitives/pointers cross Lua -> UE boundary)
    local bridgeCDO = GetDamageBridgeCDO(entry)
    if HasUFunc(bridgeCDO, "ApplyArcaneWildsDamage") then
        local okB, resB = pcall(function()
            return bridgeCDO:ApplyArcaneWildsDamage(
                targetActor, instigatorPawn, amtNum, dmgClassByte, hitVec, instVec, forceVal, attackId)
        end)
        local dropped = DidHealthDrop()
        table.insert(traceParts, string.format("BPBridge(ok=%s,res=%s,dropped=%s)", tostring(okB), tostring(resB), tostring(dropped)))
        if (okB and resB == true) or dropped then
            damageApplied = true
            usedNativePipeline = true
        end
    else
        table.insert(traceParts, "BPBridge:not-loaded")
    end

    -- Tier 2: Crash-proof direct HealthComponent fallback + official UDamageFloatiesSubsystem::DisplayDamage
    -- NOTE: We intentionally do NOT call PredictDamage / UDamageFunctionLibrary::ApplyDamage directly from Lua
    -- with Lua tables, because UE4SS marshalling Lua tables into TArray<FTypeDamage> / FDominionDamageEvent
    -- corrupts TArray::ArrayNum and crashes Unreal Engine (ContainerHelpers.cpp).
    if not damageApplied and not skipDirectHp and IsValidUObject(healthComp) then
        local ctxArg = MakeFStringArg("ArcaneWilds_CustomSpell")
        local okDec, errDec = pcall(function()
            if HasUFunc(healthComp, "DecreaseHealth") then
                healthComp:DecreaseHealth(amtNum, ctxArg)
            elseif HasUFunc(healthComp, "ModifyAuthoritativeHealth") then
                healthComp:ModifyAuthoritativeHealth(-amtNum)
            else
                error("no health decrease method")
            end
        end)
        if not okDec then
            okDec, errDec = pcall(function()
                if HasUFunc(healthComp, "DecreaseHealth") then
                    healthComp:DecreaseHealth(amtNum, "ArcaneWilds_CustomSpell")
                else
                    error("no DecreaseHealth method")
                end
            end)
        end
        local dropped = DidHealthDrop()
        table.insert(traceParts, string.format("HealthFallback(ok=%s,dropped=%s,err=%s)",
            tostring(okDec), tostring(dropped), tostring(okDec and "" or errDec)))
        if okDec or dropped then
            damageApplied = true
            DisplayDamageFloatie(amtNum, floatieLoc, logFn)
        end
    elseif damageApplied and (forceFloatie or not usedNativePipeline) then
        DisplayDamageFloatie(amtNum, floatieLoc, logFn)
    end

    local hpAfter = ReadActorHealth(healthComp)
    local hpDeltaStr = ""
    if hpBefore ~= nil and hpAfter ~= nil then
        hpDeltaStr = string.format(" hp:%.1f->%.1f", hpBefore, hpAfter)
    end
    local summary = table.concat(traceParts, " -> ") .. hpDeltaStr
    return damageApplied, summary
end

local function ApplyRolledImpactDamage(pawn, loc, minDmg, maxDmg, radius, entry, logFn, config)
    if not loc or not minDmg then return end
    local scaleMult, scaleBrk = ProgressionScaling.ComputeDamageMultiplier(config, nil, pawn, entry, nil)
    local lo, hi = ProgressionScaling.ScaleDamageRange(minDmg, maxDmg or minDmg, scaleMult)
    local rolledDmg = (hi > lo) and math.random(lo, hi) or lo
    if logFn and scaleBrk and scaleBrk.mode ~= "none" then
        logFn(string.format("ImpactDamage [%s] scaled %d..%d -> %d..%d (%.2fx: staff=%.2fx[T%d] * skill=%.2fx * attr=%.2fx)",
            tostring(entry and entry.shortName), math.floor(tonumber(minDmg) or 0), math.floor(tonumber(maxDmg or minDmg) or 0),
            lo, hi, scaleMult, scaleBrk.staffMult, scaleBrk.tier, scaleBrk.skillMult, scaleBrk.attrMult))
    end
    local rad = tonumber(radius) or 350.0
    local rSq = rad * rad

    local instLoc = nil
    pcall(function()
        if IsValidUObject(pawn) then instLoc = pawn:K2_GetActorLocation() end
    end)

    local seenNames = {}
    local pawnFullLow = SafeObjName(pawn):lower()
    local candidates = {}
    pcall(function()
        local aiList = FindAllOf("DominionAICharacter")
        if aiList then
            for _, a in ipairs(aiList) do table.insert(candidates, a) end
        end
    end)
    pcall(function()
        local chList = FindAllOf("Character")
        if chList then
            for _, c in ipairs(chList) do table.insert(candidates, c) end
        end
    end)

    local hitAny = false
    for _, ch in ipairs(candidates) do
        if IsValidUObject(ch) and ch ~= pawn then
            local fName = SafeObjName(ch)
            local fLow = fName:lower()
            if fLow ~= "" and fLow ~= pawnFullLow and not fLow:find("bp_playercharacter", 1, true) and not seenNames[fLow] then
                seenNames[fLow] = true
                local cLoc = nil
                pcall(function() cLoc = ch:K2_GetActorLocation() end)
                if cLoc then
                    local dx = (cLoc.X or 0) - (loc.X or 0)
                    local dy = (cLoc.Y or 0) - (loc.Y or 0)
                    local dz = (cLoc.Z or 0) - (loc.Z or 0)
                    if (dx * dx + dy * dy + dz * dz) <= rSq then
                        local okD = ApplyDominionBlueprintDamage(ch, pawn, rolledDmg, cLoc, instLoc or loc, entry, logFn)
                        if okD then hitAny = true end
                    end
                end
            end
        end
    end

    if not hitAny then
        pcall(function()
            local pc = IsValidUObject(pawn) and pawn.Controller or nil
            local gpStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
            if IsValidUObject(gpStatics) and gpStatics.ApplyRadialDamage then
                local ignoreList = {}
                if IsValidUObject(pawn) then table.insert(ignoreList, pawn) end
                gpStatics:ApplyRadialDamage(pawn, rolledDmg, loc, rad, nil, ignoreList, pawn, pc, true, 0)
            end
        end)
    end
end

local function FireImpactAtLocation(pawn, pending, loc, config)
    if not pending then return end

    -- 1. Trigger the ground smash ability/animation (e.g. DA_Spell_Primary_Air_04 / Death From Above)
    if pending.aoeSpellObj and pending.aoeSpellObj:IsValid() and pawn and pawn:IsValid() then
        pcall(function()
            local mods = pending.aoeSpellObj.Modules
            if mods and mods.Modules then
                mods.Modules:ForEach(function(_, elemWrapper)
                    local okE, el = pcall(function() return elemWrapper:get() end)
                    local modObj = okE and el and el.Module or nil
                    if modObj and modObj:IsValid() then
                        local mName = SafeObjName(modObj)
                        if mName:find("SpellModule_PlayMontage") or mName:find("SpellModule_PlayStagedMontage") then
                            pcall(function() modObj.bShouldBlockMovement = false end)
                            pcall(function() modObj.MaxMovementSpeedDuringMontage = 600.0 end)
                        end
                    end
                end)
            end
        end)
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

        -- 4. Roll damage on targets hit around the impact location (must run on GameThread for LoadAsset/UFunctions)
        if pending.damageMin then
            local function runImpactDmg()
                ApplyRolledImpactDamage(pawn, loc, pending.damageMin, pending.damageMax, pending.damageRadius, pending.entry, nil, config)
            end
            if type(ExecuteInGameThread) == "function" then
                pcall(function() ExecuteInGameThread(runImpactDmg) end)
            else
                runImpactDmg()
            end
        end
    end
end

-- Called on tick: tracks the flying projectile/spell actor location and triggers the AoE at the impact point
-- once the projectile actor detaches/impacts (or after flight completes).
function CustomSpells.TickProjectileImpactAoE(state, pawn, combatMagic, config)
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
            FireImpactAtLocation(pawn, p, targetLoc, config)
        end
    elseif age >= 4.0 then
        state.PendingImpactAoE = nil
    end
end

function CustomSpells.StopForcedMontage(state, pawn)
    if state then
        if state._SavedRootMotionMode ~= nil and pawn and pawn:IsValid() then
            local savedMode = state._SavedRootMotionMode
            state._SavedRootMotionMode = nil
            pcall(function()
                local mesh = pawn.Mesh
                if mesh and mesh:IsValid() then
                    local animInst = mesh:GetAnimInstance()
                    if animInst and animInst:IsValid() then
                        animInst.RootMotionMode = savedMode
                    end
                end
            end)
        end
        state.LastForcedMontageObj = nil
    end
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
    -- Disable root motion on directly played custom montages so the player can keep moving freely
    pcall(function() mont.bEnableRootMotionTranslation = false end)
    pcall(function() mont.bEnableRootMotionRotation = false end)

    local function runOnGameThread()
        pcall(function()
            if not pawn or not pawn:IsValid() or not mont or not mont:IsValid() then return end
            local mesh = pawn.Mesh
            if mesh and mesh:IsValid() then
                local animInst = mesh:GetAnimInstance()
                if animInst and animInst:IsValid() and animInst.Montage_Play then
                    pcall(function()
                        if state and state._SavedRootMotionMode == nil then
                            state._SavedRootMotionMode = animInst.RootMotionMode or 3
                        end
                        animInst.RootMotionMode = 1 -- ERootMotionMode::IgnoreRootMotion
                    end)
                    animInst:Montage_Play(mont, playRate, 0, 0.05, true)
                    if state then state.LastForcedMontageObj = mont end
                    if type(ExecuteWithDelay) == "function" then
                        pcall(function()
                            ExecuteWithDelay(1100, function()
                                if type(ExecuteInGameThread) == "function" then
                                    ExecuteInGameThread(function()
                                        pcall(function()
                                            if animInst and animInst:IsValid() and (not state or state.LastForcedMontageObj == mont) then
                                                animInst.RootMotionMode = (state and state._SavedRootMotionMode) or 3
                                                if state then state._SavedRootMotionMode = nil end
                                            end
                                        end)
                                    end)
                                end
                            end)
                        end)
                    end
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

local function ExecuteAroundPlayerHitbox(pawn, entry, debugLogFn, config)
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
        local scaleMult, scaleBrk = ProgressionScaling.ComputeDamageMultiplier(config, nil, pawn, entry, nil)
        local lo, hi = ProgressionScaling.ScaleDamageRange(minD, maxD, scaleMult)
        local rolledDmg = (hi > lo) and math.random(lo, hi) or lo

        logHb(string.format("SpinHitbox firing [%s] around player (%.1f,%.1f,%.1f) radius=%.1f dmg=%d (%d..%d, scale=%.2fx[%s]) class=%d",
            tostring(entry.shortName), loc.X or 0, loc.Y or 0, loc.Z or 0, rad, rolledDmg, lo, hi, scaleMult, tostring(scaleBrk and scaleBrk.mode or "none"), ResolveDamageClassByte(entry)))

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

        local rSq = rad * rad
        local hitCount = 0
        local seenNames = {}
        local pawnFullLow = SafeObjName(pawn):lower()
        local candidates = {}
        local aiList = FindAllOf("DominionAICharacter")
        if aiList then
            for _, a in ipairs(aiList) do table.insert(candidates, a) end
        end
        local chList = FindAllOf("Character")
        if chList then
            for _, c in ipairs(chList) do table.insert(candidates, c) end
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
                            local targetRolledDmg = (hi > lo) and math.random(lo, hi) or lo
                            local compInvoked, compInfo = ApplyDominionBlueprintDamage(
                                ai, pawn, targetRolledDmg, aLoc, loc, entry, logHb)
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
                                    if gComp and gComp:IsValid() and geObj and geObj:IsValid() then
                                        if HasUFunc(gComp, "InstantiateGameplayEffect") and HasUFunc(gComp, "ApplyGameplayEffect") then
                                            local okInst, handle = pcall(function()
                                                return gComp:InstantiateGameplayEffect(geObj, nil, true)
                                            end)
                                            table.insert(geMethods, "InstantiateGE:" .. tostring(okInst))
                                            if okInst and handle ~= nil then
                                                local okApp, appRes = pcall(function()
                                                    return gComp:ApplyGameplayEffect(pawn, pawn, handle, true)
                                                end)
                                                table.insert(geMethods, "ApplyGE:" .. tostring(okApp) .. "/" .. tostring(appRes))
                                            end
                                        end
                                    end
                                    logHb(string.format("  GE_TRACE [%s] on %s -> geObj=%s calls=[%s]",
                                        geName, fName, geObj and SafeObjName(geObj) or "NIL", table.concat(geMethods, ",")))
                                end)
                            end
                            logHb(string.format("  Hit candidate #%d: %s dist=%.1f dmg=%d applied=%s trace=[%s]",
                                hitCount, fName, math.sqrt(distSq), targetRolledDmg, tostring(compInvoked), tostring(compInfo)))
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
                                        local mName = SafeObjName(modObj)
                                        table.insert(modSummary, mName)
                                        if mName:find("SpellModule_PlayMontage") or mName:find("SpellModule_PlayStagedMontage") then
                                            pcall(function() modObj.bShouldBlockMovement = false end)
                                            pcall(function() modObj.MaxMovementSpeedDuringMontage = 600.0 end)
                                            pcall(function()
                                                local m = modObj.Montage
                                                if m and m:IsValid() then
                                                    m.bEnableRootMotionTranslation = false
                                                    m.bEnableRootMotionRotation = false
                                                end
                                            end)
                                        end
                                    end
                                end)
                            end
                        end)
                        logHb("AOE_TRACE: spell modules=[" .. table.concat(modSummary, ", ") .. "]")

                        local bpLib = StaticFindObject("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
                        local hasBpLib = IsValidUObject(bpLib)
                        local hasTrig = HasUFunc(bpLib, "TriggerModularAbilityForPlayer")
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

function CustomSpells.TriggerCustomPresentation(pawn, entry, safeGetNameFn, config)
    if not entry or not entry.isCustomSpell then return end
    if pawn and pawn:IsValid() then
        if entry.spinHitbox or entry.hitDamageMin then
            local delaySec = tonumber(entry.hitDelaySec) or 0.0
            if delaySec > 0.0 and type(ExecuteWithDelay) == "function" then
                local delayMs = math.max(10, math.floor(delaySec * 1000))
                pcall(function()
                    ExecuteWithDelay(delayMs, function()
                        if type(ExecuteInGameThread) == "function" then
                            ExecuteInGameThread(function() ExecuteAroundPlayerHitbox(pawn, entry, nil, config) end)
                        else
                            ExecuteAroundPlayerHitbox(pawn, entry, nil, config)
                        end
                    end)
                end)
            else
                if type(ExecuteInGameThread) == "function" then
                    pcall(function() ExecuteInGameThread(function() ExecuteAroundPlayerHitbox(pawn, entry, nil, config) end) end)
                else
                    ExecuteAroundPlayerHitbox(pawn, entry, nil, config)
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

-- Reusable timed AoE/cone hit pulse executor used by timeline_runner.lua `Hit` cues.
local function ExecuteHitPulse(pawn, centerLoc, centerRot, hitParams, entry, safeGetNameFn, debugLogFn, config)
    if not IsValidUObject(pawn) or not centerLoc then return 0 end
    local function logHb(msg)
        if debugLogFn then
            debugLogFn(msg)
        else
            pcall(function() print("[ArcaneWilds][DEBUG] " .. tostring(msg) .. "\n") end)
        end
    end

    local p = hitParams or {}
    local rad = tonumber(p.radius) or tonumber(entry and entry.hitRadius) or tonumber(entry and entry.impactRadius) or 400.0
    local minD = tonumber(p.dmgMin) or tonumber(entry and entry.hitDamageMin) or tonumber(entry and entry.impactDamageMin) or 65
    local maxD = tonumber(p.dmgMax) or tonumber(entry and entry.hitDamageMax) or minD
    local scaleMult, scaleBrk = ProgressionScaling.ComputeDamageMultiplier(config, nil, pawn, entry, p)
    local lo, hi = ProgressionScaling.ScaleDamageRange(minD, maxD, scaleMult)
    local coneDeg = tonumber(p.cone)
    local maxTargets = tonumber(p.maxTargets)

    if scaleBrk and scaleBrk.mode ~= "none" then
        logHb(string.format("TimelineHit Scale [%s]: base=%d..%d -> scaled=%d..%d (%.2fx [%s]: weapon=%s T%d*%.2f, skill=%.2fx, attr=%.2fx)",
            tostring(entry and entry.shortName or "TimelineHit"), math.floor(minD), math.floor(maxD), lo, hi,
            scaleMult, tostring(scaleBrk.mode), tostring(scaleBrk.weaponName), tonumber(scaleBrk.tier) or 0,
            tonumber(scaleBrk.weaponMult) or 1.0, tonumber(scaleBrk.skillMult) or 1.0, tonumber(scaleBrk.attrMult) or 1.0))
    end

    -- Build a lightweight effective entry overlay so cue-level class/force/GE overrides apply cleanly
    local effDef = {}
    if entry and entry.customDef then
        for k, v in pairs(entry.customDef) do effDef[k] = v end
    end
    if p.damageClass and p.damageClass ~= "" then effDef.damageClass = p.damageClass:lower() end
    if p.force ~= nil then effDef.damageForce = tonumber(p.force) end
    if p.ge and p.ge ~= "" then effDef.damageGE = p.ge end
    local effEntry = {
        shortName = entry and entry.shortName or "TimelineHit",
        customDef = effDef
    }

    local safeName = safeGetNameFn or SafeObjName
    if p.vfx and p.vfx ~= "" then
        local hvObj = FindObjectFast(p.vfx, safeName, function(s) return s end)
            or FindAssetByKeywordOnDemand("NiagaraSystem", p.vfx, safeName)
        if IsValidUObject(hvObj) then
            pcall(function()
                local nsLib = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
                if IsValidUObject(nsLib) and HasUFunc(nsLib, "SpawnSystemAtLocation") then
                    nsLib:SpawnSystemAtLocation(pawn, hvObj, centerLoc)
                end
            end)
        end
    end
    if p.sfx and p.sfx ~= "" then
        local hsObj = FindObjectFast(p.sfx, safeName, function(s) return s end)
            or FindAssetByKeywordOnDemand("SoundBase", p.sfx, safeName)
            or FindAssetByKeywordOnDemand("SoundWave", p.sfx, safeName)
        if IsValidUObject(hsObj) then
            pcall(function()
                local gpStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
                if IsValidUObject(gpStatics) and HasUFunc(gpStatics, "PlaySoundAtLocation") then
                    gpStatics:PlaySoundAtLocation(pawn, hsObj, centerLoc)
                end
            end)
        end
    end

    local instLoc = nil
    pcall(function() instLoc = pawn:K2_GetActorLocation() end)

    local cosHalfCone = nil
    local fwdX, fwdY = 1.0, 0.0
    if coneDeg and coneDeg > 0 and coneDeg < 360 then
        cosHalfCone = math.cos(math.rad(coneDeg * 0.5))
        local yawRad = math.rad(centerRot and centerRot.Yaw or 0.0)
        fwdX = math.cos(yawRad)
        fwdY = math.sin(yawRad)
    end

    local rSq = rad * rad
    local seenNames = {}
    local pawnFullLow = SafeObjName(pawn):lower()
    local candidates = {}
    pcall(function()
        local aiList = FindAllOf("DominionAICharacter")
        if aiList then for _, a in ipairs(aiList) do table.insert(candidates, a) end end
    end)
    pcall(function()
        local chList = FindAllOf("Character")
        if chList then for _, c in ipairs(chList) do table.insert(candidates, c) end end
    end)

    local pcObj = nil
    pcall(function() pcObj = pawn.Controller end)

    local hits = {}
    for _, ai in ipairs(candidates) do
        if IsValidUObject(ai) and ai ~= pawn and ai ~= pcObj then
            local fName = SafeObjName(ai)
            local fLow = fName:lower()
            if fLow ~= "" and fLow ~= pawnFullLow and not fLow:find("bp_playercharacter", 1, true) and not seenNames[fLow] then
                seenNames[fLow] = true
                local aLoc = nil
                pcall(function() aLoc = ai:K2_GetActorLocation() end)
                if aLoc then
                    local dx = (aLoc.X or 0) - (centerLoc.X or 0)
                    local dy = (aLoc.Y or 0) - (centerLoc.Y or 0)
                    local dz = (aLoc.Z or 0) - (centerLoc.Z or 0)
                    local distSq = dx * dx + dy * dy + dz * dz
                    if distSq <= rSq then
                        local passCone = true
                        if cosHalfCone then
                            local hLen = math.sqrt(dx * dx + dy * dy)
                            if hLen > 1e-3 then
                                passCone = (((dx / hLen) * fwdX + (dy / hLen) * fwdY) >= cosHalfCone)
                            end
                        end
                        if passCone then
                            table.insert(hits, { actor = ai, loc = aLoc, name = fName, distSq = distSq })
                        end
                    end
                end
            end
        end
    end

    table.sort(hits, function(a, b) return a.distSq < b.distSq end)
    if maxTargets and #hits > maxTargets then
        while #hits > maxTargets do table.remove(hits) end
    end

    for idx, h in ipairs(hits) do
        local rolledDmg = (hi > lo) and math.random(lo, hi) or lo
        local applied, trace = ApplyDominionBlueprintDamage(h.actor, pawn, rolledDmg, h.loc, instLoc or centerLoc, effEntry, logHb)
        if effDef.damageGE and effDef.damageGE ~= "" then
            pcall(function()
                local geName = tostring(effDef.damageGE)
                local geObj = StaticFindObject(geName)
                if not IsValidUObject(geObj) then
                    geObj = FindAssetByKeywordOnDemand("Class", geName, SafeObjName)
                        or FindAssetByKeywordOnDemand("BlueprintGeneratedClass", geName, SafeObjName)
                end
                local gComp = h.actor.GameplayEffectsComponent
                if IsValidUObject(gComp) and IsValidUObject(geObj)
                    and HasUFunc(gComp, "InstantiateGameplayEffect") and HasUFunc(gComp, "ApplyGameplayEffect") then
                    local okInst, handle = pcall(function() return gComp:InstantiateGameplayEffect(geObj, nil, true) end)
                    if okInst and handle ~= nil then
                        pcall(function() gComp:ApplyGameplayEffect(pawn, pawn, handle, true) end)
                    end
                end
            end)
        end
        logHb(string.format("  TimelineHit #%d [%s]: %s dist=%.1f dmg=%d applied=%s trace=[%s]",
            idx, tostring(effEntry.shortName), h.name, math.sqrt(h.distSq), rolledDmg, tostring(applied), tostring(trace)))
    end
    return #hits, hits
end

CustomSpells.ApplyDominionBlueprintDamage = ApplyDominionBlueprintDamage
CustomSpells.DisplayDamageFloatie = DisplayDamageFloatie
CustomSpells.ExecuteHitPulse = ExecuteHitPulse
CustomSpells.GetDamageBridgeCDO = GetDamageBridgeCDO
CustomSpells.FindAssetByKeywordOnDemand = FindAssetByKeywordOnDemand
CustomSpells.FindObjectFast = function(nameStr, safeGetNameFn, extractShortFn)
    return FindObjectFast(
        nameStr,
        safeGetNameFn or SafeObjName,
        extractShortFn or function(full)
            if not full then return "" end
            local a = full:match(":([^:]+)$") or full
            local b = a:match("%.([^%.]+)$") or a
            return (b:match("/([^/]+)$") or b)
        end
    )
end
CustomSpells.SerializeSpell = TimelineParser.SerializeSpell

return CustomSpells
