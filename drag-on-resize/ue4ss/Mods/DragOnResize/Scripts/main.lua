local MOD_NAME = "DragOnResize"
local VERSION = "0.3.3"

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
    return "C:\\steam\\steamapps\\common\\RSDragonwilds\\RSDragonwilds\\Binaries\\Win64\\ue4ss\\Mods\\DragOnResize\\"
end

local MOD_DIR = ResolveModDir()
local SCRIPTS_DIR = MOD_DIR .. "Scripts\\"
local EXTENSIONS_DIR = MOD_DIR .. "extensions\\"
local CONFIG_TXT_PATH = MOD_DIR .. "config.txt"
local LAYOUTS_PATH = MOD_DIR .. "panel_layouts.lua"
local DEBUG_LOG_PATH = MOD_DIR .. "drag_on_resize_debug.log"

local Config = {
    Enabled = true,
    EnableMouseDrag = true,
    EnableKeyboardMove = true,
    EnableScaling = true,
    ClampToViewport = true,
    ClampEdgePaddingPx = 8,
    SafeZoneMinX = 0.00,
    SafeZoneMaxX = 1.00,
    SafeZoneMinY = 0.00,
    SafeZoneMaxY = 1.00,
    DragSensitivity = 1.0,
    MouseScaleSensitivity = 0.0025,
    KeyboardStepPx = 20,
    RepeatIntervalMs = 50,
    ScaleStep = 0.05,
    MinScale = 0.50,
    MaxScale = 1.75,
    VerboseLog = true,
    Groups = {
        inventory = true,
        containers = true,
        stations = true,
        build_spells = true,
        pause_menu = true,
    },
    TargetPanels = {},
    PanelOverrides = {},
    BlockedPanels = {
        WBP_HUD_RootWidget_C = true,
    },
}

local function Log(msg)
    local line = string.format("[%s] %s", MOD_NAME, tostring(msg))
    print(line)
    if Config.VerboseLog then
        local f = io.open(DEBUG_LOG_PATH, "a")
        if f then
            f:write(os.date("[%H:%M:%S] ") .. line .. "\n")
            f:close()
        end
    end
end

local function Diag(msg)
    if Config.VerboseLog then
        Log("[DIAG] " .. tostring(msg))
    end
end

do
    local ok, loaded = pcall(dofile, SCRIPTS_DIR .. "config.lua")
    if ok and type(loaded) == "table" then
        for k, v in pairs(loaded) do
            Config[k] = v
        end
    end
end

local function RegisterExternalPanel(modId, className, opts)
    if type(className) ~= "string" or className == "" then return false end
    if Config.BlockedPanels and Config.BlockedPanels[className] then
        Log(string.format("Rejected blocked panel %s from %s", className, tostring(modId)))
        return false
    end
    opts = type(opts) == "table" and opts or {}
    Config.TargetPanels[className] = {
        group = opts.group or "containers",
        label = opts.label or className,
        priority = tonumber(opts.priority) or 5,
        allowDrag = (opts.allowDrag ~= false),
        allowScale = (opts.allowScale ~= false),
        estW = tonumber(opts.estW) or 540,
        estH = tonumber(opts.estH) or 720,
        sourceMod = tostring(modId or "external"),
    }
    if opts.minScale or opts.maxScale or opts.defaultX or opts.defaultY then
        Config.PanelOverrides[className] = Config.PanelOverrides[className] or {}
        if opts.minScale then Config.PanelOverrides[className].minScale = opts.minScale end
        if opts.maxScale then Config.PanelOverrides[className].maxScale = opts.maxScale end
        if opts.defaultX then Config.PanelOverrides[className].defaultX = opts.defaultX end
        if opts.defaultY then Config.PanelOverrides[className].defaultY = opts.defaultY end
    end
    Diag(string.format("Registered external panel %s (mod=%s)", className, tostring(modId)))
    return true
end

_G.DragOnResize = _G.DragOnResize or {}
_G.DragOnResize.RegisterPanel = RegisterExternalPanel
_G.ResizeAndDragWindow = _G.DragOnResize

if type(_G.ResizeAndDragWindowPending) == "table" then
    for _, item in ipairs(_G.ResizeAndDragWindowPending) do
        if type(item) == "table" then
            RegisterExternalPanel(item.modId, item.className, item.opts)
        end
    end
    _G.ResizeAndDragWindowPending = nil
end

local function ParseBool(val, defaultVal)
    if val == nil then return defaultVal end
    local s = tostring(val):lower():gsub("%s+", "")
    if s == "1" or s == "true" or s == "yes" or s == "on" then return true end
    if s == "0" or s == "false" or s == "no" or s == "off" then return false end
    return defaultVal
end

local PanelLayouts = {}
local PendingGlobalReset = false
local LayoutDirty = false
local LastDirtyTime = 0.0

