// Arcane Wilds - Detected Asset Catalog Store (Spells, VFX, SFX, Montages + Custom Spells)

export class CatalogStore {
  constructor() {
    this.catalog = {
      schemaVersion: 1,
      modVersion: "1.0.0",
      categories: ["Air", "Fire", "Water", "Earth", "Air_Wand", "Fire_Wand", "Water_Wand", "Earth_Wand", "AncientMagicks", "Custom"],
      spells: [],
      vfx: [],
      sfx: [],
      montages: [],
    };
    this.defaultSpells = {};
    this.userSpells = {};
    this.disabledDefaults = new Set();
  }

  setCatalog(rawCatalog) {
    if (!rawCatalog || typeof rawCatalog !== "object") return;
    this.catalog = {
      schemaVersion: rawCatalog.schemaVersion || 1,
      modVersion: rawCatalog.modVersion || "1.0.0",
      categories: Array.isArray(rawCatalog.categories) ? rawCatalog.categories : [],
      spells: Array.isArray(rawCatalog.spells) ? rawCatalog.spells : [],
      vfx: Array.isArray(rawCatalog.vfx) ? rawCatalog.vfx : [],
      sfx: Array.isArray(rawCatalog.sfx) ? rawCatalog.sfx : [],
      montages: Array.isArray(rawCatalog.montages) ? rawCatalog.montages : [],
    };
  }

  setSpellLayers(defaultSpells, userSpells, disabledDefaults = [], enabledDefaults = []) {
    this.defaultSpells = defaultSpells && typeof defaultSpells === "object" ? defaultSpells : {};
    this.userSpells = userSpells && typeof userSpells === "object" ? userSpells : {};
    this.disabledDefaults = new Set((disabledDefaults || []).map((s) => String(s).toLowerCase()));
    this.enabledDefaults = new Set((enabledDefaults || []).map((s) => String(s).toLowerCase()));
  }

  getActiveCustomSpellsMap() {
    const merged = {};
    for (const [id, def] of Object.entries(this.defaultSpells)) {
      const k = id.toLowerCase();
      const active = this.disabledDefaults.has(k)
        ? false
        : this.enabledDefaults.has(k)
          ? true
          : def?.enabled !== false;
      if (active) {
        merged[id] = { ...def, _layer: "Built-in" };
      }
    }
    for (const [id, def] of Object.entries(this.userSpells)) {
      if (!this.defaultSpells[id] && def?.enabled !== false) {
        merged[id] = { ...def, _layer: "My Spell" };
      }
    }
    return merged;
  }

  getStats() {
    const activeCustom = Object.keys(this.getActiveCustomSpellsMap()).length;
    return {
      spells: this.catalog.spells.length + activeCustom,
      detectedSpells: this.catalog.spells.length,
      customSpells: activeCustom,
      vfx: this.catalog.vfx.length,
      sfx: this.catalog.sfx.length,
      montages: this.catalog.montages.length,
    };
  }

  getCategoryOptions() {
    const set = new Set(["Air", "Fire", "Water", "Earth", "Air_Wand", "Fire_Wand", "Water_Wand", "Earth_Wand", "AncientMagicks", "Custom"]);
    for (const c of this.catalog.categories) {
      if (c) set.add(c);
    }
    for (const sp of Object.values(this.getActiveCustomSpellsMap())) {
      if (sp?.category) set.add(sp.category);
    }
    return [...set].sort((a, b) => a.localeCompare(b)).map((c) => ({
      value: c,
      label: c,
      badge: "Category",
      sub: "",
    }));
  }

