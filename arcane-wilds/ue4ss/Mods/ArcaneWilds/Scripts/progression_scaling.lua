-- ArcaneWilds - Progression (Skill Level Gating), Locked-Cast Notifications & Staff Damage Scaling
-- Uses native Dominion APIs:
--   USkillComponent (GetSkillLevel, CalculateDamageModifier)
--   UHeldEquipmentData / UEquipmentData / UItemData (Tier, BasePowerLevel, DamageMultiplier, AdditionalDamageMultiplier)
--   UDominionAttributesComponent (DamageMultiplierMagic, DamageModifierWeaponTypeStaff, Elemental Outgoing)
--   UNotificationsSubsystem (DispatchTextNotification / DispatchBasicTutorialNotification)

local EquipmentRunes = require("equipment_runes")

local ProgressionScaling = {}

-- ESkill (UHTHeaderDump/Dominion/Public/ESkill.h)
local ESKILL_NAME_TO_ENUM = {
    agility      = 1,
    artisan      = 2,
    attack       = 3,
    construction = 4,
    cooking      = 5,
    defence      = 6,
    defense      = 6,
    herblore     = 7,
    magic        = 8,
    mining       = 9,
    ranged       = 10,
    runecrafting = 11,
    thieving     = 12,
    woodcutting  = 13,
    farming      = 14,
    utility      = 15,
    fishing      = 16
}

local ESKILL_ENUM_TO_DISPLAY = {
    [1]  = "Agility",
    [2]  = "Artisan",
    [3]  = "Attack",
    [4]  = "Construction",
    [5]  = "Cooking",
    [6]  = "Defence",
    [7]  = "Herblore",
    [8]  = "Magic",
    [9]  = "Mining",
    [10] = "Ranged",
    [11] = "Runecrafting",
    [12] = "Thieving",
    [13] = "Woodcutting",
    [14] = "Farming",
    [15] = "Utility",
    [16] = "Fishing"
}

local ELEMENT_ATTR_CLASS_PATHS = {
    air   = "/Script/Dominion.DamageTypeOutgoingAirMultiplierAttribute",
    wind  = "/Script/Dominion.DamageTypeOutgoingAirMultiplierAttribute",
    fire  = "/Script/Dominion.DamageTypeOutgoingFireMultiplierAttribute",
    water = "/Script/Dominion.DamageTypeOutgoingWaterMultiplierAttribute",
    ice   = "/Script/Dominion.DamageTypeOutgoingWaterMultiplierAttribute",
    earth = "/Script/Dominion.DamageTypeOutgoingEarthMultiplierAttribute"
}

local CachedSkillDataByEnum = {}
local CachedAttrClasses = {}
local CachedNotifSub = nil
local CachedNotifTag = nil
local CheckedNotifTag = false
local LastLockedNotifyAt = {}

local function IsValidUObj(obj)
    if not obj then return false end
    local t = type(obj)
    if t ~= "userdata" then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

local function SafeObjName(obj)
    if not obj then return "" end
    local ok, n = pcall(function() return obj:GetFullName() end)
    return (ok and n) or ""
end

local function HasUFunc(obj, name)
    if not IsValidUObj(obj) or not name then return false end
    local ok, fn = pcall(function() return obj[name] end)
    if not ok or fn == nil then return false end
    local t = type(fn)
    if t == "function" then return true end
    if t == "userdata" then
        local okV, valid = pcall(function() return fn:IsValid() end)
        return (not okV) or (valid == true)
    end
    return false
end

local function Trim(s)
    if not s then return "" end
    return (tostring(s):gsub("^%s*(.-)%s*$", "%1"))
end

function ProgressionScaling.ClearCache()
    CachedSkillDataByEnum = {}
    CachedAttrClasses = {}
    CachedNotifSub = nil
    CachedNotifTag = nil
    CheckedNotifTag = false
end

function ProgressionScaling.FormatSpellDisplayName(entry)
    if not entry then return "Spell" end
    if entry.customDef and entry.customDef.displayName and entry.customDef.displayName ~= "" then
        return tostring(entry.customDef.displayName)
    end
    local raw = tostring(entry.shortName or (entry.customDef and entry.customDef.name) or "Spell")
    -- Convert CamelCase ("StormOfArmadyl") -> "Storm Of Armadyl" for clean HUD messages
    local spaced = raw:gsub("_", " "):gsub("(%l)(%u)", "%1 %2"):gsub("(%u)(%u%l)", "%1 %2")
    return Trim(spaced)
end

local function ResolveSkillEnum(skillNameOrEnum)
    if type(skillNameOrEnum) == "number" then
        local e = math.floor(skillNameOrEnum)
        return e, ESKILL_ENUM_TO_DISPLAY[e] or "Magic"
    end
    local key = Trim(skillNameOrEnum or "Magic"):lower()
    if key == "" then key = "magic" end
    local e = ESKILL_NAME_TO_ENUM[key] or 8
    return e, ESKILL_ENUM_TO_DISPLAY[e] or "Magic"
