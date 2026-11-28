// Arcane Wilds - Spells Tab (Custom Spell & Timeline Cue Builder)

import { createCombobox } from "./combobox.js";

const CUE_TYPES = [
  "vfx",
  "sfx",
  "spell",
  "hit",
  "chainstrike",
  "anim",
  "weaponAnim",
  "targetAnim",
  "actor",
  "decal",
  "shake",
];

const DAMAGE_CLASSES = ["Magical", "Melee", "Ranged", "None"];
const DAMAGE_SCALING_MODES = ["", "full", "staff", "magic", "none"];
const OVERLAP_POLICIES = ["replace", "parallel", "ignore"];
const RUNE_ELEMENTS = ["", "air", "fire", "water", "earth", "blood", "death", "chaos", "law", "nature", "astral"];
const ANIM_SLOTS = ["auto", "FullBody", "Spine", "RightArm", "LeftArm", "Legs", "Pelvis", "Head", "Curves"];

export class SpellsTab {
  constructor({
    listEl,
    editorEl,
    searchInputEl,
    catalogStore,
    getDefaultSpells,
    getUserSpellsState,
    onDirty,
    onWarn,
  }) {
    this.listEl = listEl;
    this.editorEl = editorEl;
    this.searchInputEl = searchInputEl;
    this.catalogStore = catalogStore;
    this.getDefaultSpells = getDefaultSpells;
    this.getUserSpellsState = getUserSpellsState;
    this.onDirty = onDirty;
    this.onWarn = onWarn || (() => {});
    this.selectedId = null;
    this.selectedLayer = "user"; // "user" | "default"
    this.filterText = "";

    this.searchInputEl.addEventListener("input", () => {
      this.filterText = this.searchInputEl.value.trim().toLowerCase();
      this.renderList();
    });
  }

  hasBuiltInId(id) {
    const defaults = this.getDefaultSpells() || {};
    const lower = String(id || "").toLowerCase();
    return Object.keys(defaults).some((k) => k.toLowerCase() === lower);
  }

  createNewSpell(suggestedName = "") {
    const uState = this.getUserSpellsState();
    const spells = uState.spells;
    let baseId = suggestedName || "MyCustomSpell";
    let candidate = baseId;
    let n = 1;
    while (spells[candidate] || this.hasBuiltInId(candidate)) {
      n++;
      candidate = `${baseId}${n}`;
    }
    spells[candidate] = {
      enabled: true,
      displayName: candidate.replace(/([A-Z])/g, " $1").trim(),
      description: "",
      category: "Air",
      baseSpell: null,
      speed: 1.5,
      clamp: true,
      requiredMagicLevel: 0,
      scaleWithStaff: true,
      damageScaling: "full",
      runeCost: { type: "air", count: 1 },
      timelineDuration: "auto",
      overlapPolicy: "parallel",
      cues: [],
    };
    this.selectedId = candidate;
    this.selectedLayer = "user";
    this.onDirty();
    this.render();
    return candidate;
  }

  cloneDefaultToUser(defaultId, disableOriginal = false) {
    const defaults = this.getDefaultSpells() || {};
    const src = defaults[defaultId];
    if (!src) return null;

    const uState = this.getUserSpellsState();
    let baseId = `My${defaultId}`;
    let candidate = baseId;
    let n = 1;
    while (uState.spells[candidate] || this.hasBuiltInId(candidate)) {
      n++;
      candidate = `${baseId}${n}`;
    }
    const copy = structuredClone(src);
    copy.enabled = true;
    copy.displayName = `${src.displayName || defaultId} (Custom)`;
    uState.spells[candidate] = copy;

    if (disableOriginal) {
      const set = new Set((uState.disabledDefaults || []).map((x) => String(x)));
      set.add(defaultId);
      uState.disabledDefaults = [...set];
    }

    this.selectedId = candidate;
    this.selectedLayer = "user";
    this.onDirty();
    this.render();
    return candidate;
  }

