// Arcane Wilds - JavaScript JSONC Parser & Schema Migration Engine
// Mirrors Scripts/schema_migrator.lua so imports/loads migrate identically in both Lua and Web GUI.

export const MOD_SCHEMA_VERSION = 1;

export const CURRENT_VERSIONS = {
  custom_spells: 1,
  combo_rules: 1,
  detected_catalog: 1,
  bundle: 1,
};

export const FORMAT_IDS = {
  custom_spells: "arcane-wilds.custom_spells",
  combo_rules: "arcane-wilds.combo_rules",
  detected_catalog: "arcane-wilds.detected_catalog",
  bundle: "arcane-wilds.bundle",
};

/**
 * Strip UTF-8 BOM, // and /* ... *\/ comments, and trailing commas so JSONC configs parse cleanly.
 */
export function stripJsonc(text) {
  let src = String(text ?? "");
  if (src.charCodeAt(0) === 0xfeff) src = src.slice(1);

  // Pass 1: strip comments outside strings
  let out = "";
  let inStr = false;
  for (let i = 0; i < src.length; i++) {
    const ch = src[i];
    if (inStr) {
      out += ch;
      if (ch === "\\" && i + 1 < src.length) {
        out += src[++i];
      } else if (ch === '"') {
        inStr = false;
      }
    } else if (ch === '"') {
      inStr = true;
      out += ch;
    } else if (ch === "/" && src[i + 1] === "/") {
      i += 2;
      while (i < src.length && src[i] !== "\n") i++;
      if (i < src.length) out += "\n";
    } else if (ch === "/" && src[i + 1] === "*") {
      const end = src.indexOf("*/", i + 2);
      if (end === -1) throw new Error("Unterminated block comment in JSON");
      i = end + 1;
    } else {
      out += ch;
    }
  }

  // Pass 2: remove trailing commas before } or ]
  let out2 = "";
  inStr = false;
  for (let i = 0; i < out.length; i++) {
    const ch = out[i];
    if (inStr) {
      out2 += ch;
      if (ch === "\\" && i + 1 < out.length) {
        out2 += out[++i];
      } else if (ch === '"') {
        inStr = false;
      }
    } else if (ch === '"') {
      inStr = true;
      out2 += ch;
    } else if (ch === ",") {
      let j = i + 1;
      while (j < out.length && /\s/.test(out[j])) j++;
      if (out[j] === "}" || out[j] === "]") continue;
      out2 += ch;
    } else {
      out2 += ch;
    }
  }
  return out2;
}

export function parseJsonc(rawText) {
  const cleaned = stripJsonc(rawText);
  return JSON.parse(cleaned);
}

export function readVersion(doc) {
  if (!doc || typeof doc !== "object") {
    return { version: null, error: "Document must be a JSON object." };
  }
  if (doc.schemaVersion === undefined || doc.schemaVersion === null) {
    return { version: 0, error: null };
  }
  if (
    typeof doc.schemaVersion !== "number" ||
    !Number.isInteger(doc.schemaVersion) ||
    doc.schemaVersion < 0
  ) {
    return {
      version: null,
      error: `Invalid 'schemaVersion': expected a non-negative integer, got ${String(doc.schemaVersion)}`,
    };
  }
  return { version: doc.schemaVersion, error: null };
}

export function detectKind(doc) {
  if (!doc || typeof doc !== "object") return null;
  if (typeof doc.format === "string") {
    for (const [kind, fmt] of Object.entries(FORMAT_IDS)) {
      if (doc.format === fmt) return kind;
    }
  }
  if (doc.spells && typeof doc.spells === "object" && Array.isArray(doc.rules)) {
    return "bundle";
  }
  if (Array.isArray(doc.vfx) || Array.isArray(doc.sfx) || Array.isArray(doc.categories)) {
    return "detected_catalog";
  }
  if (doc.spells && typeof doc.spells === "object") {
    return "custom_spells";
  }
  if (Array.isArray(doc.rules) || Array.isArray(doc)) {
    return "combo_rules";
  }
  return null;
}

