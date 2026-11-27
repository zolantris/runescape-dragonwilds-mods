-- ArcaneWilds - Runtime EnhancedInput Quick-Cast Key Blocker
-- Dynamically constructs a high-priority UInputMappingContext + UInputAction via StaticConstructObject
-- (no IoStore pak / LoadAsset dependency) to suppress game hotbar, inventory, abilities menu, and
-- controller face-button actions while holding Block (or any configured Quick-Cast modifier).

local InputBlocker = {}

local BLOCKER_PRIORITY = 100000

local ADD_CONTEXT_OPTS = {
    bIgnoreAllPressedKeysUntilRelease = false,
    bForceImmediately = true,
    bNotifyUserSettings = false
}

local REMOVE_CONTEXT_OPTS = {
    bIgnoreAllPressedKeysUntilRelease = true,
    bForceImmediately = true,
    bNotifyUserSettings = false
}

local function IsValidUObject(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

local function IsDefaultCDO(obj)
    if not IsValidUObject(obj) then return true end
    local ok, fullName = pcall(function() return obj:GetFullName() end)
    if not ok or not fullName then return false end
    return tostring(fullName):find("Default__", 1, true) ~= nil
end

local function GetObjectIdentity(obj)
    if not IsValidUObject(obj) then return nil end
    local okAddr, addr = pcall(function() return obj:GetAddress() end)
    if okAddr and addr ~= nil then return addr end
    local okName, name = pcall(function() return obj:GetFullName() end)
    if okName and name ~= nil then return tostring(name) end
    return tostring(obj)
end

local function FindLiveInstance(className)
    if type(FindAllOf) == "function" then
        local ok, all = pcall(FindAllOf, className)
        if ok and all then
            for _, inst in ipairs(all) do
                if IsValidUObject(inst) and not IsDefaultCDO(inst) then
                    return inst
                end
            end
        end
    end
    if type(FindFirstOf) == "function" then
        local ok, first = pcall(FindFirstOf, className)
        if ok and IsValidUObject(first) and not IsDefaultCDO(first) then
            return first
        end
    end
    return nil
end

local function ValidateMapKeySignature()
    if type(StaticFindObject) ~= "function" then return true end
    local ok, fn = pcall(StaticFindObject, "/Script/EnhancedInput.InputMappingContext:MapKey")
    if not ok or not IsValidUObject(fn) then
        -- Allow direct attempt if reflection path is unavailable in mock/runtime
        return true
    end
    if type(fn.ForEachProperty) ~= "function" then
        return true
    end
    local names = {}
    local okIter = pcall(function()
        fn:ForEachProperty(function(p)
            local okN, n = pcall(function() return p:GetFName():ToString() end)
            if okN and n then
                names[#names + 1] = tostring(n)
            end
        end)
    end)
    if not okIter or #names < 2 then
        return true
    end
    return (names[1] == "Action" and names[2] == "ToKey")
end

local function ConfigureBlockerObjects(imc, ia)
    pcall(function() ia.bConsumeInput = true end)
    pcall(function() ia.bConsumesActionAndAxisMappings = true end)
    pcall(function() ia.bReserveAllMappings = true end)
    pcall(function() ia.ValueType = 0 end) -- EInputActionValueType::Boolean
    pcall(function() imc.InputModeFilterOptions = 2 end) -- EMappingContextInputModeFilterOptions::DoNotFilter
    pcall(function() imc.RegistrationTrackingMode = 0 end) -- EMappingContextRegistrationTrackingMode::Untracked
end

local function EnsureBlockerObjects(state, logFn, debugLogFn)
    if IsValidUObject(state._QuickCastIMC) and IsValidUObject(state._QuickCastIA) then
        return state._QuickCastIMC, state._QuickCastIA
    end

    -- Clear stale cached state when rebuilding (e.g. after world / level transition)
    state._QuickCastIMC = nil
    state._QuickCastIA = nil
    state._QuickCastBlockerSig = nil
    state._QuickCastInputBlocked = false
    state._QuickCastLastInputModeId = nil

    if state._QuickCastBlockerBroken then
        return nil, nil
    end

    -- Primary path: construct UInputMappingContext + UInputAction natively on GameInstance via StaticConstructObject
    if type(StaticConstructObject) == "function" and type(StaticFindObject) == "function" then
        if not ValidateMapKeySignature() then
            state._QuickCastBlockerBroken = "MapKey signature mismatch"
            if logFn then
                logFn("[WARN] Quick-Cast input blocker disabled: EnhancedInput MapKey signature mismatch")
            end
            return nil, nil
        end

        local imcClass, iaClass = nil, nil
        pcall(function()
            imcClass = StaticFindObject("/Script/EnhancedInput.InputMappingContext")
            iaClass  = StaticFindObject("/Script/EnhancedInput.InputAction")
        end)
        local outer = FindLiveInstance("GameInstance")
        if IsValidUObject(imcClass) and IsValidUObject(iaClass) and IsValidUObject(outer) then
            local imc, ia = nil, nil
            local okImc, errImc = pcall(function() imc = StaticConstructObject(imcClass, outer) end)
            local okIa, errIa   = pcall(function() ia  = StaticConstructObject(iaClass, outer) end)
            if okImc and okIa and IsValidUObject(imc) and IsValidUObject(ia) then
                ConfigureBlockerObjects(imc, ia)
                state._QuickCastIMC = imc
                state._QuickCastIA = ia
                state._QuickCastBlockerSource = "StaticConstructObject"
                if debugLogFn then
                    debugLogFn("Constructed EnhancedInput Quick-Cast blocker IMC & IA dynamically on GameInstance")
                end
                return imc, ia
            elseif not state._LoggedQuickCastBuildError then
                state._LoggedQuickCastBuildError = true
                if logFn then
                    logFn(string.format("[WARN] Quick-Cast blocker StaticConstructObject failed (imc=%s, ia=%s)",
                        tostring(errImc or okImc), tostring(errIa or okIa)))
                end
            end
        end
    end

    -- Secondary fallback: already-loaded pak assets if present
    local imc, ia = nil, nil
    if type(StaticFindObject) == "function" then
        pcall(function()
            imc = StaticFindObject("/Game/Mods/ArcaneWilds/IMC_ArcaneWildsQuickCastBlock.IMC_ArcaneWildsQuickCastBlock")
            ia  = StaticFindObject("/Game/Mods/ArcaneWilds/IA_ArcaneWildsKeyBlocker.IA_ArcaneWildsKeyBlocker")
        end)
    end
    if IsValidUObject(imc) and IsValidUObject(ia) then
        ConfigureBlockerObjects(imc, ia)
        state._QuickCastIMC = imc
        state._QuickCastIA = ia
        state._QuickCastBlockerSource = "PakAsset"
        if debugLogFn then
            debugLogFn("Loaded EnhancedInput Quick-Cast blocker IMC & IA from existing assets")
        end
        return imc, ia
    end

    return nil, nil
end

local function FindLiveEnhancedInputSubsystem(state)
    if IsValidUObject(state._QuickCastSub) and not IsDefaultCDO(state._QuickCastSub) then
        return state._QuickCastSub
    end
    local sub = FindLiveInstance("EnhancedInputLocalPlayerSubsystem")
    if IsValidUObject(sub) then
        state._QuickCastSub = sub
        return sub
    end
    state._QuickCastSub = nil
    return nil
end

local function AddModifierExclusionKeys(config, modName, normalizeKeyFn, excluded)
    local m = tostring(modName or "NONE"):upper()
    if m == "BLOCK" or m == "RMB" or m == "MODIFIER" then
        local mk = tostring(config and config.ModifierKey or "RMB"):upper()
        if mk == "RMB" or mk == "BLOCK" or mk == "RIGHTMOUSE" then
            excluded["RightMouseButton"] = true
            excluded["Gamepad_LeftTrigger"] = true
            excluded["Gamepad_LeftShoulder"] = true
        elseif mk == "SHIFT" then
            excluded["LeftShift"] = true
            excluded["RightShift"] = true
        elseif mk == "ALT" then
            excluded["LeftAlt"] = true
            excluded["RightAlt"] = true
        elseif mk == "CTRL" or mk == "CONTROL" then
            excluded["LeftControl"] = true
            excluded["RightControl"] = true
        elseif mk == "MOUSE4" then
            excluded["ThumbMouseButton"] = true
        elseif mk == "MOUSE5" then
            excluded["ThumbMouseButton2"] = true
        elseif mk == "MMB" then
            excluded["MiddleMouseButton"] = true
        else
            local normMk = normalizeKeyFn and normalizeKeyFn(mk) or mk
            if normMk ~= "" then excluded[normMk] = true end
        end
    elseif m == "SHIFT" then
        excluded["LeftShift"] = true
        excluded["RightShift"] = true
    elseif m == "ALT" then
        excluded["LeftAlt"] = true
        excluded["RightAlt"] = true
    elseif m == "CTRL" or m == "CONTROL" then
        excluded["LeftControl"] = true
        excluded["RightControl"] = true
    elseif m ~= "NONE" and m ~= "" then
        local norm = normalizeKeyFn and normalizeKeyFn(m) or m
        if norm ~= "" then excluded[norm] = true end
    end
end

function InputBlocker.CollectActiveSuppressedKeys(config, pc, bindings, parseKeyListFn, isModifierSatisfiedFn, normalizeKeyFn)
    if not config or config.Enabled == false or config.EnableQuickCastHotkeys == false or config.QuickCastSuppressGameActions == false then
        return {}
    end
    if not pc or not IsValidUObject(pc) or not bindings or #bindings == 0 then
        return {}
    end

    local activeKeys = {}
    local seen = {}
    local excludedModKeys = {}

    -- First collect all active modifier keys so we never suppress the modifier key itself
    for _, binding in ipairs(bindings) do
        local effMod = tostring(binding.modifier or "NONE"):upper()
        if config.QuickCastRequireModifier == false and (effMod == "BLOCK" or effMod == "RMB" or effMod == "MODIFIER") then
            effMod = "NONE"
        end
        if effMod ~= "NONE" and effMod ~= "" and isModifierSatisfiedFn(pc, effMod) then
            AddModifierExclusionKeys(config, effMod, normalizeKeyFn, excludedModKeys)
        end
    end

    for _, binding in ipairs(bindings) do
        local targetStr = tostring(binding.target or ""):gsub("^%s*(.-)%s*$", "%1")
        if targetStr ~= "" then
            local effMod = tostring(binding.modifier or "NONE"):upper()
            if config.QuickCastRequireModifier == false and (effMod == "BLOCK" or effMod == "RMB" or effMod == "MODIFIER") then
                effMod = "NONE"
            end
            if effMod ~= "NONE" and effMod ~= "" and isModifierSatisfiedFn(pc, effMod) then
                for _, k in ipairs(parseKeyListFn(binding.keysRaw)) do
                    if k ~= "" and not excludedModKeys[k] and not seen[k] then
                        seen[k] = true
                        table.insert(activeKeys, k)
                    end
                end
            end
        end
    end

    return activeKeys
end

local function MapKeyIntoContext(imc, ia, keyName)
    local ok, err = pcall(function()
        imc:MapKey(ia, { KeyName = FName(keyName) })
    end)
    if ok then
        return true, nil
    end

    -- Fallback to cooked Blueprint helper if present
    local bridgeCDO = nil
    if type(StaticFindObject) == "function" then
        pcall(function()
            bridgeCDO = StaticFindObject("/Game/Mods/ArcaneWilds/BFL_ArcaneWildsDamage.Default__BFL_ArcaneWildsDamage_C")
        end)
    end
    if IsValidUObject(bridgeCDO) then
        local okB, errB = pcall(function()
            bridgeCDO:MapKeySafe(imc, ia, { KeyName = FName(keyName) })
        end)
        if okB then
            return true, nil
        end
        return false, errB or err
    end
    return false, err
end

local function SyncContextKeyMappings(state, imc, ia, keys, logFn, debugLogFn)
    local sig = table.concat(keys, ",")
    if state._QuickCastBlockerSig == sig then
        return true, false
    end

    local okUnmap, errUnmap = pcall(function()
        imc:UnmapAll()
    end)
    if not okUnmap then
        if not state._LoggedQuickCastMapError and logFn then
            state._LoggedQuickCastMapError = true
            logFn("[WARN] Quick-Cast blocker UnmapAll failed: " .. tostring(errUnmap))
        end
        return false, false
    end

    local mappedCount = 0
    local firstErr = nil
    for _, k in ipairs(keys) do
        local okMap, errMap = MapKeyIntoContext(imc, ia, k)
        if okMap then
            mappedCount = mappedCount + 1
        elseif not firstErr then
            firstErr = tostring(k) .. ": " .. tostring(errMap)
        end
    end

    if mappedCount == 0 and #keys > 0 then
        if not state._LoggedQuickCastMapError and logFn then
            state._LoggedQuickCastMapError = true
            logFn("[WARN] Quick-Cast blocker failed to map any keys (" .. tostring(firstErr) .. ")")
        end
        return false, false
    end

    state._QuickCastBlockerSig = sig
    state._LoggedQuickCastMapError = false
    if debugLogFn then
        debugLogFn(string.format("Synced Quick-Cast blocker keys (%d): %s", mappedCount, sig))
    end
    return true, true
end

local function CallAddMappingContext(sub, imc)
    local ok, err = pcall(function()
        sub:AddMappingContext(imc, BLOCKER_PRIORITY, ADD_CONTEXT_OPTS)
    end)
    if ok then return true, nil end
    local okFallback, errFallback = pcall(function()
        sub:AddMappingContext(imc, BLOCKER_PRIORITY, {})
    end)
    if okFallback then return true, nil end
    return false, tostring(err) .. " | fallback: " .. tostring(errFallback)
end

local function CallRemoveMappingContext(sub, imc)
    local ok, err = pcall(function()
        sub:RemoveMappingContext(imc, REMOVE_CONTEXT_OPTS)
    end)
    if ok then return true, nil end
    local okFallback, errFallback = pcall(function()
        sub:RemoveMappingContext(imc, {})
    end)
    if okFallback then return true, nil end
    return false, tostring(err) .. " | fallback: " .. tostring(errFallback)
end

local function IsBlockerStillRegisteredOnSubsystem(sub, imc)
    if not IsValidUObject(sub) or not IsValidUObject(imc) then
        return false
    end
    local ok, hasCtx = pcall(function()
        local outPrio = {}
        return sub:HasMappingContext(imc, outPrio)
    end)
    if ok and type(hasCtx) == "boolean" then
        return hasCtx
    end
    -- If HasMappingContext is unavailable or signature differs, assume registered and rely on input-mode tracking
    return true
end

local function GetCurrentInputModeIdentity(pc)
    if not IsValidUObject(pc) then return nil end
    local mode = nil
    pcall(function() mode = pc.CurrentInputMode end)
    return GetObjectIdentity(mode)
end

function InputBlocker.Clear(state, logFn, debugLogFn)
    if not state then return end
    local wasBlocked = (state._QuickCastInputBlocked == true)
    state._QuickCastInputBlocked = false
    state._QuickCastLastInputModeId = nil

    if not wasBlocked then return end

    local imc = state._QuickCastIMC
    local sub = FindLiveEnhancedInputSubsystem(state)
    if IsValidUObject(sub) and IsValidUObject(imc) then
        local ok, err = CallRemoveMappingContext(sub, imc)
        if ok then
            if debugLogFn then
                debugLogFn("Quick-Cast input blocker OFF (game hotbar & menu shortcuts restored)")
            end
        elseif logFn then
            logFn("[WARN] Quick-Cast blocker RemoveMappingContext failed: " .. tostring(err))
        end
    end
end

function InputBlocker.Sync(config, state, pc, bindings, parseKeyListFn, isModifierSatisfiedFn, normalizeKeyFn, logFn, debugLogFn)
    local keys = InputBlocker.CollectActiveSuppressedKeys(
        config, pc, bindings, parseKeyListFn, isModifierSatisfiedFn, normalizeKeyFn)

    if #keys == 0 then
        InputBlocker.Clear(state, logFn, debugLogFn)
        return false
    end

    local imc, ia = EnsureBlockerObjects(state, logFn, debugLogFn)
    if not imc or not ia then
        state._QuickCastInputBlocked = false
        return false
    end

    local sub = FindLiveEnhancedInputSubsystem(state)
    if not sub then
        state._QuickCastInputBlocked = false
        return false
    end

    local mappedOk, keysChanged = SyncContextKeyMappings(state, imc, ia, keys, logFn, debugLogFn)
    if not mappedOk then
        InputBlocker.Clear(state, logFn, debugLogFn)
        return false
    end

    local curInputModeId = GetCurrentInputModeIdentity(pc)
    local modeChanged = (state._QuickCastInputBlocked == true)
        and (curInputModeId ~= nil)
        and (state._QuickCastLastInputModeId ~= curInputModeId)
    local droppedByGame = (state._QuickCastInputBlocked == true)
        and (not IsBlockerStillRegisteredOnSubsystem(sub, imc))

    local needsApply = (state._QuickCastInputBlocked ~= true) or keysChanged or modeChanged or droppedByGame
    if not needsApply then
        return true
    end

    local okAdd, errAdd = CallAddMappingContext(sub, imc)
    if okAdd then
        local wasOff = (state._QuickCastInputBlocked ~= true)
        state._QuickCastInputBlocked = true
        state._QuickCastLastInputModeId = curInputModeId
        state._LoggedQuickCastApplyError = false
        if debugLogFn then
            if wasOff then
                debugLogFn(string.format("Quick-Cast input blocker ON (Priority %d | Keys: %s)",
                    BLOCKER_PRIORITY, tostring(state._QuickCastBlockerSig or "")))
            elseif droppedByGame or modeChanged then
                debugLogFn(string.format("Quick-Cast input blocker RE-APPLIED after input mode/mapping change (Keys: %s)",
                    tostring(state._QuickCastBlockerSig or "")))
            end
        end
        return true
    else
        state._QuickCastInputBlocked = false
        if not state._LoggedQuickCastApplyError and logFn then
            state._LoggedQuickCastApplyError = true
            logFn("[WARN] Quick-Cast blocker AddMappingContext failed: " .. tostring(errAdd))
        end
        return false
    end
end

function InputBlocker.GetDebugStatus(state)
    return string.format("BlockerActive=%s | Source=%s | SubValid=%s | Keys=[%s] | Broken=%s",
        tostring(state and state._QuickCastInputBlocked == true),
        tostring(state and state._QuickCastBlockerSource or "None"),
        tostring(state and IsValidUObject(state._QuickCastSub) or false),
        tostring(state and state._QuickCastBlockerSig or ""),
        tostring(state and state._QuickCastBlockerBroken or "false"))
end

return InputBlocker