  render() {
    const uState = this.getUserSpellsState();
    const userSpells = uState.spells || {};
    const defaultSpells = this.getDefaultSpells() || {};

    if (this.selectedLayer === "user" && (!this.selectedId || !userSpells[this.selectedId])) {
      const uIds = Object.keys(userSpells);
      const dIds = Object.keys(defaultSpells);
      if (uIds.length) {
        this.selectedId = uIds[0];
        this.selectedLayer = "user";
      } else if (dIds.length) {
        this.selectedId = dIds[0];
        this.selectedLayer = "default";
      } else {
        this.selectedId = null;
      }
    } else if (this.selectedLayer === "default" && (!this.selectedId || !defaultSpells[this.selectedId])) {
      const dIds = Object.keys(defaultSpells);
      this.selectedId = dIds[0] || null;
    }

    this.renderList();
    this.renderEditor();
  }

  renderList() {
    const uState = this.getUserSpellsState();
    const userSpells = uState.spells || {};
    const defaultSpells = this.getDefaultSpells() || {};
    const disabledSet = new Set((uState.disabledDefaults || []).map((x) => String(x).toLowerCase()));
    const enabledSet = new Set((uState.enabledDefaults || []).map((x) => String(x).toLowerCase()));

    this.listEl.innerHTML = "";

    // Group 1: User Custom Spells
    const uHead = document.createElement("div");
    uHead.className = "layer-section-title";
    uHead.innerHTML = `<span>My Custom Spells (${Object.keys(userSpells).length})</span><span class="badge-user">User</span>`;
    this.listEl.appendChild(uHead);

    const userIds = Object.keys(userSpells).sort((a, b) => a.localeCompare(b));
    if (!userIds.length) {
      const empty = document.createElement("div");
      empty.className = "combo-row-meta";
      empty.style.padding = "6px 8px";
      empty.textContent = "Click + New Spell or clone a Mod Default below.";
      this.listEl.appendChild(empty);
    }

    userIds.forEach((id) => {
      const def = userSpells[id];
      if (this.filterText) {
        const hay = `${id} ${def?.displayName || ""} ${def?.category || ""}`.toLowerCase();
        if (!hay.includes(this.filterText)) return;
      }

      const item = document.createElement("div");
      const isSelected = this.selectedLayer === "user" && id === this.selectedId;
      item.className = `spell-list-item${isSelected ? " active" : ""}${def?.enabled === false ? " disabled" : ""}`;
      item.addEventListener("click", () => {
        this.selectedId = id;
        this.selectedLayer = "user";
        this.render();
      });

      const left = document.createElement("div");
      const nameEl = document.createElement("div");
      nameEl.className = "spell-item-name";
      nameEl.textContent = def?.displayName || id;
      const subEl = document.createElement("div");
      subEl.className = "spell-item-sub";
      const cueCount = Array.isArray(def?.cues) ? def.cues.length : 0;
      subEl.textContent = `${id} · ${def?.category || "Custom"} · ${cueCount} cue(s)`;
      left.append(nameEl, subEl);

      const chk = document.createElement("input");
      chk.type = "checkbox";
      chk.checked = def?.enabled !== false;
      chk.title = "Enable / Disable custom spell";
      chk.addEventListener("click", (e) => e.stopPropagation());
      chk.addEventListener("change", () => {
        def.enabled = chk.checked;
        this.onDirty();
        this.renderList();
      });

      item.append(left, chk);
      this.listEl.appendChild(item);
    });

    // Group 2: Read-Only Mod Default Spells
    const defIds = Object.keys(defaultSpells).sort((a, b) => a.localeCompare(b));
    if (defIds.length) {
      const dHead = document.createElement("div");
      dHead.className = "layer-section-title";
      dHead.style.marginTop = "14px";
      dHead.innerHTML = `<span>Mod Defaults (${defIds.length})</span><span class="badge-builtin">Built-in</span>`;
      this.listEl.appendChild(dHead);

      defIds.forEach((id) => {
        const def = defaultSpells[id];
        if (this.filterText) {
          const hay = `${id} ${def?.displayName || ""} ${def?.category || ""}`.toLowerCase();
          if (!hay.includes(this.filterText)) return;
        }

        const idLower = id.toLowerCase();
        const shippedEnabled = def?.enabled !== false;
        let isEffectivelyOn;
        if (disabledSet.has(idLower)) isEffectivelyOn = false;
        else if (enabledSet.has(idLower)) isEffectivelyOn = true;
        else isEffectivelyOn = shippedEnabled;
        const isSelected = this.selectedLayer === "default" && id === this.selectedId;

        const item = document.createElement("div");
        item.className = `spell-list-item${isSelected ? " active" : ""}${!isEffectivelyOn ? " disabled" : ""}`;
        item.addEventListener("click", () => {
          this.selectedId = id;
          this.selectedLayer = "default";
          this.render();
        });

        const left = document.createElement("div");
        const nameEl = document.createElement("div");
        nameEl.className = "spell-item-name";
        nameEl.textContent = def?.displayName || id;
        const subEl = document.createElement("div");
        subEl.className = "spell-item-sub";
        subEl.textContent = `${id} · ${def?.category || "Built-in"}${!isEffectivelyOn ? " · Off" : ""}`;
        left.append(nameEl, subEl);

        const chk = document.createElement("input");
        chk.type = "checkbox";
        chk.checked = isEffectivelyOn;
        chk.title = "Enable / Disable this built-in mod spell";
        chk.addEventListener("click", (e) => e.stopPropagation());
        chk.addEventListener("change", () => {
          const disSet = new Set((uState.disabledDefaults || []).map((x) => String(x)));
          const enSet = new Set((uState.enabledDefaults || []).map((x) => String(x)));
          for (const x of [...disSet]) { if (x.toLowerCase() === idLower) disSet.delete(x); }
          for (const x of [...enSet]) { if (x.toLowerCase() === idLower) enSet.delete(x); }
          if (chk.checked && !shippedEnabled) {
            enSet.add(id);
          } else if (!chk.checked && shippedEnabled) {
            disSet.add(id);
          }
          uState.disabledDefaults = [...disSet];
          uState.enabledDefaults = [...enSet];
          this.onDirty();
          this.render();
        });

        item.append(left, chk);
        this.listEl.appendChild(item);
      });
    }
  }

