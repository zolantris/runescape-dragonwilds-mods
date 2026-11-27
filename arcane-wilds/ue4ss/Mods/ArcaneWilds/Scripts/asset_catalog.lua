-- ArcaneWilds - Unified Detected Asset Catalog Exporter (Spells, VFX, SFX, Montages)
-- Merges newly discovered UE5 assets with any previously saved detected_catalog.json
-- so the Web GUI always has a complete, growing list of dropdown options.

local Json = require("json")
local SchemaMigrator = require("schema_migrator")
local SpellScanner = require("spell_scanner")

local AssetCatalog = {}

local function Trim(s)
    if not s then return "" end
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function IsValidUObject(obj)
    if not obj then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

local function ExtractObjectPath(fullName)
    if not fullName or fullName == "" then return "" end
    return (fullName:match("^[^%s]+%s+(.+)$") or fullName)
end

local function IsSkippableAssetPath(path)
    if not path or path == "" then return true end
    local lower = path:lower()
    if lower:find("default__", 1, true) then return true end
    if lower:find("/engine/transient", 1, true) then return true end
    return false
end

local function AddUniqueString(list, seen, value)
    if not value or value == "" then return end
    local key = value:lower()
    if not seen[key] then
        seen[key] = true
        list[#list + 1] = value
    end
end

-- Parse a key = path alias file (e.g. vfx_names.txt or sfx_names.txt).
-- Returns: aliasesByPathLower[pathOrShortLower] = { alias1, ... }, directMap[aliasLower] = value
function AssetCatalog.LoadAliasFile(filePath)
    local byTarget = {}
    local directMap = {}
    if not filePath or filePath == "" then
        return byTarget, directMap
    end
    local f = io.open(filePath, "r")
    if not f then
        return byTarget, directMap
    end
    for line in f:lines() do
        local clean = Trim(line)
        if clean ~= "" and not clean:match("^#") and not clean:match("^;") then
            local hashPos = clean:find("#", 1, true)
            if hashPos then clean = Trim(clean:sub(1, hashPos - 1)) end
            local lhs, rhs = clean:match("^([^=]+)=(.+)$")
            if lhs and rhs then
                local alias = Trim(lhs)
                local target = Trim(rhs)
                if alias ~= "" and target ~= "" then
                    local tKey = target:lower()
                    directMap[alias:lower()] = target
                    byTarget[tKey] = byTarget[tKey] or {}
                    local exists = false
                    for _, existing in ipairs(byTarget[tKey]) do
                        if existing:lower() == alias:lower() then
                            exists = true
                            break
                        end
                    end
                    if not exists then
                        byTarget[tKey][#byTarget[tKey] + 1] = alias
                    end
                end
            end
        end
    end
    f:close()
    return byTarget, directMap
end

-- Load and migrate an existing detected_catalog.json if present.
function AssetCatalog.LoadExistingCatalog(filePath)
    if not filePath or filePath == "" then return nil end
    local f = io.open(filePath, "r")
    if not f then return nil end
    local raw = f:read("*a") or ""
    f:close()
    if Trim(raw) == "" then return nil end

    local doc, err = Json.Decode(raw)
    if err or type(doc) ~= "table" then return nil end
    local migrated, migErr = SchemaMigrator.Migrate("detected_catalog", doc)
    if migErr or type(migrated) ~= "table" then return nil end
    return migrated
end

local function ScanClassAssetPaths(className, kind)
    local results = {}
    if type(FindAllOf) ~= "function" then
        return results
    end
    pcall(function()
        local all = FindAllOf(className)
        if not all then return end
        for _, obj in ipairs(all) do
            if IsValidUObject(obj) then
                local full = SpellScanner.SafeGetName(obj)
                local objPath = ExtractObjectPath(full)
                if not IsSkippableAssetPath(objPath) then
                    local shortName = SpellScanner.ExtractShortObjectName(objPath)
                    if shortName ~= "" then
                        results[#results + 1] = {
                            shortName = shortName,
                            path = objPath,
                            kind = kind,
                        }
                    end
                end
            end
        end
    end)
    return results
end

-- Build a merged, sorted, schema-versioned catalog table from runtime state + existing file.
function AssetCatalog.BuildCatalog(opts)
    opts = opts or {}
    local existing = opts.existingCatalog
    if not existing and opts.existingPath then
        existing = AssetCatalog.LoadExistingCatalog(opts.existingPath)
    end

    local catSet = {}
    local categories = {}
    local spellsByKey = {}
    local vfxByPath = {}
    local sfxByPath = {}
    local montagesByPath = {}

    local function registerCategory(cat)
        AddUniqueString(categories, catSet, Trim(tostring(cat or "")))
    end

    local function registerSpell(entry)
        if type(entry) ~= "table" or not entry.shortName or entry.shortName == "" then return end
        local key = entry.shortName:lower()
        local cur = spellsByKey[key]
        if not cur then
            cur = {
                shortName = entry.shortName,
                fullName = entry.fullName or "",
                category = entry.category or "",
                stepIndex = tonumber(entry.stepIndex) or 0,
                montage = entry.montage,
                aliases = {},
                _aliasSeen = {},
                isModded = entry.isModded == true,
                isSpecial = entry.isSpecial == true,
            }
            spellsByKey[key] = cur
        else
            if (not cur.fullName or cur.fullName == "") and entry.fullName then cur.fullName = entry.fullName end
            if (not cur.category or cur.category == "") and entry.category then cur.category = entry.category end
            if (not cur.montage or cur.montage == "") and entry.montage then cur.montage = entry.montage end
            if entry.isModded == true then cur.isModded = true end
            if entry.isSpecial == true then cur.isSpecial = true end
        end
        if cur.category ~= "" then
            registerCategory(cur.category)
        end
        if type(entry.aliases) == "table" then
            for _, al in ipairs(entry.aliases) do
                AddUniqueString(cur.aliases, cur._aliasSeen, al)
            end
        end
    end

    local function registerMedia(map, item, defaultKind)
        if type(item) ~= "table" or not item.path or item.path == "" then return end
        if IsSkippableAssetPath(item.path) then return end
        local pKey = item.path:lower()
        local shortName = item.shortName
        if not shortName or shortName == "" then
            shortName = SpellScanner.ExtractShortObjectName(item.path)
        end
        if shortName == "" then return end
        local cur = map[pKey]
        if not cur then
            cur = {
                shortName = shortName,
                path = item.path,
                kind = item.kind or defaultKind,
                aliases = {},
                _aliasSeen = {},
            }
            map[pKey] = cur
        end
        if type(item.aliases) == "table" then
            for _, al in ipairs(item.aliases) do
                AddUniqueString(cur.aliases, cur._aliasSeen, al)
            end
        end
    end

    local function registerMontage(shortName, path)
        if not shortName or shortName == "" then return end
        local p = (path and path ~= "") and path or shortName
        if IsSkippableAssetPath(p) then return end
        local key = p:lower()
        if not montagesByPath[key] then
            montagesByPath[key] = {
                shortName = shortName,
                path = p,
            }
        end
    end

    -- 1. Seed from existing catalog so previously discovered assets persist across scans
    if type(existing) == "table" then
        if type(existing.categories) == "table" then
            for _, c in ipairs(existing.categories) do registerCategory(c) end
        end
        if type(existing.spells) == "table" then
            for _, sp in ipairs(existing.spells) do registerSpell(sp) end
        end
        if type(existing.vfx) == "table" then
            for _, v in ipairs(existing.vfx) do registerMedia(vfxByPath, v, "niagara") end
        end
        if type(existing.sfx) == "table" then
            for _, s in ipairs(existing.sfx) do registerMedia(sfxByPath, s, "sound") end
        end
        if type(existing.montages) == "table" then
            for _, m in ipairs(existing.montages) do
                if type(m) == "table" then
                    registerMontage(m.shortName, m.path)
                end
            end
        end
    end

    -- 2. Build reverse friendly-name lookup from spell_names.txt maps
    local aliasesBySpell = {}
    if type(opts.nameMapByCat) == "table" then
        for catLower, map in pairs(opts.nameMapByCat) do
            for friendly, assetShort in pairs(map) do
                local aKey = tostring(assetShort):lower()
                aliasesBySpell[aKey] = aliasesBySpell[aKey] or {}
                aliasesBySpell[aKey][#aliasesBySpell[aKey] + 1] = friendly
            end
        end
    end
    if type(opts.globalNameMap) == "table" then
        for friendly, assetShort in pairs(opts.globalNameMap) do
            local aKey = tostring(assetShort):lower()
            aliasesBySpell[aKey] = aliasesBySpell[aKey] or {}
            aliasesBySpell[aKey][#aliasesBySpell[aKey] + 1] = friendly
        end
    end

    -- 3. Merge live discovered spells from BaseSpellRegistry / OrderedChains
    if type(opts.baseSpellRegistry) == "table" then
        for _, entry in pairs(opts.baseSpellRegistry) do
            if type(entry) == "table" and entry.shortName and entry.shortName ~= "" then
                local aKey = entry.shortName:lower()
                registerSpell({
                    shortName = entry.shortName,
                    fullName = entry.fullName or "",
                    category = entry.categoryTag or "",
                    stepIndex = entry.stepIndex or 0,
                    montage = entry.montageName,
                    aliases = aliasesBySpell[aKey],
                    isModded = entry.isModded == true,
                    isSpecial = entry.isSpecialSpell == true,
                })
                if entry.montageName and entry.montageName ~= "" then
                    local mPath = entry.montageObj and IsValidUObject(entry.montageObj)
                        and ExtractObjectPath(SpellScanner.SafeGetName(entry.montageObj))
                        or entry.montageName
                    registerMontage(entry.montageName, mPath)
                end
            end
        end
    end

    if type(opts.orderedChains) == "table" then
        for _, ch in ipairs(opts.orderedChains) do
            if type(ch) == "table" and ch.tag then
                registerCategory(ch.tag)
            end
        end
    end

    -- 4. Merge VFX from VfxPathLookup + live NiagaraSystem scan + optional vfx_names.txt aliases
    local vfxAliasesByTarget, vfxDirectAliases = AssetCatalog.LoadAliasFile(opts.vfxNamesPath)
    if type(opts.vfxPathLookup) == "table" then
        for aliasOrShort, path in pairs(opts.vfxPathLookup) do
            if type(path) == "string" and path ~= "" then
                local shortName = SpellScanner.ExtractShortObjectName(path)
                local aliases = {}
                if type(aliasOrShort) == "string" and aliasOrShort:lower() ~= shortName:lower() then
                    aliases[#aliases + 1] = aliasOrShort
                end
                registerMedia(vfxByPath, { shortName = shortName, path = path, kind = "niagara", aliases = aliases }, "niagara")
            end
        end
    end
    for _, item in ipairs(ScanClassAssetPaths("NiagaraSystem", "niagara")) do
        registerMedia(vfxByPath, item, "niagara")
    end
    for alias, path in pairs(vfxDirectAliases) do
        registerMedia(vfxByPath, {
            shortName = SpellScanner.ExtractShortObjectName(path),
            path = path,
            kind = "niagara",
            aliases = { alias },
        }, "niagara")
    end
    for _, vEntry in pairs(vfxByPath) do
        local extra = vfxAliasesByTarget[vEntry.path:lower()] or vfxAliasesByTarget[vEntry.shortName:lower()]
        if extra then
            for _, al in ipairs(extra) do
                AddUniqueString(vEntry.aliases, vEntry._aliasSeen, al)
            end
        end
    end

    -- 5. Merge SFX from live SoundBase scan + optional sfx_names.txt aliases
    local sfxAliasesByTarget, sfxDirectAliases = AssetCatalog.LoadAliasFile(opts.sfxNamesPath)
    for _, item in ipairs(ScanClassAssetPaths("SoundBase", "sound")) do
        registerMedia(sfxByPath, item, "sound")
    end
    for alias, path in pairs(sfxDirectAliases) do
        registerMedia(sfxByPath, {
            shortName = SpellScanner.ExtractShortObjectName(path),
            path = path,
            kind = "sound",
            aliases = { alias },
        }, "sound")
    end
    for _, sEntry in pairs(sfxByPath) do
        local extra = sfxAliasesByTarget[sEntry.path:lower()] or sfxAliasesByTarget[sEntry.shortName:lower()]
        if extra then
            for _, al in ipairs(extra) do
                AddUniqueString(sEntry.aliases, sEntry._aliasSeen, al)
            end
        end
    end

    -- 6. Merge loaded AnimMontages
    for _, item in ipairs(ScanClassAssetPaths("AnimMontage", "montage")) do
        registerMontage(item.shortName, item.path)
    end

    -- 7. Finalize sorted arrays (using Json.AsArray so empty arrays encode as [])
    table.sort(categories, function(a, b) return a:lower() < b:lower() end)

    local spellsList = {}
    for _, sp in pairs(spellsByKey) do
        table.sort(sp.aliases, function(a, b) return a:lower() < b:lower() end)
        spellsList[#spellsList + 1] = {
            shortName = sp.shortName,
            fullName = sp.fullName,
            category = sp.category,
            stepIndex = sp.stepIndex,
            montage = sp.montage,
            aliases = Json.AsArray(sp.aliases),
            isModded = sp.isModded,
            isSpecial = sp.isSpecial,
        }
    end
    table.sort(spellsList, function(a, b)
        if a.category ~= b.category then return a.category:lower() < b.category:lower() end
        if a.stepIndex ~= b.stepIndex then return a.stepIndex < b.stepIndex end
        return a.shortName:lower() < b.shortName:lower()
    end)

    local function finalizeMediaList(map)
        local list = {}
        for _, item in pairs(map) do
            table.sort(item.aliases, function(a, b) return a:lower() < b:lower() end)
            list[#list + 1] = {
                shortName = item.shortName,
                path = item.path,
                kind = item.kind,
                aliases = Json.AsArray(item.aliases),
            }
        end
        table.sort(list, function(a, b)
            if a.shortName:lower() ~= b.shortName:lower() then
                return a.shortName:lower() < b.shortName:lower()
            end
            return a.path:lower() < b.path:lower()
        end)
        return Json.AsArray(list)
    end

    local montagesList = {}
    for _, m in pairs(montagesByPath) do
        montagesList[#montagesList + 1] = {
            shortName = m.shortName,
            path = m.path,
        }
    end
    table.sort(montagesList, function(a, b)
        if a.shortName:lower() ~= b.shortName:lower() then
            return a.shortName:lower() < b.shortName:lower()
        end
        return a.path:lower() < b.path:lower()
    end)

    local generatedAt = opts.generatedAt or os.date("!%Y-%m-%dT%H:%M:%SZ")

    return {
        ["$schema"] = "./schemas/detected_catalog.schema.json",
        schemaVersion = SchemaMigrator.GetCurrentVersion("detected_catalog"),
        format = SchemaMigrator.GetFormatId("detected_catalog"),
        modVersion = tostring(opts.modVersion or "1.0.0"),
        generatedAt = generatedAt,
        categories = Json.AsArray(categories),
        spells = Json.AsArray(spellsList),
        vfx = finalizeMediaList(vfxByPath),
        sfx = finalizeMediaList(sfxByPath),
        montages = Json.AsArray(montagesList),
    }
end

-- Build and write detected_catalog.json to disk.
-- Returns (catalog, nil) on success, or (nil, errMsg) on failure.
function AssetCatalog.ExportCatalogFile(outPath, opts, logFn)
    if not outPath or outPath == "" then
        return nil, "missing output path"
    end
    local buildOpts = {}
    for k, v in pairs(opts or {}) do buildOpts[k] = v end
    buildOpts.existingPath = buildOpts.existingPath or outPath

    local catalog = AssetCatalog.BuildCatalog(buildOpts)
    local encoded, encErr = Json.Encode(catalog, { indent = 2 })
    if encErr or not encoded then
        return nil, encErr or "failed to encode detected_catalog.json"
    end

    local f, openErr = io.open(outPath, "w")
    if not f then
        return nil, tostring(openErr or "failed to open output file")
    end
    f:write(encoded .. "\n")
    f:close()

    if logFn then
        logFn(string.format(
            "Exported detected_catalog.json (schema v%d): %d spell(s), %d VFX, %d SFX, %d montage(s)",
            catalog.schemaVersion, #catalog.spells, #catalog.vfx, #catalog.sfx, #catalog.montages
        ))
    end

    return catalog, nil
end

return AssetCatalog