local function LoadLayouts()
    local ok, loaded = pcall(dofile, LAYOUTS_PATH)
    PanelLayouts = (ok and type(loaded) == "table") and loaded or {}
end

local function SaveLayoutsNow()
    local f = io.open(LAYOUTS_PATH, "w")
    if not f then return false end
    f:write("return {\n")
    local keys = {}
    for k in pairs(PanelLayouts) do table.insert(keys, k) end
    table.sort(keys)
    for _, cls in ipairs(keys) do
        local d = PanelLayouts[cls]
        if type(d) == "table" then
            f:write(string.format(
                "    [%q] = { x = %.2f, y = %.2f, scale = %.3f },\n",
                cls,
                tonumber(d.x) or 0.0,
                tonumber(d.y) or 0.0,
                tonumber(d.scale) or 1.0
            ))
        end
    end
    f:write("}\n")
    f:close()
    LayoutDirty = false
    return true
end

local function MarkLayoutsDirty()
    LayoutDirty = true
    LastDirtyTime = os.clock()
end

local function SaveKvConfig()
    local f = io.open(CONFIG_TXT_PATH, "w")
    if not f then return false end
    f:write(string.format(
        "Enabled=%d\nEnableMouseDrag=%d\nEnableKeyboardMove=%d\nEnableScaling=%d\nClampToViewport=%d\nClampEdgePaddingPx=%d\nSafeZoneMinX=%.2f\nSafeZoneMaxX=%.2f\nSafeZoneMinY=%.2f\nSafeZoneMaxY=%.2f\nDragSensitivity=%.2f\nMouseScaleSensitivity=%.4f\nKeyboardStepPx=%d\nRepeatIntervalMs=%d\nScaleStep=%.2f\nMinScale=%.2f\nMaxScale=%.2f\nEnableInventory=%d\nEnableContainers=%d\nEnableStations=%d\nEnableBuildSpells=%d\nEnablePauseMenu=%d\nResetAllLayouts=0\nVerboseLog=%d\n",
        Config.Enabled and 1 or 0,
        Config.EnableMouseDrag and 1 or 0,
        Config.EnableKeyboardMove and 1 or 0,
        Config.EnableScaling and 1 or 0,
        Config.ClampToViewport and 1 or 0,
        Config.ClampEdgePaddingPx,
        Config.SafeZoneMinX,
        Config.SafeZoneMaxX,
        Config.SafeZoneMinY,
        Config.SafeZoneMaxY,
        Config.DragSensitivity,
        Config.MouseScaleSensitivity,
        Config.KeyboardStepPx,
        Config.RepeatIntervalMs,
        Config.ScaleStep,
        Config.MinScale,
        Config.MaxScale,
        Config.Groups.inventory and 1 or 0,
        Config.Groups.containers and 1 or 0,
        Config.Groups.stations and 1 or 0,
        Config.Groups.build_spells and 1 or 0,
        Config.Groups.pause_menu and 1 or 0,
        Config.VerboseLog and 1 or 0
    ))
    f:close()
    return true
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
            elseif k == "ClampToViewport" then Config.ClampToViewport = ParseBool(v, Config.ClampToViewport)
            elseif k == "ClampEdgePaddingPx" then Config.ClampEdgePaddingPx = math.max(0, math.floor(tonumber(v) or Config.ClampEdgePaddingPx))
            elseif k == "SafeZoneMinX" then Config.SafeZoneMinX = tonumber(v) or Config.SafeZoneMinX
            elseif k == "SafeZoneMaxX" then Config.SafeZoneMaxX = tonumber(v) or Config.SafeZoneMaxX
            elseif k == "SafeZoneMinY" then Config.SafeZoneMinY = tonumber(v) or Config.SafeZoneMinY
            elseif k == "SafeZoneMaxY" then Config.SafeZoneMaxY = tonumber(v) or Config.SafeZoneMaxY
            elseif k == "DragSensitivity" then Config.DragSensitivity = tonumber(v) or Config.DragSensitivity
            elseif k == "MouseScaleSensitivity" then Config.MouseScaleSensitivity = tonumber(v) or Config.MouseScaleSensitivity
            elseif k == "KeyboardStepPx" then Config.KeyboardStepPx = math.floor(tonumber(v) or Config.KeyboardStepPx)
            elseif k == "RepeatIntervalMs" then Config.RepeatIntervalMs = math.max(20, math.floor(tonumber(v) or Config.RepeatIntervalMs))
            elseif k == "ScaleStep" then Config.ScaleStep = tonumber(v) or Config.ScaleStep
            elseif k == "MinScale" then Config.MinScale = tonumber(v) or Config.MinScale
            elseif k == "MaxScale" then Config.MaxScale = tonumber(v) or Config.MaxScale
            elseif k == "EnableInventory" then Config.Groups.inventory = ParseBool(v, Config.Groups.inventory)
            elseif k == "EnableContainers" then Config.Groups.containers = ParseBool(v, Config.Groups.containers)
            elseif k == "EnableStations" then Config.Groups.stations = ParseBool(v, Config.Groups.stations)
            elseif k == "EnableBuildSpells" then Config.Groups.build_spells = ParseBool(v, Config.Groups.build_spells)
            elseif k == "EnablePauseMenu" then Config.Groups.pause_menu = ParseBool(v, Config.Groups.pause_menu)
            elseif k == "VerboseLog" then Config.VerboseLog = ParseBool(v, Config.VerboseLog)
            elseif k == "ResetAllLayouts" and ParseBool(v, false) then
                PendingGlobalReset = true
            end
        end
    end
    f:close()
