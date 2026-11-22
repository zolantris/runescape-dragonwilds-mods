local MOD_NAME = "ResizeAndDragWindow"
local VERSION = "0.1.0-alpha"

local function Log(msg)
    print(string.format("[%s] %s", MOD_NAME, tostring(msg)))
end

local function ResolveModDir()
    local info = debug.getinfo(1, "S")
    local src = info and info.source or ""
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    src = src:gsub("/", "\\")
    local scriptsDir = src:match("^(.*\\)[^\\]+$")
    if scriptsDir then
        local modDir = scriptsDir:match("^(.*\\)Scripts\\?$")
        if modDir then return modDir end
    end
    return "C:\\steam\\steamapps\\common\\RSDragonwilds\\RSDragonwilds\\Binaries\\Win64\\ue4ss\\Mods\\ResizeAndDragWindow\\"
end

local MOD_DIR = ResolveModDir()
local SCRIPTS_DIR = MOD_DIR .. "Scripts\\"
local CONFIG_TXT_PATH = MOD_DIR .. "config.txt"
local LAYOUTS_PATH = MOD_DIR .. "panel_layouts.lua"

local Config = {
    Enabled = true,
    EnableMouseDrag = true,
    EnableKeyboardMove = true,
    EnableScaling = true,
    DragSensitivity = 1.0,
    KeyboardStepPx = 20,
    ScaleStep = 0.05,
    MinScale = 0.50,
    MaxScale = 1.75,
    Groups = { inventory = true, containers = true, stations = true, build_spells = true, pause_menu = true },
    TargetPanels = {},
}

do
    local ok, loaded = pcall(dofile, SCRIPTS_DIR .. "config.lua")
    if ok and type(loaded) == "table" then
        for k, v in pairs(loaded) do Config[k] = v end
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
            elseif k == "EnableMouseDrag" then Config.EnableMouseDrag = ParseBool(v, Config.EnableMouseDrag)
            elseif k == "EnableKeyboardMove" then Config.EnableKeyboardMove = ParseBool(v, Config.EnableKeyboardMove)
            elseif k == "EnableScaling" then Config.EnableScaling = ParseBool(v, Config.EnableScaling)
            elseif k == "DragSensitivity" then Config.DragSensitivity = tonumber(v) or Config.DragSensitivity
            elseif k == "KeyboardStepPx" then Config.KeyboardStepPx = math.floor(tonumber(v) or Config.KeyboardStepPx)
            elseif k == "ScaleStep" then Config.ScaleStep = tonumber(v) or Config.ScaleStep
            elseif k == "MinScale" then Config.MinScale = tonumber(v) or Config.MinScale
            elseif k == "MaxScale" then Config.MaxScale = tonumber(v) or Config.MaxScale
            elseif k == "EnableInventory" then Config.Groups.inventory = ParseBool(v, Config.Groups.inventory)
            elseif k == "EnableContainers" then Config.Groups.containers = ParseBool(v, Config.Groups.containers)
            elseif k == "EnableStations" then Config.Groups.stations = ParseBool(v, Config.Groups.stations)
            elseif k == "EnableBuildSpells" then Config.Groups.build_spells = ParseBool(v, Config.Groups.build_spells)
            elseif k == "EnablePauseMenu" then Config.Groups.pause_menu = ParseBool(v, Config.Groups.pause_menu)
            end
        end
    end
    f:close()
end

local PanelLayouts = {}

local function LoadLayouts()
    local ok, loaded = pcall(dofile, LAYOUTS_PATH)
    if ok and type(loaded) == "table" then
        PanelLayouts = loaded
    end
end

local function SaveLayouts()
    local f = io.open(LAYOUTS_PATH, "w")
    if not f then return false end
    f:write("return {\n")
    local keys = {}
    for k in pairs(PanelLayouts) do table.insert(keys, k) end
    table.sort(keys)
    for _, cls in ipairs(keys) do
        local d = PanelLayouts[cls]
        if type(d) == "table" then
            f:write(string.format("    [%q] = { x = %.2f, y = %.2f, scale = %.3f },\n",
                cls, tonumber(d.x) or 0.0, tonumber(d.y) or 0.0, tonumber(d.scale) or 1.0))
        end
    end
    f:write("}\n")
    f:close()
    return true
end

ReloadKvConfig()
LoadLayouts()

local function GetOrCreateLayout(className)
    if not PanelLayouts[className] then
        PanelLayouts[className] = { x = 0.0, y = 0.0, scale = 1.0 }
    end
    return PanelLayouts[className]
end

local function Clamp(val, minV, maxV)
    if val < minV then return minV end
    if val > maxV then return maxV end
    return val
end

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

