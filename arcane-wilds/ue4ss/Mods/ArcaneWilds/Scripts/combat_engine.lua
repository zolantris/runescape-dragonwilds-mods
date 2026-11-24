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

local function TryTriggerSpecialAbility(pawn, spellObj, debugLogFn)
    local triggered = false

    -- 1. Try PlayerCombatMagicComponent special/spell activation methods if available
    pcall(function()
        local cm = pawn.PlayerCombatMagicComponent
        if cm and cm:IsValid() then
            local cmMethods = {
                "Server_ActivateSpecialSpell",
                "ActivateSpecialSpell",
                "Server_CastSpell",
                "CastSpell",
                "TriggerSpell",
                "Server_TriggerSpell"
            }
            for _, mName in ipairs(cmMethods) do
                if not triggered and cm[mName] then
                    local ok = pcall(function() cm[mName](cm, spellObj) end)
                    if ok then
                        triggered = true
                        if debugLogFn then debugLogFn("Triggered special via CombatMagic:" .. mName) end
                    end
                end
            end
        end
    end)

    -- 2. Try DominionRuntimeBlueprintLibrary modular ability trigger (bypasses weapon-slot check for DominionSpellData)
    if not triggered then
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
    end

    return triggered
end

function CombatEngine.TriggerSpellEntryForPlayer(config, state, pawn, entry, debugLogFn)
    if not pawn or not pawn:IsValid() or not entry or not entry.spellObj or not entry.spellObj:IsValid() then
        return false
    end

    if entry.isSpecialSpell then
        local okSpec = TryTriggerSpecialAbility(pawn, entry.spellObj, debugLogFn)
        if okSpec then
            EquipmentRunes.ConsumeRunesForSpellEntry(config, state, pawn, entry, debugLogFn)
            CustomSpells.TriggerCustomPresentation(pawn, entry, SpellScanner.SafeGetName)
            return true
        end
    end

    local bpLib = StaticFindObject("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
    if bpLib and bpLib:IsValid() then
        local ok = pcall(function()
            bpLib:TriggerModularAbilityForPlayer(pawn, entry.spellObj)
        end)
        if ok then
            EquipmentRunes.ConsumeRunesForSpellEntry(config, state, pawn, entry, debugLogFn)
            if entry.impactAoEName and entry.impactAoEName ~= "" then
                CustomSpells.ArmProjectileImpactAoE(state, pawn, entry, SpellScanner.SafeGetName, SpellScanner.ExtractShortObjectName)
            else
                CustomSpells.TriggerCustomPresentation(pawn, entry, SpellScanner.SafeGetName)
            end
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

function CombatEngine.RollAndEngageMacroForAnchor(config, state, pawn, combatMagic, anchor, logFn, debugLogFn, startingSpell)
    local freshAnchor = EquipmentRunes.DetectEquippedCategory(pawn, combatMagic, state, debugLogFn) or anchor
    local detectedSpell = startingSpell or DetectActiveStartingSpell(pawn, combatMagic, state)
    -- Ignore detectedSpell if it belongs to a different element than the equipped/anchor element
    local startKey = nil
    if detectedSpell and SpellBelongsToCategory(state, detectedSpell, freshAnchor) then
        startKey = detectedSpell
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
    else
        logFn(string.format("Start [%s] (Anchor [%s]) -> No matching rule for same starting spell in combo_rules.txt",
            tostring(startKey or freshAnchor or "None"), tostring(freshAnchor or "None")))
    end
end

function CombatEngine.EngageModifierAndRollMacro(config, state, pawn, combatMagic, logFn, debugLogFn)
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
