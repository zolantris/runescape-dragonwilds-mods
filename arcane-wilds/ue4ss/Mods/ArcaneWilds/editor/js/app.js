// Arcane Wilds - Main Web GUI Controller

import { CatalogStore } from "./catalog_store.js";
import { CombosTab, cleanRuleForSave } from "./combos_tab.js";
import { SpellsTab } from "./spells_tab.js";
import { ImportModal } from "./io_modal.js";
import {
  MOD_SCHEMA_VERSION,
  CURRENT_VERSIONS,
  parseJsonc,
  migrateDocument,
  buildExportEnvelope,
} from "./schema_migrator.js";

const state = {
  connected: false,
  modVersion: "1.0.0",
  activeTab: "combos",
  spells: {},
  rules: [],
  dirtySpells: false,
  dirtyCombos: false,
};

const catalogStore = new CatalogStore();

// DOM references
const el = {
  tabBtnCombos: document.getElementById("tab-btn-combos"),
  tabBtnSpells: document.getElementById("tab-btn-spells"),
  panelCombos: document.getElementById("panel-combos"),
  panelSpells: document.getElementById("panel-spells"),
  badgeCombosCount: document.getElementById("badge-combos-count"),
  badgeSpellsCount: document.getElementById("badge-spells-count"),
  statSpells: document.getElementById("stat-spells"),
  statVfx: document.getElementById("stat-vfx"),
  statSfx: document.getElementById("stat-sfx"),
  statMontages: document.getElementById("stat-montages"),
  connectionBadge: document.getElementById("connection-badge"),
  schemaBadge: document.getElementById("schema-badge"),
  standaloneBanner: document.getElementById("standalone-banner"),
  btnRefreshCatalog: document.getElementById("btn-refresh-catalog"),
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
  setTimeout(() => div.remove(), 4200);
}

function switchTab(tab) {
  state.activeTab = tab;
  const isCombos = tab === "combos";
  el.tabBtnCombos.classList.toggle("active", isCombos);
  el.tabBtnSpells.classList.toggle("active", !isCombos);
  el.tabBtnCombos.setAttribute("aria-selected", String(isCombos));
  el.tabBtnSpells.setAttribute("aria-selected", String(!isCombos));
  el.panelCombos.classList.toggle("active", isCombos);
  el.panelSpells.classList.toggle("active", !isCombos);
}

function updateCountsAndStats() {
  catalogStore.setCustomSpells(state.spells);
  const stats = catalogStore.getStats();
  el.badgeCombosCount.textContent = String(state.rules.length);
  el.badgeSpellsCount.textContent = String(Object.keys(state.spells).length);
  el.statSpells.textContent = String(stats.spells);
  el.statVfx.textContent = String(stats.vfx);
  el.statSfx.textContent = String(stats.sfx);
  el.statMontages.textContent = String(stats.montages);
}

const combosTab = new CombosTab({
  containerEl: document.getElementById("combos-list"),
  searchInputEl: document.getElementById("combo-search"),
  catalogStore,
  getRules: () => state.rules,
  setRules: (r) => { state.rules = r; },
  onDirty: () => {
    state.dirtyCombos = true;
    updateCountsAndStats();
  },
  onCreateCustomSpell: (onCreatedCb) => {
    const newId = spellsTab.createNewSpell("CustomComboSpell");
    switchTab("spells");
    toast(`Created '${newId}' — customize it and switch back to Combos!`, "success");
    if (typeof onCreatedCb === "function") onCreatedCb(newId);
  },
});

const spellsTab = new SpellsTab({
  listEl: document.getElementById("spells-list"),
  editorEl: document.getElementById("spell-editor-container"),
  searchInputEl: document.getElementById("spell-search"),
  catalogStore,
  getSpells: () => state.spells,
  setSpells: (s) => { state.spells = s; },
  onDirty: () => {
    state.dirtySpells = true;
    updateCountsAndStats();
  },
});

const importModal = new ImportModal({
  modalEl: document.getElementById("io-modal"),
  titleEl: document.getElementById("io-modal-title"),
  bodyEl: document.getElementById("io-modal-body"),
  footerEl: document.getElementById("io-modal-footer"),
  closeBtn: document.getElementById("io-modal-close"),
  onApplyImport: ({ kind, doc, notes, mode }) => {
    if (kind === "custom_spells" || kind === "bundle") {
      if (mode === "replace") {
        state.spells = structuredClone(doc.spells || {});
      } else {
        state.spells = { ...state.spells, ...(doc.spells || {}) };
      }
      state.dirtySpells = true;
    }
    if (kind === "combo_rules" || kind === "bundle") {
      if (mode === "replace") {
        state.rules = structuredClone(doc.rules || []);
      } else {
        state.rules = [...state.rules, ...(doc.rules || [])];
      }
      state.dirtyCombos = true;
    }
    updateCountsAndStats();
    combosTab.render();
    spellsTab.render();
    const migSuffix = notes.length ? ` (${notes.length} migration step(s) applied)` : "";
    toast(`Imported ${kind} (${mode})${migSuffix}. Click Save to apply in-game.`, "success");
  },
});

// API Helpers
async function fetchJsonText(url) {
  const res = await fetch(url, { cache: "no-store" });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return await res.text();
}

