// Arcane Wilds - Reusable Searchable Dropdown (Combobox) Component
// Allows selecting from detected spells/VFX/SFX/montages or typing a custom value.

export function createCombobox({
  value = "",
  placeholder = "Select or type…",
  getOptions,
  onChange,
}) {
  const root = document.createElement("div");
  root.className = "combobox";

  const wrap = document.createElement("div");
  wrap.className = "combobox-input-wrap";

  const input = document.createElement("input");
  input.type = "text";
  input.className = "input combobox-input";
  input.value = value ?? "";
  input.placeholder = placeholder;
  input.autocomplete = "off";

  const toggleBtn = document.createElement("button");
  toggleBtn.type = "button";
  toggleBtn.className = "combobox-toggle";
  toggleBtn.textContent = "▾";
  toggleBtn.title = "Show options";

  const menu = document.createElement("div");
  menu.className = "combobox-menu hidden";

  wrap.appendChild(input);
  wrap.appendChild(toggleBtn);
  root.appendChild(wrap);
  root.appendChild(menu);

  let isOpen = false;
  let activeIndex = -1;
  let filtered = [];

  function renderMenu(filterText) {
    const all = typeof getOptions === "function" ? getOptions() : [];
    const q = (filterText || "").trim().toLowerCase();
    filtered = q
      ? all.filter((o) =>
          (o.label || "").toLowerCase().includes(q) ||
          (o.value || "").toLowerCase().includes(q) ||
          (o.badge || "").toLowerCase().includes(q) ||
          (o.sub || "").toLowerCase().includes(q)
        )
      : all;

    // Limit rendered DOM nodes for snappy performance on large UE5 asset catalogs
    const capped = filtered.slice(0, 120);
    menu.innerHTML = "";
    activeIndex = -1;

    if (capped.length === 0) {
      const empty = document.createElement("div");
      empty.className = "combobox-empty";
      empty.textContent = q
        ? `No detected matches for "${filterText}" (press Enter to keep custom text)`
        : "No detected options yet — type any asset name or path.";
      menu.appendChild(empty);
      return;
    }

    capped.forEach((opt, idx) => {
      const item = document.createElement("div");
      item.className = "combobox-option";
      item.dataset.index = String(idx);

      const top = document.createElement("div");
      top.className = "combobox-option-top";

      const lbl = document.createElement("span");
      lbl.className = "combobox-option-label";
      lbl.textContent = opt.label || opt.value;
      top.appendChild(lbl);

      if (opt.badge) {
        const badge = document.createElement("span");
        badge.className = "combobox-option-badge";
        badge.textContent = opt.badge;
        top.appendChild(badge);
      }

      item.appendChild(top);

      if (opt.sub) {
        const sub = document.createElement("div");
        sub.className = "combobox-option-sub";
        sub.textContent = opt.sub;
        item.appendChild(sub);
      }

      item.addEventListener("mousedown", (e) => {
        e.preventDefault();
        selectOption(opt);
      });

      menu.appendChild(item);
    });

    if (filtered.length > capped.length) {
      const more = document.createElement("div");
      more.className = "combobox-empty";
      more.textContent = `Showing ${capped.length} of ${filtered.length} matches — type to narrow down.`;
      menu.appendChild(more);
    }
  }

  function open(showAll = false) {
    isOpen = true;
    menu.classList.remove("hidden");
    renderMenu(showAll ? "" : input.value);
  }

  function close() {
    isOpen = false;
    menu.classList.add("hidden");
  }

  function selectOption(opt) {
    input.value = opt.value;
    close();
    if (typeof onChange === "function") onChange(opt.value);
  }

  input.addEventListener("focus", () => open(true));
  input.addEventListener("input", () => {
    open(false);
    if (typeof onChange === "function") onChange(input.value);
  });
  input.addEventListener("blur", () => {
    setTimeout(close, 120);
  });
  input.addEventListener("keydown", (e) => {
    if (!isOpen && (e.key === "ArrowDown" || e.key === "ArrowUp")) {
      open(true);
      return;
    }
    const items = menu.querySelectorAll(".combobox-option");
    if (e.key === "ArrowDown") {
      e.preventDefault();
      activeIndex = Math.min(items.length - 1, activeIndex + 1);
      items.forEach((el, i) => el.classList.toggle("active", i === activeIndex));
      items[activeIndex]?.scrollIntoView({ block: "nearest" });
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      activeIndex = Math.max(0, activeIndex - 1);
      items.forEach((el, i) => el.classList.toggle("active", i === activeIndex));
      items[activeIndex]?.scrollIntoView({ block: "nearest" });
    } else if (e.key === "Enter" && isOpen && activeIndex >= 0 && filtered[activeIndex]) {
      e.preventDefault();
      selectOption(filtered[activeIndex]);
    } else if (e.key === "Escape") {
      close();
    }
  });

  toggleBtn.addEventListener("mousedown", (e) => {
    e.preventDefault();
    if (isOpen) close();
    else {
      input.focus();
      open(true);
    }
  });

  return root;
}
