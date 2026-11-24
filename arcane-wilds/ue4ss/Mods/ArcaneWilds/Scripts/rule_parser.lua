-- Arcane Wilds - Direct Spell Name & Combo Rule Parser (Zero Numeric Abstraction)

local RuleParser = {}

local function Trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function RuleParser.ParseSpeedMultiplier(raw)
    local s = Trim(tostring(raw or "1.0")):lower()
    local isPct = s:find("%%") ~= nil
    s = s:gsub("%%", ""):gsub("x", "")
    local n = tonumber(s) or 1.0
    if isPct or n >= 10.0 then
        n = n / 100.0
    end
    if n < 1.0 then n = 1.0 end
    return n
end

function RuleParser.ComputeVariedSpeed(baseMult, variancePct)
    if not baseMult or baseMult <= 1.0 then
        return 1.0
    end
    local bonus = baseMult - 1.0
    local varFrac = math.max(0.0, math.min(1.0, (tonumber(variancePct) or 0) / 100.0))
    if varFrac <= 0.0 then
        return baseMult
    end
    local delta = (math.random() * 2.0 - 1.0) * varFrac
    local finalSpeed = 1.0 + bonus * (1.0 + delta)
    if finalSpeed < 1.0 then finalSpeed = 1.0 end
    return finalSpeed
end

-- Parse spell_names.txt into:
--   byCategory[catLower][nameLower] = assetNameString (e.g. "DA_Spell_Primary_Water_03")
--   globalNames[nameLower]          = assetNameString
function RuleParser.ParseSpellNameMap(rawText)
    local byCategory = {}
    local globalNames = {}
    if not rawText or rawText == "" then
        return byCategory, globalNames
    end

    for line in rawText:gmatch("[^\r\n]+") do
        local clean = Trim(line)
        if clean ~= "" and not clean:match("^#") and not clean:match("^;") then
            local hashPos = clean:find("#", 1, true)
            if hashPos then clean = Trim(clean:sub(1, hashPos - 1)) end
            local lhs, rhs = clean:match("^([^=]+)=(.+)$")
            if lhs and rhs then
                local targetAsset = Trim(rhs)
                local cat, friendlyName = Trim(lhs):match("^([^%.]+)%.(.+)$")
                if targetAsset ~= "" then
                    if cat and friendlyName then
                        local cKey = Trim(cat):lower()
                        local nKey = Trim(friendlyName):lower()
                        if cKey == "*" then
                            globalNames[nKey] = targetAsset
                        else
                            byCategory[cKey] = byCategory[cKey] or {}
                            byCategory[cKey][nKey] = targetAsset
                        end
                    else
                        local nKey = Trim(lhs):lower()
                        globalNames[nKey] = targetAsset
                    end
                end
            end
        end
    end
    return byCategory, globalNames
end

-- Resolve a step token directly to a spell lookup descriptor:
-- { token = "wave", assetName = "DA_Spell_Primary_Water_03" (or nil), fallbackIndex = 0..3 (or nil) }
local function ResolveStepDescriptor(token, elemLower, nameMapByCat, globalNameMap, discoveredAssets)
    local rawTok = Trim(token or "")
    local clean = rawTok:lower()
    if clean == "" then
        return { token = "0", assetName = nil, fallbackIndex = 0 }
    end

    -- 1. Check category-specific spell_names.txt entry (e.g. "Water.wave" -> "DA_Spell_Primary_Water_03")
    if nameMapByCat and elemLower and nameMapByCat[elemLower] and nameMapByCat[elemLower][clean] then
        return {
            token = rawTok,
            assetName = nameMapByCat[elemLower][clean],
            fallbackIndex = nil
        }
    end

    -- 2. Check global spell_names.txt entry (e.g. "*.wave" -> "DA_Spell_Primary_Water_03")
    if globalNameMap and globalNameMap[clean] then
        return {
            token = rawTok,
            assetName = globalNameMap[clean],
            fallbackIndex = nil
        }
    end

    -- 3. Check if the user wrote an exact discovered DA_Spell_* asset name or AnimMontage name directly!
    if discoveredAssets and discoveredAssets[clean] then
        return {
            token = rawTok,
            assetName = discoveredAssets[clean],
            fallbackIndex = nil
        }
    end

    -- 4. Optional numeric position shorthand (0..3) if explicitly typed
    local num = tonumber(clean)
    if num ~= nil then
        return {
            token = rawTok,
            assetName = nil,
            fallbackIndex = math.max(0, math.min(3, math.floor(num)))
        }
    end

    -- 5. Treat unrecognized non-numeric token as a direct asset/montage name pattern for runtime lookup
    return {
        token = rawTok,
        assetName = rawTok,
        fallbackIndex = nil
    }
