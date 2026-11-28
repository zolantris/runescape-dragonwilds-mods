// Arcane Wilds - Combos Tab (Row-Based Spell Combo Creator)

import { createCombobox } from "./combobox.js";

function normalizeStages(rule) {
  if (Array.isArray(rule.stages) && rule.stages.length > 0) {
    return rule.stages.map((st) => {
      const spells = Array.isArray(st.spells)
        ? [...st.spells]
        : st.spell
          ? [st.spell]
          : [""];
      return {
        category: st.category ?? "",
        spells: spells.length ? spells : [""],
        speed: typeof st.speed === "number" ? st.speed : 1.0,
      };
    });
  }
  return [{ category: "Air", spells: ["bolt"], speed: 1.5 }];
}

export function cleanRuleForSave(rule) {
  const out = {};
  if (rule.name && rule.name.trim() !== "") out.name = rule.name.trim();
  if (rule.description && rule.description.trim() !== "") out.description = rule.description.trim();
  out.enabled = rule.enabled !== false;
  out.weight = Math.max(0.01, Number(rule.weight) || 1);

  if (Array.isArray(rule.stages) && rule.stages.length > 0) {
    out.stages = rule.stages.map((st) => {
      const cleanSpells = (st.spells || []).map((s) => String(s || "").trim()).filter(Boolean);
      const stageOut = {};
      if (st.category && st.category.trim() !== "") {
        stageOut.category = st.category.trim();
      }
      if (!stageOut.category && cleanSpells.length === 1) {
        stageOut.spell = cleanSpells[0];
      } else {
        stageOut.spells = cleanSpells.length ? cleanSpells : ["bolt"];
      }
      stageOut.speed = Math.max(1.0, Number(st.speed) || 1.0);
      return stageOut;
    });
  } else if (rule.chain && rule.chain.trim() !== "") {
    out.chain = rule.chain.trim();
  } else {
    out.stages = [{ category: "Air", spells: ["bolt"], speed: 1.0 }];
  }
  return out;
}

export class CombosTab {
  constructor({
    containerEl,
    searchInputEl,
    disableAllDefaultsEl,
    catalogStore,
    getDefaultRules,
    getUserCombosState,
    onDirty,
    onCreateCustomSpell,
  }) {
    this.containerEl = containerEl;
    this.searchInputEl = searchInputEl;
    this.disableAllDefaultsEl = disableAllDefaultsEl;
    this.catalogStore = catalogStore;
    this.getDefaultRules = getDefaultRules;
    this.getUserCombosState = getUserCombosState;
    this.onDirty = onDirty;
    this.onCreateCustomSpell = onCreateCustomSpell;
    this.expandedIndex = null;
    this.filterText = "";

    this.searchInputEl.addEventListener("input", () => {
      this.filterText = this.searchInputEl.value.trim().toLowerCase();
      this.render();
    });

    if (this.disableAllDefaultsEl) {
      this.disableAllDefaultsEl.addEventListener("change", () => {
        const uState = this.getUserCombosState();
        uState.disableAllDefaults = this.disableAllDefaultsEl.checked;
        this.onDirty();
        this.render();
      });
    }
  }

  addNewCombo() {
    const uState = this.getUserCombosState();
    const newRule = {
      name: `My Combo ${uState.rules.length + 1}`,
      enabled: true,
      weight: 5,
      stages: [
        { category: "Air", spells: ["bolt", "gust"], speed: 2.0 },
      ],
    };
    uState.rules.push(newRule);
    this.expandedIndex = uState.rules.length - 1;
    this.onDirty();
    this.render();
  }

  cloneDefaultToUser(defRule) {
    const uState = this.getUserCombosState();
    const copy = structuredClone(defRule);
    delete copy.id;
    copy.name = `${copy.name || "Combo"} (Custom)`;
    copy.enabled = true;
    uState.rules.push(copy);
    this.expandedIndex = uState.rules.length - 1;
    this.onDirty();
    this.render();
  }