end

ReloadKvConfig()
LoadLayouts()

local function Clamp(val, minV, maxV)
    if val < minV then return minV end
    if val > maxV then return maxV end
    return val
end

local function IsObjValid(obj)
    if not obj then return false end
    local ok, res = pcall(function() return obj:IsValid() end)
    return ok and (res == true)
end

local function GetSafeFullName(obj)
    if not IsObjValid(obj) then return "" end
    local ok, res = pcall(function() return obj:GetFullName() end)
    return (ok and type(res) == "string") and res or ""
end

local function GetSafeClassName(obj)
    if not IsObjValid(obj) then return "" end
    local ok, cls = pcall(function() return obj:GetClass() end)
    if ok and IsObjValid(cls) then
        local ok2, fname = pcall(function() return cls:GetFName():ToString() end)
        if ok2 and type(fname) == "string" then return fname end
    end
    local full = GetSafeFullName(obj)
    return full:match("^([^%s]+)") or ""
end

local function IsWidgetVisible(w)
    if not IsObjValid(w) then return false end
    local vis = -1
    local ok = pcall(function() vis = w:GetVisibility() end)
    if not ok then return false end
    return (vis == 0 or vis == 4)
end

local function IsInViewportSafe(w)
    if not IsObjValid(w) then return false end
    local ok, res = pcall(function() return w:IsInViewport() end)
    return ok and (res == true)
end

local function GetPanelScaleBounds(className)
    local minS = tonumber(Config.MinScale) or 0.50
    local maxS = tonumber(Config.MaxScale) or 1.75
    local ov = Config.PanelOverrides and Config.PanelOverrides[className]
    if ov then
        if ov.minScale then minS = tonumber(ov.minScale) or minS end
        if ov.maxScale then maxS = tonumber(ov.maxScale) or maxS end
    end
    if minS > maxS then minS, maxS = maxS, minS end
    return minS, maxS
end

local function IsPanelAllowed(className, meta)
    if not Config.Enabled or not meta then return false end
    if Config.Groups[meta.group] == false then return false end
    local ov = Config.PanelOverrides and Config.PanelOverrides[className]
    if ov and ov.enabled == false then return false end
    return true
end

local function CanDragPanel(className, meta)
    if not IsPanelAllowed(className, meta) or not Config.EnableMouseDrag then return false end
    local ov = Config.PanelOverrides and Config.PanelOverrides[className]
    if ov and ov.allowDrag ~= nil then return ov.allowDrag == true end
    return meta.allowDrag ~= false
end

local function CanKeyboardMovePanel(className, meta)
    if not IsPanelAllowed(className, meta) or not Config.EnableKeyboardMove then return false end
    local ov = Config.PanelOverrides and Config.PanelOverrides[className]
    if ov and ov.allowDrag ~= nil then return ov.allowDrag == true end
    return meta.allowDrag ~= false
end

local function CanScalePanel(className, meta)
    if not IsPanelAllowed(className, meta) or not Config.EnableScaling then return false end
    local ov = Config.PanelOverrides and Config.PanelOverrides[className]
    if ov and ov.allowScale ~= nil then return ov.allowScale == true end
    return meta.allowScale ~= false
end

local function GetOrCreateLayout(className)
    if not PanelLayouts[className] then
        local ov = Config.PanelOverrides and Config.PanelOverrides[className]
        local minS, maxS = GetPanelScaleBounds(className)
        PanelLayouts[className] = {
            x = (ov and tonumber(ov.defaultX)) or 0.0,
            y = (ov and tonumber(ov.defaultY)) or 0.0,
            scale = Clamp((ov and tonumber(ov.defaultScale)) or 1.0, minS, maxS),
        }
    end
    return PanelLayouts[className]
end

local CachedPc = nil
local CachedVpW = 1920.0
local CachedVpH = 1080.0

