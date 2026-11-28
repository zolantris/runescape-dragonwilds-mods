// Arcane Wilds - Main Web GUI Controller (Two-Layer: Immutable Mod Defaults + Persistent User Profile)

import { CatalogStore } from "./catalog_store.js";
import { CombosTab, cleanRuleForSave } from "./combos_tab.js";
import { SpellsTab } from "./spells_tab.js";
import { QuickCastTab } from "./quickcast_tab.js";
import { ImportModal } from "./io_modal.js";
import {
  MOD_SCHEMA_VERSION,
  CURRENT_VERSIONS,
  FORMAT_IDS,
  parseJsonc,
  migrateDocument,
  buildExportEnvelope,
} from "./schema_migrator.js";

const state = {
  connected: false,
  modVersion: "1.0.0",
  userDir: "",
  activeTab: "combos",
  defaults: {
    spells: {},
    rules: [],
    quickCast: [],
  },
  userSpells: {
    disabledDefaults: [],
    enabledDefaults: [],
    spells: {},
  },
  userCombos: {
    disableAllDefaults: false,
    disabledDefaultIds: [],
    enabledDefaultIds: [],
    rules: [],
  },
  userQuickCast: {
    overrideDefaults: false,
    bindings: [],
    defaultBindings: [],
  },
  dirtySpells: false,
  dirtyCombos: false,
  dirtyQuickCast: false,
};

const catalogStore = new CatalogStore();

const el = {
  tabBtnCombos: document.getElementById("tab-btn-combos"),
  tabBtnSpells: document.getElementById("tab-btn-spells"),
  tabBtnQuickCast: document.getElementById("tab-btn-quickcast"),
  panelCombos: document.getElementById("panel-combos"),
  panelSpells: document.getElementById("panel-spells"),
  panelQuickCast: document.getElementById("panel-quickcast"),
  badgeCombosCount: document.getElementById("badge-combos-count"),
  badgeSpellsCount: document.getElementById("badge-spells-count"),
  badgeQcCount: document.getElementById("badge-qc-count"),
  statSpells: document.getElementById("stat-spells"),
  statVfx: document.getElementById("stat-vfx"),
  statSfx: document.getElementById("stat-sfx"),
  statMontages: document.getElementById("stat-montages"),
  connectionBadge: document.getElementById("connection-badge"),
  schemaBadge: document.getElementById("schema-badge"),
  standaloneBanner: document.getElementById("standalone-banner"),
  standaloneBannerText: document.getElementById("standalone-banner-text"),
  btnRefreshCatalog: document.getElementById("btn-refresh-catalog"),
  btnOpenUserDir: document.getElementById("btn-open-user-dir"),
  btnLoadCatalogFile: document.getElementById("btn-load-catalog-file"),
  fileInputCatalog: document.getElementById("file-input-catalog"),
  toastContainer: document.getElementById("toast-container"),
};

el.schemaBadge.textContent = `Schema v${MOD_SCHEMA_VERSION}`;

function toast(message, type = "info") {
  const div = document.createElement("div");
  div.className = `toast toast-${type}`;
  div.textContent = message;
  el.toastContainer.appendChild(div);
  setTimeout(() => div.remove(), 4500);
}

function switchTab(tab) {
  state.activeTab = tab;
  const tabs = [
    ["combos", el.tabBtnCombos, el.panelCombos],
    ["spells", el.tabBtnSpells, el.panelSpells],
    ["quickcast", el.tabBtnQuickCast, el.panelQuickCast],
  ];
  for (const [name, btn, panel] of tabs) {
    const active = name === tab;
    btn.classList.toggle("active", active);
    btn.setAttribute("aria-selected", String(active));
    panel.classList.toggle("active", active);
  }
}