  render() {
    const uState = this.getUserCombosState();
    const rules = uState.rules;
    const defaultRules = this.getDefaultRules() || [];
    const disabledSet = new Set((uState.disabledDefaultIds || []).map((x) => String(x).toLowerCase()));
    const enabledSet = new Set((uState.enabledDefaultIds || []).map((x) => String(x).toLowerCase()));

    if (this.disableAllDefaultsEl) {
      this.disableAllDefaultsEl.checked = uState.disableAllDefaults === true;
    }

    this.containerEl.innerHTML = "";

    // Section 1: Player's Persistent Custom Combos
    const userTitle = document.createElement("div");
    userTitle.className = "layer-section-title";
    userTitle.innerHTML = `<span>My Custom Combos (${rules.length})</span><span class="badge-user">Persists Across Updates</span>`;
    this.containerEl.appendChild(userTitle);

    if (!rules.length) {
      const empty = document.createElement("div");
      empty.className = "empty-state";
      empty.style.padding = "20px";
      empty.innerHTML = `<p>No custom combos yet. Click <strong>+ Add Combo</strong> or clone a Mod Default below.</p>`;
      this.containerEl.appendChild(empty);
    }

    rules.forEach((rule, idx) => {
      if (this.filterText) {
        const hay = JSON.stringify(rule).toLowerCase();
        if (!hay.includes(this.filterText)) return;
      }

      const row = document.createElement("div");
      row.className = `combo-row${rule.enabled === false ? " disabled" : ""}`;

      // Row header (2-row layout: top metadata/actions + full-width combo flow row)
      const header = document.createElement("div");
      header.className = "combo-row-header";

      const topRow = document.createElement("div");
      topRow.className = "combo-row-top";

      const leftGroup = document.createElement("div");
      leftGroup.className = "combo-row-left";

      const toggle = document.createElement("input");
      toggle.type = "checkbox";
      toggle.checked = rule.enabled !== false;
      toggle.title = "Enable / Disable combo";
      toggle.addEventListener("change", () => {
        rule.enabled = toggle.checked;
        this.onDirty();
        this.render();
      });

      const titleCol = document.createElement("div");
      titleCol.className = "combo-row-title-block";
      const badgeRow = document.createElement("div");
      badgeRow.className = "combo-row-badge-row";
      const stageCount = Array.isArray(rule.stages) ? rule.stages.length : 1;
      badgeRow.innerHTML = `<span class="badge-user">Custom</span><span class="combo-row-meta">Weight: ${rule.weight ?? 1} · ${stageCount} stage(s)</span>`;
      const titleEl = document.createElement("div");
      titleEl.className = "combo-row-title";
      titleEl.textContent = rule.name || `Combo #${idx + 1}`;
      titleCol.append(badgeRow, titleEl);
      leftGroup.append(toggle, titleCol);

      const flowCol = document.createElement("div");
      flowCol.className = "combo-flow-preview";
      if (Array.isArray(rule.stages) && rule.stages.length > 0) {
        rule.stages.forEach((st, sIdx) => {
          if (sIdx > 0) {
            const arr = document.createElement("span");
            arr.className = "stage-arrow";
            arr.textContent = "→";
            flowCol.appendChild(arr);
          }
          const pill = document.createElement("span");
          pill.className = "stage-pill";
          const spList = Array.isArray(st.spells) ? st.spells : st.spell ? [st.spell] : [];
          const catHtml = st.category ? `<span class="stage-pill-cat">${escapeHtml(st.category)}</span>` : "";
          pill.innerHTML = `${catHtml}<span>${escapeHtml(spList.join(", ") || "(empty)")}</span><span class="stage-pill-spd">${Number(st.speed || 1).toFixed(1)}x</span>`;
          flowCol.appendChild(pill);
        });
      } else if (rule.chain) {
        const pill = document.createElement("span");
        pill.className = "stage-pill";
        pill.textContent = rule.chain;
        flowCol.appendChild(pill);
      }

      const actionsCol = document.createElement("div");
      actionsCol.className = "combo-row-actions";

      const isExpanded = this.expandedIndex === idx;
      const editBtn = makeBtn(isExpanded ? "Close" : "Edit", isExpanded ? "btn-primary btn-sm" : "btn-secondary btn-sm", () => {
        this.expandedIndex = isExpanded ? null : idx;
        this.render();
      });
      const upBtn = makeBtn("↑", "btn-ghost btn-sm", () => {
        if (idx === 0) return;
        [rules[idx - 1], rules[idx]] = [rules[idx], rules[idx - 1]];
        if (this.expandedIndex === idx) this.expandedIndex = idx - 1;
        this.onDirty();
        this.render();
      });
      upBtn.disabled = idx === 0;
      const downBtn = makeBtn("↓", "btn-ghost btn-sm", () => {
        if (idx >= rules.length - 1) return;
        [rules[idx + 1], rules[idx]] = [rules[idx], rules[idx + 1]];
        if (this.expandedIndex === idx) this.expandedIndex = idx + 1;
        this.onDirty();
        this.render();
      });
      downBtn.disabled = idx >= rules.length - 1;
      const dupBtn = makeBtn("Duplicate", "btn-ghost btn-sm", () => {
        const copy = structuredClone(rule);
        copy.name = `${copy.name || "Combo"} (Copy)`;
        rules.splice(idx + 1, 0, copy);
        this.expandedIndex = idx + 1;
        this.onDirty();
        this.render();
      });
      const delBtn = makeBtn("Delete", "btn-danger btn-sm", () => {
        rules.splice(idx, 1);
        if (this.expandedIndex === idx) this.expandedIndex = null;
        else if (this.expandedIndex !== null && this.expandedIndex > idx) this.expandedIndex--;
        this.onDirty();
        this.render();
      });

      actionsCol.append(editBtn, upBtn, downBtn, dupBtn, delBtn);
      topRow.append(leftGroup, actionsCol);
      header.append(topRow, flowCol);
      row.appendChild(header);

      if (isExpanded) {
        row.appendChild(this.renderRowEditor(rule));
      }

      this.containerEl.appendChild(row);
    });

    // Section 2: Read-Only Mod Default Combos (Toggleable + Cloneable)
    if (defaultRules.length > 0) {
      const defTitle = document.createElement("div");
      defTitle.className = "layer-section-title";
      defTitle.style.marginTop = "20px";
      defTitle.innerHTML = `<span>Mod Default Combos (${defaultRules.length})</span><span class="badge-builtin">Built-in · Read-Only</span>`;
      this.containerEl.appendChild(defTitle);

      defaultRules.forEach((defRule, dIdx) => {
        if (this.filterText) {
          const hay = JSON.stringify(defRule).toLowerCase();
          if (!hay.includes(this.filterText)) return;
        }
        const keyId = defRule.id || defRule.name || `default_${dIdx}`;
        const keyLower = keyId.toLowerCase();
        const shippedEnabled = defRule.enabled !== false;
        let isEffectivelyOn;
        if (uState.disableAllDefaults || disabledSet.has(keyLower)) {
          isEffectivelyOn = false;
        } else if (enabledSet.has(keyLower)) {
          isEffectivelyOn = true;
        } else {
          isEffectivelyOn = shippedEnabled;
        }

        const row = document.createElement("div");
        row.className = `combo-row${!isEffectivelyOn ? " disabled" : ""}`;

        const header = document.createElement("div");
        header.className = "combo-row-header";

        const topRow = document.createElement("div");
        topRow.className = "combo-row-top";

        const leftGroup = document.createElement("div");
        leftGroup.className = "combo-row-left";

        const toggle = document.createElement("input");
        toggle.type = "checkbox";
        toggle.checked = isEffectivelyOn;
        toggle.disabled = uState.disableAllDefaults === true;
        toggle.title = "Enable / Disable this built-in combo";
        toggle.addEventListener("change", () => {
          const disArr = new Set((uState.disabledDefaultIds || []).map((x) => String(x)));
          const enArr = new Set((uState.enabledDefaultIds || []).map((x) => String(x)));
          for (const x of [...disArr]) { if (x.toLowerCase() === keyLower) disArr.delete(x); }
          for (const x of [...enArr]) { if (x.toLowerCase() === keyLower) enArr.delete(x); }

          if (toggle.checked && !shippedEnabled) {
            enArr.add(keyId);
          } else if (!toggle.checked && shippedEnabled) {
            disArr.add(keyId);
          }
          uState.disabledDefaultIds = [...disArr];
          uState.enabledDefaultIds = [...enArr];
          this.onDirty();
          this.render();
        });

        const titleCol = document.createElement("div");
        titleCol.className = "combo-row-title-block";
        const badgeRow = document.createElement("div");
        badgeRow.className = "combo-row-badge-row";
        const shipNote = !shippedEnabled ? " · Off by default" : "";
        badgeRow.innerHTML = `<span class="badge-builtin">Built-in</span><span class="combo-row-meta">Weight: ${defRule.weight ?? 1}${shipNote}</span>`;
        const titleEl = document.createElement("div");
        titleEl.className = "combo-row-title";
        titleEl.textContent = defRule.name || keyId;
        titleCol.append(badgeRow, titleEl);
        leftGroup.append(toggle, titleCol);

        const flowCol = document.createElement("div");
        flowCol.className = "combo-flow-preview";
        if (Array.isArray(defRule.stages)) {
          defRule.stages.forEach((st, sIdx) => {
            if (sIdx > 0) {
              const arr = document.createElement("span");
              arr.className = "stage-arrow";
              arr.textContent = "→";
              flowCol.appendChild(arr);
            }
            const pill = document.createElement("span");
            pill.className = "stage-pill";
            const spList = Array.isArray(st.spells) ? st.spells : st.spell ? [st.spell] : [];
            const catHtml = st.category ? `<span class="stage-pill-cat">${escapeHtml(st.category)}</span>` : "";
            pill.innerHTML = `${catHtml}<span>${escapeHtml(spList.join(", "))}</span><span class="stage-pill-spd">${Number(st.speed || 1).toFixed(1)}x</span>`;
            flowCol.appendChild(pill);
          });
        }

        const actionsCol = document.createElement("div");
        actionsCol.className = "combo-row-actions";
        actionsCol.appendChild(makeBtn("Clone to My Combos", "btn-secondary btn-sm", () => {
          this.cloneDefaultToUser(defRule);
        }));

        topRow.append(leftGroup, actionsCol);
        header.append(topRow, flowCol);
        row.appendChild(header);
        this.containerEl.appendChild(row);
      });
    }
  }

