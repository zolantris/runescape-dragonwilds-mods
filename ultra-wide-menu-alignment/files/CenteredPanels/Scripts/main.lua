-- CenteredPanels v1.2.9
local function GetScriptDir()
    local ok, info = pcall(debug.getinfo, 1, "S")
    if ok and info and info.source then
        local src = info.source
        if string.sub(src, 1, 1) == "@" then
            src = string.sub(src, 2)
        end
        local dir = string.match(src, "^(.*[\\/])")
        if dir then return dir end
    end
    return "C:\\steam\\steamapps\\common\\RSDragonwilds\\RSDragonwilds\\Binaries\\Win64\\ue4ss\\Mods\\CenteredPanels\\Scripts\\"
end

local SCRIPT_DIR = GetScriptDir()
local MOD_DIR = string.gsub(SCRIPT_DIR, "[\\/]Scripts[\\/]?$", "\\")
local SNAPSHOT_DIR = MOD_DIR .. "snapshots\\"
local CONFIG_TXT_PATH = MOD_DIR .. "config.txt"

local Config = nil
local okCfg, loadedCfg = pcall(dofile, SCRIPT_DIR .. "config.lua")
if okCfg and type(loadedCfg) == "table" then
    Config = loadedCfg
else
    Config = {
        Enabled = true,
        CenterInventory = true,
        CenterContainers = true,
        CenterStations = true,
        CenterPauseMenu = true,
        MinX = 0.25,
        MaxX = 0.75,
        OffsetX = 0,
        SnapshotKeyPrimary = Key.NUM_SEVEN,
        SnapshotKeySecondary = Key.F7,
        ForceApplyKey = Key.NUM_EIGHT,
        NudgeRightKey = Key.ADD,
        NudgeLeftKey = Key.SUBTRACT,
        NudgeStepPx = 40,
        TargetPanels = {
            WBP_Inventory_MainPanel_C = "inventory",
            WBP_WorldActorInventory_MainPanel_C = "containers",
            WBP_Crafting_MainPanel_C = "stations",
            WBP_ProcessingStation_MainPanel_C = "stations",
            WBP_Composter_MainPanel_C = "stations",
            WBP_Enchanting_MainPanel_C = "stations",
            WBP_Building_MainPanel_C = "stations",
            WBP_Spellcasting_MainPanel_C = "stations",
            WBP_InGameScreensRoot_C = "pause_menu"
        }
    }
end

