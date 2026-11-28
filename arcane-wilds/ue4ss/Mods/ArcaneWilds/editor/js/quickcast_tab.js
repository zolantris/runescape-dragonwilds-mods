// Arcane Wilds - Quick-Cast Hotkey Tab (Saved to %LOCALAPPDATA%\ArcaneWilds\user_quick_cast.json)

import { createCombobox } from "./combobox.js";

const MODIFIERS = ["BLOCK", "SHIFT", "ALT", "CTRL", "NONE"];

export class QuickCastTab {
  constructor({ containerEl, modeBadgeEl, catalogStore, getState, onDirty }) {
    this.containerEl = containerEl;
    this.modeBadgeEl = modeBadgeEl;
    this.catalogStore = catalogStore;
    this.getState = getState;
    this.onDirty = onDirty;
  }

  addBinding() {
    const qc = this.getState();
    if (!qc.overrideDefaults) {
      qc.bindings = structuredClone(qc.defaultBindings || []);
      qc.overrideDefaults = true;
    }
    qc.bindings.push({
      enabled: true,
      modifier: "BLOCK",
      keys: [String(qc.bindings.length + 1)],
      target: "",
    });
    this.onDirty();
    this.render();
  }

  render() {
    const qc = this.getState();
    const isCustom = qc.overrideDefaults === true;
    const list = isCustom ? qc.bindings : (qc.defaultBindings || []);

    this.modeBadgeEl.textContent = isCustom
      ? "Custom User Bindings (Persists Across Updates)"
      : "Using Mod Defaults (Edit Any Slot to Customize)";
    this.modeBadgeEl.className = `status-pill ${isCustom ? "status-connected" : "status-schema"}`;

    this.containerEl.innerHTML = "";
    if (!list.length) {
      this.containerEl.innerHTML = `<div class="empty-state"><p>No quick-cast bindings configured. Click <strong>+ Add Binding</strong> to bind a spell to a hotkey.</p></div>`;
      return;
    }

    const ensureUserCopy = () => {
      if (!qc.overrideDefaults) {
        qc.bindings = structuredClone(qc.defaultBindings || []);
        qc.overrideDefaults = true;
      }
    };

    list.forEach((b, idx) => {
      const row = document.createElement("div");
      row.className = "qc-row";
      if (b.enabled === false) row.style.opacity = "0.6";

      const chk = document.createElement("input");
      chk.type = "checkbox";
      chk.checked = b.enabled !== false;
      chk.title = "Enable / Disable binding";
      chk.addEventListener("change", () => {
        ensureUserCopy();
        qc.bindings[idx].enabled = chk.checked;
        this.onDirty();
        this.render();
      });

      const modSel = document.createElement("select");
      modSel.className = "select";
      MODIFIERS.forEach((m) => {
        const opt = document.createElement("option");
        opt.value = m;
        opt.textContent = m;
        if (m === (b.modifier || "BLOCK")) opt.selected = true;
        modSel.appendChild(opt);
      });
      modSel.addEventListener("change", () => {
        ensureUserCopy();
        qc.bindings[idx].modifier = modSel.value;
        this.onDirty();
        this.render();
      });

      const keysInp = document.createElement("input");
      keysInp.type = "text";
      keysInp.className = "input";
      keysInp.placeholder = "e.g. 1, GP_X";
      keysInp.value = Array.isArray(b.keys) ? b.keys.join(", ") : String(b.keys || "");
      keysInp.addEventListener("input", () => {
        ensureUserCopy();
        qc.bindings[idx].keys = keysInp.value.split(/[,|;]/).map((k) => k.trim()).filter(Boolean);
        this.onDirty();
      });

      const targetCombo = createCombobox({
        value: b.target || "",
        placeholder: "Select spell or type combo chain…",
        getOptions: () => this.catalogStore.getComboSpellOptions(""),
        onChange: (val) => {
          ensureUserCopy();
          qc.bindings[idx].target = val;
          this.onDirty();
        },
      });

      const delBtn = document.createElement("button");
      delBtn.type = "button";
      delBtn.className = "btn btn-danger btn-sm";
      delBtn.textContent = "Delete";
      delBtn.addEventListener("click", () => {
        ensureUserCopy();
        qc.bindings.splice(idx, 1);
        this.onDirty();
        this.render();
      });

      row.append(chk, modSel, keysInp, targetCombo, delBtn);
      this.containerEl.appendChild(row);
    });
  }
}