local CachedPanels = {}
local WorldSpawned = false

local function IsWidgetVisible(w)
    local vis = -1
    local ok = pcall(function() vis = w:GetVisibility() end)
    if not ok then return false end
    return (vis == 0 or vis == 4)
end

local function ApplyTransformToWidget(w, className, meta)
    if not w or not meta then return false end
    local fullName = GetSafeFullName(w)
    if fullName == "" or fullName:find("Default__", 1, true) or fullName:find("/Game/", 1, true) then return false end

    if not Config.Enabled or not Config.Groups[meta.group] then
        pcall(function()
            w:SetRenderTranslation({ X = 0.0, Y = 0.0 })
            w:SetRenderScale({ X = 1.0, Y = 1.0 })
        end)
        return false
    end

    local layout = PanelLayouts[className]
    local tx = layout and (tonumber(layout.x) or 0.0) or 0.0
    local ty = layout and (tonumber(layout.y) or 0.0) or 0.0
    local sc = layout and Clamp(tonumber(layout.scale) or 1.0, Config.MinScale, Config.MaxScale) or 1.0

    local ok = pcall(function()
        w:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
        w:SetRenderTranslation({ X = tx, Y = ty })
        w:SetRenderScale({ X = sc, Y = sc })
    end)
    return ok
end

local function DiscoverPanels()
    local all = FindAllOf("UserWidget")
    if not all then return end
    for i = 1, #all do
        local w = all[i]
        if w then
            local fullName = GetSafeFullName(w)
            if fullName ~= "" and not fullName:find("Default__", 1, true) and not fullName:find("/Game/", 1, true) then
                local className = GetSafeClassName(w)
                local meta = Config.TargetPanels[className]
                if meta then
                    CachedPanels[fullName] = { widget = w, className = className, meta = meta }
                    ApplyTransformToWidget(w, className, meta)
                end
            end
        end
    end
end

local function GetTopActivePanel()
    local priority = {
        WBP_InGameScreensRoot_C = 1,
        WBP_WorldActorInventory_MainPanel_C = 2,
        WBP_Crafting_MainPanel_C = 3,
        WBP_ProcessingStation_MainPanel_C = 4,
        WBP_Composter_MainPanel_C = 5,
        WBP_Enchanting_MainPanel_C = 6,
        WBP_Building_MainPanel_C = 7,
        WBP_Spellcasting_MainPanel_C = 8,
        WBP_Inventory_MainPanel_C = 9,
    }
    local bestEntry = nil
    local bestScore = 999
    for key, entry in pairs(CachedPanels) do
        if GetSafeFullName(entry.widget) ~= "" then
            if Config.Groups[entry.meta.group] and IsWidgetVisible(entry.widget) then
                local score = priority[entry.className] or 50
                if score < bestScore then
                    bestScore = score
                    bestEntry = entry
                end
            end
        else
            CachedPanels[key] = nil
        end
    end
    return bestEntry
end

RegisterHook("/Script/UMG.UserWidget:Construct", function(Context)
    local w = Context:get()
    if w then
        ExecuteInGameThread(function()
            local fullName = GetSafeFullName(w)
            if fullName == "" or fullName:find("Default__", 1, true) or fullName:find("/Game/", 1, true) then return end
            local className = GetSafeClassName(w)
            local meta = Config.TargetPanels[className]
            if meta then
                CachedPanels[fullName] = { widget = w, className = className, meta = meta }
                ReloadKvConfig()
                ApplyTransformToWidget(w, className, meta)
            end
        end)
    end
end)

local function OnWorldEntered()
    if WorldSpawned then return end
    WorldSpawned = true
    ExecuteWithDelay(1000, function() ExecuteInGameThread(DiscoverPanels) end)
    ExecuteWithDelay(3000, function() ExecuteInGameThread(DiscoverPanels) end)
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    OnWorldEntered()
end)

local IsDragging = false
local LastMouseX = 0.0
local LastMouseY = 0.0
local DragMoved = false

local function GetPlayerController()
    local pcs = FindAllOf("PlayerController")
    if pcs and #pcs > 0 then
        return pcs[1]
    end
    return nil
end