function updateCountsAndStats() {
  catalogStore.setSpellLayers(
    state.defaults.spells,
    state.userSpells.spells,
    state.userSpells.disabledDefaults,
    state.userSpells.enabledDefaults
  );
  const stats = catalogStore.getStats();

  const disabledComboSet = new Set((state.userCombos.disabledDefaultIds || []).map((x) => String(x).toLowerCase()));
  const enabledComboSet = new Set((state.userCombos.enabledDefaultIds || []).map((x) => String(x).toLowerCase()));
  const activeDefaultCombos = state.userCombos.disableAllDefaults
    ? 0
    : state.defaults.rules.filter((r, i) => {
        const k = (r.id || r.name || `default_${i}`).toLowerCase();
        if (disabledComboSet.has(k)) return false;
        if (enabledComboSet.has(k)) return true;
        return r.enabled !== false;
      }).length;

  const activeQc = state.userQuickCast.overrideDefaults
    ? state.userQuickCast.bindings.length
    : state.defaults.quickCast.length;

  el.badgeCombosCount.textContent = String(state.userCombos.rules.length + activeDefaultCombos);
  el.badgeSpellsCount.textContent = String(stats.customSpells);
  el.badgeQcCount.textContent = String(activeQc);
  el.statSpells.textContent = String(stats.spells);
  el.statVfx.textContent = String(stats.vfx);
  el.statSfx.textContent = String(stats.sfx);
  el.statMontages.textContent = String(stats.montages);
}

const combosTab = new CombosTab({
  containerEl: document.getElementById("combos-list"),
  searchInputEl: document.getElementById("combo-search"),
  disableAllDefaultsEl: document.getElementById("chk-disable-all-default-combos"),
  catalogStore,
  getDefaultRules: () => state.defaults.rules,
  getUserCombosState: () => state.userCombos,
  onDirty: () => {
    state.dirtyCombos = true;
    saveWebDraft();
    updateCountsAndStats();
  },
  onCreateCustomSpell: (onCreatedCb) => {
    const newId = spellsTab.createNewSpell("MyComboSpell");
    switchTab("spells");
    toast(`Created '${newId}' in My Custom Spells — customize it and switch back to Combos!`, "success");
    if (typeof onCreatedCb === "function") onCreatedCb(newId);
  },
});

const spellsTab = new SpellsTab({
  listEl: document.getElementById("spells-list"),
  editorEl: document.getElementById("spell-editor-container"),
  searchInputEl: document.getElementById("spell-search"),
  catalogStore,
  getDefaultSpells: () => state.defaults.spells,
  getUserSpellsState: () => state.userSpells,
  onDirty: () => {
    state.dirtySpells = true;
    saveWebDraft();
    updateCountsAndStats();
  },
  onWarn: (msg) => toast(msg, "warn"),
});

const quickCastTab = new QuickCastTab({
  containerEl: document.getElementById("qc-list"),
  modeBadgeEl: document.getElementById("qc-mode-badge"),
  catalogStore,
  getState: () => state.userQuickCast,
  onDirty: () => {
    state.dirtyQuickCast = true;
    saveWebDraft();
    updateCountsAndStats();
  },
});

function filterBuiltInSpellCollisions(incomingSpells) {
  const builtInLower = new Set(Object.keys(state.defaults.spells || {}).map((k) => k.toLowerCase()));
  const accepted = {};
  const skipped = [];
  for (const [id, def] of Object.entries(incomingSpells || {})) {
    if (builtInLower.has(id.toLowerCase())) {
      skipped.push(id);
    } else {
      accepted[id] = def;
    }
  }
  return { accepted, skipped };
}