end

local function ResolvePlayerController(pc, pawn)
    if IsValidUObj(pc) then return pc end
    if IsValidUObj(pawn) then
        local ctrl = nil
        pcall(function() ctrl = pawn.Controller end)
        if IsValidUObj(ctrl) then return ctrl end
    end
    local found = nil
    pcall(function() found = FindFirstOf("DominionPlayerController") end)
    if IsValidUObj(found) then return found end
    pcall(function() found = FindFirstOf("PlayerController") end)
    if IsValidUObj(found) then return found end
    return nil
end

local function ResolveSkillComponent(pc, pawn)
    local ctrl = ResolvePlayerController(pc, pawn)
    local comp = nil
    if IsValidUObj(ctrl) then
        pcall(function()
            if HasUFunc(ctrl, "GetPlayerSkillComponent") then
                comp = ctrl:GetPlayerSkillComponent()
            end
        end)
        if IsValidUObj(comp) then return comp end
        pcall(function() comp = ctrl.SkillComponent end)
        if IsValidUObj(comp) then return comp end
        pcall(function()
            if HasUFunc(ctrl, "GetSkillComponent") then
                comp = ctrl:GetSkillComponent()
            end
        end)
        if IsValidUObj(comp) then return comp end
    end
    pcall(function() comp = FindFirstOf("SkillComponent") end)
    if IsValidUObj(comp) then return comp end
    return nil
end

local function ReadSkillTypeEnum(skillDataObj)
    if not IsValidUObj(skillDataObj) then return nil end
    local st = nil
    pcall(function()
        if HasUFunc(skillDataObj, "GetSkillType") then
            st = tonumber(skillDataObj:GetSkillType())
        end
    end)
    if st == nil then
        pcall(function() st = tonumber(skillDataObj.SkillType) end)
    end
    return st
end

local function ResolveSkillData(skillEnum, skillNameLower, skillComp, heldData)
    local cached = CachedSkillDataByEnum[skillEnum]
    if IsValidUObj(cached) then
        return cached
    end
    CachedSkillDataByEnum[skillEnum] = nil

    -- Tier 1: Inspect the live USkillComponent.Skills TArray<FSkill>
    if IsValidUObj(skillComp) then
        local foundInComp = nil
        pcall(function()
            local skillsArr = skillComp.Skills
            if skillsArr and skillsArr.ForEach then
                skillsArr:ForEach(function(_, elemWrapper)
                    if IsValidUObj(foundInComp) then return end
                    local sd = nil
                    pcall(function()
                        local el = elemWrapper:get()
                        if el then sd = el.SkillData end
                    end)
                    if IsValidUObj(sd) then
                        local st = ReadSkillTypeEnum(sd)
                        if st == skillEnum then
                            foundInComp = sd
                        elseif st == nil and skillNameLower and SafeObjName(sd):lower():find(skillNameLower, 1, true) then
                            foundInComp = sd
                        end
                    end
                end)
            end
        end)
        if IsValidUObj(foundInComp) then
            CachedSkillDataByEnum[skillEnum] = foundInComp
            return foundInComp
        end
    end

    -- Tier 2: Held weapon's AssociatedSkill / SkillUsed (for Magic staves)
    if IsValidUObj(heldData) then
        for _, prop in ipairs({ "AssociatedSkill", "SkillUsed" }) do
            local sd = nil
            pcall(function() sd = heldData[prop] end)
            if IsValidUObj(sd) and ReadSkillTypeEnum(sd) == skillEnum then
                CachedSkillDataByEnum[skillEnum] = sd
                return sd
            end
        end
    end

    -- Tier 3: Scan loaded USkillData assets
    local foundAsset = nil
    pcall(function()
        local allSkills = FindAllOf("SkillData")
        if allSkills then
            for _, sd in ipairs(allSkills) do
                if IsValidUObj(sd) then
                    local fullLow = SafeObjName(sd):lower()
                    if not fullLow:find("default__", 1, true) then
                        local st = ReadSkillTypeEnum(sd)
                        if st == skillEnum then
                            foundAsset = sd
                            break
                        elseif not foundAsset and skillNameLower and fullLow:find(skillNameLower, 1, true) then
                            foundAsset = sd
                        end
                    end
                end
            end
        end
    end)

    if IsValidUObj(foundAsset) then
        CachedSkillDataByEnum[skillEnum] = foundAsset
        return foundAsset
    end
    return nil
end