LoopAsync(35, function()
    if not WorldSpawned then return false end
    ExecuteInGameThread(function()
        ReloadKvConfig()
        if not Config.Enabled then return end

        local hasAny = false
        for key, entry in pairs(CachedPanels) do
            hasAny = true
            if GetSafeFullName(entry.widget) ~= "" then
                if IsWidgetVisible(entry.widget) then
                    ApplyTransformToWidget(entry.widget, entry.className, entry.meta)
                end
            else
                CachedPanels[key] = nil
            end
        end
        if not hasAny then
            DiscoverPanels()
        end

        if not Config.EnableMouseDrag then
            IsDragging = false
            return
        end

        local pc = GetPlayerController()
        if not pc then return end

        local okDown, mDown = pcall(function()
            return pc:IsInputKeyDown({ KeyName = FName("MiddleMouseButton") })
        end)
        local okMouse, mx, my = pcall(function()
            return pc:GetMousePosition()
        end)

        if okDown and mDown and okMouse and mx and my then
            local active = GetTopActivePanel()
            if active then
                if not IsDragging then
                    IsDragging = true
                    DragMoved = false
                    LastMouseX = mx
                    LastMouseY = my
                else
                    local dx = (mx - LastMouseX) * Config.DragSensitivity
                    local dy = (my - LastMouseY) * Config.DragSensitivity
                    if math.abs(dx) > 0.1 or math.abs(dy) > 0.1 then
                        local layout = GetOrCreateLayout(active.className)
                        layout.x = layout.x + dx
                        layout.y = layout.y + dy
                        ApplyTransformToWidget(active.widget, active.className, active.meta)
                        DragMoved = true
                        LastMouseX = mx
                        LastMouseY = my
                    end
                end
            end
        else
            if IsDragging then
                IsDragging = false
                if DragMoved then
                    SaveLayouts()
                    DragMoved = false
                end
            end
        end
    end)
    return false
end)

local function NudgeActivePanel(dxSign, dySign)
    ReloadKvConfig()
    if not Config.Enabled or not Config.EnableKeyboardMove then return end
    local active = GetTopActivePanel()
    if not active then return end
    local layout = GetOrCreateLayout(active.className)
    layout.x = layout.x + (dxSign * Config.KeyboardStepPx)
    layout.y = layout.y + (dySign * Config.KeyboardStepPx)
    ApplyTransformToWidget(active.widget, active.className, active.meta)
    SaveLayouts()
end

RegisterKeyBind(Key.LEFT_ARROW, { ModifierKey.ALT }, function() ExecuteInGameThread(function() NudgeActivePanel(-1, 0) end) end)
RegisterKeyBind(Key.RIGHT_ARROW, { ModifierKey.ALT }, function() ExecuteInGameThread(function() NudgeActivePanel(1, 0) end) end)
RegisterKeyBind(Key.UP_ARROW, { ModifierKey.ALT }, function() ExecuteInGameThread(function() NudgeActivePanel(0, -1) end) end)
RegisterKeyBind(Key.DOWN_ARROW, { ModifierKey.ALT }, function() ExecuteInGameThread(function() NudgeActivePanel(0, 1) end) end)

local function ScaleActivePanel(deltaSign)
    ReloadKvConfig()
    if not Config.Enabled or not Config.EnableScaling then return end
    local active = GetTopActivePanel()
    if not active then return end
    local layout = GetOrCreateLayout(active.className)
    layout.scale = Clamp((tonumber(layout.scale) or 1.0) + (deltaSign * Config.ScaleStep), Config.MinScale, Config.MaxScale)
    ApplyTransformToWidget(active.widget, active.className, active.meta)
    SaveLayouts()
end

RegisterKeyBind(Key.MOUSE_SCROLL_UP, { ModifierKey.ALT }, function() ExecuteInGameThread(function() ScaleActivePanel(1) end) end)
RegisterKeyBind(Key.MOUSE_SCROLL_DOWN, { ModifierKey.ALT }, function() ExecuteInGameThread(function() ScaleActivePanel(-1) end) end)
RegisterKeyBind(Key.ADD, { ModifierKey.ALT }, function() ExecuteInGameThread(function() ScaleActivePanel(1) end) end)
RegisterKeyBind(Key.SUBTRACT, { ModifierKey.ALT }, function() ExecuteInGameThread(function() ScaleActivePanel(-1) end) end)

local function ResetActivePanel()
    ReloadKvConfig()
    if not Config.Enabled then return end
    local active = GetTopActivePanel()
    if not active then return end
    PanelLayouts[active.className] = { x = 0.0, y = 0.0, scale = 1.0 }
    ApplyTransformToWidget(active.widget, active.className, active.meta)
    SaveLayouts()
    Log(string.format("Reset layout for %s (%s)", active.meta.label, active.className))
end

RegisterKeyBind(Key.BACKSPACE, { ModifierKey.ALT }, function() ExecuteInGameThread(ResetActivePanel) end)
RegisterKeyBind(Key.NUM_ZERO, { ModifierKey.ALT }, function() ExecuteInGameThread(ResetActivePanel) end)

Log(string.format("v%s initialized cleanly (Dir: %s)", VERSION, MOD_DIR))
