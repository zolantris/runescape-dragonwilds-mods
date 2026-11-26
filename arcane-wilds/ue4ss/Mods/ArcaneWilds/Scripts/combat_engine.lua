-- ArcaneWilds v1.70.0 - Combo Execution, Montage Pacing & Input Helpers
-- Handles weighted macro selection, notify-safe speed clamps, spell triggering, and anchor return state.

local RuleParser = require("rule_parser")
local SpellScanner = require("spell_scanner")
local CustomSpells = require("custom_spells")
local ConfigManager = require("config_manager")
local EquipmentRunes = require("equipment_runes")

local CombatEngine = {}

local function GetMacroStartCategory(macro)
    if not macro or not macro.stages or not macro.stages[1] then return nil end
    local st1 = macro.stages[1]
    if st1.elementLower and st1.elementLower ~= "" and st1.elementLower ~= "*" then
        return st1.elementLower
    end
    local firstStep = st1.steps and st1.steps[1]
    if firstStep and firstStep.token and firstStep.token ~= "" and tonumber(firstStep.token) == nil then
        return firstStep.token:lower()
    end
    return nil
end

local function GetMacroStartSpellToken(macro)
    if not macro or not macro.stages or not macro.stages[1] then return nil end
    local firstStep = macro.stages[1].steps and macro.stages[1].steps[1]
    if firstStep and firstStep.token and firstStep.token ~= "" and tonumber(firstStep.token) == nil then
        return firstStep.token:lower()
    end
    return nil
end

local function DetectActiveStartingSpell(pawn, combatMagic, state)
    local spellName = nil
    if combatMagic and combatMagic:IsValid() then
        pcall(function()
            if combatMagic.CurrentSpellActor and combatMagic.CurrentSpellActor:IsValid() then
                local d = combatMagic.CurrentSpellActor.Data
                if d and d:IsValid() then
                    spellName = SpellScanner.ExtractShortObjectName(SpellScanner.SafeGetName(d))
                end
            end
        end)
        if not spellName then
            pcall(function()
                if combatMagic.LastChainedSpell and combatMagic.LastChainedSpell:IsValid() then
                    spellName = SpellScanner.ExtractShortObjectName(SpellScanner.SafeGetName(combatMagic.LastChainedSpell))
                end
            end)
        end
    end
    -- Keep canonical asset shortName (e.g. "DA_Spell_Primary_Earth_01") so element identity is never lost
    return spellName
end