const importModal = new ImportModal({
  modalEl: document.getElementById("io-modal"),
  titleEl: document.getElementById("io-modal-title"),
  bodyEl: document.getElementById("io-modal-body"),
  footerEl: document.getElementById("io-modal-footer"),
  closeBtn: document.getElementById("io-modal-close"),
  onApplyImport: ({ kind, doc, notes, mode }) => {
    let skippedBuiltIns = [];

    if (kind === "custom_spells" || kind === "user_spells" || kind === "bundle") {
      const { accepted, skipped } = filterBuiltInSpellCollisions(doc.spells || {});
      skippedBuiltIns = skipped;
      if (mode === "replace") {
        state.userSpells.spells = structuredClone(accepted);
        if (Array.isArray(doc.disabledDefaults)) {
          state.userSpells.disabledDefaults = [...doc.disabledDefaults];
        }
      } else {
        state.userSpells.spells = { ...state.userSpells.spells, ...accepted };
        if (Array.isArray(doc.disabledDefaults)) {
          state.userSpells.disabledDefaults = [
            ...new Set([...state.userSpells.disabledDefaults, ...doc.disabledDefaults]),
          ];
        }
      }
      state.dirtySpells = true;
    }

    if (kind === "combo_rules" || kind === "user_combos" || kind === "bundle") {
      const incomingRules = Array.isArray(doc.rules) ? doc.rules : [];
      if (mode === "replace") {
        state.userCombos.rules = structuredClone(incomingRules);
        if (typeof doc.disableAllDefaults === "boolean") state.userCombos.disableAllDefaults = doc.disableAllDefaults;
        if (Array.isArray(doc.disabledDefaultIds)) state.userCombos.disabledDefaultIds = [...doc.disabledDefaultIds];
      } else {
        state.userCombos.rules = [...state.userCombos.rules, ...incomingRules];
        if (Array.isArray(doc.disabledDefaultIds)) {
          state.userCombos.disabledDefaultIds = [
            ...new Set([...state.userCombos.disabledDefaultIds, ...doc.disabledDefaultIds]),
          ];
        }
      }
      state.dirtyCombos = true;
    }

    if (kind === "user_quick_cast" || (kind === "bundle" && doc.quickCast)) {
      const qcDoc = kind === "bundle" ? doc.quickCast : doc;
      if (Array.isArray(qcDoc.bindings)) {
        state.userQuickCast.overrideDefaults = qcDoc.overrideDefaults !== false;
        state.userQuickCast.bindings =
          mode === "replace"
            ? structuredClone(qcDoc.bindings)
            : [...state.userQuickCast.bindings, ...qcDoc.bindings];
        state.dirtyQuickCast = true;
      }
    }

    saveWebDraft();
    updateCountsAndStats();
    combosTab.render();
    spellsTab.render();
    quickCastTab.render();

    const migSuffix = notes.length ? ` (${notes.length} migration step(s) applied)` : "";
    toast(`Imported ${kind} (${mode})${migSuffix}. Click Save to persist to your user profile.`, "success");
    if (skippedBuiltIns.length) {
      toast(`Skipped built-in spell IDs (${skippedBuiltIns.join(", ")}) to protect mod defaults.`, "warn");
    }
  },
});

const WEB_DRAFT_STORAGE_KEY = "arcane_wilds_web_draft_v1";

function saveWebDraft() {
  if (state.connected) return;
  try {
    const payload = {
      userSpells: state.userSpells,
      userCombos: state.userCombos,
      userQuickCast: {
        overrideDefaults: state.userQuickCast.overrideDefaults === true,
        bindings: state.userQuickCast.bindings,
      },
    };
    window.localStorage.setItem(WEB_DRAFT_STORAGE_KEY, JSON.stringify(payload));
  } catch {
    // Ignore storage errors (private mode / quota)
  }
}

function loadWebDraft() {
  try {
    const raw = window.localStorage.getItem(WEB_DRAFT_STORAGE_KEY);
    if (!raw) return false;
    const saved = JSON.parse(raw);
    if (saved?.userSpells) {
      state.userSpells.disabledDefaults = Array.isArray(saved.userSpells.disabledDefaults) ? saved.userSpells.disabledDefaults : [];
      state.userSpells.enabledDefaults = Array.isArray(saved.userSpells.enabledDefaults) ? saved.userSpells.enabledDefaults : [];
      state.userSpells.spells = saved.userSpells.spells && typeof saved.userSpells.spells === "object" ? saved.userSpells.spells : {};
    }
    if (saved?.userCombos) {
      state.userCombos.disableAllDefaults = saved.userCombos.disableAllDefaults === true;
      state.userCombos.disabledDefaultIds = Array.isArray(saved.userCombos.disabledDefaultIds) ? saved.userCombos.disabledDefaultIds : [];
      state.userCombos.enabledDefaultIds = Array.isArray(saved.userCombos.enabledDefaultIds) ? saved.userCombos.enabledDefaultIds : [];
      state.userCombos.rules = Array.isArray(saved.userCombos.rules) ? saved.userCombos.rules : [];
    }
    if (saved?.userQuickCast) {
      state.userQuickCast.overrideDefaults = saved.userQuickCast.overrideDefaults === true;
      state.userQuickCast.bindings = Array.isArray(saved.userQuickCast.bindings) ? saved.userQuickCast.bindings : [];
    }
    return true;
  } catch {
    return false;
  }
}

async function fetchJsonText(url) {
  const res = await fetch(url, { cache: "no-store" });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return await res.text();
}