  renderEditor() {
    const uState = this.getUserSpellsState();
    const userSpells = uState.spells || {};
    const defaultSpells = this.getDefaultSpells() || {};
    this.editorEl.innerHTML = "";

    if (!this.selectedId) {
      this.editorEl.innerHTML = `<div class="empty-state"><p>Select a spell on the left or click <strong>+ New Spell</strong> to create one.</p></div>`;
      return;
    }

    if (this.selectedLayer === "default") {
      const def = defaultSpells[this.selectedId];
      if (!def) return;
      this.renderReadOnlyDefaultView(this.selectedId, def);
      return;
    }

    const spells = userSpells;
    if (!spells[this.selectedId]) return;

    const id = this.selectedId;
    const def = spells[id];

    // Header actions
    const topBar = document.createElement("div");
    topBar.className = "toolbar";
    topBar.style.marginBottom = "12px";

    const titleWrap = document.createElement("div");
    titleWrap.innerHTML = `<h3 style="margin:0;font-size:16px;">${escapeHtml(def.displayName || id)}</h3><span class="combo-row-meta">Internal ID: <code>${escapeHtml(id)}</code></span>`;

    const topBtns = document.createElement("div");
    topBtns.className = "combo-row-actions";
    topBtns.appendChild(makeBtn("Duplicate", "btn-secondary btn-sm", () => {
      let copyId = `${id}Copy`;
      let n = 1;
      while (spells[copyId]) copyId = `${id}Copy${++n}`;
      spells[copyId] = structuredClone(def);
      spells[copyId].displayName = `${def.displayName || id} (Copy)`;
      this.selectedId = copyId;
      this.onDirty();
      this.render();
    }));
    topBtns.appendChild(makeBtn("Delete Spell", "btn-danger btn-sm", () => {
      delete spells[id];
      this.selectedId = Object.keys(spells)[0] || null;
      this.onDirty();
      this.render();
    }));
    topBar.append(titleWrap, topBtns);
    this.editorEl.appendChild(topBar);

    // Section 1: Core Properties
    const coreCard = makeSectionCard("Core Properties");
    const coreGrid = document.createElement("div");
    coreGrid.className = "grid-3";

    // Renameable Spell ID
    const idField = makeTextField("Spell ID (referenced in combos)", id, () => {});
    const idInput = idField.querySelector("input");
    idInput.addEventListener("change", () => {
      const nextId = idInput.value.trim().replace(/[^A-Za-z0-9_]/g, "");
      if (!nextId || nextId === id) {
        idInput.value = id;
        return;
      }
      if (spells[nextId] || this.hasBuiltInId(nextId)) {
        this.onWarn(`Cannot use '${nextId}': that spell ID is already taken or reserved by a built-in mod spell.`);
        idInput.value = id;
        return;
      }
      spells[nextId] = def;
      delete spells[id];
      this.selectedId = nextId;
      this.onDirty();
      this.render();
    });
    coreGrid.appendChild(idField);

    coreGrid.appendChild(makeTextField("Display Name", def.displayName || "", (v) => {
      def.displayName = v;
      this.onDirty();
      this.renderList();
    }));

    const catField = document.createElement("div");
    catField.className = "field";
    catField.innerHTML = `<label>Category</label>`;
    catField.appendChild(createCombobox({
      value: def.category || "",
      placeholder: "Air, Fire, Water, Earth…",
      getOptions: () => this.catalogStore.getCategoryOptions(),
      onChange: (v) => {
        def.category = v;
        this.onDirty();
        this.renderList();
      },
    }));
    coreGrid.appendChild(catField);

    const baseSpellField = document.createElement("div");
    baseSpellField.className = "field";
    baseSpellField.innerHTML = `<label>Base Spell (Detected)</label>`;
    baseSpellField.appendChild(createCombobox({
      value: def.baseSpell ?? "",
      placeholder: "(None — Pure Custom / Timeline)",
      getOptions: () => this.catalogStore.getDetectedSpellOptions(true),
      onChange: (v) => {
        def.baseSpell = v.trim() === "" ? null : v.trim();
        this.onDirty();
      },
    }));
    coreGrid.appendChild(baseSpellField);

    coreGrid.appendChild(makeNumberField("Cast Speed Multiplier", def.speed ?? 1.0, 0.1, 0.1, (v) => {
      def.speed = v;
      this.onDirty();
    }));

    const clampWrap = makeCheckboxField("Speed Clamp (Notify-Safe)", def.clamp === true, (checked) => {
      def.clamp = checked;
      this.onDirty();
    });
    coreGrid.appendChild(clampWrap);

    coreCard.appendChild(coreGrid);

    const descField = document.createElement("div");
    descField.className = "field";
    descField.style.marginTop = "10px";
    descField.innerHTML = `<label>Description</label>`;
    const descArea = document.createElement("textarea");
    descArea.className = "textarea";
    descArea.value = def.description || "";
    descArea.addEventListener("input", () => {
      def.description = descArea.value;
      this.onDirty();
    });
    descField.appendChild(descArea);
    coreCard.appendChild(descField);
    this.editorEl.appendChild(coreCard);

    // Section 2: Rune Cost, Progression & Scaling
    const progCard = makeSectionCard("Rune Cost, Progression & Scaling");
    const progGrid = document.createElement("div");
    progGrid.className = "grid-4";

    const currentRuneType = typeof def.runeCost === "object" && def.runeCost ? (def.runeCost.type || "") : (typeof def.runeCost === "string" ? def.runeCost : "");
    const currentRuneCount = typeof def.runeCost === "object" && def.runeCost ? (def.runeCost.count || 1) : (def.runeCount || 1);

    progGrid.appendChild(makeSelectField("Rune Type", currentRuneType, RUNE_ELEMENTS, (v) => {
      if (!v) {
        delete def.runeCost;
      } else {
        def.runeCost = { type: v, count: currentRuneCount };
      }
      this.onDirty();
    }));

    progGrid.appendChild(makeNumberField("Rune Count", currentRuneCount, 1, 1, (v) => {
      const cnt = Math.max(1, Math.floor(v));
      if (typeof def.runeCost === "object" && def.runeCost) {
        def.runeCost.count = cnt;
      } else if (currentRuneType) {
        def.runeCost = { type: currentRuneType, count: cnt };
      }
      this.onDirty();
    }));

    progGrid.appendChild(makeNumberField("Required Magic Level", def.requiredMagicLevel ?? 0, 0, 1, (v) => {
      def.requiredMagicLevel = Math.max(0, Math.floor(v));
      this.onDirty();
    }));

    progGrid.appendChild(makeSelectField("Damage Scaling", def.damageScaling || "", DAMAGE_SCALING_MODES, (v) => {
      if (!v) delete def.damageScaling;
      else def.damageScaling = v;
      this.onDirty();
    }));

    progGrid.appendChild(makeCheckboxField("Scale With Staff", def.scaleWithStaff !== false, (checked) => {
      def.scaleWithStaff = checked;
      this.onDirty();
    }));

    progGrid.appendChild(makeSelectField("Overlap Policy", def.overlapPolicy || "replace", OVERLAP_POLICIES, (v) => {
      def.overlapPolicy = v;
      this.onDirty();
    }));

    progGrid.appendChild(makeNumberField("Step Advance At (sec)", def.stepAdvanceAt ?? "", 0, 0.05, (v) => {
      if (v === null) delete def.stepAdvanceAt;
      else def.stepAdvanceAt = v;
      this.onDirty();
    }, true));

    progGrid.appendChild(makeNumberField("Auto-Target Range (cm)", def.autoTarget?.range ?? "", 100, 100, (v) => {
      if (v === null) {
        if (def.autoTarget) delete def.autoTarget.range;
      } else {
        def.autoTarget = def.autoTarget || {};
        def.autoTarget.range = v;
      }
      this.onDirty();
    }, true));

    progCard.appendChild(progGrid);
    this.editorEl.appendChild(progCard);

    // Section 3: Timeline Cues Builder
    const cuesCard = makeSectionCard("Timeline Cues (VFX, SFX, Spells, Hits, Animations)");
    const cuesHeader = cuesCard.querySelector("h3");
    const addCueWrap = document.createElement("div");
    addCueWrap.className = "combo-row-actions";

    const cueTypeSelect = document.createElement("select");
    cueTypeSelect.className = "select";
    cueTypeSelect.style.width = "140px";
    CUE_TYPES.forEach((t) => {
      const opt = document.createElement("option");
      opt.value = t;
      opt.textContent = t;
      cueTypeSelect.appendChild(opt);
    });

    addCueWrap.append(cueTypeSelect, makeBtn("+ Add Cue", "btn-primary btn-xs", () => {
      if (!Array.isArray(def.cues)) def.cues = [];
      def.cues.push(createDefaultCue(cueTypeSelect.value));
      this.onDirty();
      this.render();
    }));
    cuesHeader.appendChild(addCueWrap);

    const cuesList = document.createElement("div");
    cuesList.className = "cues-list";
    const cues = Array.isArray(def.cues) ? def.cues : [];

    if (cues.length === 0) {
      const empty = document.createElement("div");
      empty.className = "combo-row-meta";
      empty.textContent = "No timeline cues yet. Pick a cue type (vfx, sfx, spell, hit, anim, chainstrike…) and click + Add Cue.";
      cuesList.appendChild(empty);
    } else {
      cues.forEach((cue, cIdx) => {
        cuesList.appendChild(this.renderCueCard(def, cue, cIdx));
      });
    }

    cuesCard.appendChild(cuesList);
    this.editorEl.appendChild(cuesCard);
  }

