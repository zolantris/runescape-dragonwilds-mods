-- ArcaneWilds - Serializable Spell Animation & Effects Timeline Parser
-- Parses, validates, compiles (including legacy flat keys), and round-trip serializes
-- custom_spells.txt timeline definitions supporting simultaneous (&/@/+) and synchronous (>) cues.

local TimelineParser = {}

local function Trim(s)
    if not s then return "" end
    return (tostring(s):gsub("^%s*(.-)%s*$", "%1"))
end

local function ParseBool(v, defaultVal)
    if v == nil then return defaultVal end
    local l = Trim(v):lower()
    if l == "true" or l == "1" or l == "yes" or l == "on" then return true end
    if l == "false" or l == "0" or l == "no" or l == "off" then return false end
    return defaultVal
end

local function ParseVec3(raw, defaultX, defaultY, defaultZ)
    if not raw or raw == "" then
        return { X = defaultX or 0.0, Y = defaultY or 0.0, Z = defaultZ or 0.0 }
    end
    local parts = {}
    for tok in tostring(raw):gmatch("[^,;]+") do
        local n = tonumber(Trim(tok))
        if n ~= nil then table.insert(parts, n) end
    end
    if #parts == 1 then
        return { X = parts[1], Y = parts[1], Z = parts[1] }
    end
    return {
        X = parts[1] or defaultX or 0.0,
        Y = parts[2] or defaultY or 0.0,
        Z = parts[3] or defaultZ or 0.0
    }
end

