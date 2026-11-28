#!/usr/bin/env python3
"""Stage the Arcane Wilds Web Studio + public schemas/data for GitHub Pages."""

from __future__ import annotations

import argparse
import json
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
MOD_DIR = REPO_ROOT / "arcane-wilds" / "ue4ss" / "Mods" / "ArcaneWilds"


def strip_jsonc_comments(text: str) -> str:
    """Remove // and /* */ comments while preserving string literals."""
    out: list[str] = []
    i = 0
    n = len(text)
    in_str = False
    escaped = False
    while i < n:
        ch = text[i]
        if in_str:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_str = False
            i += 1
        else:
            if ch == '"':
                in_str = True
                out.append(ch)
                i += 1
            elif ch == "/" and i + 1 < n and text[i + 1] == "/":
                i += 2
                while i < n and text[i] != "\n":
                    i += 1
            elif ch == "/" and i + 1 < n and text[i + 1] == "*":
                i += 2
                while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                    i += 1
                i += 2
            else:
                out.append(ch)
                i += 1
    return "".join(out)


def parse_quick_cast(path: Path) -> list[dict]:
    bindings: list[dict] = []
    if not path.is_file():
        return bindings
    if path.suffix.lower() == ".json":
        try:
            doc = json.loads(strip_jsonc(path.read_text(encoding="utf-8")))
            raw_bindings = doc.get("bindings", []) if isinstance(doc, dict) else []
            for item in raw_bindings:
                if not isinstance(item, dict):
                    continue
                mod = str(item.get("modifier", "BLOCK")).strip().upper()
                if mod in {"RMB", "MODIFIER", "MOD"}:
                    mod = "BLOCK"
                elif mod in {"OFF", "FALSE", ""}:
                    mod = "NONE"
                keys = [str(k).strip() for k in item.get("keys", []) if str(k).strip()]
                target = str(item.get("target", "")).strip()
                enabled = bool(item.get("enabled", True))
                if keys and target:
                    bindings.append({
                        "enabled": enabled,
                        "modifier": mod,
                        "keys": keys,
                        "target": target,
                    })
        except Exception:
            pass
        return bindings
    for line in path.read_text(encoding="utf-8").splitlines():
        clean = line.strip()
        if not clean or clean.startswith("#") or clean.startswith(";"):
            continue
        if "#" in clean:
            clean = clean.split("#", 1)[0].strip()
        if "=" not in clean:
            continue
        lhs, rhs = (p.strip() for p in clean.split("=", 1))
        if not lhs or not rhs:
            continue
        mod = "BLOCK"
        keys_part = lhs
        m = re.match(r"^([A-Za-z0-9_]+)\s*\+\s*(.+)$", lhs)
        if m:
            mod = m.group(1).strip().upper()
            keys_part = m.group(2).strip()
        if mod in {"RMB", "MODIFIER", "MOD"}:
            mod = "BLOCK"
        elif mod in {"OFF", "FALSE", ""}:
            mod = "NONE"
        keys = [k.strip() for k in re.split(r"[,|;]", keys_part) if k.strip()]
        if keys:
            bindings.append({
                "enabled": True,
                "modifier": mod,
                "keys": keys,
                "target": rhs,
            })
    return bindings