async function tryFetchJsonText(url) {
  try {
    return await fetchJsonText(url);
  } catch {
    return null;
  }
}

async function loadStaticDefaultsAndCatalog() {
  const [catalogRaw, spellsRaw, combosRaw, qcRaw, versionRaw] = await Promise.all([
    tryFetchJsonText("./data/fallback_catalog.json"),
    tryFetchJsonText("./data/defaults_spells.json"),
    tryFetchJsonText("./data/defaults_combos.json"),
    tryFetchJsonText("./data/defaults_quickcast.json"),
    tryFetchJsonText("./data/version.json"),
  ]);

  if (versionRaw) {
    try {
      const ver = JSON.parse(versionRaw);
      if (ver?.modVersion) state.modVersion = String(ver.modVersion);
    } catch {
      // Ignore malformed version.json
    }
  }

  if (catalogRaw) {
    try {
      const mig = migrateDocument("detected_catalog", parseJsonc(catalogRaw));
      if (!mig.error && mig.doc) {
        catalogStore.setCatalog(mig.doc);
        if (mig.doc.modVersion && mig.doc.modVersion !== "local-fallback") {
          state.modVersion = mig.doc.modVersion;
        }
      }
    } catch (err) {
      console.warn("Static fallback catalog load failed:", err);
    }
  }

  if (spellsRaw) {
    try {
      const defSpMig = migrateDocument("custom_spells", parseJsonc(spellsRaw));
      if (!defSpMig.error && defSpMig.doc) state.defaults.spells = defSpMig.doc.spells || {};
    } catch (err) {
      console.warn("Static default spells load failed:", err);
    }
  }

  if (combosRaw) {
    try {
      const defCbMig = migrateDocument("combo_rules", parseJsonc(combosRaw));
      if (!defCbMig.error && defCbMig.doc) state.defaults.rules = defCbMig.doc.rules || [];
    } catch (err) {
      console.warn("Static default combos load failed:", err);
    }
  }

  if (qcRaw) {
    try {
      const parsedQc = JSON.parse(qcRaw);
      const list = Array.isArray(parsedQc) ? parsedQc : Array.isArray(parsedQc?.bindings) ? parsedQc.bindings : [];
      state.defaults.quickCast = list;
      state.userQuickCast.defaultBindings = structuredClone(list);
    } catch (err) {
      console.warn("Static default quick-cast load failed:", err);
    }
  }
}

async function loadCatalogFromServer() {
  try {
    const raw = await fetchJsonText("/api/catalog");
    const mig = migrateDocument("detected_catalog", parseJsonc(raw));
    if (!mig.error && mig.doc) {
      catalogStore.setCatalog(mig.doc);
      if (mig.doc.modVersion) state.modVersion = mig.doc.modVersion;
      updateCountsAndStats();
    }
  } catch (err) {
    console.warn("Catalog load failed:", err);
  }
}

