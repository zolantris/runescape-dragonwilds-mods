-- Arcane Wilds - Direct Spell Name & Combo Rule Parser (JSON Schema + Legacy DSL)

local Json = require("json")
local SchemaMigrator = require("schema_migrator")
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

local function ParseLegacyMacroList(ruleStr, nameMapByCat, globalNameMap, discoveredAssets)
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
                    -- Consistent with multi-stage syntax: Category@spells:speed :weight;
                    speedMult = RuleParser.ParseSpeedMultiplier(tokens[2])
                    macroWeight = tonumber(tokens[3]) or 1.0
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

local function FormatMacroDisplaySummary(ruleName, stages, weight)
    local stageParts = {}
    for _, st in ipairs(stages) do
        local stepNames = {}
        for _, sd in ipairs(st.steps) do
            table.insert(stepNames, tostring(sd.token or "?"))
        end
        local spStr = string.format("%.2g", tonumber(st.speed) or 1.0)
        if #stepNames == 1 and st.elementLower == stepNames[1]:lower() then
            table.insert(stageParts, string.format("%s:%s", stepNames[1], spStr))
        else
            table.insert(stageParts, string.format("%s@%s:%s", tostring(st.element), table.concat(stepNames, ","), spStr))
        end
    end
    local summary = table.concat(stageParts, " -> ") .. " :" .. tostring(weight)
    if ruleName and ruleName ~= "" then
        return "[" .. ruleName .. "] " .. summary
    end
    return summary
end

-- Parse combo_rules.json (or JSONC) into normalized weighted macros.
-- Returns (macros, nil) on success, or (nil, errMsg) on syntax/schema error.
function RuleParser.ParseJsonMacros(rawJson, nameMapByCat, globalNameMap, discoveredAssets)
    if not rawJson or Trim(rawJson) == "" then
        return {}, nil
    end
    local doc, err = Json.Decode(rawJson)
    if err then
        return nil, err
    end
    if type(doc) ~= "table" then
        return nil, "root JSON value must be an object with a 'rules' array"
    end

    local migratedDoc, migErr = SchemaMigrator.Migrate("combo_rules", doc)
    if migErr then
        return nil, migErr
    end
    doc = migratedDoc

    local rulesList = doc.rules
    if type(rulesList) ~= "table" then
        if doc[1] ~= nil then
            rulesList = doc
        else
            return nil, "missing 'rules' array in combo_rules.json"
        end
    end

    local macros = {}
    for rIdx, rule in ipairs(rulesList) do
        if type(rule) == "table" and rule.enabled ~= false then
            local ruleName = rule.name ~= nil and Trim(tostring(rule.name)) or nil
            local weight = tonumber(rule.weight)
            if weight == nil then weight = 1.0 end

            if weight > 0 then
                if type(rule.stages) == "table" and #rule.stages > 0 then
                    local stages = {}
                    for _, st in ipairs(rule.stages) do
                        if type(st) == "table" then
                            local rawSteps = {}
                            if type(st.spells) == "table" then
                                for _, tok in ipairs(st.spells) do
                                    local cleanTok = Trim(tostring(tok or ""))
                                    if cleanTok ~= "" then table.insert(rawSteps, cleanTok) end
                                end
                            elseif st.spell ~= nil then
                                local cleanTok = Trim(tostring(st.spell))
                                if cleanTok ~= "" then table.insert(rawSteps, cleanTok) end
                            end

                            if #rawSteps > 0 then
                                local elem = st.category ~= nil and Trim(tostring(st.category)) or ""
                                if elem == "" then
                                    -- Allow omitting category for custom/global single-spell stages (e.g. { spell: "SaradominGodsword" })
                                    elem = rawSteps[1]
                                end
                                local elemLower = elem:lower()
                                local stepDescriptors = {}
                                for _, tok in ipairs(rawSteps) do
                                    table.insert(stepDescriptors, ResolveStepDescriptor(tok, elemLower, nameMapByCat, globalNameMap, discoveredAssets))
                                end
                                local speedMult = RuleParser.ParseSpeedMultiplier(st.speed or 1.0)
                                table.insert(stages, {
                                    element = elem,
                                    elementLower = elemLower,
                                    steps = stepDescriptors,
                                    speed = speedMult
                                })
                            end
                        end
                    end

                    if #stages > 0 then
                        table.insert(macros, {
                            name = ruleName,
                            raw = FormatMacroDisplaySummary(ruleName, stages, weight),
                            weight = weight,
                            stages = stages
                        })
                    end
                elseif type(rule.chain) == "string" and Trim(rule.chain) ~= "" then
                    local chainStr = Trim(rule.chain)
                    if not chainStr:match(";$") then chainStr = chainStr .. ";" end
                    local parsed = ParseLegacyMacroList(chainStr, nameMapByCat, globalNameMap, discoveredAssets)
                    for _, m in ipairs(parsed) do
                        if rule.weight ~= nil then m.weight = weight end
                        m.name = ruleName
                        if ruleName and ruleName ~= "" then
                            m.raw = "[" .. ruleName .. "] " .. m.raw
                        end
                        if m.weight > 0 then
                            table.insert(macros, m)
                        end
                    end
                else
                    return nil, string.format("rule #%d missing 'stages' array or 'chain' string", rIdx)
                end
            end
        end
    end

    return macros, nil
end

function RuleParser.ParseWeightedMacros(ruleStr, nameMapByCat, globalNameMap, discoveredAssets)
    if not ruleStr or Trim(ruleStr) == "" then
        return {}, nil
    end
    if Json.LooksLikeJson(ruleStr) then
        return RuleParser.ParseJsonMacros(ruleStr, nameMapByCat, globalNameMap, discoveredAssets)
    end
    return ParseLegacyMacroList(ruleStr, nameMapByCat, globalNameMap, discoveredAssets), nil
end

return RuleParser