local function SyncFromConfigTxt()
    local f = io.open(CONFIG_TXT_PATH, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = string.match(line, "^%s*([^=%s]+)%s*=%s*(.-)%s*$")
        if k and v then
            if v == "true" then Config[k] = true
            elseif v == "false" then Config[k] = false
            else
                local num = tonumber(v)
                if num ~= nil then Config[k] = num end
            end
        end
    end
    f:close()
end

local function SaveConfigTxt()
    pcall(function()
        local f = io.open(CONFIG_TXT_PATH, "w")
        if not f then return end
        f:write(string.format("Enabled=%s\n", tostring(Config.Enabled)))
        f:write(string.format("CenterInventory=%s\n", tostring(Config.CenterInventory)))
        f:write(string.format("CenterContainers=%s\n", tostring(Config.CenterContainers)))
        f:write(string.format("CenterStations=%s\n", tostring(Config.CenterStations)))
        f:write(string.format("CenterPauseMenu=%s\n", tostring(Config.CenterPauseMenu)))
        f:write(string.format("MinX=%.2f\n", tonumber(Config.MinX) or 0.25))
        f:write(string.format("MaxX=%.2f\n", tonumber(Config.MaxX) or 0.75))
        f:write(string.format("OffsetX=%d\n", math.floor(tonumber(Config.OffsetX) or 0)))
        f:close()
    end)
end

local function IsGroupEnabled(group)
    if not Config.Enabled then return false end
    if group == "inventory" then return Config.CenterInventory ~= false end
    if group == "containers" then return Config.CenterContainers ~= false end
    if group == "stations" then return Config.CenterStations ~= false end
    if group == "pause_menu" then return Config.CenterPauseMenu ~= false end
    return true
end

local function GetShortClassName(w)
    local ok, cls = pcall(function() return w:GetClass() end)
    if ok and cls then
        local okN, fn = pcall(function() return cls:GetFName():ToString() end)
        if okN and fn and fn ~= "" then return fn end
    end
    local okFull, full = pcall(function() return w:GetFullName() end)
    if okFull and full then
        local c = string.match(full, "^([^%s]+)")
        if c then return c end
    end
    return ""
end

local function GetShortObjName(w)
    local ok, fn = pcall(function() return w:GetFName():ToString() end)
    if ok and fn and fn ~= "" then return fn end
    return "Unknown"
end

-- Cache discovered live instances of our exact target panels (zero per-frame FindAllOf)
local CachedPanels = {}

local function ApplyCenterToWidget(w)
    if not w then return false end
    local clsName = GetShortClassName(w)
    local group = Config.TargetPanels[clsName]
    if not group then return false end

    local fullOk, fullName = pcall(function() return w:GetFullName() end)
    if not fullOk or not fullName or string.find(fullName, "Default__", 1, true) then
        return false
    end

    CachedPanels[fullName] = w

    local minX = tonumber(Config.MinX) or 0.25
    local maxX = tonumber(Config.MaxX) or 0.75
    local offX = tonumber(Config.OffsetX) or 0

    if not IsGroupEnabled(group) then
        minX, maxX, offX = 0.0, 1.0, 0
    end

    local inVp = false
    pcall(function() inVp = w:IsInViewport() end)

    local applied = false
    if inVp then
        local okVp = pcall(function()
            w:SetAnchorsInViewport({
                Minimum = { X = minX, Y = 0.0 },
                Maximum = { X = maxX, Y = 1.0 }
            })
        end)
        if okVp then applied = true end
    else
        local okSlot = pcall(function()
            local slot = w.Slot
            if slot then
                slot:SetAnchors({
                    Minimum = { X = minX, Y = 0.0 },
                    Maximum = { X = maxX, Y = 1.0 }
                })
                slot:SetOffsets({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                applied = true
            end
        end)
        if not okSlot then applied = false end
    end

    pcall(function()
        w:SetRenderTranslation({ X = offX, Y = 0.0 })
    end)

    return applied
end

local function RefreshAllTargetPanels()
    SyncFromConfigTxt()
    local widgets = nil
    pcall(function() widgets = FindAllOf("UserWidget") end)
    if not widgets then return 0 end

    local count = 0
    for _, w in ipairs(widgets) do
        local clsName = GetShortClassName(w)
        if Config.TargetPanels[clsName] then
            if ApplyCenterToWidget(w) then
                count = count + 1
            end
        end
    end
    return count
end

-- Lightweight watch ONLY on our ~9 cached target pointers (never scans 6000 widgets)
-- Re-applies anchors if the game resets CanvasPanelSlot when opening Inventory/Chest
LoopAsync(400, function()
    if not Config.Enabled then return false end
    ExecuteInGameThread(function()
        SyncFromConfigTxt()
        local hasAny = false
        for fullName, w in pairs(CachedPanels) do
            hasAny = true
            local vis = -1
            local okV = pcall(function() vis = w:GetVisibility() end)
            if okV and (vis == 0 or vis == 4) then
                ApplyCenterToWidget(w)
            elseif not okV then
                CachedPanels[fullName] = nil
            end
        end
        if not hasAny then
            RefreshAllTargetPanels()
        end
    end)
    return false
end)

-- Event hooks on exact Blueprint classes
RegisterHook("/Script/UMG.UserWidget:Construct", function(Context)
    local w = Context:get()
    local clsName = GetShortClassName(w)
    if Config.TargetPanels[clsName] then
        ExecuteInGameThread(function()
            SyncFromConfigTxt()
            ApplyCenterToWidget(w)
        end)
    end
end)

RegisterHook("/Script/UMG.UserWidget:AddToViewport", function(Context)
    local w = Context:get()
    local clsName = GetShortClassName(w)
    if Config.TargetPanels[clsName] then
        ExecuteInGameThread(function()
            SyncFromConfigTxt()
            ApplyCenterToWidget(w)
        end)
    end
end)

-- Clean Snapshot Dumper (filters out floating damage/text spam)
local LastStateMap = {}

local function TakeCleanSnapshot()
    ExecuteInGameThread(function()
        pcall(function() os.execute('mkdir "' .. SNAPSHOT_DIR .. '" >nul 2>&1') end)
        local tsFile = os.date("%Y-%m-%d_%H-%M-%S")
        local tsHuman = os.date("%Y-%m-%d %H:%M:%S")

        local widgets = nil
        pcall(function() widgets = FindAllOf("UserWidget") end)
        if not widgets then return end

        local shortLines = {
            "==========================================",
            "[CenteredPanels] CLEAN PANEL DIFF SNAPSHOT",
            "Timestamp: " .. tsHuman,
            "Config: MinX=" .. tostring(Config.MinX) .. " MaxX=" .. tostring(Config.MaxX) .. " OffsetX=" .. tostring(Config.OffsetX),
            "=========================================="
        }
        local fullLines = {
            "==========================================",
            "[CenteredPanels] CLEAN VIEWPORT & PANEL SNAPSHOT",
            "Timestamp: " .. tsHuman,
            "=========================================="
        }

        local currentMap = {}
        local inspected = 0

        for _, w in ipairs(widgets) do
            local fullOk, fullName = pcall(function() return w:GetFullName() end)
            if fullOk and fullName and not string.find(fullName, "Default__", 1, true) and string.find(fullName, "/Engine/Transient", 1, true) then
                local clsName = GetShortClassName(w)
                if not string.find(clsName, "FloatingDamage", 1, true) and not string.find(clsName, "FloatingText", 1, true) then
                    local isTarget = (Config.TargetPanels[clsName] ~= nil)
                    local inVp = false
                    pcall(function() inVp = w:IsInViewport() end)

                    if isTarget or inVp then
                        inspected = inspected + 1
                        local vis = -1
                        pcall(function() vis = w:GetVisibility() end)
                        local objName = GetShortObjName(w)

                        local slotInfo = "None"
                        if not inVp then
                            pcall(function()
                                local s = w.Slot
                                if s then
                                    local a = s:GetAnchors()
                                    slotInfo = string.format("%s Anchors=(%.2f,%.2f)-(%.2f,%.2f)",
                                        GetShortClassName(s), a.Minimum.X, a.Minimum.Y, a.Maximum.X, a.Maximum.Y)
                                end
                            end)
                        else
                            slotInfo = "ViewportRoot"
                        end

                        local stateSig = string.format("vis=%s|inVp=%s|%s", tostring(vis), tostring(inVp), slotInfo)
                        currentMap[fullName] = stateSig
                        local tag = (LastStateMap[fullName] ~= stateSig) and "[NEW/CHANGED]" or "[UNCHANGED]"

                        local line = string.format("  %s %s [%s] %s | %s", tag, clsName, objName, stateSig, fullName)
                        table.insert(fullLines, line)
                        if tag == "[NEW/CHANGED]" or isTarget then
                            table.insert(shortLines, string.format("  %s %s [%s] %s", tag, clsName, objName, stateSig))
                        end
                    end
                end
            end
        end

        LastStateMap = currentMap
        table.insert(shortLines, "------------------------------------------")
        table.insert(shortLines, string.format("Total Scanned: %d | Clean Panels Inspected: %d", #widgets, inspected))
        table.insert(shortLines, "==========================================")

        local shortPath = SNAPSHOT_DIR .. "snapshot_short_" .. tsFile .. ".txt"
        local fullPath = SNAPSHOT_DIR .. "snapshot_" .. tsFile .. ".txt"

        local fShort, errS = io.open(shortPath, "w")
        if fShort then
            fShort:write(table.concat(shortLines, "\n") .. "\n")
            fShort:close()
            print("[CenteredPanels] Short (SAVED): " .. shortPath)
        else
            print("[CenteredPanels] Short (FAILED): " .. tostring(errS))
        end

        local fFull, errF = io.open(fullPath, "w")
        if fFull then
            fFull:write(table.concat(fullLines, "\n") .. "\n")
            fFull:close()
            print("[CenteredPanels] Full (SAVED): " .. fullPath)
        else
            print("[CenteredPanels] Full (FAILED): " .. tostring(errF))
        end

        for _, l in ipairs(shortLines) do
            print("[CenteredPanels] " .. l)
        end
    end)
end

RegisterKeyBind(Config.SnapshotKeyPrimary, TakeCleanSnapshot)
RegisterKeyBind(Config.SnapshotKeySecondary, TakeCleanSnapshot)

RegisterKeyBind(Config.ForceApplyKey, function()
    ExecuteInGameThread(function()
        local n = RefreshAllTargetPanels()
        print(string.format("[CenteredPanels] [NumPad8] Force-applied centering to %d target panels (MinX=%.2f, MaxX=%.2f, OffsetX=%d)",
            n, Config.MinX, Config.MaxX, Config.OffsetX))
    end)
end)

RegisterKeyBind(Config.NudgeRightKey, function()
    ExecuteInGameThread(function()
        Config.OffsetX = (tonumber(Config.OffsetX) or 0) + (tonumber(Config.NudgeStepPx) or 40)
        SaveConfigTxt()
        local n = RefreshAllTargetPanels()
        print(string.format("[CenteredPanels] [NumPad+] OffsetX = %d px (applied to %d panels)", Config.OffsetX, n))
    end)
end)

RegisterKeyBind(Config.NudgeLeftKey, function()
    ExecuteInGameThread(function()
        Config.OffsetX = (tonumber(Config.OffsetX) or 0) - (tonumber(Config.NudgeStepPx) or 40)
        SaveConfigTxt()
        local n = RefreshAllTargetPanels()
        print(string.format("[CenteredPanels] [NumPad-] OffsetX = %d px (applied to %d panels)", Config.OffsetX, n))
    end)
end)

print("[CenteredPanels] v1.2.9 initialized cleanly. ScriptDir=" .. SCRIPT_DIR)