local function GetLocalPlayerController()
    if IsObjValid(CachedPc) then return CachedPc end
    local pcs = FindAllOf("PlayerController")
    if pcs then
        for i = 1, #pcs do
            local pc = pcs[i]
            if IsObjValid(pc) then
                local fn = GetSafeFullName(pc)
                if fn ~= "" and not fn:find("Default__", 1, true) then
                    CachedPc = pc
                    return pc
                end
            end
        end
    end
    return nil
end

local function RefreshViewportSize()
    local pc = GetLocalPlayerController()
    if pc then
        local ok, a, b = pcall(function() return pc:GetViewportSize() end)
        if ok then
            if type(a) == "number" and type(b) == "number" and a > 0 and b > 0 then
                CachedVpW, CachedVpH = a, b
            elseif type(a) == "table" then
                local w = tonumber(a.SizeX or a.X)
                local h = tonumber(a.SizeY or a.Y)
                if w and h and w > 0 and h > 0 then
                    CachedVpW, CachedVpH = w, h
                end
            end
        end
    end
    return CachedVpW, CachedVpH
end

local function ClampLayoutToEntryBounds(entry, layout)
    if not Config.ClampToViewport or not layout then return end
    local vpW, vpH = RefreshViewportSize()
    local padPx = tonumber(Config.ClampEdgePaddingPx) or 8.0
    local padNormX = padPx / vpW
    local padNormY = padPx / vpH

    local boundMinX = Clamp((tonumber(Config.SafeZoneMinX) or 0.0) + padNormX, 0.0, 0.90)
    local boundMaxX = Clamp((tonumber(Config.SafeZoneMaxX) or 1.0) - padNormX, 0.10, 1.0)
    local boundMinY = Clamp((tonumber(Config.SafeZoneMinY) or 0.0) + padNormY, 0.0, 0.90)
    local boundMaxY = Clamp((tonumber(Config.SafeZoneMaxY) or 1.0) - padNormY, 0.10, 1.0)

    local sc = tonumber(layout.scale) or 1.0
    local meta = entry and entry.meta or {}
    local estNormW = (tonumber(meta.estW) or 540.0) / vpW
    local estNormH = (tonumber(meta.estH) or 720.0) / vpH

    local baseMinX = (entry and entry.hasBaseAnchors) and entry.baseMinX or 0.15
    local baseMaxX = (entry and entry.hasBaseAnchors) and entry.baseMaxX or (baseMinX + estNormW)
    local baseMinY = (entry and entry.hasBaseAnchors) and entry.baseMinY or 0.12
    local baseMaxY = (entry and entry.hasBaseAnchors) and entry.baseMaxY or (baseMinY + estNormH)

    local baseW = baseMaxX - baseMinX
    local baseH = baseMaxY - baseMinY

    if baseW < 0.02 or baseW > 0.95 then
        local centerX = (baseMinX + baseMaxX) * 0.5
        if baseW > 0.95 then centerX = 0.22 end
        baseMinX = centerX - (estNormW * 0.5)
        baseMaxX = centerX + (estNormW * 0.5)
        baseW = estNormW
    end
    if baseH < 0.02 or baseH > 0.95 then
        local centerY = (baseMinY + baseMaxY) * 0.5
        if baseH > 0.95 then centerY = 0.45 end
        baseMinY = centerY - (estNormH * 0.5)
        baseMaxY = centerY + (estNormH * 0.5)
        baseH = estNormH
    end

    local halfW = (baseW * sc) * 0.5
    local halfH = (baseH * sc) * 0.5
    local baseCenterX = (baseMinX + baseMaxX) * 0.5
    local baseCenterY = (baseMinY + baseMaxY) * 0.5

    local minDxNorm = (boundMinX + halfW) - baseCenterX
    local maxDxNorm = (boundMaxX - halfW) - baseCenterX
    if minDxNorm > maxDxNorm then
        local mid = (minDxNorm + maxDxNorm) * 0.5
        minDxNorm, maxDxNorm = mid, mid
    end

    local minDyNorm = (boundMinY + halfH) - baseCenterY
    local maxDyNorm = (boundMaxY - halfH) - baseCenterY
    if minDyNorm > maxDyNorm then
        local mid = (minDyNorm + maxDyNorm) * 0.5
        minDyNorm, maxDyNorm = mid, mid
    end

    layout.x = Clamp(tonumber(layout.x) or 0.0, minDxNorm * vpW, maxDxNorm * vpW)
    layout.y = Clamp(tonumber(layout.y) or 0.0, minDyNorm * vpH, maxDyNorm * vpH)
end

local CachedPanels = {}
local WorldReady = false
local TransformBusy = false
local LastTransformTime = 0.0