def build_fallback_catalog(mod_dir: Path, mod_version: str) -> dict:
    categories: dict[str, str] = {}
    spells_map: dict[str, dict] = {}
    vfx_map: dict[str, dict] = {}
    sfx_map: dict[str, dict] = {}
    montages_map: dict[str, dict] = {}

    def add_category(cat: str) -> None:
        if cat and cat != "*":
            categories.setdefault(cat.lower(), cat)

    # 1. spell_names.txt
    spell_names_path = mod_dir / "spell_names.txt"
    if spell_names_path.is_file():
        for line in spell_names_path.read_text(encoding="utf-8").splitlines():
            clean = line.strip()
            if not clean or clean.startswith("#") or clean.startswith(";"):
                continue
            if "#" in clean:
                clean = clean.split("#", 1)[0].strip()
            if "=" not in clean:
                continue
            lhs, rhs = (p.strip() for p in clean.split("=", 1))
            if not lhs or not rhs:
                continue
            cat = ""
            alias = lhs
            if "." in lhs:
                cat, alias = (p.strip() for p in lhs.split(".", 1))
            add_category(cat)
            key = rhs.lower()
            if key not in spells_map:
                spells_map[key] = {
                    "shortName": rhs,
                    "fullName": "",
                    "category": "" if cat == "*" else cat,
                    "stepIndex": 0,
                    "montage": None,
                    "aliases": [],
                    "isModded": False,
                    "isSpecial": False,
                }
            if alias and alias not in spells_map[key]["aliases"]:
                spells_map[key]["aliases"].append(alias)

    # 2. detected_spells.txt (if present)
    detected_spells_path = mod_dir / "detected_spells.txt"
    if detected_spells_path.is_file():
        current_cat = ""
        for line in detected_spells_path.read_text(encoding="utf-8").splitlines():
            m_cat = re.match(r"^\[([^\]]+)\]", line)
            if m_cat:
                current_cat = m_cat.group(1).strip()
                add_category(current_cat)
                continue
            m_sp = re.match(r"^\s+([A-Za-z0-9_]+)", line)
            if m_sp:
                s_name = m_sp.group(1).strip()
                montage = None
                m_mon = re.search(r"\(Montage:\s*([^)]+)\)", line)
                if m_mon:
                    montage = m_mon.group(1).strip()
                    montages_map.setdefault(
                        montage.lower(), {"shortName": montage, "path": montage}
                    )
                key = s_name.lower()
                if key not in spells_map:
                    spells_map[key] = {
                        "shortName": s_name,
                        "fullName": "",
                        "category": current_cat,
                        "stepIndex": 0,
                        "montage": montage,
                        "aliases": [],
                        "isModded": False,
                        "isSpecial": False,
                    }
                else:
                    if current_cat and not spells_map[key]["category"]:
                        spells_map[key]["category"] = current_cat
                    if montage and not spells_map[key]["montage"]:
                        spells_map[key]["montage"] = montage

    # 3. detected_vfx.txt & vfx_names.txt
    for vf_name in ("detected_vfx.txt", "vfx_names.txt"):
        vf_path = mod_dir / vf_name
        if not vf_path.is_file():
            continue
        for line in vf_path.read_text(encoding="utf-8").splitlines():
            clean = line.strip()
            if not clean or clean.startswith("#") or clean.startswith(";") or "=" not in clean:
                continue
            lhs, rhs = (p.strip() for p in clean.split("=", 1))
            if not rhs:
                continue
            p_key = rhs.lower()
            short = re.split(r"[./:]", rhs)[-1] or lhs
            entry = vfx_map.setdefault(
                p_key,
                {"shortName": short, "path": rhs, "kind": "niagara", "aliases": []},
            )
            if lhs and lhs.lower() != entry["shortName"].lower() and lhs not in entry["aliases"]:
                entry["aliases"].append(lhs)

    # 4. sfx_names.txt
    sfx_path = mod_dir / "sfx_names.txt"
    if sfx_path.is_file():
        for line in sfx_path.read_text(encoding="utf-8").splitlines():
            clean = line.strip()
            if not clean or clean.startswith("#") or clean.startswith(";") or "=" not in clean:
                continue
            lhs, rhs = (p.strip() for p in clean.split("=", 1))
            if not rhs:
                continue
            p_key = rhs.lower()
            short = re.split(r"[./:]", rhs)[-1] or lhs
            entry = sfx_map.setdefault(
                p_key,
                {"shortName": short, "path": rhs, "kind": "sound", "aliases": []},
            )
            if lhs and lhs.lower() != entry["shortName"].lower() and lhs not in entry["aliases"]:
                entry["aliases"].append(lhs)

    # 5. Seed VFX/SFX/Montages from custom_spells.json
    custom_spells_path = mod_dir / "custom_spells.json"
    if custom_spells_path.is_file():
        try:
            cs_obj = json.loads(strip_jsonc_comments(custom_spells_path.read_text(encoding="utf-8")))
            for sp in (cs_obj.get("spells") or {}).values():
                if not isinstance(sp, dict):
                    continue
                if sp.get("category"):
                    add_category(str(sp["category"]))
                if sp.get("montage"):
                    mon = str(sp["montage"])
                    montages_map.setdefault(mon.lower(), {"shortName": mon, "path": mon})
                for cue in sp.get("cues") or []:
                    if not isinstance(cue, dict):
                        continue
                    ct = str(cue.get("type") or "")
                    asset = str(cue.get("asset") or "")
                    if ct == "vfx" and asset:
                        sh = re.split(r"[./:]", asset)[-1] or asset
                        vfx_map.setdefault(
                            asset.lower(),
                            {"shortName": sh, "path": asset, "kind": "niagara", "aliases": []},
                        )
                    elif ct == "sfx" and asset:
                        sh = re.split(r"[./:]", asset)[-1] or asset
                        sfx_map.setdefault(
                            asset.lower(),
                            {"shortName": sh, "path": asset, "kind": "sound", "aliases": []},
                        )
                    elif ct in {"anim", "weaponAnim", "targetAnim"} and asset:
                        sh = re.split(r"[./:]", asset)[-1] or asset
                        montages_map.setdefault(asset.lower(), {"shortName": sh, "path": asset})
                    if cue.get("sfx"):
                        sa = str(cue["sfx"])
                        sfx_map.setdefault(
                            sa.lower(),
                            {"shortName": sa, "path": sa, "kind": "keyword", "aliases": []},
                        )
                    if cue.get("vfx"):
                        va = str(cue["vfx"])
                        vfx_map.setdefault(
                            va.lower(),
                            {"shortName": va, "path": va, "kind": "keyword", "aliases": []},
                        )
        except Exception:
            pass

    for entry in spells_map.values():
        entry["aliases"].sort()
    for entry in vfx_map.values():
        entry["aliases"].sort()
    for entry in sfx_map.values():
        entry["aliases"].sort()

    return {
        "$schema": "../schemas/detected_catalog.schema.json",
        "schemaVersion": 1,
        "format": "arcane-wilds.detected_catalog",
        "modVersion": mod_version,
        "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "source": "fallback",
        "categories": sorted(categories.values(), key=str.lower),
        "spells": sorted(
            spells_map.values(), key=lambda x: (x["category"].lower(), x["shortName"].lower())
        ),
        "vfx": sorted(vfx_map.values(), key=lambda x: x["shortName"].lower()),
        "sfx": sorted(sfx_map.values(), key=lambda x: x["shortName"].lower()),
        "montages": sorted(montages_map.values(), key=lambda x: x["shortName"].lower()),
    }


