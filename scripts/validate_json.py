#!/usr/bin/env python3
import json
import sys
from pathlib import Path
from jsonschema import Draft7Validator


def main() -> int:
    root = Path("arcane-wilds")
    mod_root = root / "ue4ss/Mods/ArcaneWilds"

    # 1. Verify every .json file under arcane-wilds is valid JSON
    for jf in sorted(root.rglob("*.json")):
        if "Intermediate" in jf.parts or "Saved" in jf.parts:
            continue
        with jf.open("r", encoding="utf-8-sig") as f:
            json.load(f)
        print(f"JSON OK: {jf}")

    # 2. Verify all Draft-07 schemas themselves are valid
    schema_dir = mod_root / "schemas"
    for sf in sorted(schema_dir.glob("*.schema.json")):
        with sf.open("r", encoding="utf-8-sig") as f:
            Draft7Validator.check_schema(json.load(f))
        print(f"META-SCHEMA OK: {sf}")

    # 3. Validate configs against their Draft-07 JSON Schemas and verify schemaVersion
    pairs = [
        (mod_root / "custom_spells.json", mod_root / "schemas/custom_spells.schema.json"),
        (mod_root / "combo_rules.json", mod_root / "schemas/combo_rules.schema.json"),
        (mod_root / "combo_rules_examples.json", mod_root / "schemas/combo_rules.schema.json"),
    ]

    for data_path, schema_path in pairs:
        with schema_path.open("r", encoding="utf-8-sig") as sf:
            schema = json.load(sf)
        Draft7Validator.check_schema(schema)
        validator = Draft7Validator(schema)

        with data_path.open("r", encoding="utf-8-sig") as df:
            data = json.load(df)

        if not isinstance(data.get("schemaVersion"), int) or data.get("schemaVersion") < 1:
            print(f"SCHEMA FAIL: {data_path} missing integer schemaVersion >= 1")
            return 1

        errors = sorted(validator.iter_errors(data), key=lambda e: list(e.path))
        if errors:
            print(f"SCHEMA FAIL: {data_path}")
            for err in errors:
                loc = ".".join(str(p) for p in err.path) or "<root>"
                print(f"  - [{loc}] {err.message}")
            return 1

        print(f"SCHEMA OK: {data_path} -> {schema_path.name}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
