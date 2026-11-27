-- ArcaneWilds - Mod-Wide JSON Schema Versioning & Migration Engine
-- Ensures all JSON configs, detected asset catalogs, and exports carry an integer
-- `schemaVersion` and can safely migrate forward across breaking schema changes.

local SchemaMigrator = {}

SchemaMigrator.MOD_SCHEMA_VERSION = 1

SchemaMigrator.CURRENT_VERSIONS = {
    custom_spells    = 1,
    combo_rules      = 1,
    detected_catalog = 1,
    bundle           = 1,
}

SchemaMigrator.FORMAT_IDS = {
    custom_spells    = "arcane-wilds.custom_spells",
    combo_rules      = "arcane-wilds.combo_rules",
    detected_catalog = "arcane-wilds.detected_catalog",
    bundle           = "arcane-wilds.bundle",
}

local function ShallowCopy(tbl)
    if type(tbl) ~= "table" then return tbl end
    local copy = {}
    for k, v in pairs(tbl) do
        copy[k] = v
    end
    return copy
end

-- Step-by-step migration registry: Migrations[kind][fromVersion] = function(doc) -> migratedDoc, note
local Migrations = {
    custom_spells = {
        -- Legacy v0 (no schemaVersion field) -> v1
        [0] = function(doc)
            local out = ShallowCopy(doc)
            out.schemaVersion = 1
            if type(out.spells) ~= "table" then
                -- Legacy root-level map without 'spells' wrapper is preserved as-is if already wrapped
                -- or normalized if caller passed a valid object with spells
                out.spells = out.spells or {}
            end
            return out, "Upgraded legacy custom_spells (v0 -> v1): added schemaVersion=1"
        end,
    },
    combo_rules = {
        -- Legacy v0 (no schemaVersion field) -> v1
        [0] = function(doc)
            local out
            if doc[1] ~= nil and doc.rules == nil then
                out = {
                    schemaVersion = 1,
                    rules = doc,
                }
                return out, "Upgraded legacy combo_rules array (v0 -> v1): wrapped rules and added schemaVersion=1"
            end
            out = ShallowCopy(doc)
            out.schemaVersion = 1
            return out, "Upgraded legacy combo_rules (v0 -> v1): added schemaVersion=1"
        end,
    },
    detected_catalog = {
        [0] = function(doc)
            local out = ShallowCopy(doc)
            out.schemaVersion = 1
            out.format = out.format or SchemaMigrator.FORMAT_IDS.detected_catalog
            return out, "Upgraded detected_catalog (v0 -> v1): added schemaVersion=1"
        end,
    },
    bundle = {
        [0] = function(doc)
            local out = ShallowCopy(doc)
            out.schemaVersion = 1
            out.format = out.format or SchemaMigrator.FORMAT_IDS.bundle
            return out, "Upgraded export bundle (v0 -> v1): added schemaVersion=1"
        end,
    },
}

function SchemaMigrator.GetCurrentVersion(kind)
    return SchemaMigrator.CURRENT_VERSIONS[kind]
end

function SchemaMigrator.GetFormatId(kind)
    return SchemaMigrator.FORMAT_IDS[kind]
end

-- Validate and extract schemaVersion from a decoded JSON document.
-- Missing schemaVersion is treated as legacy version 0.
-- Returns (versionInt, nil) or (nil, errMsg).
function SchemaMigrator.ReadVersion(doc)
    if type(doc) ~= "table" then
        return nil, "document must be a JSON object"
    end
    local raw = doc.schemaVersion
    if raw == nil then
        return 0, nil
    end
    if type(raw) ~= "number" or raw ~= raw or math.floor(raw) ~= raw or raw < 0 then
        return nil, "invalid 'schemaVersion': expected a non-negative integer, got " .. tostring(raw)
    end
    return raw, nil
end

-- Detect document kind from explicit `format` field or top-level keys.
function SchemaMigrator.DetectKind(doc)
    if type(doc) ~= "table" then return nil end
    if type(doc.format) == "string" then
        for kind, fmtId in pairs(SchemaMigrator.FORMAT_IDS) do
            if doc.format == fmtId then
                return kind
            end
        end
    end
    if type(doc.spells) == "table" and type(doc.rules) == "table" then
        return "bundle"
    end
    if type(doc.vfx) == "table" or type(doc.sfx) == "table" or type(doc.categories) == "table" then
        return "detected_catalog"
    end
    if type(doc.spells) == "table" then
        return "custom_spells"
    end
    if type(doc.rules) == "table" or doc[1] ~= nil then
        return "combo_rules"
    end
    return nil
end

-- Migrate `doc` of `kind` to the current schema version (or optional `opts.targetVersion` for testing).
-- Optional `opts.registry` overrides the migration table for unit tests.
-- Returns (migratedDoc, nil, notes) on success, or (nil, errMsg, notes) on failure.
function SchemaMigrator.Migrate(kind, doc, opts)
    local targetVersion = (opts and opts.targetVersion) or SchemaMigrator.CURRENT_VERSIONS[kind]
    if not targetVersion then
        return nil, "unknown schema kind '" .. tostring(kind) .. "'", {}
    end

    local ver, verErr = SchemaMigrator.ReadVersion(doc)
    if verErr then
        return nil, verErr, {}
    end

    local notes = {}
    if ver > targetVersion then
        return nil, string.format(
            "%s uses schemaVersion %d, which is newer than supported version %d — please update Arcane Wilds",
            tostring(kind), ver, targetVersion
        ), notes
    end

    if ver == targetVersion then
        return doc, nil, notes
    end

    local registry = (opts and opts.registry) or Migrations[kind]
    if type(registry) ~= "table" then
        return nil, string.format("no migration registry available for '%s'", tostring(kind)), notes
    end

    local current = doc
    while ver < targetVersion do
        local stepFn = registry[ver]
        if type(stepFn) ~= "function" then
            return nil, string.format(
                "missing migration step for %s from schemaVersion %d to %d",
                tostring(kind), ver, ver + 1
            ), notes
        end
        local ok, nextDoc, note = pcall(stepFn, current)
        if not ok then
            return nil, string.format(
                "migration failed for %s (v%d -> v%d): %s",
                tostring(kind), ver, ver + 1, tostring(nextDoc)
            ), notes
        end
        if type(nextDoc) ~= "table" then
            return nil, string.format(
                "migration step for %s (v%d -> v%d) did not return a table",
                tostring(kind), ver, ver + 1
            ), notes
        end
        current = nextDoc
        ver = ver + 1
        current.schemaVersion = ver
        if note and note ~= "" then
            notes[#notes + 1] = tostring(note)
        else
            notes[#notes + 1] = string.format("Migrated %s v%d -> v%d", tostring(kind), ver - 1, ver)
        end
    end

    return current, nil, notes
end

return SchemaMigrator