local function CaptureBaseline(entry)
    if entry.baseCaptured or not IsObjValid(entry.widget) then return end
    local w = entry.widget
    entry.inViewport = IsInViewportSafe(w)
    local okA, anchors = pcall(function() return w:GetAnchorsInViewport() end)
    if okA and type(anchors) == "table" and anchors.Minimum and anchors.Maximum then
        entry.baseMinX = tonumber(anchors.Minimum.X) or 0.0
        entry.baseMinY = tonumber(anchors.Minimum.Y) or 0.0
        entry.baseMaxX = tonumber(anchors.Maximum.X) or 1.0
        entry.baseMaxY = tonumber(anchors.Maximum.Y) or 1.0
        entry.hasBaseAnchors = true
    end
    entry.baseCaptured = true
    Diag(string.format("Baseline [%s] inVp=%s anchors=(%.3f,%.3f)-(%.3f,%.3f)",
        entry.className, tostring(entry.inViewport),
        entry.baseMinX or 0, entry.baseMinY or 0, entry.baseMaxX or 1, entry.baseMaxY or 1))
end

local function RestoreOriginalWidget(entry)
    if not entry or not IsObjValid(entry.widget) then return false end
    local w = entry.widget
    if entry.hasBaseAnchors and IsInViewportSafe(w) then
        pcall(function()
            w:SetAnchorsInViewport({
                Minimum = { X = entry.baseMinX, Y = entry.baseMinY },
                Maximum = { X = entry.baseMaxX, Y = entry.baseMaxY },
            })
        end)
    end
    pcall(function()
        w:SetRenderTranslation({ X = 0.0, Y = 0.0 })
        w:SetRenderScale({ X = 1.0, Y = 1.0 })
    end)
    return true
end

local function ApplyTransformToEntry(entry, force)
    if not entry or not IsObjValid(entry.widget) then return false end
    if TransformBusy and not force then return false end

    local now = os.clock()
    local minGap = ((tonumber(Config.RepeatIntervalMs) or 50) * 0.70) / 1000.0
    if not force and (now - LastTransformTime) < minGap then
        return false
    end

    TransformBusy = true
    LastTransformTime = now

    local okMain, res = pcall(function()
        local w = entry.widget
        local fullName = GetSafeFullName(w)
        if fullName == "" or fullName:find("Default__", 1, true) or fullName:find("/Game/", 1, true) then
            return false
        end

        CaptureBaseline(entry)

        if not IsPanelAllowed(entry.className, entry.meta) then
            RestoreOriginalWidget(entry)
            return false
        end

        local layout = PanelLayouts[entry.className]
        local tx = layout and (tonumber(layout.x) or 0.0) or 0.0
        local ty = layout and (tonumber(layout.y) or 0.0) or 0.0
        local sc = layout and (tonumber(layout.scale) or 1.0) or 1.0

        if layout then
            local minS, maxS = GetPanelScaleBounds(entry.className)
            layout.scale = Clamp(sc, minS, maxS)
            ClampLayoutToEntryBounds(entry, layout)
            tx = layout.x
            ty = layout.y
            sc = layout.scale
        end

        local vpW, vpH = RefreshViewportSize()
        local moved = false

        if entry.hasBaseAnchors and IsInViewportSafe(w) then
            local dxNorm = tx / vpW
            local dyNorm = ty / vpH
            local okVp = pcall(function()
                w:SetAnchorsInViewport({
                    Minimum = { X = entry.baseMinX + dxNorm, Y = entry.baseMinY + dyNorm },
                    Maximum = { X = entry.baseMaxX + dxNorm, Y = entry.baseMaxY + dyNorm },
                })
            end)
            if okVp then
                moved = true
                pcall(function() w:SetRenderTranslation({ X = 0.0, Y = 0.0 }) end)
            end
        end

        if not moved then
            pcall(function() w:SetRenderTranslation({ X = tx, Y = ty }) end)
        end

        pcall(function() w:SetRenderScale({ X = sc, Y = sc }) end)
        return true
    end)

    TransformBusy = false
    return okMain and res
end