end

local function ParseStepDescriptors(stepsStr, elemLower, nameMapByCat, globalNameMap, discoveredAssets)
    local steps = {}
    for tok in (stepsStr or ""):gmatch("[^,]+") do
        local cleanTok = Trim(tok)
        if cleanTok ~= "" then
            table.insert(steps, ResolveStepDescriptor(cleanTok, elemLower, nameMapByCat, globalNameMap, discoveredAssets))
        end
    end
    if #steps == 0 then
        table.insert(steps, { token = "0", assetName = nil, fallbackIndex = 0 })
    end
    return steps
end

local function ParseStageHeader(stageStr)
    local elem = "*"
    local body = Trim(stageStr or "")
    local atPos = body:find("@", 1, true)
    if atPos then
        elem = Trim(body:sub(1, atPos - 1))
        if elem == "" then elem = "*" end
        body = Trim(body:sub(atPos + 1))
    end
    local tokens = {}
    for tok in body:gmatch("[^:]+") do
        table.insert(tokens, Trim(tok))
    end
    return elem, tokens
end

function RuleParser.ParseWeightedMacros(ruleStr, nameMapByCat, globalNameMap, discoveredAssets)
    local macros = {}
    if not ruleStr or Trim(ruleStr) == "" then
        return macros
    end

    for entry in ruleStr:gmatch("[^;]+") do
        local rawEntry = Trim(entry)
        if rawEntry ~= "" then
            local stages = {}
            local macroWeight = 1.0

            if rawEntry:find("->", 1, true) then
                local parts = {}
                local remaining = rawEntry
                while remaining and remaining ~= "" do
                    local arrowPos = remaining:find("->", 1, true)
                    if arrowPos then
                        table.insert(parts, Trim(remaining:sub(1, arrowPos - 1)))
                        remaining = Trim(remaining:sub(arrowPos + 2))
                    else
                        table.insert(parts, Trim(remaining))
                        break
                    end
                end

                for i, stageStr in ipairs(parts) do
                    local elem, tokens = ParseStageHeader(stageStr)
                    local elemLower = elem:lower()
                    local stepDescriptors = ParseStepDescriptors(tokens[1] or "0", elemLower, nameMapByCat, globalNameMap, discoveredAssets)
                    local speedMult = 1.0
                    if i == #parts and #tokens >= 3 then
                        speedMult = RuleParser.ParseSpeedMultiplier(tokens[2])
                        macroWeight = tonumber(tokens[3]) or 1.0
                    else
                        speedMult = RuleParser.ParseSpeedMultiplier(tokens[2] or "1.0")
                    end

                    table.insert(stages, {
                        element = elem,
                        elementLower = elemLower,
                        steps = stepDescriptors,
                        speed = speedMult
                    })
                end
            else
                local elem, tokens = ParseStageHeader(rawEntry)
                local elemLower = elem:lower()
                local stepDescriptors = ParseStepDescriptors(tokens[1] or "0", elemLower, nameMapByCat, globalNameMap, discoveredAssets)
                local speedMult = 1.0
                if #tokens >= 3 then
                    macroWeight = tonumber(tokens[2]) or 1.0
                    speedMult = RuleParser.ParseSpeedMultiplier(tokens[3])
                elseif #tokens == 2 then
                    macroWeight = 1.0
                    speedMult = RuleParser.ParseSpeedMultiplier(tokens[2])
                end

                table.insert(stages, {
                    element = elem,
                    elementLower = elemLower,
                    steps = stepDescriptors,
                    speed = speedMult
                })
            end

            if #stages > 0 and macroWeight > 0 then
                table.insert(macros, {
                    raw = rawEntry,
                    weight = macroWeight,
                    stages = stages
                })
            end
        end
    end

    return macros
end

return RuleParser
