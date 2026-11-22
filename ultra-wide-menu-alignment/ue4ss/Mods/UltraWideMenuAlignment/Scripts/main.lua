local MOD_NAME = "UltraWideMenuAlignment"
local VERSION = "1.3.3"

local function Log(msg)
    print(string.format("[%s] %s", MOD_NAME, tostring(msg)))
end

local function ResolveModDir()
    local info = debug.getinfo(1, "S")
    local src = info and info.source or ""
    if src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    src = src:gsub("/", "\\")
    local scriptsDir = src:match("^(.*\\)[^\\]+$")
    if scriptsDir then
        local modDir = scriptsDir:match("^(.*\\)Scripts\\?$")
        if modDir then
            return modDir
        end
    end
    return "C:\\steam\\steamapps\\common\\RSDragonwilds\\RSDragonwilds\\Binaries\\Win64\\ue4ss\\Mods\\UltraWideMenuAlignment\\"
end

local MOD_DIR = ResolveModDir()
local SCRIPTS_DIR = MOD_DIR .. "Scripts\\"
local SNAPSHOTS_DIR = MOD_DIR .. "snapshots\\"
local CONFIG_TXT_PATH = MOD_DIR .. "config.txt"

local Config = {
    Enabled = true,
    MinX = 0.25,
    MaxX = 0.75,
    OffsetX = 0,
    Groups = {
        inventory = true,
        containers = true,
        stations = true,
        build_spells = true,
        pause_menu = true,
    },
    EnableDebugHotkeys = false,
    ShowDebugBanner = false,
    TargetPanels = {},
    SnapshotIgnoreSubstrings = {
        "Default__",
        "WBP_FloatingDamage",
        "WBP_FloatingText",
        "ItemSlot",
        "CategoryItemSlot",
        "Tooltip",
    },
}

do
    local ok, loaded = pcall(dofile, SCRIPTS_DIR .. "config.lua")
    if ok and type(loaded) == "table" then
        for k, v in pairs(loaded) do
            Config[k] = v
        end
    end
end

local function ParseBool(val, defaultVal)
    if val == nil then return defaultVal end
    local s = tostring(val):lower():gsub("%s+", "")
    if s == "1" or s == "true" or s == "yes" or s == "on" then return true end
    if s == "0" or s == "false" or s == "no" or s == "off" then return false end
    return defaultVal
end