local function DiscoverTargetPanels()
    local all = FindAllOf("UserWidget")
    local count = 0
    if not all then return 0 end
    local limit = math.min(#all, 2500)
    for i = 1, limit do
        local w = all[i]
        if IsObjValid(w) then
            local fullName = GetSafeFullName(w)
            if fullName ~= "" and not fullName:find("Default__", 1, true) and not fullName:find("/Game/", 1, true) then
                local className = GetSafeClassName(w)
                local meta = Config.TargetPanels[className]
                if meta and not (Config.BlockedPanels and Config.BlockedPanels[className]) then
                    if not CachedPanels[fullName] or not IsObjValid(CachedPanels[fullName].widget) then
                        CachedPanels[fullName] = { widget = w, className = className, meta = meta }
                    end
                    count = count + 1
                end
            end
        end
    end
    return count
end

local function GetTopActivePanel(allowLazyScan)
    local bestEntry = nil
    local bestScore = 999
    local hasValid = false

    for key, entry in pairs(CachedPanels) do
        if IsObjValid(entry.widget) then
            hasValid = true
            if IsPanelAllowed(entry.className, entry.meta) and IsWidgetVisible(entry.widget) then
                local score = tonumber(entry.meta.priority) or 10
                if score < bestScore then
                    bestScore = score
                    bestEntry = entry
                end
            end
        else
            CachedPanels[key] = nil
        end
    end

    if not bestEntry and allowLazyScan and not hasValid then
        DiscoverTargetPanels()
        return GetTopActivePanel(false)
    end
    return bestEntry
end

local function LoadDropInExtensions()
    local p = io.popen('dir /b "' .. EXTENSIONS_DIR:gsub("\\$", "") .. '\\*.lua" 2>nul')
    if not p then return end
    for file in p:lines() do
        local ok, ext = pcall(dofile, EXTENSIONS_DIR .. file)
        if ok and type(ext) == "table" and type(ext.panels) == "table" then
            for cls, opts in pairs(ext.panels) do
                RegisterExternalPanel(ext.modId or file, cls, opts)
            end
        end
    end
    p:close()
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    WorldReady = true
    CachedPc = nil
    RefreshViewportSize()
    LoadDropInExtensions()
    Diag(string.format("ClientRestart -> WorldReady=true (vp=%.0fx%.0f)", CachedVpW, CachedVpH))
end)

RegisterHook("/Script/UMG.UserWidget:Construct", function(Context)
    if not WorldReady then return end
    local w = Context:get()
    if not IsObjValid(w) then return end
    local fullName = GetSafeFullName(w)
    if fullName == "" or fullName:find("Default__", 1, true) or fullName:find("/Game/", 1, true) then return end
    local className = GetSafeClassName(w)
    local meta = Config.TargetPanels[className]
    if not meta or (Config.BlockedPanels and Config.BlockedPanels[className]) then return end

    ExecuteInGameThread(function()
        if not IsObjValid(w) then return end
        local entry = CachedPanels[fullName] or { widget = w, className = className, meta = meta }
        CachedPanels[fullName] = entry
        ReloadKvConfig()
        if PendingGlobalReset then
            PendingGlobalReset = false
            PanelLayouts = {}
            SaveLayoutsNow()
            SaveKvConfig()
        end
        ApplyTransformToEntry(entry, true)
    end)
end)

local function GetMouseCoordsSafe()
    local pc = GetLocalPlayerController()
    if not pc then return nil, nil end
    local ok, a, b = pcall(function() return pc:GetMousePosition() end)
    if ok then
        if type(a) == "number" and type(b) == "number" then
            return a, b
        elseif type(a) == "table" then
            local x = a.LocationX or a.X
            local y = a.LocationY or a.Y
            if type(x) == "number" and type(y) == "number" then return x, y end
        elseif a == true and type(b) == "table" then
            local x = b.LocationX or b.X
            local y = b.LocationY or b.Y
            if type(x) == "number" and type(y) == "number" then return x, y end
        end
    end
    return nil, nil
end

local function IsKeyDownSafe(keyNameStr)
    local pc = GetLocalPlayerController()
    if not pc then return false end
    local ok, res = pcall(function()
        return pc:IsInputKeyDown({ KeyName = FName(keyNameStr) })
    end)
    return ok and (res == true)
end

local ToggleDragAnchor = nil
local ToggleScaleAnchor = nil
local HeldDragMode = nil
local HeldDragEntry = nil
local LastMouseX = 0.0
local LastMouseY = 0.0
local ActiveRepeatAction = nil
local LastRepeatTick = 0.0

local function RunRepeatStep(action)
    local active = GetTopActivePanel(false)
    if not active then return false end
    local layout = GetOrCreateLayout(active.className)

    if action == "left" or action == "right" or action == "up" or action == "down" then
        if not CanKeyboardMovePanel(active.className, active.meta) then return false end
        local step = tonumber(Config.KeyboardStepPx) or 20
        if action == "left" then layout.x = (tonumber(layout.x) or 0.0) - step
        elseif action == "right" then layout.x = (tonumber(layout.x) or 0.0) + step
        elseif action == "up" then layout.y = (tonumber(layout.y) or 0.0) - step
        elseif action == "down" then layout.y = (tonumber(layout.y) or 0.0) + step
        end
        if ApplyTransformToEntry(active, false) then
            MarkLayoutsDirty()
        end
        return true
    elseif action == "scale_up" or action == "scale_down" then
        if not CanScalePanel(active.className, active.meta) then return false end
        local step = tonumber(Config.ScaleStep) or 0.05
        local sign = (action == "scale_up") and 1 or -1
        local minS, maxS = GetPanelScaleBounds(active.className)
        layout.scale = Clamp((tonumber(layout.scale) or 1.0) + (sign * step), minS, maxS)
        if ApplyTransformToEntry(active, false) then
            MarkLayoutsDirty()
        end
        return true
    end
    return false