  renderCueCard(def, cue, cIdx) {
    const card = document.createElement("div");
    card.className = "cue-card";

    const head = document.createElement("div");
    head.className = "cue-header";

    const left = document.createElement("div");
    left.className = "combo-row-actions";
    const badge = document.createElement("span");
    badge.className = "cue-type-badge";
    badge.textContent = `#${cIdx + 1} ${cue.type}`;
    left.appendChild(badge);

    const right = document.createElement("div");
    right.className = "combo-row-actions";
    const upBtn = makeBtn("↑", "btn-ghost btn-xs", () => {
      if (cIdx === 0) return;
      [def.cues[cIdx - 1], def.cues[cIdx]] = [def.cues[cIdx], def.cues[cIdx - 1]];
      this.onDirty();
      this.render();
    });
    upBtn.disabled = cIdx === 0;
    const downBtn = makeBtn("↓", "btn-ghost btn-xs", () => {
      if (cIdx >= def.cues.length - 1) return;
      [def.cues[cIdx + 1], def.cues[cIdx]] = [def.cues[cIdx], def.cues[cIdx + 1]];
      this.onDirty();
      this.render();
    });
    downBtn.disabled = cIdx >= def.cues.length - 1;
    const delBtn = makeBtn("Delete", "btn-danger btn-xs", () => {
      def.cues.splice(cIdx, 1);
      this.onDirty();
      this.render();
    });
    right.append(upBtn, downBtn, delBtn);
    head.append(left, right);
    card.appendChild(head);

    const grid = document.createElement("div");
    grid.className = "grid-4";

    // Common timing + id fields
    grid.appendChild(makeTextField("At (Timing: @0.00, &, >id)", cue.at ?? "@0.00", (v) => {
      cue.at = v;
      this.onDirty();
    }));

    grid.appendChild(makeTextField("Cue ID (Optional)", cue.id || "", (v) => {
      if (v.trim() === "") delete cue.id;
      else cue.id = v.trim();
      this.onDirty();
    }));

    // Asset dropdown tailored to cue.type!
    const t = cue.type;
    if (t === "vfx" || t === "chainstrike") {
      grid.appendChild(this.makeAssetField("VFX Asset (Detected)", cue.asset || "", () => this.catalogStore.getVfxOptions(), (v) => {
        cue.asset = v;
        this.onDirty();
      }));
    } else if (t === "sfx") {
      grid.appendChild(this.makeAssetField("SFX Asset (Detected)", cue.asset || "", () => this.catalogStore.getSfxOptions(), (v) => {
        cue.asset = v;
        this.onDirty();
      }));
    } else if (t === "spell") {
      grid.appendChild(this.makeAssetField("Spell Asset (Detected)", cue.asset || "", () => this.catalogStore.getDetectedSpellOptions(false), (v) => {
        cue.asset = v;
        this.onDirty();
      }));
    } else if (t === "anim" || t === "weaponAnim" || t === "targetAnim") {
      grid.appendChild(this.makeAssetField("Montage Asset (Detected)", cue.asset || "", () => this.catalogStore.getMontageOptions(), (v) => {
        cue.asset = v;
        this.onDirty();
      }));
    } else if (t === "actor" || t === "decal" || t === "shake") {
      grid.appendChild(makeTextField("Asset Path / Name", cue.asset || "", (v) => {
        cue.asset = v;
        this.onDirty();
      }));
    }

    // Spatial target
    if (t !== "anim" && t !== "weaponAnim") {
      grid.appendChild(makeTextField("Target (player, impact, lock…)", cue.target || "", (v) => {
        if (v.trim() === "") delete cue.target;
        else cue.target = v.trim();
        this.onDirty();
      }));
    }

    // Type-specific fields
    if (t === "vfx") {
      grid.appendChild(makeNumberField("Duration (sec)", cue.duration ?? 0.5, 0, 0.1, (v) => {
        cue.duration = v;
        this.onDirty();
      }));
      grid.appendChild(makeTextField("Scale (e.g. 1.0 or 0.5,0.5,0.5)", formatVecOrNum(cue.scale), (v) => {
        const parsed = parseVecOrNum(v);
        if (parsed === undefined) delete cue.scale;
        else cue.scale = parsed;
        this.onDirty();
      }));
    }

    if (t === "sfx") {
      grid.appendChild(makeNumberField("Volume", cue.volume ?? 1.0, 0, 0.1, (v) => {
        cue.volume = v;
        this.onDirty();
      }));
      grid.appendChild(makeNumberField("Pitch", cue.pitch ?? 1.0, 0.1, 0.1, (v) => {
        cue.pitch = v;
        this.onDirty();
      }));
    }

    if (t === "spell") {
      grid.appendChild(makeCheckboxField("Track Impact", cue.trackImpact === true, (checked) => {
        cue.trackImpact = checked;
        this.onDirty();
      }));
      grid.appendChild(makeNumberField("Impact Timeout (sec)", cue.impactTimeout ?? 1.8, 0.1, 0.1, (v) => {
        cue.impactTimeout = v;
        this.onDirty();
      }));
    }

    if (t === "anim" || t === "weaponAnim" || t === "targetAnim") {
      grid.appendChild(makeNumberField("Playback Rate", cue.rate ?? 1.0, 0.1, 0.1, (v) => {
        cue.rate = v;
        this.onDirty();
      }));
      grid.appendChild(makeSelectField("Anim Slot", cue.slot || "auto", ANIM_SLOTS, (v) => {
        cue.slot = v;
        this.onDirty();
      }));
    }

    if (t === "hit" || t === "chainstrike") {
      const dmgMin = Array.isArray(cue.damage) ? cue.damage[0] : (cue.damageMin ?? 50);
      const dmgMax = Array.isArray(cue.damage) ? cue.damage[1] : (cue.damageMax ?? 100);

      grid.appendChild(makeNumberField("Damage Min", dmgMin, 0, 5, (v) => {
        const curMax = Array.isArray(cue.damage) ? cue.damage[1] : dmgMax;
        cue.damage = [v, curMax];
        this.onDirty();
      }));
      grid.appendChild(makeNumberField("Damage Max", dmgMax, 0, 5, (v) => {
        const curMin = Array.isArray(cue.damage) ? cue.damage[0] : dmgMin;
        cue.damage = [curMin, v];
        this.onDirty();
      }));
      grid.appendChild(makeSelectField("Damage Class", cue.class || "Magical", DAMAGE_CLASSES, (v) => {
        cue.class = v;
        this.onDirty();
      }));
      grid.appendChild(makeNumberField(t === "chainstrike" ? "Chain Radius (cm)" : "Hit Radius (cm)", t === "chainstrike" ? (cue.chainRadius ?? 650) : (cue.radius ?? 350), 10, 25, (v) => {
        if (t === "chainstrike") cue.chainRadius = v;
        else cue.radius = v;
        this.onDirty();
      }));
      grid.appendChild(makeNumberField("Stun (sec)", cue.stun ?? "", 0, 0.1, (v) => {
        if (v === null) delete cue.stun;
        else cue.stun = v;
        this.onDirty();
      }, true));
      grid.appendChild(this.makeAssetField("Secondary SFX (Detected)", cue.sfx || "", () => this.catalogStore.getSfxOptions(), (v) => {
        if (v.trim() === "") delete cue.sfx;
        else cue.sfx = v.trim();
        this.onDirty();
      }));
      if (t === "hit") {
        grid.appendChild(this.makeAssetField("Secondary VFX (Detected)", cue.vfx || "", () => this.catalogStore.getVfxOptions(), (v) => {
          if (v.trim() === "") delete cue.vfx;
          else cue.vfx = v.trim();
          this.onDirty();
        }));
        grid.appendChild(makeNumberField("Pushback (cm/s)", cue.pushback ?? "", -2000, 50, (v) => {
          if (v === null) delete cue.pushback;
          else cue.pushback = v;
          this.onDirty();
        }, true));
      } else {
        grid.appendChild(makeNumberField("Max Strikes", cue.maxStrikes ?? 5, 1, 1, (v) => {
          cue.maxStrikes = Math.max(1, Math.floor(v));
          this.onDirty();
        }));
        grid.appendChild(makeNumberField("Interval (sec)", cue.interval ?? 0.4, 0.05, 0.05, (v) => {
          cue.interval = v;
          this.onDirty();
        }));
      }
    }

    card.appendChild(grid);
    return card;
  }

