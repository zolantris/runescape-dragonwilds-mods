// Arcane Wilds - Import Modal (JSON/JSONC Parser + Schema Version Migration Preview)

import { parseJsonc, detectKind, migrateDocument } from "./schema_migrator.js";

export class ImportModal {
  constructor({ modalEl, titleEl, bodyEl, footerEl, closeBtn, onApplyImport }) {
    this.modalEl = modalEl;
    this.titleEl = titleEl;
    this.bodyEl = bodyEl;
    this.footerEl = footerEl;
    this.onApplyImport = onApplyImport;
    this.parsedResult = null;
    this.expectedKind = null;

    closeBtn.addEventListener("click", () => this.close());
    modalEl.addEventListener("click", (e) => {
      if (e.target === modalEl) this.close();
    });
  }

  open(expectedKind = null) {
    this.expectedKind = expectedKind;
    this.parsedResult = null;
    this.titleEl.textContent =
      expectedKind === "custom_spells"
        ? "Import Custom Spells JSON"
        : expectedKind === "combo_rules"
          ? "Import Combo Rules JSON"
          : "Import Arcane Wilds JSON";

    this.renderBody();
    this.modalEl.classList.remove("hidden");
  }

  close() {
    this.modalEl.classList.add("hidden");
  }

  renderBody() {
    this.bodyEl.innerHTML = "";
    this.footerEl.innerHTML = "";

    const dropzone = document.createElement("div");
    dropzone.className = "dropzone";
    dropzone.innerHTML = `<strong>Click to choose a .json file</strong> or drag &amp; drop an exported JSON here.<br/><span class="combo-row-meta">Supports custom_spells, combo_rules, or combined bundle JSON (with automatic schema migration).</span>`;

    const fileInput = document.createElement("input");
    fileInput.type = "file";
    fileInput.accept = ".json,.jsonc";
    fileInput.className = "hidden";
    dropzone.appendChild(fileInput);

    dropzone.addEventListener("click", () => fileInput.click());
    dropzone.addEventListener("dragover", (e) => {
      e.preventDefault();
      dropzone.classList.add("dragover");
    });
    dropzone.addEventListener("dragleave", () => dropzone.classList.remove("dragover"));
    dropzone.addEventListener("drop", (e) => {
      e.preventDefault();
      dropzone.classList.remove("dragover");
      const file = e.dataTransfer?.files?.[0];
      if (file) this.readFile(file);
    });
    fileInput.addEventListener("change", () => {
      const file = fileInput.files?.[0];
      if (file) this.readFile(file);
    });

    const pasteWrap = document.createElement("div");
    pasteWrap.className = "field";
    pasteWrap.innerHTML = `<label>Or Paste JSON Directly</label>`;
    const pasteArea = document.createElement("textarea");
    pasteArea.className = "textarea";
    pasteArea.style.minHeight = "110px";
    pasteArea.style.fontFamily = "var(--mono)";
    pasteArea.placeholder = '{ "schemaVersion": 1, ... }';
    pasteArea.addEventListener("input", () => {
      if (pasteArea.value.trim()) this.analyzeRawText(pasteArea.value);
    });
    pasteWrap.appendChild(pasteArea);

    this.previewBox = document.createElement("div");
    this.bodyEl.append(dropzone, pasteWrap, this.previewBox);

    // Merge vs Replace selector
    const modeRow = document.createElement("div");
    modeRow.className = "field-inline";
    modeRow.style.marginRight = "auto";
    this.mergeRadio = document.createElement("select");
    this.mergeRadio.className = "select";
    this.mergeRadio.style.width = "auto";
    this.mergeRadio.innerHTML = `
      <option value="merge">Merge with existing</option>
      <option value="replace">Replace existing</option>
    `;
    modeRow.append(this.mergeRadio);

    const cancelBtn = document.createElement("button");
    cancelBtn.type = "button";
    cancelBtn.className = "btn btn-ghost";
    cancelBtn.textContent = "Cancel";
    cancelBtn.addEventListener("click", () => this.close());

    this.confirmBtn = document.createElement("button");
    this.confirmBtn.type = "button";
    this.confirmBtn.className = "btn btn-primary";
    this.confirmBtn.textContent = "Import";
    this.confirmBtn.disabled = true;
    this.confirmBtn.addEventListener("click", () => {
      if (!this.parsedResult) return;
      this.onApplyImport({
        ...this.parsedResult,
        mode: this.mergeRadio.value,
      });
      this.close();
    });

    this.footerEl.append(modeRow, cancelBtn, this.confirmBtn);
  }

  readFile(file) {
    const reader = new FileReader();
    reader.onload = () => this.analyzeRawText(String(reader.result || ""), file.name);
    reader.readAsText(file);
  }

  analyzeRawText(rawText, fileName = "") {
    this.parsedResult = null;
    this.confirmBtn.disabled = true;
    this.previewBox.innerHTML = "";

    let decoded;
    try {
      decoded = parseJsonc(rawText);
    } catch (err) {
      this.previewBox.innerHTML = `<div class="error-box">JSON Parse Error: ${escapeHtml(err.message)}</div>`;
      return;
    }

    const detectedKind = detectKind(decoded);
    if (!detectedKind || detectedKind === "detected_catalog") {
      this.previewBox.innerHTML = `<div class="error-box">Could not recognize this JSON as custom_spells, combo_rules, or a combined bundle.</div>`;
      return;
    }

    const migrated = migrateDocument(detectedKind, decoded);
    if (migrated.error) {
      this.previewBox.innerHTML = `<div class="error-box">${escapeHtml(migrated.error)}</div>`;
      return;
    }

    const spellCount = migrated.doc.spells ? Object.keys(migrated.doc.spells).length : 0;
    const ruleCount = Array.isArray(migrated.doc.rules) ? migrated.doc.rules.length : 0;

    const summaryParts = [];
    if (fileName) summaryParts.push(`<strong>File:</strong> ${escapeHtml(fileName)}`);
    summaryParts.push(`<strong>Detected Format:</strong> <code>${escapeHtml(detectedKind)}</code>`);
    summaryParts.push(
      `<strong>Schema Version:</strong> v${migrated.fromVersion} → v${migrated.toVersion}`
    );
    if (detectedKind === "custom_spells" || detectedKind === "bundle") {
      summaryParts.push(`<strong>Custom Spells:</strong> ${spellCount}`);
    }
    if (detectedKind === "combo_rules" || detectedKind === "bundle") {
      summaryParts.push(`<strong>Combo Rules:</strong> ${ruleCount}`);
    }

    let notesHtml = "";
    if (migrated.notes.length > 0) {
      notesHtml = `<div style="margin-top:6px;"><strong>Migrations Applied:</strong><ul style="margin:4px 0 0 18px;padding:0;">${migrated.notes.map((n) => `<li>${escapeHtml(n)}</li>`).join("")}</ul></div>`;
    }

    this.previewBox.innerHTML = `<div class="migration-box">${summaryParts.join(" · ")}${notesHtml}</div>`;
    this.parsedResult = {
      kind: detectedKind,
      doc: migrated.doc,
      notes: migrated.notes,
    };
    this.confirmBtn.disabled = false;
  }
}

function escapeHtml(str) {
  return String(str ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}