const MIGRATIONS = {
  custom_spells: {
    0: (doc) => ({
      doc: {
        $schema: doc.$schema || "./schemas/custom_spells.schema.json",
        ...doc,
        schemaVersion: 1,
        spells: doc.spells && typeof doc.spells === "object" ? doc.spells : {},
      },
      note: "Upgraded legacy custom_spells (v0 -> v1): added schemaVersion=1",
    }),
  },
  combo_rules: {
    0: (doc) => {
      if (Array.isArray(doc)) {
        return {
          doc: {
            $schema: "./schemas/combo_rules.schema.json",
            schemaVersion: 1,
            rules: doc,
          },
          note: "Upgraded legacy combo_rules array (v0 -> v1): wrapped rules and added schemaVersion=1",
        };
      }
      return {
        doc: {
          $schema: doc.$schema || "./schemas/combo_rules.schema.json",
          ...doc,
          schemaVersion: 1,
          rules: Array.isArray(doc.rules) ? doc.rules : [],
        },
        note: "Upgraded legacy combo_rules (v0 -> v1): added schemaVersion=1",
      };
    },
  },
  detected_catalog: {
    0: (doc) => ({
      doc: {
        ...doc,
        schemaVersion: 1,
        format: doc.format || FORMAT_IDS.detected_catalog,
      },
      note: "Upgraded detected_catalog (v0 -> v1): added schemaVersion=1",
    }),
  },
  bundle: {
    0: (doc) => ({
      doc: {
        ...doc,
        schemaVersion: 1,
        format: doc.format || FORMAT_IDS.bundle,
      },
      note: "Upgraded export bundle (v0 -> v1): added schemaVersion=1",
    }),
  },
};

export function migrateDocument(kind, doc) {
  const targetVersion = CURRENT_VERSIONS[kind];
  if (!targetVersion) {
    return { doc: null, error: `Unknown schema kind '${kind}'.`, notes: [], fromVersion: null, toVersion: null };
  }

  const { version, error } = readVersion(doc);
  if (error) {
    return { doc: null, error, notes: [], fromVersion: null, toVersion: targetVersion };
  }

  if (version > targetVersion) {
    return {
      doc: null,
      error: `${kind} uses schemaVersion ${version}, which is newer than supported version ${targetVersion} — please update Arcane Wilds.`,
      notes: [],
      fromVersion: version,
      toVersion: targetVersion,
    };
  }

  const notes = [];
  let current = structuredClone(doc);
  let ver = version;

  while (ver < targetVersion) {
    const stepFn = MIGRATIONS[kind]?.[ver];
    if (typeof stepFn !== "function") {
      return {
        doc: null,
        error: `Missing migration step for ${kind} from schemaVersion ${ver} to ${ver + 1}.`,
        notes,
        fromVersion: version,
        toVersion: targetVersion,
      };
    }
    const res = stepFn(current);
    current = res.doc;
    ver += 1;
    current.schemaVersion = ver;
    notes.push(res.note || `Migrated ${kind} v${ver - 1} -> v${ver}`);
  }

  return { doc: current, error: null, notes, fromVersion: version, toVersion: targetVersion };
}

export function buildExportEnvelope(kind, payload, modVersion = "1.0.0") {
  const base = {
    schemaVersion: CURRENT_VERSIONS[kind],
    format: FORMAT_IDS[kind],
    modVersion,
    exportedAt: new Date().toISOString(),
  };
  if (kind === "custom_spells") {
    return {
      $schema: "./schemas/custom_spells.schema.json",
      ...base,
      spells: payload,
    };
  }
  if (kind === "combo_rules") {
    return {
      $schema: "./schemas/combo_rules.schema.json",
      ...base,
      rules: payload,
    };
  }
  if (kind === "bundle") {
    return {
      $schema: "./schemas/export_bundle.schema.json",
      ...base,
      spells: payload.spells || {},
      rules: payload.rules || [],
    };
  }
  throw new Error(`Unsupported export kind: ${kind}`);
}