local function ParseRot3(raw)
    if not raw or raw == "" then
        return { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
    end
    local parts = {}
    for tok in tostring(raw):gmatch("[^,;]+") do
        local n = tonumber(Trim(tok))
        if n ~= nil then table.insert(parts, n) end
    end
    if #parts == 1 then
        return { Pitch = 0.0, Yaw = parts[1], Roll = 0.0 }
    end
    return {
        Pitch = parts[1] or 0.0,
        Yaw   = parts[2] or 0.0,
        Roll  = parts[3] or 0.0
    }
end

local function ParseRange(raw)
    if not raw or raw == "" then return nil, nil end
    local s = Trim(raw)
    local a, b = s:match("^([%-%d%.]+)%s*%.%.%s*([%-%d%.]+)$")
    if not a then
        a, b = s:match("^([%-%d%.]+)%s*%-%s*([%-%d%.]+)$")
    end
    if a and b then
        local lo = tonumber(a)
        local hi = tonumber(b)
        if lo and hi then
            if hi < lo then lo, hi = hi, lo end
            return lo, hi
        end
    end
    local single = tonumber(s)
    if single then return single, single end
    return nil, nil
end

local function ParsePattern(raw)
    if not raw or raw == "" then
        return { kind = "point", count = 1, radius = 0.0, step = 0.0, arcDeg = 360.0 }
    end
    local parts = {}
    for tok in tostring(raw):gmatch("[^:]+") do
        table.insert(parts, Trim(tok))
    end
    local kind = (parts[1] or "point"):lower()
    if kind == "ring" then
        return {
            kind = "ring",
            count = math.max(1, math.floor(tonumber(parts[2]) or 6)),
            radius = tonumber(parts[3]) or 200.0,
            arcDeg = 360.0
        }
    elseif kind == "line" then
        return {
            kind = "line",
            count = math.max(1, math.floor(tonumber(parts[2]) or 4)),
            step = tonumber(parts[3]) or 150.0
        }
    elseif kind == "arc" then
        return {
            kind = "arc",
            count = math.max(1, math.floor(tonumber(parts[2]) or 5)),
            radius = tonumber(parts[3]) or 220.0,
            arcDeg = tonumber(parts[4]) or 120.0
        }
    end
    return { kind = "point", count = 1, radius = 0.0, step = 0.0, arcDeg = 360.0 }
end

local function FormatNumber(n)
    if n == nil then return "0" end
    if math.abs(n - math.floor(n + 0.5)) < 1e-4 then
        return string.format("%d", math.floor(n + 0.5))
    end
    local s = string.format("%.3f", n)
    s = s:gsub("0+$", ""):gsub("%.$", "")
    return s
end

-- Normalize cue key names into canonical cue types and default targets.
local CUE_KEY_MAP = {
    anim       = { cueType = "anim",  alwaysCue = true,  defaultTarget = "player" },
    animcue    = { cueType = "anim",  alwaysCue = true,  defaultTarget = "player" },
    playeranim = { cueType = "anim",  alwaysCue = true,  defaultTarget = "player" },
    weaponanim = { cueType = "anim",  alwaysCue = true,  defaultTarget = "weapon_right" },
    equipanim  = { cueType = "anim",  alwaysCue = true,  defaultTarget = "weapon_right" },
    heldanim   = { cueType = "anim",  alwaysCue = true,  defaultTarget = "weapon_right" },
    targetanim = { cueType = "anim",  alwaysCue = true,  defaultTarget = "targets" },
    enemyanim  = { cueType = "anim",  alwaysCue = true,  defaultTarget = "targets" },
    aianim     = { cueType = "anim",  alwaysCue = true,  defaultTarget = "targets" },
    montage    = { cueType = "anim",  alwaysCue = false, defaultTarget = "player" },
    vfx        = { cueType = "vfx",   alwaysCue = false, defaultTarget = "player" },
    vfxcue     = { cueType = "vfx",   alwaysCue = true,  defaultTarget = "player" },
    sfx        = { cueType = "sfx",   alwaysCue = false, defaultTarget = "player" },
    sfxcue     = { cueType = "sfx",   alwaysCue = true,  defaultTarget = "player" },
    actor      = { cueType = "actor", alwaysCue = false, defaultTarget = "world" },
    actorcue   = { cueType = "actor", alwaysCue = true,  defaultTarget = "world" },
    spell      = { cueType = "spell", alwaysCue = false, defaultTarget = "player" },
    spellcue   = { cueType = "spell", alwaysCue = true,  defaultTarget = "player" },
    castspell  = { cueType = "spell", alwaysCue = true,  defaultTarget = "player" },
    hit        = { cueType = "hit",   alwaysCue = true,  defaultTarget = "player" },
    hitpulse   = { cueType = "hit",   alwaysCue = true,  defaultTarget = "player" },
    damagepulse= { cueType = "hit",   alwaysCue = true,  defaultTarget = "player" },
    decal      = { cueType = "decal", alwaysCue = true,  defaultTarget = "player" },
    shake      = { cueType = "shake", alwaysCue = true,  defaultTarget = "player" },
    camerashake= { cueType = "shake", alwaysCue = true,  defaultTarget = "player" },
    cue        = { cueType = "cue",   alwaysCue = true,  defaultTarget = nil }
}

local function LooksLikeTimelineValue(val)
    if not val or val == "" then return false end
    if val:find("|", 1, true) ~= nil then return true end
    local first = val:sub(1, 1)
    return first == "@" or first == "&" or first == ">" or first == "+"
end

-- Returns (isCue, cueType, defaultTarget)
function TimelineParser.ClassifyKey(keyLower, rawVal)
    local info = CUE_KEY_MAP[keyLower]
    if not info then return false, nil, nil end
    if info.alwaysCue or LooksLikeTimelineValue(rawVal) then
        return true, info.cueType, info.defaultTarget
    end
    return false, nil, nil
end

-- Parse timing token:
--   @0.35 / 0.35s          -> { mode="abs", offset=0.35 }
--   & / &+0.10 / &-0.05    -> { mode="sync_start", anchor="prev", offset=... }
--   &slash1+0.15           -> { mode="sync_start", anchor="id", anchorId="slash1", offset=0.15 }
--   +0.25                  -> { mode="sync_start", anchor="prev", offset=0.25 }
--   > / >+0.10 / >-0.12    -> { mode="after_end", anchor="lane", offset=... }
--   >prev / >prev-0.10     -> { mode="after_end", anchor="prev", offset=... }
--   >slash1 / >slash1-0.10 -> { mode="after_end", anchor="id", anchorId="slash1", offset=... }
function TimelineParser.ParseTiming(rawTiming)
    local s = Trim(rawTiming or "@0"):gsub("%s+", "")
    -- Strip trailing "s" unit (only if preceded by a digit)
    s = s:gsub("(%d)[sS]$", "%1")

    if s == "" then
        return { mode = "abs", offset = 0.0, raw = "@0" }
    end

    local first = s:sub(1, 1)

    if first == "@" then
        local num = tonumber(s:sub(2)) or 0.0
        return { mode = "abs", offset = math.max(0.0, num), raw = s }
    end

    if first == "+" then
        local num = tonumber(s:sub(2)) or 0.0
        return { mode = "sync_start", anchor = "prev", offset = num, raw = s }
    end

    if first == "&" then
        local rest = s:sub(2)
        if rest == "" then
            return { mode = "sync_start", anchor = "prev", offset = 0.0, raw = "&" }
        end
        -- Pure signed offset: &+0.15 or &-0.05
        local signOff = rest:match("^([%+%-][%d%.]+)$")
        if signOff then
            return { mode = "sync_start", anchor = "prev", offset = tonumber(signOff) or 0.0, raw = s }
        end
        -- Named anchor with optional signed offset: &slash1+0.15 or &slash1-0.05 or &slash1
        local aid, offStr = rest:match("^([%w_]+)([%+%-][%d%.]+)$")
        if aid then
            local aLow = aid:lower()
            if aLow == "prev" then
                return { mode = "sync_start", anchor = "prev", offset = tonumber(offStr) or 0.0, raw = s }
            end
            return { mode = "sync_start", anchor = "id", anchorId = aLow, anchorIdRaw = aid, offset = tonumber(offStr) or 0.0, raw = s }
        end
        local aLow = rest:lower()
        if aLow == "prev" then
            return { mode = "sync_start", anchor = "prev", offset = 0.0, raw = s }
        end
        return { mode = "sync_start", anchor = "id", anchorId = aLow, anchorIdRaw = rest, offset = 0.0, raw = s }
    end

    if first == ">" then
        local rest = s:sub(2)
        if rest == "" then
            return { mode = "after_end", anchor = "lane", offset = 0.0, raw = ">" }
        end
        -- Pure signed offset: >+0.10 or >-0.12
        local signOff = rest:match("^([%+%-][%d%.]+)$")
        if signOff then
            return { mode = "after_end", anchor = "lane", offset = tonumber(signOff) or 0.0, raw = s }
        end
        -- Named anchor (or "prev" / "lane") with optional offset: >slash1-0.10
        local aid, offStr = rest:match("^([%w_]+)([%+%-][%d%.]+)$")
        if aid then
            local aLow = aid:lower()
            local off = tonumber(offStr) or 0.0
            if aLow == "prev" then
                return { mode = "after_end", anchor = "prev", offset = off, raw = s }
            elseif aLow == "lane" then
                return { mode = "after_end", anchor = "lane", offset = off, raw = s }
            end
            return { mode = "after_end", anchor = "id", anchorId = aLow, anchorIdRaw = aid, offset = off, raw = s }
        end
        local aLow = rest:lower()
        if aLow == "prev" then
            return { mode = "after_end", anchor = "prev", offset = 0.0, raw = s }
        elseif aLow == "lane" then
            return { mode = "after_end", anchor = "lane", offset = 0.0, raw = s }
        end
        return { mode = "after_end", anchor = "id", anchorId = aLow, anchorIdRaw = rest, offset = 0.0, raw = s }
    end

    -- Plain numeric timestamp (e.g. "0.35")
    local plainNum = tonumber(s)
    if plainNum ~= nil then
        return { mode = "abs", offset = math.max(0.0, plainNum), raw = "@" .. FormatNumber(plainNum) }
    end

    return { mode = "abs", offset = 0.0, raw = s, parseWarning = "Unrecognized timing token '" .. tostring(rawTiming) .. "', defaulting to @0" }
end

local function ComputeLaneKeys(cue)
    local t = cue.type or "unknown"
    local target = (cue.params and cue.params.target or "player"):lower()
    if t == "anim" then
        local slot = (cue.params and cue.params.slot or "auto"):lower()
        return "anim:" .. target .. ":" .. slot, "anim:" .. target
    end
    return t .. ":" .. target, t
end

-- Parse a single timeline cue line into a normalized cue struct.
function TimelineParser.ParseCueLine(cueType, rawVal, defaultTarget)
    local segments = {}
    for seg in tostring(rawVal or ""):gmatch("[^|]+") do
        local clean = Trim(seg)
        if clean ~= "" then
            table.insert(segments, clean)
        end
    end
    if #segments == 0 then return nil, "Empty cue line" end

    local idx = 1
    local resolvedType = cueType
    if resolvedType == "cue" then
        local typeTok = (segments[idx] or ""):lower()
        local mapped = CUE_KEY_MAP[typeTok]
        if mapped and mapped.cueType ~= "cue" then
            resolvedType = mapped.cueType
            defaultTarget = defaultTarget or mapped.defaultTarget
        else
            resolvedType = typeTok
        end
        idx = idx + 1
    end

    -- Segment 1: Timing token (if it looks like a timing token; else default @0)
    local timing = { mode = "abs", offset = 0.0, raw = "@0" }
    local firstSeg = segments[idx]
    if firstSeg and not firstSeg:find("=", 1, true) then
        local c = firstSeg:sub(1, 1)
        if c == "@" or c == "&" or c == ">" or c == "+" or tonumber((firstSeg:gsub("(%d)[sS]$", "%1"))) ~= nil then
            timing = TimelineParser.ParseTiming(firstSeg)
            idx = idx + 1
        end
    end

    -- Segment 2: Primary asset (optional for Hit cues where all remaining segments are k=v)
    local asset = nil
    if segments[idx] and not segments[idx]:find("=", 1, true) then
        asset = segments[idx]
        idx = idx + 1
    end

    -- Remaining segments: key=value options
    local params = {}
    local rawParamsOrder = {}
    if defaultTarget then
        params.target = defaultTarget
    end

    for i = idx, #segments do
        local k, v = segments[i]:match("^([%w_%-]+)%s*=%s*(.+)$")
        if k and v then
            local kl = Trim(k):lower()
            local val = Trim(v)
            if kl == "id" or kl == "name" then
                params.id = val
                params.idLower = val:lower()
            elseif kl == "rate" or kl == "speed" or kl == "playrate" then
                params.rate = tonumber(val) or 1.0
            elseif kl == "start" or kl == "starttime" then
                params.start = tonumber(val) or 0.0
            elseif kl == "dur" or kl == "duration" then
                if val:lower() == "auto" then
                    params.dur = nil
                    params.durAuto = true
                else
                    params.dur = tonumber(val)
                    params.durAuto = false
                end
            elseif kl == "slot" or kl == "animslot" then
                params.slot = val
            elseif kl == "section" then
                params.section = val
            elseif kl == "blendin" then
                params.blendIn = tonumber(val)
            elseif kl == "blendout" then
                params.blendOut = tonumber(val)
            elseif kl == "loop" or kl == "loopcount" then
                params.loop = math.max(1, math.floor(tonumber(val) or 1))
            elseif kl == "stopall" or kl == "stopallmontages" then
                params.stopAll = ParseBool(val, false)
            elseif kl == "syncto" or kl == "sync" then
                params.syncTo = val:lower()
                params.syncToRaw = val
            elseif kl == "target" then
                params.target = val
            elseif kl == "attach" then
                params.attach = val
            elseif kl == "socket" or kl == "bone" then
                params.socket = val
            elseif kl == "offset" or kl == "loc" then
                params.offset = ParseVec3(val, 0.0, 0.0, 0.0)
                params.offsetRaw = val
            elseif kl == "rot" or kl == "rotation" then
                params.rot = ParseRot3(val)
                params.rotRaw = val
            elseif kl == "scale" then
                params.scale = ParseVec3(val, 1.0, 1.0, 1.0)
                params.scaleRaw = val
            elseif kl == "size" then
                params.size = ParseVec3(val, 128.0, 256.0, 256.0)
                params.sizeRaw = val
            elseif kl == "pattern" then
                params.pattern = ParsePattern(val)
                params.patternRaw = val
            elseif kl == "vol" or kl == "volume" then
                params.vol = tonumber(val) or 1.0
            elseif kl == "pitch" then
                params.pitch = tonumber(val) or 1.0
            elseif kl == "radius" or kl == "hitradius" then
                params.radius = tonumber(val)
            elseif kl == "cone" or kl == "angle" then
                params.cone = tonumber(val)
            elseif kl == "maxtargets" then
                params.maxTargets = math.max(1, math.floor(tonumber(val) or 1))
            elseif kl == "dmg" or kl == "damage" then
                local lo, hi = ParseRange(val)
                params.dmgMin = lo
                params.dmgMax = hi
                params.dmgRaw = val
            elseif kl == "dmgmin" or kl == "damagemin" then
                params.dmgMin = tonumber(val)
            elseif kl == "dmgmax" or kl == "damagemax" then
                params.dmgMax = tonumber(val)
            elseif kl == "class" or kl == "damageclass" then
                params.damageClass = val
            elseif kl == "force" or kl == "knockback" then
                params.force = tonumber(val)
            elseif kl == "ge" or kl == "damagege" then
                params.ge = val
            elseif kl == "vfx" then
                params.vfx = val
            elseif kl == "sfx" then
                params.sfx = val
            elseif kl == "innerradius" then
                params.innerRadius = tonumber(val)
            elseif kl == "outerradius" then
                params.outerRadius = tonumber(val)
            elseif kl == "falloff" then
                params.falloff = tonumber(val)
            elseif kl == "allowunsafespawn" or kl == "forcespawn" then
                params.allowUnsafeSpawn = ParseBool(val, false)
            elseif kl == "scalewithspeed" then
                params.scaleWithSpeed = ParseBool(val, true)
            elseif kl == "trackimpact" or kl == "waitimpact" then
                params.trackImpact = ParseBool(val, true)
            elseif kl == "impacttimeout" then
                params.impactTimeout = tonumber(val) or 2.5
            elseif kl == "range" or kl == "maxrange" then
                params.range = tonumber(val) or 2500.0
            elseif kl == "vfxfloat" or kl == "paramfloat" then
                -- Syntax: vfxFloat=Name:Val (multiple allowed via semicolon, e.g. Scale:0.35;Width:0.4)
                params.vfxFloats = params.vfxFloats or {}
                for item in val:gmatch("[^;]+") do
                    local pn, pv = Trim(item):match("^([^:]+):([%-%d%.]+)$")
                    if pn and pv then
                        table.insert(params.vfxFloats, { name = Trim(pn), value = tonumber(pv) })
                    end
                end
                params.vfxFloatRaw = val
            elseif kl == "vfxvec" or kl == "paramvec" then
                -- Syntax: vfxVec=Name:X,Y,Z (multiple allowed via semicolon)
                params.vfxVecs = params.vfxVecs or {}
                for item in val:gmatch("[^;]+") do
                    local pn, pv = Trim(item):match("^([^:]+):(.+)$")
                    if pn and pv then
                        table.insert(params.vfxVecs, { name = Trim(pn), value = ParseVec3(pv, 0, 0, 0) })
                    end
                end
                params.vfxVecRaw = val
            elseif kl == "asset" then
                asset = val
            else
                params[kl] = val
            end
            table.insert(rawParamsOrder, kl)
        end
    end

    local cue = {
        type = resolvedType,
        timing = timing,
        asset = asset,
        id = params.id,
        idLower = params.idLower,
        params = params,
        rawVal = rawVal
    }
    return cue, timing.parseWarning
end

-- Compile legacy flat fields in a custom_spells.txt [Section] into timeline cues
-- when the section has no explicit timeline lines.
function TimelineParser.CompileLegacyDef(def)
    local cues = {}
    if not def then return cues end

    local hasMontage = (def.montage and def.montage ~= "" and not def.skipMontage)
    local hasVfx     = (def.vfx and def.vfx ~= "")
    local hasSfx     = (def.sfx and def.sfx ~= "")
    local hasHit     = (def.spinHitbox or def.hitDamageMin ~= nil or def.hitDamageMax ~= nil or def.hitRadius ~= nil)
    local hasExtra   = (def.damageSpell and def.damageSpell ~= "")
    local hasActor   = (def.spawnActor and def.spawnActor ~= "" and def.allowUnsafeSpawn == true)

    if not (hasMontage or hasVfx or hasSfx or hasHit or hasExtra or hasActor) then
        return cues
    end

    if hasMontage then
        table.insert(cues, {
            type = "anim",
            timing = { mode = "abs", offset = 0.0, raw = "@0" },
            asset = def.montage,
            id = "main_anim",
            idLower = "main_anim",
            params = {
                target = "player",
                slot = "auto",
                -- Keep cue rate at 1.0 so stageSpeed (entry.customOverrideSpeed) does not double-multiply Speed!
                rate = 1.0,
                start = 0.05,
                durAuto = true,
                stopAll = true,
                scaleWithSpeed = true
            }
        })
    end

    if hasActor then
        table.insert(cues, {
            type = "actor",
            timing = { mode = "abs", offset = 0.0, raw = "@0" },
            asset = def.spawnActor,
            params = {
                target = "world",
                attach = "world",
                allowUnsafeSpawn = true,
                scaleWithSpeed = false
            }
        })
    end

    if hasSfx then
        table.insert(cues, {
            type = "sfx",
            timing = { mode = "abs", offset = 0.0, raw = "@0" },
            asset = def.sfx,
            params = { target = "player", vol = 1.0, pitch = 1.0, scaleWithSpeed = false }
        })
    end

    if hasVfx then
        table.insert(cues, {
            type = "vfx",
            timing = { mode = "abs", offset = 0.0, raw = "@0" },
            asset = def.vfx,
            params = { target = "player", scaleWithSpeed = false }
        })
    end

    if hasHit then
        local hitDelay = tonumber(def.hitDelaySec) or 0.0
        table.insert(cues, {
            type = "hit",
            timing = { mode = "abs", offset = math.max(0.0, hitDelay), raw = "@" .. FormatNumber(math.max(0.0, hitDelay)) },
            asset = nil,
            id = "legacy_hit",
            idLower = "legacy_hit",
            params = {
                target = "player",
                radius = tonumber(def.hitRadius) or tonumber(def.impactRadius) or 400.0,
                dmgMin = tonumber(def.hitDamageMin) or tonumber(def.hitDamageMax) or 65,
                dmgMax = tonumber(def.hitDamageMax) or tonumber(def.hitDamageMin) or 135,
                damageClass = def.damageClass,
                force = tonumber(def.damageForce) or 260.0,
                ge = def.damageGE,
                vfx = def.hitVfx,
                sfx = def.hitSfx,
                scaleWithSpeed = false
            }
        })
    end

    if hasExtra then
        local baseHitDelay = hasHit and (tonumber(def.hitDelaySec) or 0.0) or 0.0
        local extraDelay = baseHitDelay + (tonumber(def.extraAoEDelaySec) or 0.0)
        table.insert(cues, {
            type = "spell",
            timing = { mode = "abs", offset = math.max(0.0, extraDelay), raw = "@" .. FormatNumber(math.max(0.0, extraDelay)) },
            asset = def.damageSpell,
            params = { target = "player", scaleWithSpeed = false }
        })
    end

    return cues
end

-- Build a validated, dependency-resolved timeline from a parsed CustomSpell definition.
function TimelineParser.BuildTimeline(def)
    local warnings = {}
    local cues = {}
    local isLegacyCompiled = false

    if def and def.rawCues and #def.rawCues > 0 then
        for _, rc in ipairs(def.rawCues) do
            local cue, warn = TimelineParser.ParseCueLine(rc.cueType, rc.rawVal, rc.defaultTarget)
            if warn then table.insert(warnings, warn) end
            if cue then
                table.insert(cues, cue)
            end
        end
    else
        cues = TimelineParser.CompileLegacyDef(def)
        isLegacyCompiled = (#cues > 0)
    end

    if #cues == 0 then
        return nil, warnings
    end

    local idToIndex = {}
    local lastByLaneExact = {}
    local lastByLaneBroad = {}
    local maxEstimatedEnd = 0.0

    for i, cue in ipairs(cues) do
        cue.index = i
        if cue.idLower and cue.idLower ~= "" then
            if idToIndex[cue.idLower] then
                table.insert(warnings, string.format("Cue #%d duplicates id '%s'", i, tostring(cue.id)))
            end
            idToIndex[cue.idLower] = i
        end

        local exactLane, broadLane = ComputeLaneKeys(cue)
        cue.laneExact = exactLane
        cue.laneBroad = broadLane

        local t = cue.timing or { mode = "abs", offset = 0.0 }
        cue.anchorIndex = nil

        if t.mode == "sync_start" then
            if t.anchor == "id" then
                local refIdx = idToIndex[t.anchorId]
                if refIdx and refIdx < i then
                    cue.anchorIndex = refIdx
                else
                    table.insert(warnings, string.format("Cue #%d references unknown/future anchor '&%s'; falling back to prev", i, tostring(t.anchorIdRaw or t.anchorId)))
                    cue.anchorIndex = (i > 1) and (i - 1) or nil
                end
            else
                cue.anchorIndex = (i > 1) and (i - 1) or nil
            end
        elseif t.mode == "after_end" then
            if t.anchor == "id" then
                local refIdx = idToIndex[t.anchorId]
                if refIdx and refIdx < i then
                    cue.anchorIndex = refIdx
                else
                    table.insert(warnings, string.format("Cue #%d references unknown/future anchor '>%s'; falling back to lane/prev", i, tostring(t.anchorIdRaw or t.anchorId)))
                    cue.anchorIndex = lastByLaneExact[exactLane] or lastByLaneBroad[broadLane] or ((i > 1) and (i - 1) or nil)
                end
            elseif t.anchor == "prev" then
                cue.anchorIndex = (i > 1) and (i - 1) or nil
            else
                -- Smart lane anchor: exact slot/target match first, then same type/target, then prev
                cue.anchorIndex = lastByLaneExact[exactLane] or lastByLaneBroad[broadLane] or ((i > 1) and (i - 1) or nil)
            end
        end

        -- Resolve optional syncTo cue id
        if cue.params and cue.params.syncTo then
            local sIdx = idToIndex[cue.params.syncTo]
            if sIdx and sIdx < i then
                cue.syncToIndex = sIdx
            else
                table.insert(warnings, string.format("Cue #%d syncTo='%s' not found among earlier cues", i, tostring(cue.params.syncToRaw or cue.params.syncTo)))
            end
        end

        -- Static start/end estimation (refined dynamically at runtime when Anim dur=auto)
        local estStart = 0.0
        if t.mode == "abs" or not cue.anchorIndex then
            estStart = math.max(0.0, tonumber(t.offset) or 0.0)
        elseif t.mode == "sync_start" then
            local aCue = cues[cue.anchorIndex]
            estStart = math.max(0.0, (aCue and aCue.estimatedStart or 0.0) + (tonumber(t.offset) or 0.0))
        elseif t.mode == "after_end" then
            local aCue = cues[cue.anchorIndex]
            estStart = math.max(0.0, (aCue and aCue.estimatedEnd or 0.0) + (tonumber(t.offset) or 0.0))
        end

        local estDur = 0.0
        if cue.params and cue.params.dur ~= nil then
            estDur = math.max(0.0, tonumber(cue.params.dur) or 0.0)
        elseif cue.type == "anim" then
            -- Default conservative estimate until runtime reads Montage_Play / SequenceLength
            local r = math.max(0.1, tonumber(cue.params and cue.params.rate) or 1.0)
            estDur = 0.85 / r
        end

        cue.estimatedStart = estStart
        cue.estimatedDur = estDur
        cue.estimatedEnd = estStart + estDur
        if cue.estimatedEnd > maxEstimatedEnd then
            maxEstimatedEnd = cue.estimatedEnd
        end

        lastByLaneExact[exactLane] = i
        lastByLaneBroad[broadLane] = i
    end

    local explicitDur = def and def.timelineDuration or nil
    local explicitAdvance = def and def.stepAdvanceAt or nil
    local overlapPolicy = (def and def.overlapPolicy or "replace"):lower()
    if overlapPolicy ~= "replace" and overlapPolicy ~= "parallel" and overlapPolicy ~= "ignore" then
        overlapPolicy = "replace"
    end

    local timeline = {
        cues = cues,
        idToIndex = idToIndex,
        isLegacyCompiled = isLegacyCompiled,
        estimatedDuration = explicitDur or maxEstimatedEnd,
        explicitDuration = explicitDur,
        stepAdvanceAt = explicitAdvance,
        cancelOnRelease = (def and def.cancelOnRelease == true) or false,
        overlapPolicy = overlapPolicy,
        scaleWithSpeed = (def == nil or def.scaleTimelineWithSpeed ~= false),
        warnings = warnings
    }
    return timeline, warnings
end

-- Serialize timing struct back to canonical string.
function TimelineParser.SerializeTiming(t)
    if not t then return "@0" end
    local off = tonumber(t.offset) or 0.0
    local function signedOff()
        if math.abs(off) < 1e-4 then return "" end
        if off > 0 then return "+" .. FormatNumber(off) end
        return FormatNumber(off)
    end
    if t.mode == "abs" then
        return "@" .. FormatNumber(math.max(0.0, off))
    elseif t.mode == "sync_start" then
        if t.anchor == "id" and (t.anchorIdRaw or t.anchorId) then
            return "&" .. tostring(t.anchorIdRaw or t.anchorId) .. signedOff()
        end
        if math.abs(off) < 1e-4 then return "&" end
        return "&" .. signedOff()
    elseif t.mode == "after_end" then
        if t.anchor == "id" and (t.anchorIdRaw or t.anchorId) then
            return ">" .. tostring(t.anchorIdRaw or t.anchorId) .. signedOff()
        elseif t.anchor == "prev" then
            return ">prev" .. signedOff()
        end
        return ">" .. signedOff()
    end
    return "@0"
end

local SERIALIZE_KEY_LABELS = {
    anim  = "Anim",
    vfx   = "VFX",
    sfx   = "SFX",
    actor = "Actor",
    spell = "Spell",
    hit   = "Hit",
    decal = "Decal",
    shake = "Shake"
}

local function FormatVec3(v)
    return FormatNumber(v.X or 0) .. "," .. FormatNumber(v.Y or 0) .. "," .. FormatNumber(v.Z or 0)
end

local function FormatRot3(r)
    return FormatNumber(r.Pitch or 0) .. "," .. FormatNumber(r.Yaw or 0) .. "," .. FormatNumber(r.Roll or 0)
end

-- Deterministically serialize a single cue back to INI line form.
function TimelineParser.SerializeCue(cue)
    if not cue then return "" end
    local p = cue.params or {}
    local keyLabel = SERIALIZE_KEY_LABELS[cue.type] or "Cue"
    local suppressTarget = false
    if cue.type == "anim" then
        local tl = (p.target or "player"):lower()
        if tl == "weapon_right" then
            keyLabel = "WeaponAnim"
            suppressTarget = true
        elseif tl == "targets" then
            keyLabel = "TargetAnim"
            suppressTarget = true
        elseif tl == "player" then
            suppressTarget = true
        end
    end

    local parts = {}
    if keyLabel == "Cue" then
        table.insert(parts, tostring(cue.type or "anim"))
    end
    table.insert(parts, TimelineParser.SerializeTiming(cue.timing))
    if cue.asset and cue.asset ~= "" then
        table.insert(parts, cue.asset)
    end

    if cue.id and cue.id ~= "" then table.insert(parts, "id=" .. cue.id) end
    if p.target and not suppressTarget then table.insert(parts, "target=" .. tostring(p.target)) end
    if p.slot and p.slot ~= "auto" then table.insert(parts, "slot=" .. tostring(p.slot)) end
    if p.section and p.section ~= "" then table.insert(parts, "section=" .. tostring(p.section)) end
    if p.rate and math.abs(p.rate - 1.0) > 1e-4 then table.insert(parts, "rate=" .. FormatNumber(p.rate)) end
    if p.start and math.abs(p.start) > 1e-4 then table.insert(parts, "start=" .. FormatNumber(p.start)) end
    if p.dur ~= nil then table.insert(parts, "dur=" .. FormatNumber(p.dur)) end
    if p.blendIn ~= nil then table.insert(parts, "blendIn=" .. FormatNumber(p.blendIn)) end
    if p.blendOut ~= nil then table.insert(parts, "blendOut=" .. FormatNumber(p.blendOut)) end
    if p.loop and p.loop > 1 then table.insert(parts, "loop=" .. tostring(p.loop)) end
    if p.stopAll == true then table.insert(parts, "stopAll=true") end
    if p.syncToRaw or p.syncTo then table.insert(parts, "syncTo=" .. tostring(p.syncToRaw or p.syncTo)) end
    if p.attach and p.attach ~= "" then table.insert(parts, "attach=" .. tostring(p.attach)) end
    if p.socket and p.socket ~= "" then table.insert(parts, "socket=" .. tostring(p.socket)) end
    if p.offset then table.insert(parts, "offset=" .. FormatVec3(p.offset)) end
    if p.rot then table.insert(parts, "rot=" .. FormatRot3(p.rot)) end
    if p.scale then table.insert(parts, "scale=" .. FormatVec3(p.scale)) end
    if p.size then table.insert(parts, "size=" .. FormatVec3(p.size)) end
    if p.patternRaw and p.patternRaw ~= "" then table.insert(parts, "pattern=" .. p.patternRaw) end
    if p.vol and math.abs(p.vol - 1.0) > 1e-4 then table.insert(parts, "vol=" .. FormatNumber(p.vol)) end
    if p.pitch and math.abs(p.pitch - 1.0) > 1e-4 then table.insert(parts, "pitch=" .. FormatNumber(p.pitch)) end
    if p.radius ~= nil then table.insert(parts, "radius=" .. FormatNumber(p.radius)) end
    if p.cone ~= nil then table.insert(parts, "cone=" .. FormatNumber(p.cone)) end
    if p.maxTargets ~= nil then table.insert(parts, "maxTargets=" .. tostring(p.maxTargets)) end
    if p.dmgMin ~= nil then
        if p.dmgMax ~= nil and math.abs(p.dmgMax - p.dmgMin) > 1e-4 then
            table.insert(parts, "dmg=" .. FormatNumber(p.dmgMin) .. ".." .. FormatNumber(p.dmgMax))
        else
            table.insert(parts, "dmg=" .. FormatNumber(p.dmgMin))
        end
    end
    if p.damageClass and p.damageClass ~= "" then table.insert(parts, "class=" .. tostring(p.damageClass)) end
    if p.force ~= nil then table.insert(parts, "force=" .. FormatNumber(p.force)) end
    if p.ge and p.ge ~= "" then table.insert(parts, "ge=" .. tostring(p.ge)) end
    if p.vfx and p.vfx ~= "" then table.insert(parts, "vfx=" .. tostring(p.vfx)) end
    if p.sfx and p.sfx ~= "" then table.insert(parts, "sfx=" .. tostring(p.sfx)) end
    if p.innerRadius ~= nil then table.insert(parts, "innerRadius=" .. FormatNumber(p.innerRadius)) end
    if p.outerRadius ~= nil then table.insert(parts, "outerRadius=" .. FormatNumber(p.outerRadius)) end
    if p.falloff ~= nil then table.insert(parts, "falloff=" .. FormatNumber(p.falloff)) end
    if p.allowUnsafeSpawn == true then table.insert(parts, "allowUnsafeSpawn=true") end
    if p.scaleWithSpeed == false then table.insert(parts, "scaleWithSpeed=false") end
    if p.trackImpact == true then table.insert(parts, "trackImpact=true") end
    if p.impactTimeout ~= nil then table.insert(parts, "impactTimeout=" .. FormatNumber(p.impactTimeout)) end
    if p.range ~= nil then table.insert(parts, "range=" .. FormatNumber(p.range)) end
    if p.vfxFloatRaw and p.vfxFloatRaw ~= "" then table.insert(parts, "vfxFloat=" .. p.vfxFloatRaw) end
    if p.vfxVecRaw and p.vfxVecRaw ~= "" then table.insert(parts, "vfxVec=" .. p.vfxVecRaw) end

    return string.format("%-10s = %s", keyLabel, table.concat(parts, " | "))
end

-- Round-trip serialize a full CustomSpell definition + its timeline back to custom_spells.txt format.
function TimelineParser.SerializeSpell(def, timeline)
    if not def or not def.name then return "" end
    local lines = { "[" .. tostring(def.name) .. "]" }
    if def.suppressBaseSpell then
        table.insert(lines, "BaseSpell        = none")
    elseif def.baseSpell then
        table.insert(lines, "BaseSpell        = " .. tostring(def.baseSpell))
    end
    if def.category then table.insert(lines, "Category         = " .. tostring(def.category)) end
    if def.speed then table.insert(lines, "Speed            = " .. FormatNumber(def.speed)) end
    if def.clamp then table.insert(lines, "Clamp            = true") end
    if def.runeCost then table.insert(lines, "RuneCost         = " .. tostring(def.runeCost)) end
    if def.runeCount and def.runeCount > 1 then table.insert(lines, "RuneCount        = " .. tostring(def.runeCount)) end

    local tl = timeline or TimelineParser.BuildTimeline(def)
    if tl then
        if tl.explicitDuration then table.insert(lines, "TimelineDuration = " .. FormatNumber(tl.explicitDuration)) end
        if tl.stepAdvanceAt then table.insert(lines, "StepAdvanceAt    = " .. FormatNumber(tl.stepAdvanceAt)) end
        if tl.cancelOnRelease then table.insert(lines, "CancelOnRelease  = true") end
        if tl.overlapPolicy and tl.overlapPolicy ~= "replace" then
            table.insert(lines, "OverlapPolicy    = " .. tostring(tl.overlapPolicy))
        end
        if tl.scaleWithSpeed == false then
            table.insert(lines, "ScaleTimelineWithSpeed = false")
        end
        for _, cue in ipairs(tl.cues) do
            table.insert(lines, TimelineParser.SerializeCue(cue))
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

return TimelineParser