  renderRowEditor(rule) {
    if (!Array.isArray(rule.stages) && !rule.chain) {
      rule.stages = normalizeStages(rule);
    }

    const editor = document.createElement("div");
    editor.className = "combo-row-editor";

    // Top metadata grid
    const metaGrid = document.createElement("div");
    metaGrid.className = "grid-4";

    metaGrid.appendChild(makeTextField("Combo Name", rule.name || "", (v) => {
      rule.name = v;
      this.onDirty();
    }));

    metaGrid.appendChild(makeNumberField("Roll Weight", rule.weight ?? 1, 0.1, 0.1, (v) => {
      rule.weight = v;
      this.onDirty();
    }));

    metaGrid.appendChild(makeTextField("Description (Optional)", rule.description || "", (v) => {
      rule.description = v;
      this.onDirty();
    }));

    const enabledWrap = document.createElement("div");
    enabledWrap.className = "field";
    enabledWrap.innerHTML = `<label>Status</label>`;
    const enInline = document.createElement("div");
    enInline.className = "field-inline";
    const enChk = document.createElement("input");
    enChk.type = "checkbox";
    enChk.checked = rule.enabled !== false;
    enChk.addEventListener("change", () => {
      rule.enabled = enChk.checked;
      this.onDirty();
      this.render();
    });
    const enLbl = document.createElement("label");
    enLbl.textContent = "Enabled in rotation";
    enInline.append(enChk, enLbl);
    enabledWrap.appendChild(enInline);
    metaGrid.appendChild(enabledWrap);

    editor.appendChild(metaGrid);

    // Stages list
    if (!Array.isArray(rule.stages)) {
      rule.stages = normalizeStages(rule);
      delete rule.chain;
    }

    const stagesSection = document.createElement("div");
    stagesSection.className = "stages-section";

    const stagesBar = document.createElement("div");
    stagesBar.className = "stage-card-header";
    stagesBar.innerHTML = `<strong>Combo Stages (${rule.stages.length})</strong>`;
    const barBtns = document.createElement("div");
    barBtns.className = "combo-row-actions";
    barBtns.appendChild(makeBtn("+ Add Stage", "btn-primary btn-sm", () => {
      rule.stages.push({ category: "Air", spells: ["bolt"], speed: 2.0 });
      this.onDirty();
      this.render();
    }));
    stagesBar.appendChild(barBtns);
    stagesSection.appendChild(stagesBar);

    rule.stages.forEach((stage, sIdx) => {
      if (!Array.isArray(stage.spells)) {
        stage.spells = stage.spell ? [stage.spell] : [""];
        delete stage.spell;
      }

      const card = document.createElement("div");
      card.className = "stage-card";

      const cardHead = document.createElement("div");
      cardHead.className = "stage-card-header";
      cardHead.innerHTML = `<strong>Stage ${sIdx + 1}</strong>`;
      const sBtns = document.createElement("div");
      sBtns.className = "combo-row-actions";
      if (rule.stages.length > 1) {
        sBtns.appendChild(makeBtn("Remove Stage", "btn-danger btn-xs", () => {
          rule.stages.splice(sIdx, 1);
          this.onDirty();
          this.render();
        }));
      }
      cardHead.appendChild(sBtns);
      card.appendChild(cardHead);

      const stageGrid = document.createElement("div");
      stageGrid.className = "grid-2";

      const catField = document.createElement("div");
      catField.className = "field";
      catField.innerHTML = `<label>Category (optional for custom spells)</label>`;
      catField.appendChild(createCombobox({
        value: stage.category || "",
        placeholder: "e.g. Air, Fire, Water, Earth, AncientMagicks…",
        getOptions: () => this.catalogStore.getCategoryOptions(),
        onChange: (val) => {
          stage.category = val;
          this.onDirty();
        },
      }));
      stageGrid.appendChild(catField);

      stageGrid.appendChild(makeNumberField("Speed Multiplier (x)", stage.speed ?? 1.0, 1.0, 0.1, (v) => {
        stage.speed = Math.max(1.0, v);
        this.onDirty();
      }));

      card.appendChild(stageGrid);

      // Spells in stage
      const spellsWrap = document.createElement("div");
      spellsWrap.className = "stage-spells-list";

      const spLabel = document.createElement("div");
      spLabel.className = "stage-card-header";
      spLabel.style.marginTop = "8px";
      spLabel.innerHTML = `<span class="combo-row-meta">SPELLS IN STAGE (ORDERED)</span>`;
      const spActions = document.createElement("div");
      spActions.className = "combo-row-actions";
      spActions.appendChild(makeBtn("+ Add Spell", "btn-secondary btn-xs", () => {
        stage.spells.push("");
        this.onDirty();
        this.render();
      }));
      spActions.appendChild(makeBtn("✦ Create Custom Spell", "btn-ghost btn-xs", () => {
        if (typeof this.onCreateCustomSpell === "function") {
          this.onCreateCustomSpell((newSpellId) => {
            if (newSpellId) {
              stage.spells.push(newSpellId);
              this.onDirty();
              this.render();
            }
          });
        }
      }));
      spLabel.appendChild(spActions);
      spellsWrap.appendChild(spLabel);

      stage.spells.forEach((spVal, spIdx) => {
        const spRow = document.createElement("div");
        spRow.className = "stage-spell-row";

        const num = document.createElement("span");
        num.className = "step-num";
        num.textContent = String(spIdx + 1);

        const combo = createCombobox({
          value: spVal || "",
          placeholder: "Select detected spell, alias, or custom spell…",
          getOptions: () => this.catalogStore.getComboSpellOptions(stage.category),
          onChange: (val) => {
            stage.spells[spIdx] = val;
            this.onDirty();
          },
        });

        const rmBtn = makeBtn("✕", "btn-danger btn-xs", () => {
          stage.spells.splice(spIdx, 1);
          if (stage.spells.length === 0) stage.spells.push("");
          this.onDirty();
          this.render();
        });

        spRow.append(num, combo, rmBtn);
        spellsWrap.appendChild(spRow);
      });

      card.appendChild(spellsWrap);
      stagesSection.appendChild(card);
    });

    editor.appendChild(stagesSection);
    return editor;
  }
}

function makeBtn(text, cls, onClick) {
  const b = document.createElement("button");
  b.type = "button";
  b.className = `btn ${cls}`;
  b.textContent = text;
  b.addEventListener("click", onClick);
  return b;
}

function makeTextField(label, value, onChange) {
  const f = document.createElement("div");
  f.className = "field";
  f.innerHTML = `<label>${escapeHtml(label)}</label>`;
  const inp = document.createElement("input");
  inp.type = "text";
  inp.className = "input";
  inp.value = value;
  inp.addEventListener("input", () => onChange(inp.value));
  f.appendChild(inp);
  return f;
}

function makeNumberField(label, value, min, step, onChange) {
  const f = document.createElement("div");
  f.className = "field";
  f.innerHTML = `<label>${escapeHtml(label)}</label>`;
  const inp = document.createElement("input");
  inp.type = "number";
  inp.className = "input";
  inp.value = String(value);
  if (min !== undefined) inp.min = String(min);
  if (step !== undefined) inp.step = String(step);
  inp.addEventListener("input", () => {
    const n = parseFloat(inp.value);
    if (!Number.isNaN(n)) onChange(n);
  });
  f.appendChild(inp);
  return f;
}

function escapeHtml(str) {
  return String(str ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}