  /**
   * Options for combo stage spell dropdowns (optionally prioritized by category).
   * Includes friendly aliases, detected DA_Spell_* assets, active built-in spells, and user spells.
   */
  getComboSpellOptions(category = "") {
    const catLower = (category || "").trim().toLowerCase();
    const options = [];
    const seen = new Set();

    const push = (opt) => {
      const key = `${opt.value.toLowerCase()}|${opt.badge}`;
      if (seen.has(key)) return;
      seen.add(key);
      options.push(opt);
    };

    // 1. Active Built-in & User custom spells
    for (const [id, def] of Object.entries(this.getActiveCustomSpellsMap())) {
      push({
        value: id,
        label: def?.displayName ? `${id} (${def.displayName})` : id,
        badge: def._layer || "Custom",
        sub: def?.category ? `Category: ${def.category}` : "Custom Spell",
        priority: def._layer === "My Spell" ? 0.8 : 1,
      });
    }

    // 2. Detected spells (category matches first, then others)
    for (const sp of this.catalog.spells) {
      const spCatLower = (sp.category || "").toLowerCase();
      const matchesCat = catLower && spCatLower === catLower;
      const priority = matchesCat ? 0 : 2;
      const aliases = Array.isArray(sp.aliases) ? sp.aliases : [];

      for (const al of aliases) {
        push({
          value: al,
          label: al,
          badge: sp.category || "Alias",
          sub: sp.shortName,
          priority,
        });
      }

      push({
        value: sp.shortName,
        label: sp.shortName,
        badge: sp.category || "Spell",
        sub: aliases.length ? `Aliases: ${aliases.join(", ")}` : (sp.montage || ""),
        priority: priority + 0.5,
      });
    }

    options.sort((a, b) => (a.priority - b.priority) || a.label.localeCompare(b.label));
    return options;
  }

  getDetectedSpellOptions(includeNone = false) {
    const opts = [];
    if (includeNone) {
      opts.push({
        value: "",
        label: "(None — Pure Custom / Timeline Spell)",
        badge: "None",
        sub: "baseSpell: null",
      });
    }
    for (const sp of this.catalog.spells) {
      opts.push({
        value: sp.shortName,
        label: sp.shortName,
        badge: sp.category || "Spell",
        sub: sp.aliases?.length ? `Aliases: ${sp.aliases.join(", ")}` : (sp.fullName || ""),
      });
    }
    return opts;
  }

  getVfxOptions() {
    const opts = [];
    const seen = new Set();
    const push = (o) => {
      const k = o.value.toLowerCase();
      if (seen.has(k)) return;
      seen.add(k);
      opts.push(o);
    };

    // Built-in helpful keywords
    for (const kw of ["lightning", "fire", "water", "air", "earth"]) {
      push({ value: kw, label: kw, badge: "Keyword", sub: `Dynamic keyword lookup: '${kw}'` });
    }

    for (const v of this.catalog.vfx) {
      if (Array.isArray(v.aliases)) {
        for (const al of v.aliases) {
          push({ value: al, label: al, badge: "VFX Alias", sub: v.path });
        }
      }
      push({
        value: v.path,
        label: v.shortName,
        badge: v.kind || "VFX",
        sub: v.path,
      });
    }
    return opts;
  }

  getSfxOptions() {
    const opts = [];
    const seen = new Set();
    const push = (o) => {
      const k = o.value.toLowerCase();
      if (seen.has(k)) return;
      seen.add(k);
      opts.push(o);
    };

    for (const kw of ["lightning", "explosion", "impact", "whoosh"]) {
      push({ value: kw, label: kw, badge: "Keyword", sub: `Dynamic keyword lookup: '${kw}'` });
    }

    for (const s of this.catalog.sfx) {
      if (Array.isArray(s.aliases)) {
        for (const al of s.aliases) {
          push({ value: al, label: al, badge: "SFX Alias", sub: s.path });
        }
      }
      push({
        value: s.path,
        label: s.shortName,
        badge: s.kind || "SFX",
        sub: s.path,
      });
    }
    return opts;
  }

  getMontageOptions() {
    return this.catalog.montages.map((m) => ({
      value: m.shortName,
      label: m.shortName,
      badge: "Montage",
      sub: m.path !== m.shortName ? m.path : "",
    }));
  }
}