local function ReloadKvConfig()
    local f = io.open(CONFIG_TXT_PATH, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k and v then
            if k == "Enabled" then Config.Enabled = ParseBool(v, Config.Enabled)
            elseif k == "MinX" then Config.MinX = tonumber(v) or Config.MinX
            elseif k == "MaxX" then Config.MaxX = tonumber(v) or Config.MaxX
            elseif k == "OffsetX" then Config.OffsetX = math.floor(tonumber(v) or Config.OffsetX)
            elseif k == "CenterInventory" then Config.Groups.inventory = ParseBool(v, Config.Groups.inventory)
            elseif k == "CenterContainers" then Config.Groups.containers = ParseBool(v, Config.Groups.containers)
            elseif k == "CenterStations" then Config.Groups.stations = ParseBool(v, Config.Groups.stations)
            elseif k == "CenterBuildSpells" then Config.Groups.build_spells = ParseBool(v, Config.Groups.build_spells)
            elseif k == "CenterPauseMenu" then Config.Groups.pause_menu = ParseBool(v, Config.Groups.pause_menu)
            elseif k == "EnableDebugHotkeys" then Config.EnableDebugHotkeys = ParseBool(v, Config.EnableDebugHotkeys)
            elseif k == "ShowDebugBanner" then Config.ShowDebugBanner = ParseBool(v, Config.ShowDebugBanner)
            end
        end
    end
    f:close()
end

local function SaveKvConfig()
    local f = io.open(CONFIG_TXT_PATH, "w")
    if not f then return false end
    f:write(string.format(
        "Enabled=%d\nMinX=%.2f\nMaxX=%.2f\nOffsetX=%d\nCenterInventory=%d\nCenterContainers=%d\nCenterStations=%d\nCenterBuildSpells=%d\nCenterPauseMenu=%d\nEnableDebugHotkeys=%d\nShowDebugBanner=%d\n",
        Config.Enabled and 1 or 0,
        Config.MinX,
        Config.MaxX,
        Config.OffsetX,
        Config.Groups.inventory and 1 or 0,
        Config.Groups.containers and 1 or 0,
        Config.Groups.stations and 1 or 0,
        Config.Groups.build_spells and 1 or 0,
        Config.Groups.pause_menu and 1 or 0,
        Config.EnableDebugHotkeys and 1 or 0,
        Config.ShowDebugBanner and 1 or 0
    ))
    f:close()
    return true
end

ReloadKvConfig()

local function GetSafeFullName(obj)
    if not obj then return "" end
    local ok, res = pcall(function() return obj:GetFullName() end)
    return (ok and type(res) == "string") and res or ""
end

local function GetSafeClassName(obj)
    if not obj then return "" end
    local ok, cls = pcall(function() return obj:GetClass() end)
    if ok and cls then
        local ok2, fname = pcall(function() return cls:GetFName():ToString() end)
        if ok2 and type(fname) == "string" then return fname end
    end
    local full = GetSafeFullName(obj)
    return full:match("^([^%s]+)") or ""
end

local function IsInViewportSafe(w)
    local ok, res = pcall(function() return w:IsInViewport() end)
    return ok and (res == true)
end

local CachedPanels = {}
local WorldReady = false

local function ApplySafeZoneToWidget(w, className, meta)
    if not w or not meta or not Config.Enabled or not Config.Groups[meta.group] then
        return false
    end
    local fullName = GetSafeFullName(w)
    if fullName == "" or fullName:find("Default__", 1, true) or fullName:find("/Game/", 1, true) then
        return false
    end

    local applied = false
    if IsInViewportSafe(w) then
        local okVp = pcall(function()
            w:SetAnchorsInViewport({
                Minimum = { X = Config.MinX, Y = 0.0 },
                Maximum = { X = Config.MaxX, Y = 1.0 }
            })
        end)
        if okVp then applied = true end
    else
        local okSlot = pcall(function()
            local slot = w.Slot
            if slot and slot.SetAnchors then
                slot:SetAnchors({
                    Minimum = { X = Config.MinX, Y = 0.0 },
                    Maximum = { X = Config.MaxX, Y = 1.0 }
                })
                if slot.SetOffsets then
                    slot:SetOffsets({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                end
                applied = true
            end
        end)
        if not okSlot then applied = false end
    end

    pcall(function()
        w:SetRenderTranslation({ X = tonumber(Config.OffsetX) or 0.0, Y = 0.0 })
    end)
    return applied
end

local function TrackAndApply(w)
    if not WorldReady or not w then return end
    local fullName = GetSafeFullName(w)
    if fullName == "" or fullName:find("Default__", 1, true) or fullName:find("/Game/", 1, true) then
        return
    end
    local className = GetSafeClassName(w)
    local meta = Config.TargetPanels[className]
    if not meta then return end
    CachedPanels[fullName] = { widget = w, className = className, meta = meta }
    ReloadKvConfig()
    ApplySafeZoneToWidget(w, className, meta)
end

local function DiscoverTargetPanels()
    if not WorldReady then return 0 end
    local all = FindAllOf("UserWidget")
    local found = 0
    if all then
        for i = 1, #all do
            local w = all[i]
            if w then
                local fullName = GetSafeFullName(w)
                if fullName ~= "" and not fullName:find("Default__", 1, true) and not fullName:find("/Game/", 1, true) then
                    local className = GetSafeClassName(w)
                    local meta = Config.TargetPanels[className]
                    if meta then
                        CachedPanels[fullName] = { widget = w, className = className, meta = meta }
                        found = found + 1
                    end
                end
            end
        end
    end
    return found
end

local function ReapplyAllCached(doDiscovery)
    ReloadKvConfig()
    if doDiscovery then
        DiscoverTargetPanels()
    end
    local count = 0
    for key, entry in pairs(CachedPanels) do
        if GetSafeFullName(entry.widget) ~= "" then
            if ApplySafeZoneToWidget(entry.widget, entry.className, entry.meta) then
                count = count + 1
            end
        else
            CachedPanels[key] = nil
        end
    end
    return count
end

local function ScheduleWorldSpawnInit()
    WorldReady = true
    local delays = { 500, 1500, 3500, 6500 }
    for _, ms in ipairs(delays) do
        ExecuteWithDelay(ms, function()
            ExecuteInGameThread(function()
                ReapplyAllCached(true)
            end)
        end)
    end
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    ScheduleWorldSpawnInit()
end)

RegisterHook("/Script/UMG.UserWidget:Construct", function(Context)
    if not WorldReady then return end
    local w = Context:get()
    if w then
        ExecuteInGameThread(function() TrackAndApply(w) end)
    end
end)

RegisterHook("/Script/UMG.UserWidget:AddToViewport", function(Context)
    if not WorldReady then return end
    local w = Context:get()
    if w then
        ExecuteInGameThread(function() TrackAndApply(w) end)
    end
end)

LoopAsync(400, function()
    if not WorldReady then return false end
    ExecuteInGameThread(function()
        local hasAny = false
        for _ in pairs(CachedPanels) do
            hasAny = true
            break
        end
        if not hasAny then
            DiscoverTargetPanels()
        end
        ReloadKvConfig()
        if not Config.Enabled then return end
        for key, entry in pairs(CachedPanels) do
            if GetSafeFullName(entry.widget) ~= "" then
                local vis = -1
                pcall(function() vis = entry.widget:GetVisibility() end)
                if vis == 0 or vis == 4 then
                    ApplySafeZoneToWidget(entry.widget, entry.className, entry.meta)
                end
            else
                CachedPanels[key] = nil
            end
        end
    end)
    return false
end)

local LastSnapshotState = {}

local function ShouldIgnoreInSnapshot(fullName, className)
    if fullName == "" or fullName:find("/Game/", 1, true) then return true end
    for _, sub in ipairs(Config.SnapshotIgnoreSubstrings) do
        if fullName:find(sub, 1, true) or className:find(sub, 1, true) then return true end
    end
    return false
end

local function RunDiffSnapshot()
    os.execute('mkdir "' .. SNAPSHOTS_DIR:gsub("\\$", "") .. '" >nul 2>&1')
    local tsFile = os.date("%Y-%m-%d_%H-%M-%S")
    local tsHuman = os.date("%Y-%m-%d %H:%M:%S")
    local all = FindAllOf("UserWidget")
    local totalScanned = all and #all or 0
    local inspected = 0
    local shortLines = {
        "==========================================",
        "[" .. MOD_NAME .. "] COMPACT DIFF SNAPSHOT (v" .. VERSION .. ")",
        "Timestamp: " .. tsHuman,
        "=========================================="
    }
    local fullLines = {
        "==========================================",
        "[" .. MOD_NAME .. "] FULL FILTERED SNAPSHOT (v" .. VERSION .. ")",
        "Timestamp: " .. tsHuman,
        "=========================================="
    }
    local currentState = {}

    if all then
        for i = 1, totalScanned do
            local w = all[i]
            if w then
                local fullName = GetSafeFullName(w)
                local className = GetSafeClassName(w)
                if not ShouldIgnoreInSnapshot(fullName, className) then
                    local inVp = IsInViewportSafe(w)
                    local isTarget = (Config.TargetPanels[className] ~= nil)
                    if inVp or isTarget then
                        inspected = inspected + 1
                        local vis = -1
                        pcall(function() vis = w:GetVisibility() end)
                        local slotInfo = "None"
                        pcall(function()
                            local slot = w.Slot
                            if slot then
                                local sClass = GetSafeClassName(slot)
                                slotInfo = sClass
                                if slot.GetAnchors then
                                    local a = slot:GetAnchors()
                                    if a and a.Minimum and a.Maximum then
                                        slotInfo = string.format("%s Anchors=(%.2f,%.2f)-(%.2f,%.2f)", sClass, a.Minimum.X, a.Minimum.Y, a.Maximum.X, a.Maximum.Y)
                                    end
                                end
                            end
                        end)
                        local objShort = fullName:match("%.([^%.]+)$") or className
                        local sig = string.format("vis=%s|inVp=%s|slot=%s", tostring(vis), tostring(inVp), slotInfo)
                        currentState[fullName] = sig
                        local tag = (LastSnapshotState[fullName] ~= sig) and "[NEW/CHANGED]" or "[UNCHANGED]"
                        local line = string.format("  %s %s [%s] vis=%s | InVp=%s | Slot=%s", tag, className, objShort, tostring(vis), tostring(inVp), slotInfo)
                        table.insert(fullLines, line)
                        if tag == "[NEW/CHANGED]" or isTarget then
                            table.insert(shortLines, line)
                        end
                    end
                end
            end
        end
    end

    LastSnapshotState = currentState
    local footer = string.format("Total Scanned: %d | Live Viewport/MainPanel Inspected: %d", totalScanned, inspected)
    for _, tbl in ipairs({ shortLines, fullLines }) do
        table.insert(tbl, "------------------------------------------")
        table.insert(tbl, footer)
        table.insert(tbl, "==========================================")
    end

    local shortPath = SNAPSHOTS_DIR .. "snapshot_short_" .. tsFile .. ".txt"
    local fullPath = SNAPSHOTS_DIR .. "snapshot_" .. tsFile .. ".txt"
    local fShort = io.open(shortPath, "w")
    if fShort then
        fShort:write(table.concat(shortLines, "\n") .. "\n")
        fShort:close()
        Log("Short (SAVED): " .. shortPath)
    else
        Log("Short (FAILED): " .. shortPath)
    end
    local fFull = io.open(fullPath, "w")
    if fFull then
        fFull:write(table.concat(fullLines, "\n") .. "\n")
        fFull:close()
        Log("Full (SAVED): " .. fullPath)
    else
        Log("Full (FAILED): " .. fullPath)
    end
    for _, l in ipairs(shortLines) do
        Log(l)
    end
end

local function IsDebugAllowed()
    ReloadKvConfig()
    return Config.EnableDebugHotkeys == true
end

local function BindShiftDebugKey(keyEnum, actionName, fn)
    RegisterKeyBind(keyEnum, { ModifierKey.SHIFT }, function()
        if not IsDebugAllowed() then return end
        ExecuteInGameThread(function()
            Log("Debug hotkey: " .. actionName)
            fn()
        end)
    end)
end

BindShiftDebugKey(Key.F7, "Shift+F7 (Snapshot)", RunDiffSnapshot)
BindShiftDebugKey(Key.NUM_SEVEN, "Shift+NumPad7 (Snapshot)", RunDiffSnapshot)
BindShiftDebugKey(Key.F8, "Shift+F8 (Force Apply)", function()
    WorldReady = true
    local c = ReapplyAllCached(true)
    Log(string.format("Force-applied (MinX=%.2f, MaxX=%.2f, OffsetX=%d) to %d panels.", Config.MinX, Config.MaxX, Config.OffsetX, c))
end)
BindShiftDebugKey(Key.NUM_EIGHT, "Shift+NumPad8 (Force Apply)", function()
    WorldReady = true
    local c = ReapplyAllCached(true)
    Log(string.format("Force-applied (MinX=%.2f, MaxX=%.2f, OffsetX=%d) to %d panels.", Config.MinX, Config.MaxX, Config.OffsetX, c))
end)
BindShiftDebugKey(Key.F9, "Shift+F9 (Toggle Banner)", function()
    ReloadKvConfig()
    Config.ShowDebugBanner = not Config.ShowDebugBanner
    SaveKvConfig()
    Log("ShowDebugBanner -> " .. tostring(Config.ShowDebugBanner))
end)
BindShiftDebugKey(Key.ADD, "Shift+NumPad+ (+40px)", function()
    ReloadKvConfig()
    Config.OffsetX = Config.OffsetX + 40
    SaveKvConfig()
    Log("OffsetX -> " .. Config.OffsetX .. "px (" .. ReapplyAllCached(false) .. " panels)")
end)
BindShiftDebugKey(Key.SUBTRACT, "Shift+NumPad- (-40px)", function()
    ReloadKvConfig()
    Config.OffsetX = Config.OffsetX - 40
    SaveKvConfig()
    Log("OffsetX -> " .. Config.OffsetX .. "px (" .. ReapplyAllCached(false) .. " panels)")
end)

Log(string.format("v%s initialized cleanly (Dir: %s | DebugHotkeys=%s)", VERSION, MOD_DIR, tostring(Config.EnableDebugHotkeys)))