-- Returns: level (integer or nil), skillComp, skillData, skillDisplayName
function ProgressionScaling.GetPlayerSkillLevel(pc, pawn, skillNameOrEnum, heldData)
    local skillEnum, skillDisplay = ResolveSkillEnum(skillNameOrEnum)
    local skillNameLower = skillDisplay:lower()
    local skillComp = ResolveSkillComponent(pc, pawn)
    if not IsValidUObj(skillComp) then
        return nil, nil, nil, skillDisplay
    end

    local skillData = ResolveSkillData(skillEnum, skillNameLower, skillComp, heldData)
    local level = nil

    if IsValidUObj(skillData) and HasUFunc(skillComp, "GetSkillLevel") then
        local ok, res = pcall(function() return skillComp:GetSkillLevel(skillData) end)
        if ok and tonumber(res) ~= nil then
            level = math.floor(tonumber(res))
        end
    end

    -- Fallback: read CurrentXP from SkillComponent.Skills + SkillSubsystem:GetLevelFromXp
    if level == nil and IsValidUObj(skillData) then
        local xp = nil
        pcall(function()
            local skillsArr = skillComp.Skills
            if skillsArr and skillsArr.ForEach then
                skillsArr:ForEach(function(_, elemWrapper)
                    if xp ~= nil then return end
                    local el = nil
                    pcall(function() el = elemWrapper:get() end)
                    if el and IsValidUObj(el.SkillData) and el.SkillData == skillData then
                        xp = tonumber(el.CurrentXP)
                    end
                end)
            end
        end)
        if xp ~= nil then
            pcall(function()
                local sub = FindFirstOf("SkillSubsystem")
                if IsValidUObj(sub) and HasUFunc(sub, "GetLevelFromXp") then
                    local lv = tonumber(sub:GetLevelFromXp(math.floor(xp)))
                    if lv ~= nil then level = math.floor(lv) end
                end
            end)
        end
    end

    return level, skillComp, skillData, skillDisplay
end

-- ============================================================================
-- FEATURE 2: MAGIC SKILL LEVEL GATING & LOCKED-CAST IN-GAME NOTIFICATIONS
-- ============================================================================

function ProgressionScaling.GetSpellRequirement(config, entry)
    if not entry then return 0, "Magic", true end
    local def = entry.customDef
    local reqLevel = tonumber(entry.requiredMagicLevel)
        or (def and tonumber(def.requiredMagicLevel))
        or 0
    local reqSkill = entry.requiredSkill
        or (def and def.requiredSkill)
        or "Magic"
    local unlockedByDefault = true
    if entry.unlockedByDefault == false or (def and def.unlockedByDefault == false) then
        unlockedByDefault = false
    end

    -- Apply optional global default level requirement for custom spells that omit RequiredMagicLevel
    if entry.isCustomSpell and reqLevel <= 0 and unlockedByDefault then
        local globalDef = tonumber(config and config.DefaultCustomSpellRequiredMagicLevel) or 0
        if globalDef > 0 then
            reqLevel = math.floor(globalDef)
        end
    end

    reqLevel = math.max(0, math.floor(reqLevel))
    if reqLevel > 0 then
        unlockedByDefault = false
    end
    return reqLevel, reqSkill, unlockedByDefault
end

-- Returns: isUnlocked (bool), infoTable { spellName, displayName, requiredSkill, requiredLevel, currentLevel, reason }
function ProgressionScaling.CheckSpellUnlocked(config, pc, pawn, entry)
    if not entry then
        return true, nil
    end
    if config and config.EnforceSpellLevelRequirements == false then
        return true, nil
    end

    local reqLevel, reqSkill, unlockedByDefault = ProgressionScaling.GetSpellRequirement(config, entry)
    if reqLevel <= 0 and unlockedByDefault then
        return true, nil
    end

    local curLevel, _, _, skillDisplay = ProgressionScaling.GetPlayerSkillLevel(pc, pawn, reqSkill)
    local displayName = ProgressionScaling.FormatSpellDisplayName(entry)

    if reqLevel <= 0 and not unlockedByDefault then
        return false, {
            spellName = entry.shortName or displayName,
            displayName = displayName,
            requiredSkill = skillDisplay,
            requiredLevel = 0,
            currentLevel = curLevel or 0,
            reason = string.format("%s is currently locked", displayName)
        }
    end

    if curLevel == nil or curLevel < reqLevel then
        local shownCur = curLevel or 0
        return false, {
            spellName = entry.shortName or displayName,
            displayName = displayName,
            requiredSkill = skillDisplay,
            requiredLevel = reqLevel,
            currentLevel = shownCur,
            reason = string.format("%s requires %s Level %d (Current: %d)",
                displayName, skillDisplay, reqLevel, shownCur)
        }
    end

    return true, {
        spellName = entry.shortName or displayName,
        displayName = displayName,
        requiredSkill = skillDisplay,
        requiredLevel = reqLevel,
        currentLevel = curLevel
    }
end

-- Check whether every step in a parsed combo macro is unlocked for the player.
-- Returns: isUnlocked (bool), firstLockedInfo (table or nil)
function ProgressionScaling.CheckMacroUnlocked(config, pc, pawn, state, macro, resolveStepFn)
    if not macro or not macro.stages then return true, nil end
    if config and config.EnforceSpellLevelRequirements == false then
        return true, nil
    end
    for _, st in ipairs(macro.stages) do
        if st and st.steps then
            for _, desc in ipairs(st.steps) do
                local ent = resolveStepFn and resolveStepFn(state, st, desc) or nil
                if ent then
                    local ok, info = ProgressionScaling.CheckSpellUnlocked(config, pc, pawn, ent)
                    if not ok then
                        return false, info
                    end
                end
            end
        end
    end
    return true, nil