async function bootstrap() {
  try {
    const status = JSON.parse(await fetchJsonText("/api/status"));
    if (status?.ok) {
      state.connected = true;
      state.userDir = status.userDir || "";
      el.connectionBadge.textContent = "Connected (User Profile)";
      el.connectionBadge.title = `User Profile: ${state.userDir}\nMod Dir: ${status.modDir || ""}`;
      el.connectionBadge.className = "status-pill status-connected";
      el.standaloneBanner.classList.add("hidden");

      await loadCatalogFromServer();

      const [defaultsRaw, userSpellsRaw, userCombosRaw, userQcRaw] = await Promise.all([
        fetchJsonText("/api/defaults"),
        fetchJsonText("/api/user/spells"),
        fetchJsonText("/api/user/combos"),
        fetchJsonText("/api/user/quickcast"),
      ]);

      const defs = JSON.parse(defaultsRaw);
      const defSpMig = migrateDocument("custom_spells", parseJsonc(defs.spellsRaw || "{}"));
      if (!defSpMig.error && defSpMig.doc) state.defaults.spells = defSpMig.doc.spells || {};
      const defCbMig = migrateDocument("combo_rules", parseJsonc(defs.combosRaw || "{}"));
      if (!defCbMig.error && defCbMig.doc) state.defaults.rules = defCbMig.doc.rules || [];
      state.defaults.quickCast = Array.isArray(defs.quickCast) ? defs.quickCast : [];
      state.userQuickCast.defaultBindings = structuredClone(state.defaults.quickCast);

      const uSpMig = migrateDocument("user_spells", parseJsonc(userSpellsRaw));
      if (!uSpMig.error && uSpMig.doc) {
        state.userSpells.disabledDefaults = Array.isArray(uSpMig.doc.disabledDefaults) ? uSpMig.doc.disabledDefaults : [];
        state.userSpells.enabledDefaults = Array.isArray(uSpMig.doc.enabledDefaults) ? uSpMig.doc.enabledDefaults : [];
        state.userSpells.spells = uSpMig.doc.spells || {};
      }

      const uCbMig = migrateDocument("user_combos", parseJsonc(userCombosRaw));
      if (!uCbMig.error && uCbMig.doc) {
        state.userCombos.disableAllDefaults = uCbMig.doc.disableAllDefaults === true;
        state.userCombos.disabledDefaultIds = Array.isArray(uCbMig.doc.disabledDefaultIds) ? uCbMig.doc.disabledDefaultIds : [];
        state.userCombos.enabledDefaultIds = Array.isArray(uCbMig.doc.enabledDefaultIds) ? uCbMig.doc.enabledDefaultIds : [];
        state.userCombos.rules = Array.isArray(uCbMig.doc.rules) ? uCbMig.doc.rules : [];
      }

      const uQcMig = migrateDocument("user_quick_cast", parseJsonc(userQcRaw));
      if (!uQcMig.error && uQcMig.doc) {
        state.userQuickCast.overrideDefaults = uQcMig.doc.overrideDefaults === true;
        state.userQuickCast.bindings = Array.isArray(uQcMig.doc.bindings) ? uQcMig.doc.bindings : [];
      }

      updateCountsAndStats();
      combosTab.render();
      spellsTab.render();
      quickCastTab.render();
      return;
    }
  } catch {
    // Fall through to standalone mode
  }

  state.connected = false;
  const isHostedWeb = window.location.protocol === "http:" || window.location.protocol === "https:";
  if (isHostedWeb) {
    el.connectionBadge.textContent = "Web Mode";
    el.connectionBadge.title = "Hosted Web Studio — edits auto-save in your browser; download JSON to install.";
    if (el.standaloneBannerText) {
      el.standaloneBannerText.innerHTML =
        '<strong>Web Mode:</strong> Your edits auto-save in this browser. Click <strong>Save</strong> or <strong>Bundle</strong> to download JSON and drop it into <code>%LOCALAPPDATA%\\RSDragonwilds\\Saved\\Config\\ArcaneWilds</code>, or run <code>Launch-ArcaneWilds-Editor.bat</code> for 1-click Save.';
    }
  } else {
    el.connectionBadge.textContent = "Standalone Mode";
  }
  el.connectionBadge.className = "status-pill status-standalone";
  el.standaloneBanner.classList.remove("hidden");

  await loadStaticDefaultsAndCatalog();
  loadWebDraft();

  updateCountsAndStats();
  combosTab.render();
  spellsTab.render();
  quickCastTab.render();
}

async function saveUserSpells() {
  const payload = {
    schemaVersion: CURRENT_VERSIONS.user_spells,
    format: FORMAT_IDS.user_spells,
    disabledDefaults: state.userSpells.disabledDefaults,
    enabledDefaults: state.userSpells.enabledDefaults,
    spells: state.userSpells.spells,
  };
  const jsonText = JSON.stringify(payload, null, 2);

  if (state.connected) {
    try {
      const res = await fetch("/api/user/spells", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: jsonText,
      });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || `HTTP ${res.status}`);
      state.dirtySpells = false;
      toast("Saved user_spells.json to %LOCALAPPDATA%\\RSDragonwilds\\Saved\\Config\\ArcaneWilds — persists across mod updates!", "success");
    } catch (err) {
      toast(`Failed to save user_spells.json: ${err.message}`, "error");
    }
  } else {
    downloadJsonFile("user_spells.json", jsonText);
    toast("Downloaded user_spells.json (place in %LOCALAPPDATA%\\RSDragonwilds\\Saved\\Config\\ArcaneWilds\\).", "warn");
  }
}