async function loadCatalogFromServer() {
  try {
    const raw = await fetchJsonText("/api/catalog");
    const parsed = parseJsonc(raw);
    const mig = migrateDocument("detected_catalog", parsed);
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
    const statusRaw = await fetchJsonText("/api/status");
    const status = JSON.parse(statusRaw);
    if (status?.ok) {
      state.connected = true;
      el.connectionBadge.textContent = "Connected to Mod Folder";
      el.connectionBadge.className = "status-pill status-connected";
      el.standaloneBanner.classList.add("hidden");

      await loadCatalogFromServer();

      const [spellsRaw, combosRaw] = await Promise.all([
        fetchJsonText("/api/spells"),
        fetchJsonText("/api/combos"),
      ]);

      const spMig = migrateDocument("custom_spells", parseJsonc(spellsRaw));
      if (!spMig.error && spMig.doc) {
        state.spells = spMig.doc.spells || {};
        if (spMig.notes.length) toast(spMig.notes.join("; "), "info");
      }

      const cbMig = migrateDocument("combo_rules", parseJsonc(combosRaw));
      if (!cbMig.error && cbMig.doc) {
        state.rules = cbMig.doc.rules || [];
        if (cbMig.notes.length) toast(cbMig.notes.join("; "), "info");
      }

      updateCountsAndStats();
      combosTab.render();
      spellsTab.render();
      return;
    }
  } catch {
    // Fall through to standalone mode
  }

  state.connected = false;
  el.connectionBadge.textContent = "Standalone Mode";
  el.connectionBadge.className = "status-pill status-standalone";
  el.standaloneBanner.classList.remove("hidden");
  updateCountsAndStats();
  combosTab.render();
  spellsTab.render();
}

async function saveSpells() {
  const payload = {
    $schema: "./schemas/custom_spells.schema.json",
    schemaVersion: CURRENT_VERSIONS.custom_spells,
    spells: state.spells,
  };
  const jsonText = JSON.stringify(payload, null, 2);

  if (state.connected) {
    try {
      const res = await fetch("/api/spells", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: jsonText,
      });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || `HTTP ${res.status}`);
      state.dirtySpells = false;
      toast("Saved custom_spells.json — game will hot-reload automatically!", "success");
    } catch (err) {
      toast(`Failed to save custom_spells.json: ${err.message}`, "error");
    }
  } else {
    downloadJsonFile("custom_spells.json", jsonText);
    toast("Downloaded custom_spells.json (replace file in ArcaneWilds folder).", "warn");
  }
}

async function saveCombos() {
  const payload = {
    $schema: "./schemas/combo_rules.schema.json",
    schemaVersion: CURRENT_VERSIONS.combo_rules,
    rules: state.rules.map(cleanRuleForSave),
  };
  const jsonText = JSON.stringify(payload, null, 2);

  if (state.connected) {
    try {
      const res = await fetch("/api/combos", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: jsonText,
      });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || `HTTP ${res.status}`);
      state.dirtyCombos = false;
      toast("Saved combo_rules.json — game will hot-reload automatically!", "success");
    } catch (err) {
      toast(`Failed to save combo_rules.json: ${err.message}`, "error");
    }
  } else {
    downloadJsonFile("combo_rules.json", jsonText);
    toast("Downloaded combo_rules.json (replace file in ArcaneWilds folder).", "warn");
  }
}

async function exportAndReveal(kind) {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
  let envelope;
  let filename;

  if (kind === "custom_spells") {
    envelope = buildExportEnvelope("custom_spells", state.spells, state.modVersion);
    filename = `custom_spells-${stamp}.json`;
  } else if (kind === "combo_rules") {
    envelope = buildExportEnvelope("combo_rules", state.rules.map(cleanRuleForSave), state.modVersion);
    filename = `combo_rules-${stamp}.json`;
  } else {
    envelope = buildExportEnvelope("bundle", {
      spells: state.spells,
      rules: state.rules.map(cleanRuleForSave),
    }, state.modVersion);
    filename = `arcane-wilds-bundle-${stamp}.json`;
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

document.getElementById("btn-add-combo").addEventListener("click", () => combosTab.addNewCombo());
document.getElementById("btn-combo-new-spell").addEventListener("click", () => {
  const newId = spellsTab.createNewSpell("NewCustomSpell");
  switchTab("spells");
  toast(`Created '${newId}' — edit it here, then pick it in any Combo dropdown!`, "success");
});
document.getElementById("btn-import-combos").addEventListener("click", () => importModal.open("combo_rules"));
document.getElementById("btn-export-combos").addEventListener("click", () => exportAndReveal("combo_rules"));
document.getElementById("btn-save-combos").addEventListener("click", () => saveCombos());

document.getElementById("btn-add-spell").addEventListener("click", () => spellsTab.createNewSpell("NewCustomSpell"));
document.getElementById("btn-import-spells").addEventListener("click", () => importModal.open("custom_spells"));
document.getElementById("btn-export-spells").addEventListener("click", () => exportAndReveal("custom_spells"));
document.getElementById("btn-save-spells").addEventListener("click", () => saveSpells());

document.getElementById("btn-export-bundle-1").addEventListener("click", () => exportAndReveal("bundle"));
document.getElementById("btn-export-bundle-2").addEventListener("click", () => exportAndReveal("bundle"));

el.btnRefreshCatalog.addEventListener("click", async () => {
  if (!state.connected) {
    el.fileInputCatalog.click();
    return;
  }
  await loadCatalogFromServer();
  combosTab.render();
  spellsTab.render();
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
      toast(`Loaded ${file.name} (${catalogStore.getStats().detectedSpells} spells, ${catalogStore.getStats().vfx} VFX, ${catalogStore.getStats().sfx} SFX).`, "success");
    } catch (err) {
      toast(`Failed to load catalog: ${err.message}`, "error");
    }
  };
  reader.readAsText(file);
});

bootstrap();