  renderReadOnlyDefaultView(id, def) {
    const banner = document.createElement("div");
    banner.className = "readonly-banner";
    banner.innerHTML = `
      <div>
        <span class="badge-builtin">Built-in Mod Spell</span>
        <strong>${escapeHtml(def.displayName || id)}</strong> (<code>${escapeHtml(id)}</code>) is managed by Arcane Wilds so it automatically receives mod updates.
        You can toggle it off on the left, or clone it into <strong>My Custom Spells</strong> to customize your own version.
      </div>
    `;
    const btnGroup = document.createElement("div");
    btnGroup.className = "combo-row-actions";
    btnGroup.appendChild(makeBtn("Clone to My Spells", "btn-primary btn-sm", () => {
      this.cloneDefaultToUser(id, false);
    }));
    btnGroup.appendChild(makeBtn("Clone & Disable Built-in", "btn-secondary btn-sm", () => {
      this.cloneDefaultToUser(id, true);
    }));
    banner.appendChild(btnGroup);
    this.editorEl.appendChild(banner);

    const summaryCard = makeSectionCard("Built-in Spell Definition (Read-Only Preview)");
    const pre = document.createElement("pre");
    pre.style.margin = "0";
    pre.style.overflowX = "auto";
    pre.style.fontFamily = "var(--mono)";
    pre.style.fontSize = "12px";
    pre.style.color = "var(--text-muted)";
    pre.textContent = JSON.stringify(def, null, 2);
    summaryCard.appendChild(pre);
    this.editorEl.appendChild(summaryCard);
  }