async function saveUserCombos() {
  const payload = {
    schemaVersion: CURRENT_VERSIONS.user_combos,
    format: FORMAT_IDS.user_combos,
    disableAllDefaults: state.userCombos.disableAllDefaults === true,
    disabledDefaultIds: state.userCombos.disabledDefaultIds,
    enabledDefaultIds: state.userCombos.enabledDefaultIds,
    rules: state.userCombos.rules.map(cleanRuleForSave),
  };
  const jsonText = JSON.stringify(payload, null, 2);

  if (state.connected) {
    try {
      const res = await fetch("/api/user/combos", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: jsonText,
      });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || `HTTP ${res.status}`);
      state.dirtyCombos = false;
      toast("Saved user_combos.json to %LOCALAPPDATA%\\RSDragonwilds\\Saved\\Config\\ArcaneWilds — persists across mod updates!", "success");
    } catch (err) {
      toast(`Failed to save user_combos.json: ${err.message}`, "error");
    }
  } else {
    downloadJsonFile("user_combos.json", jsonText);
    toast("Downloaded user_combos.json (place in %LOCALAPPDATA%\\RSDragonwilds\\Saved\\Config\\ArcaneWilds\\).", "warn");
  }
}

async function saveUserQuickCast() {
  const payload = {
    schemaVersion: CURRENT_VERSIONS.user_quick_cast,
    format: FORMAT_IDS.user_quick_cast,
    overrideDefaults: state.userQuickCast.overrideDefaults === true,
    bindings: state.userQuickCast.bindings,
  };
  const jsonText = JSON.stringify(payload, null, 2);

  if (state.connected) {
    try {
      const res = await fetch("/api/user/quickcast", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: jsonText,
      });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || `HTTP ${res.status}`);
      state.dirtyQuickCast = false;
      toast("Saved user_quick_cast.json to %LOCALAPPDATA%\\RSDragonwilds\\Saved\\Config\\ArcaneWilds!", "success");
    } catch (err) {
      toast(`Failed to save user_quick_cast.json: ${err.message}`, "error");
    }
  } else {
    downloadJsonFile("user_quick_cast.json", jsonText);
    toast("Downloaded user_quick_cast.json (place in %LOCALAPPDATA%\\RSDragonwilds\\Saved\\Config\\ArcaneWilds\\).", "warn");
  }
}

async function resetUserQuickCast() {
  state.userQuickCast.overrideDefaults = false;
  state.userQuickCast.bindings = [];
  if (state.connected) {
    try {
      await fetch("/api/user/quickcast", { method: "DELETE" });
    } catch {
      // Ignore
    }
  } else {
    saveWebDraft();
  }
  updateCountsAndStats();
  quickCastTab.render();
  toast("Reset Quick-Cast to mod defaults.", "info");
}

async function exportAndReveal(kind) {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
  let envelope;
  let filename;

  if (kind === "user_spells") {
    envelope = buildExportEnvelope("user_spells", {
      disabledDefaults: state.userSpells.disabledDefaults,
      spells: state.userSpells.spells,
    }, state.modVersion);
    filename = `user_spells-${stamp}.json`;
  } else if (kind === "user_combos") {
    envelope = buildExportEnvelope("user_combos", {
      disableAllDefaults: state.userCombos.disableAllDefaults,
      disabledDefaultIds: state.userCombos.disabledDefaultIds,
      rules: state.userCombos.rules.map(cleanRuleForSave),
    }, state.modVersion);
    filename = `user_combos-${stamp}.json`;
  } else if (kind === "user_quick_cast") {
    envelope = buildExportEnvelope("user_quick_cast", {
      overrideDefaults: state.userQuickCast.overrideDefaults,
      bindings: state.userQuickCast.bindings,
    }, state.modVersion);
    filename = `user_quick_cast-${stamp}.json`;
  } else {
    envelope = buildExportEnvelope("bundle", {
      disabledDefaults: state.userSpells.disabledDefaults,
      spells: state.userSpells.spells,
      disableAllDefaults: state.userCombos.disableAllDefaults,
      disabledDefaultIds: state.userCombos.disabledDefaultIds,
      rules: state.userCombos.rules.map(cleanRuleForSave),
      quickCast: state.userQuickCast.overrideDefaults
        ? {
            schemaVersion: CURRENT_VERSIONS.user_quick_cast,
            format: FORMAT_IDS.user_quick_cast,
            overrideDefaults: true,
            bindings: state.userQuickCast.bindings,
          }
        : undefined,
    }, state.modVersion);
    filename = `arcane-wilds-user-bundle-${stamp}.json`;
  }

  const content = JSON.stringify(envelope, null, 2);

  if (state.connected) {
    try {
      const res = await fetch("/api/export", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ filename, content, openExplorer: true }),
      });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || `HTTP ${res.status}`);
      toast(`Exported ${data.filename} and opened Windows Explorer!`, "success");
    } catch (err) {
      toast(`Export failed: ${err.message}`, "error");
    }
  } else {
    downloadJsonFile(filename, content);
    toast(`Downloaded ${filename} (schema v${envelope.schemaVersion}).`, "info");
  }
}

