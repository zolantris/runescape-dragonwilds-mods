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
    if spellName and state.DiscoveredLookup then
        local mapped = state.DiscoveredLookup[spellName:lower()]
        if mapped then return mapped end
    end
    return spellName
end

function CombatEngine.PickWeightedMacroForElement(state, anchorCategory, activeStartingSpell)
    if #state.ParsedMacros == 0 then return nil end

    local anchorLower = (anchorCategory and anchorCategory ~= "") and anchorCategory:lower() or nil
    local anchorBase = anchorLower and anchorLower:gsub("_wand$", ""):gsub("_hold$", "") or nil
    local startSpellLower = (activeStartingSpell and activeStartingSpell ~= "") and activeStartingSpell:lower() or nil

    -- Determine the required starting element/category:
    -- Equipped/anchor element is authoritative unless no anchor exists and a specific spell/custom-spell is starting.
    local requiredCat = anchorLower
    if not requiredCat and startSpellLower then
        requiredCat = startSpellLower
    end
    if not requiredCat then return nil end

    local requiredBase = requiredCat:gsub("_wand$", ""):gsub("_hold$", "")
    local candidates = {}

    -- Priority 1: If a specific starting spell token is active, check rules whose Stage 1 starts with that exact spell token
    -- AND matches the active element/category (when an element prefix is specified).
    if startSpellLower then
        for _, m in ipairs(state.ParsedMacros) do
            local mCat = GetMacroStartCategory(m)
            local mSpell = GetMacroStartSpellToken(m)
            local catMatches = (not anchorLower) or (mCat == anchorLower) or (mCat == anchorBase)
            if catMatches and mSpell and mSpell == startSpellLower then
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
    local targetChain = state.SpellChains[stage.elementLower]
    if targetChain then
        for idx, montage in pairs(targetChain.montages) do
            if montage and montage:IsValid() then
                local chainAirSmash = (idx == 3 and stage.elementLower:find("^air") ~= nil)
                CombatEngine.ApplyMontageRateToInstance(config, nil, montage, variedSpeed, chainAirSmash)
            end
        end
    end

    if combatMagic and combatMagic:IsValid() then
        if entry and entry.prevSpellObj and entry.prevSpellObj:IsValid() then
            pcall(function() combatMagic.LastChainedSpell = entry.prevSpellObj end)
            state.LastObservedChainedSpell = entry.prevSpellObj
        else
            pcall(function() combatMagic.LastChainedSpell = nil end)
            state.LastObservedChainedSpell = nil
        end
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
    if not state.ModifierHeld then
        CombatEngine.SetAllComboMontageRates(config, state, 1.0)
    end
    debugLogFn("Restored anchor category: " .. tostring(anchor or "None"))
end

function CombatEngine.TriggerSpellEntryForPlayer(config, state, pawn, entry, debugLogFn)
    if not pawn or not pawn:IsValid() or not entry or not entry.spellObj or not entry.spellObj:IsValid() then
        return false
    end
    local bpLib = StaticFindObject("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
    if bpLib and bpLib:IsValid() then
        local ok = pcall(function()
            bpLib:TriggerModularAbilityForPlayer(pawn, entry.spellObj)
        end)
        if ok then
            EquipmentRunes.ConsumeRunesForSpellEntry(config, state, pawn, entry, debugLogFn)
            CustomSpells.TriggerCustomPresentation(pawn, entry, SpellScanner.SafeGetName)
            return true
        end
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

function CombatEngine.RollAndEngageMacroForAnchor(config, state, pawn, combatMagic, anchor, logFn, debugLogFn, startingSpell)
    local startKey = startingSpell or DetectActiveStartingSpell(pawn, combatMagic, state)
    local macro = CombatEngine.PickWeightedMacroForElement(state, anchor, startKey)
    state.ActiveMacro = macro
    state.StageIndex = 1
    state.StepInStage = 1
    state.PendingAnchorReturn = false
    state.LastCastSpellData = nil

    if macro then
        logFn(string.format("Start [%s] (Anchor [%s]) -> Locked macro (%d stages): %s",
            tostring(startKey or anchor or "None"), tostring(anchor or "None"), #macro.stages, macro.raw))
        CombatEngine.ApplyStageSpeedAndPriming(config, state, combatMagic, macro.stages[1], 1, pawn, debugLogFn)
    else
        logFn(string.format("Start [%s] (Anchor [%s]) -> No matching rule for same starting spell in combo_rules.txt",
            tostring(startKey or anchor or "None"), tostring(anchor or "None")))
    end
end

function CombatEngine.EngageModifierAndRollMacro(config, state, pawn, combatMagic, logFn, debugLogFn)
    local anchor = EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, state, debugLogFn)
    local startSpell = DetectActiveStartingSpell(pawn, combatMagic, state)
    state.AnchorElement = anchor
    CombatEngine.RollAndEngageMacroForAnchor(config, state, pawn, combatMagic, anchor, logFn, debugLogFn, startSpell)
end

function CombatEngine.ReleaseModifierAndRevert(config, state, pawn, combatMagic, logFn, debugLogFn)
    local originalAnchor = state.AnchorElement
    local hadSwappedStage = (state.ActiveMacro ~= nil and state.StageIndex > 1)
    CombatEngine.RestoreAnchorElementAndReset(config, state, combatMagic, debugLogFn)
    CombatEngine.SetAllComboMontageRates(config, state, 1.0)
    if hadSwappedStage and originalAnchor then
        state.AnchorElement = originalAnchor
        state.PendingAnchorReturn = true
        logFn("Modifier RELEASED mid-swap -> Returning to original spell [" .. tostring(originalAnchor) .. "] & 100% base speed")
    else
        local currentEquipped = EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, state, debugLogFn) or originalAnchor
        state.AnchorElement = currentEquipped
        logFn("Modifier RELEASED -> Restored anchor [" .. tostring(currentEquipped or "None") .. "] & 100% base speed")
    end
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
        local lockedAnchor = state.AnchorElement or state.LastKnownEquippedElement
        state.AnchorElement = lockedAnchor
        state.ActiveMacro = nil
        state.StageIndex = 1
        state.StepInStage = 1
        state.PendingAnchorReturn = true
        state.StepInFlight = false
        state.InFlightSpellObj = nil
        state.LastObservedChainedSpell = nil
        state.LastCastSpellData = nil

        if combatMagic and combatMagic:IsValid() then
            pcall(function() combatMagic.LastChainedSpell = nil end)
        end

        CombatEngine.SetAllComboMontageRates(config, state, 1.0)
        debugLogFn("Macro finished -> Returning to original anchor [" .. tostring(lockedAnchor or "None") .. "] before next roll")
    end
end

return CombatEngine
