import json
import sys
from jsonschema import validate, ValidationError

def validate_json(data_path, schema_path):
    with open(data_path, 'r') as df, open(schema_path, 'r') as sf:
        data = json.load(df)
        schema = json.load(sf)
    try:
        validate(instance=data, schema=schema)
        print("JSON is valid.")
    except ValidationError as e:
        print(f"Validation error: {e.message}")
        sys.exit(1)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python validate_json.py <path_to_json> <path_to_schema>")
        sys.exit(1)
    validate_json(sys.argv[1], sys.argv[2])