function downloadJsonFile(filename, text) {
  const blob = new Blob([text + "\n"], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

// Event bindings
el.tabBtnCombos.addEventListener("click", () => switchTab("combos"));
el.tabBtnSpells.addEventListener("click", () => switchTab("spells"));
el.tabBtnQuickCast.addEventListener("click", () => switchTab("quickcast"));

document.getElementById("btn-add-combo").addEventListener("click", () => combosTab.addNewCombo());
document.getElementById("btn-combo-new-spell").addEventListener("click", () => {
  const newId = spellsTab.createNewSpell("MyCustomSpell");
  switchTab("spells");
  toast(`Created '${newId}' — edit it here, then pick it in any Combo dropdown!`, "success");
});
document.getElementById("btn-import-combos").addEventListener("click", () => importModal.open("user_combos"));
document.getElementById("btn-export-combos").addEventListener("click", () => exportAndReveal("user_combos"));
document.getElementById("btn-save-combos").addEventListener("click", () => saveUserCombos());

document.getElementById("btn-add-spell").addEventListener("click", () => spellsTab.createNewSpell("MyCustomSpell"));
document.getElementById("btn-import-spells").addEventListener("click", () => importModal.open("user_spells"));
document.getElementById("btn-export-spells").addEventListener("click", () => exportAndReveal("user_spells"));
document.getElementById("btn-save-spells").addEventListener("click", () => saveUserSpells());

document.getElementById("btn-add-qc").addEventListener("click", () => quickCastTab.addBinding());
document.getElementById("btn-reset-qc").addEventListener("click", () => resetUserQuickCast());
document.getElementById("btn-import-qc").addEventListener("click", () => importModal.open("user_quick_cast"));
document.getElementById("btn-export-qc").addEventListener("click", () => exportAndReveal("user_quick_cast"));
document.getElementById("btn-save-qc").addEventListener("click", () => saveUserQuickCast());

document.getElementById("btn-export-bundle-1").addEventListener("click", () => exportAndReveal("bundle"));
document.getElementById("btn-export-bundle-2").addEventListener("click", () => exportAndReveal("bundle"));

el.btnOpenUserDir.addEventListener("click", async () => {
  if (!state.connected) {
    toast("Run Launch-ArcaneWilds-Editor.bat to open the persistent user folder directly.", "warn");
    return;
  }
  await fetch("/api/open-user-dir", { method: "POST" });
});

el.btnRefreshCatalog.addEventListener("click", async () => {
  if (!state.connected) {
    el.fileInputCatalog.click();
    return;
  }
  await loadCatalogFromServer();
  combosTab.render();
  spellsTab.render();
  quickCastTab.render();
  toast("Refreshed detected asset catalog from mod folder.", "info");
});

el.btnLoadCatalogFile.addEventListener("click", () => el.fileInputCatalog.click());
el.fileInputCatalog.addEventListener("change", () => {
  const file = el.fileInputCatalog.files?.[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    try {
      const mig = migrateDocument("detected_catalog", parseJsonc(String(reader.result || "")));
      if (mig.error) throw new Error(mig.error);
      catalogStore.setCatalog(mig.doc);
      updateCountsAndStats();
      combosTab.render();
      spellsTab.render();
      quickCastTab.render();
      toast(`Loaded ${file.name} (${catalogStore.getStats().detectedSpells} spells, ${catalogStore.getStats().vfx} VFX, ${catalogStore.getStats().sfx} SFX).`, "success");
    } catch (err) {
      toast(`Failed to load catalog: ${err.message}`, "error");
    }
  };
  reader.readAsText(file);
});

bootstrap();