end

local function MakeFTextSafe(strVal)
    local s = tostring(strVal or "")
    local ft = nil
    pcall(function()
        if type(FText) == "function" then
            ft = FText(s)
        end
    end)
    if ft ~= nil then return ft end
    pcall(function()
        local ktl = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
        if IsValidUObj(ktl) and HasUFunc(ktl, "Conv_StringToText") then
            ft = ktl:Conv_StringToText(s)
        end
    end)
    return ft or s
end

local function ReadGameplayTagNameStr(tag)
    if not tag then return "" end
    local out = ""
    pcall(function()
        if tag.TagName then
            if type(tag.TagName) == "userdata" and tag.TagName.ToString then
                out = tag.TagName:ToString() or ""
            else
                out = tostring(tag.TagName or "")
            end
        end
    end)
    if out == "None" then return "" end
    return out
end

local function ResolveValidTextNotificationTag(pc)
    if CachedNotifTag ~= nil then
        return CachedNotifTag
    end
    if CheckedNotifTag then
        return nil
    end
    CheckedNotifTag = true

    -- 1. Borrow a live HUD text notification FGameplayTag directly from DominionPlayerController
    if IsValidUObj(pc) then
        pcall(function()
            local t = pc.SpawnedInASafePlaceNotification
            local tStr = ReadGameplayTagNameStr(t)
            if tStr ~= "" then
                CachedNotifTag = { TagName = FName(tStr) }
            end
        end)
        if CachedNotifTag then return CachedNotifTag end
    end

    -- 2. Borrow a live notification tag from NotificationSettings CDO
    pcall(function()
        local settings = StaticFindObject("/Script/Dominion.Default__NotificationSettings")
        if IsValidUObj(settings) then
            for _, prop in ipairs({ "FoodConsumptionNotificationTag", "DrinkConsumptionNotificationTag" }) do
                local t = settings[prop]
                local tStr = ReadGameplayTagNameStr(t)
                if tStr ~= "" then
                    CachedNotifTag = { TagName = FName(tStr) }
                    break
                end
            end
        end
    end)
    return CachedNotifTag
end

local function GetNotificationsSubsystem()
    if IsValidUObj(CachedNotifSub) then
        return CachedNotifSub
    end
    local sub = nil
    pcall(function() sub = FindFirstOf("NotificationsSubsystem") end)
    if IsValidUObj(sub) then
        CachedNotifSub = sub
        return sub
    end
    return nil
end