  makeAssetField(label, value, getOptions, onChange) {
    const f = document.createElement("div");
    f.className = "field";
    f.innerHTML = `<label>${escapeHtml(label)}</label>`;
    f.appendChild(createCombobox({
      value,
      placeholder: "Select detected asset or type…",
      getOptions,
      onChange,
    }));
    return f;
  }
}

function createDefaultCue(type) {
  switch (type) {
    case "vfx":
      return { type: "vfx", at: "@0.00", asset: "lightning", target: "impact", scale: 1.0, duration: 0.8 };
    case "sfx":
      return { type: "sfx", at: "@0.00", asset: "lightning", target: "player", volume: 1.0, pitch: 1.0 };
    case "spell":
      return { type: "spell", id: "proj", at: "@0.00", asset: "DA_Spell_Primary_Air_01", trackImpact: true, impactTimeout: 1.8 };
    case "hit":
      return { type: "hit", at: "@0.10", target: "impact", radius: 350, damage: [65, 125], class: "Magical", force: 260 };
    case "chainstrike":
      return { type: "chainstrike", at: "@0.00", asset: "lightning", maxStrikes: 5, interval: 0.35, chainRadius: 650, damage: [65, 125], class: "Magical", sfx: "lightning" };
    case "anim":
    case "weaponAnim":
    case "targetAnim":
      return { type, at: "@0.00", asset: "AM_Spell_Primary_Air_01", rate: 1.2, slot: "FullBody" };
    default:
      return { type, at: "@0.00", asset: "" };
  }
}