end

local function StartRepeatAction(action)
    if not WorldReady then return end
    ReloadKvConfig()
    if not Config.Enabled then return end
    GetTopActivePanel(true)
    ActiveRepeatAction = action
    LastRepeatTick = os.clock()
    RunRepeatStep(action)
end

local function ToggleMouseDragAnchor()
    if not WorldReady then return end
    ReloadKvConfig()
    if not Config.Enabled or not Config.EnableMouseDrag then return end
    local active = GetTopActivePanel(true)
    if not active or not CanDragPanel(active.className, active.meta) then return end
    local mx, my = GetMouseCoordsSafe()
    if not mx or not my then return end

    if not ToggleDragAnchor then
        local layout = GetOrCreateLayout(active.className)
        ToggleDragAnchor = { className = active.className, startMouseX = mx, startMouseY = my, startX = layout.x, startY = layout.y }
        Log(string.format("Drag START [%s] -> move cursor and press Alt+M again to drop", active.className))
    else
        local layout = GetOrCreateLayout(active.className)
        layout.x = ToggleDragAnchor.startX + ((mx - ToggleDragAnchor.startMouseX) * Config.DragSensitivity)
        layout.y = ToggleDragAnchor.startY + ((my - ToggleDragAnchor.startMouseY) * Config.DragSensitivity)
        ToggleDragAnchor = nil
        ApplyTransformToEntry(active, true)
        SaveLayoutsNow()
        Log(string.format("Drag DROP [%s] saved x=%.1f y=%.1f", active.className, layout.x, layout.y))
    end
end

local function ToggleMouseScaleAnchor()
    if not WorldReady then return end
    ReloadKvConfig()
    if not Config.Enabled or not Config.EnableScaling then return end
    local active = GetTopActivePanel(true)
    if not active or not CanScalePanel(active.className, active.meta) then return end
    local mx, my = GetMouseCoordsSafe()
    if not mx or not my then return end

    if not ToggleScaleAnchor then
        local layout = GetOrCreateLayout(active.className)
        ToggleScaleAnchor = { className = active.className, startMouseX = mx, startMouseY = my, startScale = layout.scale }
        Log(string.format("Scale START [%s] -> move cursor and press Alt+R again to lock", active.className))
    else
        local layout = GetOrCreateLayout(active.className)
        local deltaPx = (mx - ToggleScaleAnchor.startMouseX) - (my - ToggleScaleAnchor.startMouseY)
        local minS, maxS = GetPanelScaleBounds(active.className)
        layout.scale = Clamp(ToggleScaleAnchor.startScale + (deltaPx * Config.MouseScaleSensitivity), minS, maxS)
        ToggleScaleAnchor = nil
        ApplyTransformToEntry(active, true)
        SaveLayoutsNow()
        Log(string.format("Scale DROP [%s] saved scale=%.2f", active.className, layout.scale))
    end
end

local function ResetActivePanel()
    if not WorldReady then return end
    ReloadKvConfig()
    ToggleDragAnchor = nil
    ToggleScaleAnchor = nil
    ActiveRepeatAction = nil
    local active = GetTopActivePanel(true)
    if not active then return end
    PanelLayouts[active.className] = nil
    RestoreOriginalWidget(active)
    SaveLayoutsNow()
    Log(string.format("Reset active panel [%s] to original position & 1.00x scale", active.className))
end

local function ResetAllPanels()
    ToggleDragAnchor = nil
    ToggleScaleAnchor = nil
    ActiveRepeatAction = nil
    PanelLayouts = {}
    SaveLayoutsNow()
    for key, entry in pairs(CachedPanels) do
        if IsObjValid(entry.widget) then
            RestoreOriginalWidget(entry)
        else
            CachedPanels[key] = nil
        end
    end
    Log("Reset ALL saved panels to original defaults")
end