def detect_mod_version(mod_dir: Path) -> str:
    for candidate in (REPO_ROOT / "arcane-wilds" / "version.json", mod_dir / "modmenu.json"):
        if candidate.is_file():
            try:
                data = json.loads(candidate.read_text(encoding="utf-8"))
                if data.get("version"):
                    return str(data["version"])
            except Exception:
                pass
    return "1.0.0"


def build_llms_txt(mod_version: str, schema_names: list[str]) -> str:
    lines = [
        "# Arcane Wilds Studio — AI & Schema Index",
        "",
        f"> RuneScape: Dragonwilds UE4SS mod (Arcane Wilds v{mod_version}) configuration studio, JSON schemas, built-in defaults, and asset catalog.",
        "",
        "## Interactive Web Studio",
        "- [Arcane Wilds Studio](./index.html): Visual editor for custom spells, combo rules, and quick-cast hotkeys. Supports pasting/importing AI-generated JSON and exporting user configs.",
        "",
        "## JSON Schemas (Draft-07)",
    ]
    for name in sorted(schema_names):
        lines.append(f"- [{name}](./schemas/{name})")
    lines.extend([
        "",
        "## Default Configs & Asset Catalog",
        "- [defaults_spells.json](./data/defaults_spells.json): Built-in custom spell definitions.",
        "- [defaults_combos.json](./data/defaults_combos.json): Built-in combo rules.",
        "- [combo_rules_examples.json](./data/combo_rules_examples.json): Extended combo rule examples.",
        "- [defaults_quickcast.json](./data/defaults_quickcast.json): Default quick-cast hotkey bindings.",
        "- [fallback_catalog.json](./data/fallback_catalog.json): Baseline spell names, categories, VFX, SFX, and animation montages.",
        "- [version.json](./data/version.json): Mod version and build timestamp.",
        "",
        "## Usage Notes for AI Assistants",
        "- Generate `user_spells.json`, `user_combos.json`, `user_quick_cast.json`, or an `export_bundle` JSON matching the corresponding schema above.",
        "- Prefer spell/VFX/SFX/montage names from `fallback_catalog.json` or `defaults_spells.json` to avoid invalid asset references.",
        "- Users can paste generated JSON directly into the studio's **Import JSON** modal or drop downloaded files into `%LOCALAPPDATA%\\ArcaneWilds\\`.",
        "",
    ])
    return "\n".join(lines)