function formatVecOrNum(val) {
  if (val === undefined || val === null) return "";
  if (Array.isArray(val)) return val.join(", ");
  return String(val);
}

function parseVecOrNum(str) {
  const s = (str || "").trim();
  if (!s) return undefined;
  if (s.includes(",")) {
    const parts = s.split(",").map((x) => parseFloat(x.trim())).filter((n) => !Number.isNaN(n));
    return parts.length ? parts : undefined;
  }
  const n = parseFloat(s);
  return Number.isNaN(n) ? undefined : n;
}

function makeSectionCard(title) {
  const card = document.createElement("div");
  card.className = "section-card";
  const h = document.createElement("h3");
  h.textContent = title;
  card.appendChild(h);
  return card;
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
  inp.value = String(value ?? "");
  inp.addEventListener("input", () => onChange(inp.value));
  f.appendChild(inp);
  return f;
}

function makeNumberField(label, value, min, step, onChange, allowBlank = false) {
  const f = document.createElement("div");
  f.className = "field";
  f.innerHTML = `<label>${escapeHtml(label)}</label>`;
  const inp = document.createElement("input");
  inp.type = "number";
  inp.className = "input";
  inp.value = value === "" || value === undefined || value === null ? "" : String(value);
  if (min !== undefined) inp.min = String(min);
  if (step !== undefined) inp.step = String(step);
  inp.addEventListener("input", () => {
    if (allowBlank && inp.value.trim() === "") {
      onChange(null);
      return;
    }
    const n = parseFloat(inp.value);
    if (!Number.isNaN(n)) onChange(n);
  });
  f.appendChild(inp);
  return f;
}

function makeSelectField(label, value, options, onChange) {
  const f = document.createElement("div");
  f.className = "field";
  f.innerHTML = `<label>${escapeHtml(label)}</label>`;
  const sel = document.createElement("select");
  sel.className = "select";
  options.forEach((o) => {
    const opt = document.createElement("option");
    opt.value = o;
    opt.textContent = o === "" ? "(Default / None)" : o;
    if (o === value) opt.selected = true;
    sel.appendChild(opt);
  });
  sel.addEventListener("change", () => onChange(sel.value));
  f.appendChild(sel);
  return f;
}

function makeCheckboxField(label, checked, onChange) {
  const f = document.createElement("div");
  f.className = "field";
  f.innerHTML = `<label>&nbsp;</label>`;
  const wrap = document.createElement("div");
  wrap.className = "field-inline";
  const chk = document.createElement("input");
  chk.type = "checkbox";
  chk.checked = checked;
  chk.addEventListener("change", () => onChange(chk.checked));
  const lbl = document.createElement("label");
  lbl.textContent = label;
  wrap.append(chk, lbl);
  f.appendChild(wrap);
  return f;
}

function escapeHtml(str) {
  return String(str ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}