LoopAsync(30, function()
    if not WorldReady then return false end
    ExecuteInGameThread(function()
        local now = os.clock()

        if LayoutDirty and (now - LastDirtyTime) >= 0.35 then
            SaveLayoutsNow()
        end

        if PendingGlobalReset then
            PendingGlobalReset = false
            ResetAllPanels()
            SaveKvConfig()
        end

        local active = GetTopActivePanel(false)
        if not active then
            ActiveRepeatAction = nil
            HeldDragMode = nil
            HeldDragEntry = nil
            return
        end

        local altDown = IsKeyDownSafe("LeftAlt") or IsKeyDownSafe("RightAlt")

        if ActiveRepeatAction then
            local keyStillHeld = false
            if altDown then
                if ActiveRepeatAction == "left" then keyStillHeld = IsKeyDownSafe("Left")
                elseif ActiveRepeatAction == "right" then keyStillHeld = IsKeyDownSafe("Right")
                elseif ActiveRepeatAction == "up" then keyStillHeld = IsKeyDownSafe("Up")
                elseif ActiveRepeatAction == "down" then keyStillHeld = IsKeyDownSafe("Down")
                elseif ActiveRepeatAction == "scale_up" then keyStillHeld = IsKeyDownSafe("PageUp") or IsKeyDownSafe("Add")
                elseif ActiveRepeatAction == "scale_down" then keyStillHeld = IsKeyDownSafe("PageDown") or IsKeyDownSafe("Subtract")
                end
            end

            if keyStillHeld then
                local intervalSec = (tonumber(Config.RepeatIntervalMs) or 50) / 1000.0
                if (now - LastRepeatTick) >= intervalSec then
                    LastRepeatTick = now
                    RunRepeatStep(ActiveRepeatAction)
                end
            else
                ActiveRepeatAction = nil
            end
        end

        local midDown = Config.EnableMouseDrag and IsKeyDownSafe("MiddleMouseButton")
        local altLeftDown = Config.EnableMouseDrag and altDown and IsKeyDownSafe("LeftMouseButton")
        local altRightDown = Config.EnableScaling and altDown and IsKeyDownSafe("RightMouseButton")

        local desiredMode = nil
        if (midDown or altLeftDown) and CanDragPanel(active.className, active.meta) then
            desiredMode = "move"
        elseif altRightDown and CanScalePanel(active.className, active.meta) then
            desiredMode = "scale"
        end

        local mx, my = GetMouseCoordsSafe()
        if desiredMode and mx and my then
            if HeldDragMode ~= desiredMode or not HeldDragEntry or not IsObjValid(HeldDragEntry.widget) then
                HeldDragMode = desiredMode
                HeldDragEntry = active
                LastMouseX = mx
                LastMouseY = my
            else
                local dx = mx - LastMouseX
                local dy = my - LastMouseY
                if math.abs(dx) > 0.1 or math.abs(dy) > 0.1 then
                    local layout = GetOrCreateLayout(HeldDragEntry.className)
                    if HeldDragMode == "move" then
                        layout.x = (tonumber(layout.x) or 0.0) + (dx * Config.DragSensitivity)
                        layout.y = (tonumber(layout.y) or 0.0) + (dy * Config.DragSensitivity)
                    elseif HeldDragMode == "scale" then
                        local minS, maxS = GetPanelScaleBounds(HeldDragEntry.className)
                        local deltaScale = (dx - dy) * Config.MouseScaleSensitivity
                        layout.scale = Clamp((tonumber(layout.scale) or 1.0) + deltaScale, minS, maxS)
                    end
                    if ApplyTransformToEntry(HeldDragEntry, false) then
                        MarkLayoutsDirty()
                    end
                    LastMouseX = mx
                    LastMouseY = my
                end
            end
        else
            HeldDragMode = nil
            HeldDragEntry = nil
        end
    end)
    return false
end)

local function SafeBind(keyEnum, mods, fn)
    if keyEnum then
        pcall(function()
            RegisterKeyBind(keyEnum, mods, function()
                ExecuteInGameThread(fn)
            end)
        end)
    end
end

SafeBind(Key.M, { ModifierKey.ALT }, ToggleMouseDragAnchor)
SafeBind(Key.R, { ModifierKey.ALT }, ToggleMouseScaleAnchor)

SafeBind(Key.LEFT_ARROW, { ModifierKey.ALT }, function() StartRepeatAction("left") end)
SafeBind(Key.RIGHT_ARROW, { ModifierKey.ALT }, function() StartRepeatAction("right") end)
SafeBind(Key.UP_ARROW, { ModifierKey.ALT }, function() StartRepeatAction("up") end)
SafeBind(Key.DOWN_ARROW, { ModifierKey.ALT }, function() StartRepeatAction("down") end)

SafeBind(Key.PAGE_UP, { ModifierKey.ALT }, function() StartRepeatAction("scale_up") end)
SafeBind(Key.PAGE_DOWN, { ModifierKey.ALT }, function() StartRepeatAction("scale_down") end)
SafeBind(Key.ADD, { ModifierKey.ALT }, function() StartRepeatAction("scale_up") end)
SafeBind(Key.SUBTRACT, { ModifierKey.ALT }, function() StartRepeatAction("scale_down") end)

SafeBind(Key.BACKSPACE, { ModifierKey.ALT }, ResetActivePanel)
SafeBind(Key.NUM_ZERO, { ModifierKey.ALT }, ResetActivePanel)
SafeBind(Key.BACKSPACE, { ModifierKey.ALT, ModifierKey.SHIFT }, ResetAllPanels)

Log(string.format("v%s initialized cleanly (Dir: %s)", VERSION, MOD_DIR))