def stage_site(out_dir: Path, mod_dir: Path = MOD_DIR) -> None:
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    # 1. Copy editor static assets (excluding server.ps1)
    editor_dir = mod_dir / "editor"
    for item in editor_dir.iterdir():
        if item.name.lower() == "server.ps1":
            continue
        dest = out_dir / item.name
        if item.is_dir():
            shutil.copytree(item, dest)
        else:
            shutil.copy2(item, dest)

    # 2. Copy schemas
    schemas_src = mod_dir / "schemas"
    schemas_dst = out_dir / "schemas"
    schemas_dst.mkdir(parents=True, exist_ok=True)
    schema_names: list[str] = []
    for schema_file in sorted(schemas_src.glob("*.json")):
        shutil.copy2(schema_file, schemas_dst / schema_file.name)
        schema_names.append(schema_file.name)

    # 3. Populate data/
    data_dst = out_dir / "data"
    data_dst.mkdir(parents=True, exist_ok=True)

    mod_version = detect_mod_version(mod_dir)
    built_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

    for src_name, dst_name in (
        ("custom_spells.json", "defaults_spells.json"),
        ("combo_rules.json", "defaults_combos.json"),
        ("combo_rules_examples.json", "combo_rules_examples.json"),
    ):
        src_path = mod_dir / src_name
        if src_path.is_file():
            shutil.copy2(src_path, data_dst / dst_name)

    qc_path = mod_dir / "quick_cast.json"
    if not qc_path.is_file():
        qc_path = mod_dir / "quick_cast.txt"
    qc_bindings = parse_quick_cast(qc_path)
    (data_dst / "defaults_quickcast.json").write_text(
        json.dumps(qc_bindings, indent=2) + "\n", encoding="utf-8"
    )

    fallback_catalog = build_fallback_catalog(mod_dir, mod_version)
    (data_dst / "fallback_catalog.json").write_text(
        json.dumps(fallback_catalog, indent=2) + "\n", encoding="utf-8"
    )

    (data_dst / "version.json").write_text(
        json.dumps({"modVersion": mod_version, "builtAt": built_at}, indent=2) + "\n",
        encoding="utf-8",
    )

    # 4. Generate llms.txt & .nojekyll
    (out_dir / "llms.txt").write_text(
        build_llms_txt(mod_version, schema_names), encoding="utf-8"
    )
    (out_dir / ".nojekyll").write_text("", encoding="utf-8")

    print(
        f"Staged Arcane Wilds Web Studio to {out_dir} "
        f"(v{mod_version}, {len(schema_names)} schemas, "
        f"{len(fallback_catalog['spells'])} spells, "
        f"{len(fallback_catalog['vfx'])} VFX, "
        f"{len(fallback_catalog['sfx'])} SFX, "
        f"{len(qc_bindings)} quick-cast defaults)"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Build GitHub Pages site for Arcane Wilds Studio.")
    parser.add_argument("--out", default="_site", help="Output directory (default: _site)")
    args = parser.parse_args()
    out_path = Path(args.out)
    if not out_path.is_absolute():
        out_path = REPO_ROOT / out_path
    stage_site(out_path)


if __name__ == "__main__":
    main()