function CombatEngine.PickWeightedMacroForElement(state, anchorCategory, activeStartingSpell)
    if #state.ParsedMacros == 0 then return nil end

    local anchorLower = (anchorCategory and anchorCategory ~= "") and anchorCategory:lower() or nil
    local anchorBase = anchorLower and anchorLower:gsub("_wand$", ""):gsub("_hold$", "") or nil
    local startSpellLower = (activeStartingSpell and activeStartingSpell ~= "") and activeStartingSpell:lower() or nil

    -- Derive element/category from activeStartingSpell if anchorCategory is missing or stale
    local derivedFromSpell = nil
    if startSpellLower and state.SpellRegistry and state.SpellRegistry[startSpellLower] then
        local regEntry = state.SpellRegistry[startSpellLower]
        if regEntry.categoryTag and regEntry.categoryTag ~= "" then
            derivedFromSpell = regEntry.categoryTag:lower()
        end
    end

    -- Equipped/anchor element is authoritative; fall back to spell's category if no anchor is set.
    local requiredCat = anchorLower or derivedFromSpell or startSpellLower
    if not requiredCat then return nil end

    local requiredBase = requiredCat:gsub("_wand$", ""):gsub("_hold$", "")
    local candidates = {}

    -- Priority 1: If a specific starting spell asset is active, match rules whose Stage 1 category matches
    -- AND whose Stage 1 first step resolves to that exact starting spell asset.
    if startSpellLower then
        for _, m in ipairs(state.ParsedMacros) do
            local mCat = GetMacroStartCategory(m)
            local st1 = m.stages and m.stages[1]
            local firstStep = st1 and st1.steps and st1.steps[1]
            local resolvedFirst = firstStep and ConfigManager.ResolveStepEntry(state, st1, firstStep)
            local resolvedShort = resolvedFirst and resolvedFirst.shortName and resolvedFirst.shortName:lower() or nil
            local catMatches = (mCat == requiredCat) or (mCat == requiredBase)
            if catMatches and resolvedShort and resolvedShort == startSpellLower then
                table.insert(candidates, m)
            end
        end
    end

    -- Priority 2: Strict exact element/category match on Stage 1 (e.g. "water" matches ONLY "water@...")
    if #candidates == 0 then
        for _, m in ipairs(state.ParsedMacros) do
            local mCat = GetMacroStartCategory(m)
            if mCat and mCat == requiredCat then
                table.insert(candidates, m)
            end
        end
    end

    -- Priority 3: Same base element match (e.g. "water_wand" -> "water"), NEVER crossing into another element
    if #candidates == 0 and requiredBase ~= requiredCat then
        for _, m in ipairs(state.ParsedMacros) do
            local mCat = GetMacroStartCategory(m)
            if mCat and mCat == requiredBase then
                table.insert(candidates, m)
            end
        end
    end

    if #candidates == 0 then return nil end

    local totalWeight = 0.0
    for _, m in ipairs(candidates) do
        totalWeight = totalWeight + (m.weight or 1.0)
    end
    if totalWeight <= 0.0 then return candidates[1] end

    local roll = math.random() * totalWeight
    local acc = 0.0
    for _, m in ipairs(candidates) do
        acc = acc + (m.weight or 1.0)
        if roll <= acc then return m end
    end
    return candidates[#candidates]
end

function CombatEngine.SetAllComboMontageRates(config, state, targetRate)
    local clampMax = math.max(1.0, tonumber(config.MaxFinisherSpeedClamp) or 5.0)
    for _, entry in pairs(state.SpellRegistry) do
        local montage = entry.montageObj
        if montage and montage:IsValid() then
            if entry.isSmash and config.KeepGroundSmashAnchored then
                pcall(function() montage.RateScale = math.min(targetRate, clampMax) end)
            else
                pcall(function() montage.RateScale = targetRate end)
            end
        end
    end
end

function CombatEngine.IsNotifyClampedEntry(entry)
    if not entry then return false end
    local sName = (entry.shortName or ""):lower()
    local mName = (entry.montageName or ""):lower()
    return entry.isSmash
        or sName:find("slam") ~= nil
        or sName:find("smash") ~= nil
        or sName:find("meteor") ~= nil
        or mName:find("meteor") ~= nil
        or mName:find("slam") ~= nil
end


function CombatEngine.GetActiveMontageObj(pawn)
    local activeMontage = nil
    if pawn and pawn:IsValid() then
        pcall(function()
            local mesh = pawn.Mesh
            if mesh and mesh:IsValid() then
                local animInst = mesh:GetAnimInstance()
                if animInst and animInst:IsValid() then
                    local m = animInst:GetCurrentActiveMontage()
                    if m and m:IsValid() then
                        activeMontage = m
                    end
                end
            end
        end)
    end
    return activeMontage
end

function CombatEngine.ApplyMontageRateToInstance(config, pawn, montageObj, targetRate, isAirSmash)
    local effectiveRate = targetRate
    if isAirSmash and config.KeepGroundSmashAnchored then
        local clampMax = math.max(1.0, tonumber(config.MaxFinisherSpeedClamp) or 5.0)
        effectiveRate = math.min(targetRate, clampMax)
    end
    if montageObj and montageObj:IsValid() then
        pcall(function() montageObj.RateScale = effectiveRate end)
    end
    if pawn and pawn:IsValid() then
        pcall(function()
            local mesh = pawn.Mesh
            if mesh and mesh:IsValid() then
                local animInst = mesh:GetAnimInstance()
                if animInst and animInst:IsValid() then
                    local activeMontage = animInst:GetCurrentActiveMontage()
                    if activeMontage and activeMontage:IsValid() then
                        activeMontage.RateScale = effectiveRate
                        pcall(function() animInst:Montage_SetPlayRate(activeMontage, effectiveRate) end)
                    end
                end
            end
        end)
    end
end

function CombatEngine.ApplyStageSpeedAndPriming(config, state, combatMagic, stage, stepInStage, pawn, debugLogFn)
    if not stage then return end
    local stepDesc = stage.steps[stepInStage] or stage.steps[1]
    local entry = ConfigManager.ResolveStepEntry(state, stage, stepDesc)
    local effectiveBaseSpeed = (entry and entry.customOverrideSpeed) or stage.speed
    local variedSpeed = RuleParser.ComputeVariedSpeed(effectiveBaseSpeed, config.BonusSpeedVariancePct)
    local isAirSmash = CombatEngine.IsNotifyClampedEntry(entry)

    state.ActiveStageTargetSpeed = variedSpeed
    state.ActiveStageIsAirSmash = isAirSmash
    state.StepInFlight = false
    state.InFlightSpellObj = nil

    if config.DebugMode then
        debugLogFn(string.format("Stage %d/%d Step %d/%d (speed=%.2fx, base=%.2fx) => %s",
            state.StageIndex, state.ActiveMacro and #state.ActiveMacro.stages or 0,
            stepInStage, #stage.steps, variedSpeed, tonumber(effectiveBaseSpeed) or 1.0,
            ConfigManager.DescribeStepDescriptor(state, stage, stepDesc)))
    end

    if entry and entry.montageObj and entry.montageObj:IsValid() then
        CombatEngine.ApplyMontageRateToInstance(config, pawn, entry.montageObj, variedSpeed, isAirSmash)
    end
    local targetChain = (entry and entry.isSpecialSpell) and nil or state.SpellChains[stage.elementLower]
    if targetChain then
        for idx, montage in pairs(targetChain.montages) do
            if montage and montage:IsValid() then
                local chainAirSmash = (idx == 3 and stage.elementLower:find("^air") ~= nil)
                CombatEngine.ApplyMontageRateToInstance(config, nil, montage, variedSpeed, chainAirSmash)
            end
        end
    end

    if combatMagic and combatMagic:IsValid() then
        -- Only prime LastChainedSpell when the step matches the player's currently equipped element;
        -- never leave a cross-element spell (e.g. Air) in LastChainedSpell where normal LMB attacks can inherit it!
        local equippedLower = (state.LastKnownEquippedElement or ""):lower():gsub("_wand$", ""):gsub("_hold$", "")
        local entryCatLower = (entry and entry.categoryTag or ""):lower():gsub("_wand$", ""):gsub("_hold$", "")
        if entry and entry.prevSpellObj and entry.prevSpellObj:IsValid() and equippedLower ~= "" and entryCatLower == equippedLower then
            pcall(function() combatMagic.LastChainedSpell = entry.prevSpellObj end)
            state.LastObservedChainedSpell = entry.prevSpellObj
        else
            pcall(function() combatMagic.LastChainedSpell = nil end)
            state.LastObservedChainedSpell = nil
        end
    end
end

function CombatEngine.ResetAllState(config, state, combatMagic, pawn, debugLogFn, reason)
    if not state then return end
    state.ActiveMacro = nil
    state.StageIndex = 1
    state.StepInStage = 1
    state.PendingAnchorReturn = false
    state.StepInFlight = false
    state.InFlightSpellObj = nil
    state.InFlightStartedTime = 0
    state.ActiveStageTargetSpeed = 1.0
    state.ActiveStageIsAirSmash = false
    state.SpecialPostPauseUntil = 0
    state.AnimPadUntil = 0
    state._AppliedPadForCurrentStep = false
    state._LastTriggeredSpellPtr = nil
    state._LastTriggeredSpellPtrTime = 0
    state.LastObservedChainedSpell = nil
    state.LastCastSpellData = nil

    if combatMagic and combatMagic:IsValid() then
        pcall(function() combatMagic.LastChainedSpell = nil end)
    end
    CustomSpells.StopForcedMontage(state, pawn)
    if not (state.ModifierHeld) and config then
        CombatEngine.SetAllComboMontageRates(config, state, 1.0)
    end
    if debugLogFn and reason then
        debugLogFn("Reset state (" .. tostring(reason) .. ")")
    end
end

function CombatEngine.RestoreAnchorElementAndReset(config, state, combatMagic, debugLogFn)
    local anchor = state.AnchorElement or state.LastKnownEquippedElement
    state.ActiveMacro = nil
    state.StageIndex = 1
    state.StepInStage = 1
    state.PendingAnchorReturn = false
    state.StepInFlight = false
    state.InFlightSpellObj = nil
    state.ActiveStageTargetSpeed = 1.0
    state.ActiveStageIsAirSmash = false
    state.LastObservedChainedSpell = nil
    state.LastCastSpellData = nil

    if combatMagic and combatMagic:IsValid() then
        pcall(function() combatMagic.LastChainedSpell = nil end)
    end
    CustomSpells.StopForcedMontage(state, pawn)
    if not state.ModifierHeld then
        CombatEngine.SetAllComboMontageRates(config, state, 1.0)
    end
    debugLogFn("Restored anchor category: " .. tostring(anchor or "None"))
end


local SPECIAL_ENERGY_PROPS = {
    "CurrentSpecialCharge", "SpecialCharge", "SpecialEnergy", "CurrentSpecialEnergy",
    "SpecialAttackCharge", "SpecialPoints", "CurrentSpecialPoints", "Adrenaline", "CurrentAdrenaline"
}
local MAX_SPECIAL_ENERGY_PROPS = {
    "MaxSpecialCharge", "MaxSpecialEnergy", "MaxSpecialPoints", "MaxAdrenaline"
}

local function FindSpecialEnergyTarget(pawn, combatMagic)
    local containers = {}
    if combatMagic and combatMagic:IsValid() then
        table.insert(containers, combatMagic)
    end
    if pawn and pawn:IsValid() then
        pcall(function()
            if pawn.PlayerActionPerformerComponent and pawn.PlayerActionPerformerComponent:IsValid() then
                table.insert(containers, pawn.PlayerActionPerformerComponent)
            end
        end)
        pcall(function()
            if pawn.AbilitySystemComponent and pawn.AbilitySystemComponent:IsValid() then
                table.insert(containers, pawn.AbilitySystemComponent)
            end
        end)
        table.insert(containers, pawn)
    end

    for _, obj in ipairs(containers) do
        for _, prop in ipairs(SPECIAL_ENERGY_PROPS) do
            local ok, val = pcall(function() return obj[prop] end)
            if ok and type(val) == "number" then
                local maxVal = 100.0
                for _, mProp in ipairs(MAX_SPECIAL_ENERGY_PROPS) do
                    local okM, mVal = pcall(function() return obj[mProp] end)
                    if okM and type(mVal) == "number" and mVal > 0 then
                        maxVal = mVal
                        break
                    end
                end
                return obj, prop, val, maxVal
            end
        end
    end
    return nil, nil, nil, 100.0
end

function CombatEngine.InjectSpecialEnergy(config, pawn, combatMagic, debugLogFn)
    if config and config.InjectSpecialBarOnSpecials == false then
        return false
    end
    local targetObj, propName, curVal, maxVal = FindSpecialEnergyTarget(pawn, combatMagic)
    if not targetObj or not propName then
        return false
    end
    local floorNeeded = tonumber(config and config.MinSpecialEnergyCost) or 25.0
    local injectAmt = tonumber(config and config.SpecialBarInjectAmount) or 100.0
    local desiredVal = math.min(maxVal, math.max(curVal + injectAmt, floorNeeded + injectAmt))
    if desiredVal > curVal then
        local ok = pcall(function() targetObj[propName] = desiredVal end)
        if ok and debugLogFn then
            debugLogFn(string.format("Injected special bar [%s.%s]: %.1f -> %.1f (max=%.1f)",
                SpellScanner.ExtractShortObjectName(SpellScanner.SafeGetName(targetObj)), propName, curVal, desiredVal, maxVal))
        end
        return ok
    end
    return true
end

local function CanTriggerSpecialWithGuards(config, pawn, combatMagic, entry, debugLogFn)
    if config and config.InjectSpecialBarOnSpecials ~= false then
        CombatEngine.InjectSpecialEnergy(config, pawn, combatMagic, debugLogFn)
    end
    if config and config.RequireSpecialEnergyForSpecials == true then
        local _, propName, curVal = FindSpecialEnergyTarget(pawn, combatMagic)
        local reqCost = tonumber(config.MinSpecialEnergyCost) or 25.0
        if curVal ~= nil and curVal < reqCost then
            if debugLogFn then
                debugLogFn(string.format("Blocked special [%s]: %s (%.1f) < required (%.1f)",
                    tostring(entry and entry.shortName), tostring(propName or "SpecialEnergy"), curVal, reqCost))
            end
            return false
        end
    end
    return true
end

local function TryTriggerSpecialAbility(pawn, spellObj, debugLogFn)
    if not pawn or not pawn:IsValid() or not spellObj or not spellObj:IsValid() then
        return false
    end
    local triggered = false
    pcall(function()
        local bpLib = StaticFindObject("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
        if bpLib and bpLib:IsValid() and bpLib.TriggerModularAbilityForPlayer then
            local ok = pcall(function() bpLib:TriggerModularAbilityForPlayer(pawn, spellObj) end)
            if ok then
                triggered = true
                if debugLogFn then debugLogFn("Triggered special via TriggerModularAbilityForPlayer") end
            end
        end
    end)
    return triggered
end

function CombatEngine.TriggerSpellEntryForPlayer(config, state, pawn, entry, debugLogFn, combatMagic)
    if not pawn or not pawn:IsValid() or not entry then
        return false
    end
    if not entry.suppressBaseSpell and (not entry.spellObj or not entry.spellObj:IsValid()) then
        return false
    end
    local now = os.clock()
    local spKey = tostring(entry.spellObj)
    local minGap = entry.isSpecialSpell and (tonumber(config and config.SpecialCastCooldownSec) or 1.50) or 0.35
    if state._LastTriggeredSpellPtr == spKey and (now - (state._LastTriggeredSpellPtrTime or 0)) < minGap then
        return false
    end

    if entry.isSpecialSpell then
        if not CanTriggerSpecialWithGuards(config, pawn, combatMagic, entry, debugLogFn) then
            return false
        end
        state._LastTriggeredSpellPtr = spKey
        state._LastTriggeredSpellPtrTime = now
        state._LastSpecialCastTime = now
    else
        state._LastTriggeredSpellPtr = spKey
        state._LastTriggeredSpellPtrTime = now
    end

    if entry.isSpecialSpell then
        local okSpec = TryTriggerSpecialAbility(pawn, entry.spellObj, debugLogFn)
        if okSpec then
            EquipmentRunes.ConsumeRunesForSpellEntry(config, state, pawn, entry, debugLogFn)
            if (entry.impactAoEName and entry.impactAoEName ~= "") or (entry.impactLightningName and entry.impactLightningName ~= "") or entry.impactDamageMin then
                CustomSpells.ArmProjectileImpactAoE(state, pawn, entry, SpellScanner.SafeGetName, SpellScanner.ExtractShortObjectName)
            else
                CustomSpells.TriggerCustomPresentation(pawn, entry, SpellScanner.SafeGetName)
            end
            return true
        end
    end

    local bpLib = StaticFindObject("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
    local anyTriggered = false
    if not entry.suppressBaseSpell and bpLib and bpLib:IsValid() and entry.spellObj and entry.spellObj:IsValid() then
        local function fireAbility()
            pcall(function()
                if pawn and pawn:IsValid() and bpLib and bpLib:IsValid() and entry.spellObj and entry.spellObj:IsValid() then
                    bpLib:TriggerModularAbilityForPlayer(pawn, entry.spellObj)
                end
            end)
        end
        if type(ExecuteInGameThread) == "function" then
            pcall(function() ExecuteInGameThread(fireAbility) end)
        else
            fireAbility()
        end
        anyTriggered = true
    elseif entry.suppressBaseSpell then
        anyTriggered = true
    end

    if entry.isCustomSpell and entry.montageObj then
        local rate = tonumber(entry.customOverrideSpeed) or tonumber(state.ActiveStageTargetSpeed) or 1.0
        if CustomSpells.PlayEntryMontageOnPawn(pawn, entry, rate, state) then
            anyTriggered = true
            if debugLogFn then
                debugLogFn("Played custom montage directly on pawn: " .. tostring(entry.montageName))
            end
        end
    end

    if anyTriggered then
        EquipmentRunes.ConsumeRunesForSpellEntry(config, state, pawn, entry, debugLogFn)
        if (entry.impactAoEName and entry.impactAoEName ~= "") or (entry.impactLightningName and entry.impactLightningName ~= "") or entry.impactDamageMin then
            CustomSpells.ArmProjectileImpactAoE(state, pawn, entry, SpellScanner.SafeGetName, SpellScanner.ExtractShortObjectName)
        else
            CustomSpells.TriggerCustomPresentation(pawn, entry, SpellScanner.SafeGetName)
        end
        return true
    end
    return false
end

function CombatEngine.IsModifierDown(config, pc)
    if not config.RequireModifierKey then return true end
    if not pc or not pc:IsValid() then return false end
    local mk = (config.ModifierKey or "RMB"):upper()
    local down = false
    pcall(function()
        if mk == "RMB" or mk == "BLOCK" or mk == "RIGHTMOUSE" then
            down = pc:IsInputKeyDown({ KeyName = FName("RightMouseButton") })
                or pc:IsInputKeyDown({ KeyName = FName("Gamepad_LeftTrigger") })
                or pc:IsInputKeyDown({ KeyName = FName("Gamepad_LeftShoulder") })
        elseif mk == "SHIFT" then
            down = pc:IsInputKeyDown({ KeyName = FName("LeftShift") }) or pc:IsInputKeyDown({ KeyName = FName("RightShift") })
        elseif mk == "ALT" then
            down = pc:IsInputKeyDown({ KeyName = FName("LeftAlt") }) or pc:IsInputKeyDown({ KeyName = FName("RightAlt") })
        elseif mk == "CTRL" then
            down = pc:IsInputKeyDown({ KeyName = FName("LeftControl") }) or pc:IsInputKeyDown({ KeyName = FName("RightControl") })
        elseif mk == "MOUSE4" then
            down = pc:IsInputKeyDown({ KeyName = FName("ThumbMouseButton") })
        elseif mk == "MOUSE5" then
            down = pc:IsInputKeyDown({ KeyName = FName("ThumbMouseButton2") })
        elseif mk == "MMB" then
            down = pc:IsInputKeyDown({ KeyName = FName("MiddleMouseButton") })
        else
            down = pc:IsInputKeyDown({ KeyName = FName(mk) })
        end
    end)
    return down
end

function CombatEngine.IsPrimaryAttackDown(pc)
    if not pc or not pc:IsValid() then return false end
    local down = false
    pcall(function()
        down = pc:IsInputKeyDown({ KeyName = FName("LeftMouseButton") })
            or pc:IsInputKeyDown({ KeyName = FName("Gamepad_RightTrigger") })
    end)
    return down
end

local function SpellBelongsToCategory(state, spellShortName, anchorCategory)
    if not spellShortName or spellShortName == "" or not anchorCategory or anchorCategory == "" then
        return false
    end
    local anchorBase = anchorCategory:lower():gsub("_wand$", ""):gsub("_hold$", "")
    local regEntry = state.SpellRegistry and state.SpellRegistry[spellShortName:lower()]
    if regEntry and regEntry.categoryTag then
        local catBase = regEntry.categoryTag:lower():gsub("_wand$", ""):gsub("_hold$", "")
        if catBase == anchorBase then return true end
    end
    local sLower = spellShortName:lower()
    if anchorBase == "fire" and (sLower:find("fire") or sLower:find("flame")) then return true end
    if anchorBase == "water" and (sLower:find("water") or sLower:find("ice")) then return true end
    if anchorBase == "air" and (sLower:find("air") or sLower:find("wind")) then return true end
    if anchorBase == "earth" and sLower:find("earth") then return true end
    return false
end


local ELEMENT_WEAPON_DEFAULTS = {
    fire = {
        staff = { cat = "fire",      spell = "DA_Spell_Primary_Fire_01" },
        wand  = { cat = "fire_wand", spell = "DA_Spell_Primary_Fire_Wand_01" }
    },
    earth = {
        staff = { cat = "earth",      spell = "DA_Spell_Primary_Earth_01" },
        wand  = { cat = "earth_wand", spell = "DA_Spell_Primary_Earth_Wand_01" }
    },
    air = {
        staff = { cat = "air",      spell = "DA_Spell_Primary_Air_01" },
        wand  = { cat = "air_wand", spell = "DA_Spell_Primary_Air_Wand_01" }
    },
    wind = {
        staff = { cat = "air",      spell = "DA_Spell_Primary_Air_01" },
        wand  = { cat = "air_wand", spell = "DA_Spell_Primary_Air_Wand_01" }
    },
    water = {
        staff = { cat = "water",      spell = "DA_Spell_Primary_Water_01" },
        wand  = { cat = "water_wand", spell = "DA_Spell_Primary_Water_Wand_01" }
    }
}

function CombatEngine.ResolveClosestElementSpellAndCategory(state, anchorCategory, weaponSuffix)
    if not anchorCategory or anchorCategory == "" then return nil, nil end
    local lower = anchorCategory:lower()
    local isWand = lower:find("_wand$") ~= nil or tostring(weaponSuffix or ""):lower():find("wand") ~= nil
    local baseElem = lower:gsub("_wand$", ""):gsub("_hold$", "")
    if baseElem == "wind" then baseElem = "air" end

    local mapEntry = ELEMENT_WEAPON_DEFAULTS[baseElem]
    if mapEntry then
        local mode = isWand and mapEntry.wand or mapEntry.staff
        if mode then
            local targetCat = mode.cat
            if isWand and state and state.SpellChains and not state.SpellChains[targetCat] then
                targetCat = baseElem
            end
            local spellName = mode.spell
            if state and state.SpellRegistry and not state.SpellRegistry[spellName:lower()] then
                local chain = state.SpellChains and state.SpellChains[targetCat]
                if chain and chain.stepNames and chain.stepNames[0] then
                    spellName = chain.stepNames[0]
                end
            end
            return targetCat, spellName
        end
    end

    local chain = state and state.SpellChains and state.SpellChains[lower]
    if chain and chain.stepNames and chain.stepNames[0] then
        return lower, chain.stepNames[0]
    end
    return lower, nil
end

function CombatEngine.RollAndEngageMacroForAnchor(config, state, pawn, combatMagic, anchor, logFn, debugLogFn, startingSpell)
    local freshAnchor = EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, state, debugLogFn) or anchor
    local mappedCat, mappedSpell = CombatEngine.ResolveClosestElementSpellAndCategory(
        state, freshAnchor, state.LastKnownWeaponSuffix)
    if mappedCat then
        freshAnchor = mappedCat
    end

    local detectedSpell = startingSpell or DetectActiveStartingSpell(pawn, combatMagic, state)
    -- Ignore detectedSpell if it belongs to a different element than the equipped/anchor element
    local startKey = nil
    if detectedSpell and SpellBelongsToCategory(state, detectedSpell, freshAnchor) then
        startKey = detectedSpell
    elseif mappedSpell then
        startKey = mappedSpell
    end

    local macro = CombatEngine.PickWeightedMacroForElement(state, freshAnchor, startKey)
    state.ActiveMacro = macro
    state.StageIndex = 1
    state.StepInStage = 1
    state.PendingAnchorReturn = false
    state.LastCastSpellData = nil

    if macro then
        logFn(string.format("Start [%s] (Anchor [%s]) -> Locked macro (%d stages): %s",
            tostring(startKey or freshAnchor or "None"), tostring(freshAnchor or "None"), #macro.stages, macro.raw))
        CombatEngine.ApplyStageSpeedAndPriming(config, state, combatMagic, macro.stages[1], 1, pawn, debugLogFn)
        local st1 = macro.stages[1]
        if st1 and st1.elementLower then
            local ch = state.SpellChains and state.SpellChains[st1.elementLower]
            if ch and ch.montages then
                local spd = tonumber(st1.speed) or 1.0
                for _, mObj in pairs(ch.montages) do
                    if mObj and mObj:IsValid() then
                        CombatEngine.ApplyMontageRateToInstance(config, pawn, mObj, spd, false)
                    end
                end
            end
        end
    else
        logFn(string.format("Start [%s] (Anchor [%s]) -> No matching rule for same starting spell in combo_rules.txt",
            tostring(startKey or freshAnchor or "None"), tostring(freshAnchor or "None")))
    end
end

function CombatEngine.EngageModifierAndRollMacro(config, state, pawn, combatMagic, logFn, debugLogFn)
    state.LastKnownEquippedElement = nil
    local anchor = EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, state, debugLogFn)
    local startSpell = DetectActiveStartingSpell(pawn, combatMagic, state)
    if startSpell and not SpellBelongsToCategory(state, startSpell, anchor) then
        startSpell = nil
        if combatMagic and combatMagic:IsValid() then
            pcall(function() combatMagic.LastChainedSpell = nil end)
        end
    end
    state.AnchorElement = anchor
    CombatEngine.RollAndEngageMacroForAnchor(config, state, pawn, combatMagic, anchor, logFn, debugLogFn, startSpell)
end

function CombatEngine.ReleaseModifierAndRevert(config, state, pawn, combatMagic, logFn, debugLogFn)
    local originalAnchor = state.AnchorElement
    local relPawn = nil
    pcall(function()
        if combatMagic and combatMagic:IsValid() then relPawn = combatMagic:GetOwner() end
        if not relPawn or not relPawn:IsValid() then
            local pc = FindFirstOf("DominionPlayerController") or FindFirstOf("PlayerController")
            if pc and pc:IsValid() then relPawn = pc.Pawn end
        end
    end)
    CustomSpells.StopForcedMontage(state, relPawn)
    CombatEngine.RestoreAnchorElementAndReset(config, state, combatMagic, debugLogFn)
    CombatEngine.SetAllComboMontageRates(config, state, 1.0)
    state.PendingAnchorReturn = false
    local currentEquipped = EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, state, debugLogFn) or originalAnchor
    state.AnchorElement = currentEquipped
    if combatMagic and combatMagic:IsValid() then
        pcall(function() combatMagic.LastChainedSpell = nil end)
    end
    logFn("Modifier RELEASED -> Cleanly reset combo & restored equipped element [" .. tostring(currentEquipped or "None") .. "]")
end

function CombatEngine.AdvanceLockedMacro(config, state, pawn, combatMagic, debugLogFn)
    local macro = state.ActiveMacro
    if not macro or not macro.stages or #macro.stages == 0 then return end

    local curStage = macro.stages[state.StageIndex]
    if not curStage then
        CombatEngine.RestoreAnchorElementAndReset(config, state, combatMagic, debugLogFn)
        return
    end

    if state.StepInStage < #curStage.steps then
        state.StepInStage = state.StepInStage + 1
        CombatEngine.ApplyStageSpeedAndPriming(config, state, combatMagic, curStage, state.StepInStage, pawn, debugLogFn)
    elseif state.StageIndex < #macro.stages then
        state.StageIndex = state.StageIndex + 1
        state.StepInStage = 1
        CombatEngine.ApplyStageSpeedAndPriming(config, state, combatMagic, macro.stages[state.StageIndex], 1, pawn, debugLogFn)
    else
        local lockedAnchor = EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, state, debugLogFn)
            or state.AnchorElement or state.LastKnownEquippedElement
        state.AnchorElement = lockedAnchor
        state.ActiveMacro = nil
        state.StageIndex = 1
        state.StepInStage = 1
        state.PendingAnchorReturn = state.ModifierHeld and true or false
        state.StepInFlight = false
        state.InFlightSpellObj = nil
        state.LastObservedChainedSpell = nil
        state.LastCastSpellData = nil

        if combatMagic and combatMagic:IsValid() then
            pcall(function() combatMagic.LastChainedSpell = nil end)
        end

        CombatEngine.SetAllComboMontageRates(config, state, 1.0)
        debugLogFn("Macro finished -> Reset cleanly to [" .. tostring(lockedAnchor or "None") .. "]")
    end
end

return CombatEngine