-- Display an in-game notification when a player attempts to cast a spell above their Magic level.
-- Cooldown-throttled per spell so rapid key presses never flood the HUD.
function ProgressionScaling.NotifySpellLocked(config, pc, pawn, lockInfo, logFn, forceNotify)
    if not lockInfo then return false end
    if config and config.NotifyOnLockedSpellCast == false then return false end

    local now = os.clock()
    local key = tostring(lockInfo.spellName or lockInfo.displayName or "spell"):lower()
    local cooldownSec = math.max(0.25, tonumber(config and config.LockedSpellNotifyCooldownSec) or 1.5)
    if not forceNotify and LastLockedNotifyAt[key] and (now - LastLockedNotifyAt[key]) < cooldownSec then
        return false
    end
    LastLockedNotifyAt[key] = now

    local msg = lockInfo.reason or string.format("%s requires %s Level %d (Current: %d)",
        tostring(lockInfo.displayName or "Spell"),
        tostring(lockInfo.requiredSkill or "Magic"),
        tonumber(lockInfo.requiredLevel) or 1,
        tonumber(lockInfo.currentLevel) or 0)

    if logFn then
        logFn("LOCKED SPELL: " .. msg)
    end

    local ctrl = ResolvePlayerController(pc, pawn)
    local notifSub = GetNotificationsSubsystem()
    local ftextVal = MakeFTextSafe(msg)
    local style = tostring((config and config.LockedSpellNotifyStyle) or "auto"):lower()
    local dispatched = false

    -- Method 1: Native HUD text toast via UNotificationsSubsystem::DispatchTextNotification
    -- (only when we have a real game FGameplayTag so the HUD NotificationFilter accepts it)
    if not dispatched and (style == "auto" or style == "text") and IsValidUObj(notifSub) and HasUFunc(notifSub, "DispatchTextNotification") then
        local validTag = ResolveValidTextNotificationTag(ctrl)
        if validTag then
            local ok = pcall(function()
                notifSub:DispatchTextNotification(validTag, ftextVal)
            end)
            if ok then dispatched = true end
        end
    end

    -- Method 2: Guaranteed-visible HUD banner via UNotificationsSubsystem::DispatchBasicTutorialNotification
    -- (passes only FText + bool; uses Dominion's own internal tutorial notification tag)
    if not dispatched and (style == "auto" or style == "tutorial" or style == "text")
        and IsValidUObj(notifSub) and HasUFunc(notifSub, "DispatchBasicTutorialNotification") then
        local ok = pcall(function()
            notifSub:DispatchBasicTutorialNotification(ftextVal, false)
        end)
        if ok then dispatched = true end
    end

    -- Method 3: Fallback via ADominionPlayerController::Client_DisplayTextNotification
    if not dispatched and IsValidUObj(ctrl) and HasUFunc(ctrl, "Client_DisplayTextNotification") then
        local validTag = ResolveValidTextNotificationTag(ctrl)
        if validTag then
            local ok = pcall(function()
                ctrl:Client_DisplayTextNotification(validTag, ftextVal)
            end)
            if ok then dispatched = true end
        end
    end

    return dispatched
end

-- ============================================================================
-- FEATURE 1: STAFF + MAGIC SKILL + ATTRIBUTE DAMAGE SCALING
-- ============================================================================

local function GetCachedAttrClass(classPath)
    if not classPath or classPath == "" then return nil end
    local cached = CachedAttrClasses[classPath]
    if cached ~= nil then
        if cached == false then return nil end
        if IsValidUObj(cached) then return cached end
        CachedAttrClasses[classPath] = nil
    end
    local cls = nil
    pcall(function() cls = StaticFindObject(classPath) end)
    CachedAttrClasses[classPath] = IsValidUObj(cls) and cls or false
    return IsValidUObj(cls) and cls or nil
end

local function ReadFloatAttributeValue(pawn, attrComp, classPath)
    if not classPath or classPath == "" then return nil end
    local attrCls = GetCachedAttrClass(classPath)

    -- Tier 1: Direct UDominionAttributesComponent parallel arrays (FloatAttributes/AttributeValues & Shared*)
    -- Avoids any out-param marshalling quirks across UE4SS versions.
    if IsValidUObj(attrComp) then
        local shortClsName = (classPath:match("%.([^%.]+)$") or classPath):lower()
        local foundVal = nil
        local function scanPair(arrObjs, arrVals)
            if foundVal ~= nil or not arrObjs or not arrVals or not arrObjs.ForEach then return end
            arrObjs:ForEach(function(luaIdx, elemWrapper)
                if foundVal ~= nil then return end
                local attrObj = nil
                pcall(function() attrObj = elemWrapper:get() end)
                if IsValidUObj(attrObj) then
                    local matched = false
                    if IsValidUObj(attrCls) and HasUFunc(attrObj, "IsA") then
                        pcall(function() matched = (attrObj:IsA(attrCls) == true) end)
                    end
                    if not matched then
                        local fn = SafeObjName(attrObj):lower()
                        if fn:find(shortClsName, 1, true) then matched = true end
                    end
                    if matched then
                        pcall(function()
                            local v = arrVals[luaIdx]
                            if v ~= nil and type(v) == "userdata" and v.get then v = v:get() end
                            local num = tonumber(v)
                            if num ~= nil then foundVal = num end
                        end)
                    end
                end
            end)
        end
        pcall(function() scanPair(attrComp.FloatAttributes, attrComp.AttributeValues) end)
        if foundVal == nil then
            pcall(function() scanPair(attrComp.SharedFloatAttributes, attrComp.SharedAttributeValues) end)
        end
        if foundVal ~= nil then
            return foundVal
        end
    end

    -- Tier 2: UAttributeFunctionLibrary::BP_TryGetFloatAttributeValue
    if IsValidUObj(pawn) and IsValidUObj(attrCls) then
        local lib = nil
        pcall(function() lib = StaticFindObject("/Script/Dominion.Default__AttributeFunctionLibrary") end)
        if IsValidUObj(lib) and HasUFunc(lib, "BP_TryGetFloatAttributeValue") then
            local outVal = {}
            local outFound = {}
            local ok = pcall(function()
                lib:BP_TryGetFloatAttributeValue(pawn, attrCls, 1.0, outVal, outFound)
            end)
            if ok and outFound.OutbFound == true and tonumber(outVal.OutAttributeValue) ~= nil then
                return tonumber(outVal.OutAttributeValue)
            end
        end
    end

    return nil
end

local function NormalizeMultiplier(rawVal, defaultVal)
    local n = tonumber(rawVal)
    if n == nil then return defaultVal or 1.0 end
    if n <= 0.01 or n > 50.0 then return defaultVal or 1.0 end
    return n
end

-- Inspect the player's currently equipped weapon/staff stats.
function ProgressionScaling.GetEquippedStaffStats(pc, pawn)
    local stats = {
        hasMagicWeapon = false,
        isWand = false,
        weaponName = "None",
        tier = 0,
        basePowerLevel = 0,
        damageMultiplier = 1.0,
        additionalDamageMultiplier = 0.0,
        isMasterwork = false,
        equipmentPowerLevel = 0.0,
        heldData = nil
    }
    if not IsValidUObj(pawn) then return stats end

    local ctrl = ResolvePlayerController(pc, pawn)
    local loadout = nil
    if IsValidUObj(ctrl) then
        pcall(function()
            if HasUFunc(ctrl, "GetLoadout") then loadout = ctrl:GetLoadout()
            else loadout = ctrl.LoadoutComponent end
        end)
    end

    local wInfo = EquipmentRunes.GetEquippedMagicWeaponInfo(pawn, loadout)
    stats.hasMagicWeapon = (wInfo and wInfo.hasMagicWeapon == true) or false
    stats.isWand = (wInfo and tostring(wInfo.weaponSuffix or ""):lower():find("wand", 1, true) ~= nil) or false
    stats.weaponName = (wInfo and wInfo.weaponName) or "None"
    stats.heldData = wInfo and wInfo.heldData or nil

    local hd = stats.heldData
    if IsValidUObj(hd) then
        pcall(function()
            if HasUFunc(hd, "GetTier") then
                stats.tier = tonumber(hd:GetTier()) or 0
            else
                stats.tier = tonumber(hd.Tier) or 0
            end
        end)
        pcall(function()
            if HasUFunc(hd, "GetBasePowerLevel") then
                stats.basePowerLevel = tonumber(hd:GetBasePowerLevel()) or 0
            else
                stats.basePowerLevel = tonumber(hd.PowerLevel) or 0
            end
        end)
        pcall(function()
            local dm = tonumber(hd.DamageMultiplier)
            if dm and dm > 0.0 then stats.damageMultiplier = dm end
        end)
        pcall(function()
            local adm = tonumber(hd.AdditionalDamageMultiplier)
            if adm then stats.additionalDamageMultiplier = adm end
        end)
        pcall(function()
            stats.isMasterwork = (hd.bIsMasterworkItem == true)
        end)
    end

    if IsValidUObj(ctrl) then
        pcall(function()
            local bpLib = StaticFindObject("/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
            if IsValidUObj(bpLib) and HasUFunc(bpLib, "GetCurrentEquipmentPowerLevel") then
                local pl = tonumber(bpLib:GetCurrentEquipmentPowerLevel(ctrl))
                if pl and pl > 0 then stats.equipmentPowerLevel = pl end
            end
        end)
    end

    return stats
end

-- Parse optional per-staff bonus map: either a Lua table { Armadyl = 1.35, Zamorak = 1.25 }
-- (from custom_spells.json) or legacy string "Armadyl:1.35, Zamorak:1.25".
local function ResolveStaffSpecificBonus(staffBonusVal, weaponName)
    if not staffBonusVal or not weaponName or weaponName == "" then
        return 1.0
    end
    local wLow = tostring(weaponName):lower()
    if type(staffBonusVal) == "table" then
        local keys = {}
        for k, _ in pairs(staffBonusVal) do table.insert(keys, tostring(k)) end
        table.sort(keys)
        for _, kw in ipairs(keys) do
            local kwLow = Trim(kw):lower()
            local m = tonumber(staffBonusVal[kw])
            if kwLow ~= "" and m and m > 0 and wLow:find(kwLow, 1, true) then
                return m
            end
        end
        return 1.0
    end
    if staffBonusVal == "" then return 1.0 end
    local bestBonus = 1.0
    for token in tostring(staffBonusVal):gmatch("[^,;]+") do
        local kw, multStr = Trim(token):match("^([^:=]+)%s*[:=]%s*([%-%d%.]+)$")
        if kw and multStr then
            local kwLow = Trim(kw):lower()
            local m = tonumber(multStr)
            if kwLow ~= "" and m and m > 0 and wLow:find(kwLow, 1, true) then
                bestBonus = m
                break
            end
        end
    end
    return bestBonus
end

-- Compute the combined damage scaling multiplier for a custom spell hit.
-- Modes:
--   "none"  -> 1.0x (raw flat dmg=min..max)
--   "staff" -> scales by equipped staff Tier, DamageMultiplier, AdditionalDamageMultiplier, Masterwork & StaffBonus
--   "magic" -> scales by Magic skill damage modifier + player magic/staff/elemental attributes
--   "full"  -> staff * magic (default when ScaleWithStaff = true)
-- Returns: finalMult (number), breakdown (table)
function ProgressionScaling.ComputeDamageMultiplier(config, pc, pawn, entry, hitParams)
    local breakdown = {
        mode = "none",
        staffMult = 1.0,
        tierMult = 1.0,
        weaponMult = 1.0,
        staffBonus = 1.0,
        skillMult = 1.0,
        attrMult = 1.0,
        finalMult = 1.0,
        weaponName = "None",
        tier = 0,
        magicLevel = nil
    }

    if config and config.EnableStaffDamageScaling == false then
        return 1.0, breakdown
    end
    if not IsValidUObj(pawn) then
        return 1.0, breakdown
    end

    local def = entry and entry.customDef or nil
    local mode = nil
    if hitParams and hitParams.dmgScale and hitParams.dmgScale ~= "" then
        mode = tostring(hitParams.dmgScale):lower()
    elseif def and def.damageScaling and def.damageScaling ~= "" then
        mode = tostring(def.damageScaling):lower()
    elseif def and def.scaleWithStaff ~= nil then
        mode = def.scaleWithStaff and "full" or "none"
    elseif entry and entry.scaleWithStaff ~= nil then
        mode = entry.scaleWithStaff and "full" or "none"
    else
        mode = "none"
    end

    if mode == "false" or mode == "off" or mode == "0" or mode == "flat" then
        mode = "none"
    elseif mode == "true" or mode == "on" or mode == "1" or mode == "all" then
        mode = "full"
    end
    breakdown.mode = mode

    if mode == "none" then
        return 1.0, breakdown
    end

    local ctrl = ResolvePlayerController(pc, pawn)
    local staffStats = ProgressionScaling.GetEquippedStaffStats(ctrl, pawn)
    breakdown.weaponName = staffStats.weaponName
    breakdown.tier = staffStats.tier

    local wantsStaff = (mode == "staff" or mode == "full")
    local wantsMagic = (mode == "magic" or mode == "full")

    if wantsStaff then
        local baselineTier = tonumber(def and def.staffBaselineTier)
            or tonumber(config and config.StaffBaselineTier)
            or 1
        local tierStep = tonumber(def and def.staffTierStep)
            or tonumber(config and config.StaffTierStep)
            or 0.30
        local masterworkBonus = tonumber(config and config.StaffMasterworkBonus) or 0.15

        -- Effective weapon multiplier from UHeldEquipmentData
        local rawWeaponMult = math.max(0.25, (staffStats.damageMultiplier or 1.0) + (staffStats.additionalDamageMultiplier or 0.0))
        breakdown.weaponMult = rawWeaponMult

        -- Effective tier scaling (1.0x at baselineTier, +tierStep per tier above; scales down safely if unarmed/lower tier)
        local effTier = staffStats.tier
        local tierMult = 1.0
        if not staffStats.hasMagicWeapon and (not def or (def.damageClass or "magical") == "magical") then
            -- Casting a magic staff-scaled spell without a magic weapon equipped applies a reduced unarmed factor
            tierMult = tonumber(config and config.NoStaffDamageMultiplier) or 0.50
        elseif effTier and effTier > 0 then
            tierMult = math.max(0.40, 1.0 + (effTier - baselineTier) * tierStep)
            if staffStats.isMasterwork then
                tierMult = tierMult + masterworkBonus
            end
        elseif staffStats.basePowerLevel and staffStats.basePowerLevel > 0 then
            -- Fallback if an item defines BasePowerLevel without Tier
            tierMult = math.max(0.50, 0.75 + (staffStats.basePowerLevel * 0.025))
        end
        breakdown.tierMult = tierMult

        local staffBonus = ResolveStaffSpecificBonus(def and def.staffBonus, staffStats.weaponName)
        breakdown.staffBonus = staffBonus
        breakdown.staffMult = tierMult * rawWeaponMult * staffBonus
    end

    if wantsMagic then
        local magicLevel, skillComp, magicSkillData = ProgressionScaling.GetPlayerSkillLevel(ctrl, pawn, "Magic", staffStats.heldData)
        breakdown.magicLevel = magicLevel

        -- Native USkillComponent::CalculateDamageModifier(MagicSkillData)
        local skillMult = 1.0
        if IsValidUObj(skillComp) and IsValidUObj(magicSkillData) and HasUFunc(skillComp, "CalculateDamageModifier") then
            local ok, rawMod = pcall(function() return skillComp:CalculateDamageModifier(magicSkillData) end)
            if ok and tonumber(rawMod) ~= nil then
                local v = tonumber(rawMod)
                -- Handle both multiplier-style (>= 0.5, e.g. 1.24) and additive-delta-style (0..0.5, e.g. 0.24 -> 1.24)
                if v >= 0.5 and v <= 10.0 then
                    skillMult = v
                elseif v > 0.0 and v < 0.5 then
                    skillMult = 1.0 + v
                end
            end
        end
        breakdown.skillMult = skillMult

        -- Live player attributes (gear/potions/perks/staff modifiers)
        local attrComp = nil
        pcall(function()
            if HasUFunc(pawn, "GetPlayerAttributesComponent") then
                attrComp = pawn:GetPlayerAttributesComponent()
            else
                attrComp = pawn.AttributesComponent
            end
        end)

        local attrMult = 1.0
        if IsValidUObj(attrComp) then
            local magicAttr = ReadFloatAttributeValue(pawn, attrComp, "/Script/Dominion.DamageMultiplierMagicAttribute")
            if magicAttr then attrMult = attrMult * NormalizeMultiplier(magicAttr, 1.0) end

            local allCombatAttr = ReadFloatAttributeValue(pawn, attrComp, "/Script/Dominion.DamageMultiplierAllCombatStylesAttribute")
            if allCombatAttr then attrMult = attrMult * NormalizeMultiplier(allCombatAttr, 1.0) end

            if staffStats.hasMagicWeapon and not staffStats.isWand then
                local staffAttr = ReadFloatAttributeValue(pawn, attrComp, "/Script/Dominion.DamageModifierWeaponTypeStaff")
                if staffAttr then attrMult = attrMult * NormalizeMultiplier(staffAttr, 1.0) end
            end

            local catBase = tostring((entry and entry.categoryTag) or (def and def.category) or ""):lower():gsub("_wand$", ""):gsub("_hold$", "")
            local elemPath = ELEMENT_ATTR_CLASS_PATHS[catBase]
            if elemPath then
                local elemAttr = ReadFloatAttributeValue(pawn, attrComp, elemPath)
                if elemAttr then attrMult = attrMult * NormalizeMultiplier(elemAttr, 1.0) end
            end
        end
        breakdown.attrMult = attrMult
    end

    local finalMult = breakdown.staffMult * breakdown.skillMult * breakdown.attrMult
    local minCap = tonumber(config and config.MinScaledDamageMultiplier) or 0.25
    local maxCap = tonumber(config and config.MaxScaledDamageMultiplier) or 10.0
    finalMult = math.max(minCap, math.min(maxCap, finalMult))
    breakdown.finalMult = finalMult

    return finalMult, breakdown
end

function ProgressionScaling.ScaleDamageRange(baseMin, baseMax, mult)
    local m = tonumber(mult) or 1.0
    local lo = math.max(1, math.floor((tonumber(baseMin) or 1) * m + 0.5))
    local hi = math.max(lo, math.floor((tonumber(baseMax) or lo) * m + 0.5))
    return lo, hi
end

-- Diagnostic dump called by SHIFT + DebugHotkey so the user can inspect live staff/skill values in-game.
function ProgressionScaling.LogDebugSummary(config, state, pc, pawn, logFn)
    if not logFn then return end
    local ctrl = ResolvePlayerController(pc, pawn)
    local staff = ProgressionScaling.GetEquippedStaffStats(ctrl, pawn)
    local magicLv, skillComp, magicData = ProgressionScaling.GetPlayerSkillLevel(ctrl, pawn, "Magic", staff.heldData)

    local rawSkillDmgMod = "nil"
    if IsValidUObj(skillComp) and IsValidUObj(magicData) and HasUFunc(skillComp, "CalculateDamageModifier") then
        local ok, v = pcall(function() return skillComp:CalculateDamageModifier(magicData) end)
        if ok and v ~= nil then rawSkillDmgMod = string.format("%.3f", tonumber(v) or 0) end
    end

    logFn("=== Progression & Staff Scaling Status ===")
    logFn(string.format("  Magic Level: %s | NativeSkillDmgMod: %s | EnforceLevelGates: %s | StaffScaling: %s",
        tostring(magicLv or "Unavailable"), tostring(rawSkillDmgMod),
        tostring(config.EnforceSpellLevelRequirements ~= false),
        tostring(config.EnableStaffDamageScaling ~= false)))
    logFn(string.format("  Equipped Staff: %s (MagicWeapon=%s, Wand=%s, Tier=%d, BasePower=%d, DmgMult=%.2f, AddMult=%.2f, Masterwork=%s, EquipPower=%.1f)",
        tostring(staff.weaponName), tostring(staff.hasMagicWeapon), tostring(staff.isWand),
        tonumber(staff.tier) or 0, tonumber(staff.basePowerLevel) or 0,
        tonumber(staff.damageMultiplier) or 1.0, tonumber(staff.additionalDamageMultiplier) or 0.0,
        tostring(staff.isMasterwork), tonumber(staff.equipmentPowerLevel) or 0.0))

    if state and state.SpellRegistry then
        local customNames = {}
        for _, entry in pairs(state.SpellRegistry) do
            if entry and entry.isCustomSpell then
                table.insert(customNames, entry)
            end
        end
        table.sort(customNames, function(a, b) return tostring(a.shortName) < tostring(b.shortName) end)
        for _, entry in ipairs(customNames) do
            local ok, lockInfo = ProgressionScaling.CheckSpellUnlocked(config, ctrl, pawn, entry)
            local mult, brk = ProgressionScaling.ComputeDamageMultiplier(config, ctrl, pawn, entry, nil)
            local reqLv, reqSkill = ProgressionScaling.GetSpellRequirement(config, entry)
            local statusStr = ok and "UNLOCKED" or ("LOCKED (" .. tostring(lockInfo and lockInfo.reason or "locked") .. ")")
            logFn(string.format("  CustomSpell [%s]: %s | Req=%s:%d | Scale=%s (final=%.2fx: staff=%.2fx[T%d*%.2f] * skill=%.2fx * attr=%.2fx)",
                tostring(entry.shortName), statusStr, tostring(reqSkill), tonumber(reqLv) or 0,
                tostring(brk.mode), mult, brk.staffMult, brk.tier, brk.weaponMult, brk.skillMult, brk.attrMult))
        end
    end
end

return ProgressionScaling
