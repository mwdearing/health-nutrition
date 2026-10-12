"""Synthetic JSON Schema conformance; run with Python and jsonschema installed."""
import json
from pathlib import Path
import unittest

import jsonschema

ROOT = Path(__file__).resolve().parent
SCHEMA = json.loads((ROOT / "shared-products-v2.schema.json").read_text())
FIXTURES = ROOT / "fixtures/shared-products-v2"
FORMAT = jsonschema.FormatChecker()


def nodes(value, path=()):
    if isinstance(value, dict):
        yield path, value
        for key, child in value.items():
            yield from nodes(child, path + (key,))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from nodes(child, path + (str(index),))


class SharedProductsSchemaTests(unittest.TestCase):
    def test_all_whole_string_patterns_reject_line_terminators(self):
        checked = 0
        for path, node in nodes(SCHEMA):
            pattern = node.get("pattern", "")
            if not pattern.startswith("^") or pattern.startswith("^ingredient:"):
                continue
            validator = jsonschema.Draft202012Validator(node)
            samples = [v for v in ["0", "1", "1.250000", "0012345678905", "12345670"] if validator.is_valid(v)]
            self.assertTrue(samples, path)
            checked += 1
            for sample in samples:
                for suffix in ["\n", "\r", "\r\n", "\u2028", "\u2029"]:
                    with self.subTest(path=path, sample=sample, suffix=repr(suffix)):
                        self.assertFalse(validator.is_valid(sample + suffix))
                        self.assertFalse(validator.is_valid(suffix + sample))
        self.assertGreaterEqual(checked, 20)

    def test_uuid_format_requires_canonical_hyphenated_spelling(self):
        checked = 0
        valid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        for path, node in nodes(SCHEMA):
            if node.get("format") != "uuid":
                continue
            checked += 1
            validator = jsonschema.Draft202012Validator(node, format_checker=FORMAT)
            with self.subTest(path=path):
                self.assertTrue(validator.is_valid(valid))
                self.assertTrue(validator.is_valid(valid.upper()))
                for invalid in [valid + "\n", valid + "\r", "\n" + valid, "{" + valid + "}", valid.replace("-", "")]:
                    self.assertFalse(validator.is_valid(invalid))
        self.assertGreaterEqual(checked, 10)

    def test_all_valid_shared_fixtures(self):
        jsonschema.Draft202012Validator.check_schema(SCHEMA)
        mapping = {
            "bounded-public-product": "public_product", "capabilities-bounded": "capabilities", "alternatives-response": "alternatives_response",
            "public-product": "public_product", "search-response": "search_response", "search-request": "search_request",
            "detail-response": "detail_response", "own-state-none": "own_state", "receipt": "receipt",
            "capabilities": "capabilities", "capabilities-resolution": "capabilities",
            "resolution-committed": "publish_resolution", "resolution-canceled": "publish_resolution", "resolution-replayed": "publish_resolution", "consent-receipt": "consent_receipt", "error": "error_detail", "withdraw": "withdraw_request",
            "legacy-public-product": "public_product", "legacy-alternative": "public_product",
            "legacy-detail-response": "detail_response", "legacy-search-response": "search_response", "legacy-receipt": "receipt",
        }
        for path in sorted(FIXTURES.glob("*-valid.json")):
            definition = mapping.get(path.stem.removesuffix("-valid"), "publish_request")
            schema = {"$ref": "#/$defs/" + definition, "$defs": SCHEMA["$defs"]}
            with self.subTest(fixture=path.name):
                jsonschema.validate(json.loads(path.read_text()), schema, format_checker=FORMAT)

    def test_resolution_union_is_closed_and_receipt_requires_replay(self):
        schema = {"$ref": "#/$defs/publish_resolution", "$defs": SCHEMA["$defs"]}
        validator = jsonschema.Draft202012Validator(schema, format_checker=FORMAT)
        canceled = {"outcome": "canceled_before_commit", "operation_id": "00000000-0000-4000-8000-000000000001", "replayed": False}
        self.assertTrue(validator.is_valid(canceled))
        for extra in ["receipt", "product_id", "current_state", "acknowledged_revision"]:
            self.assertFalse(validator.is_valid(dict(canceled, **{extra: None})))
        for key in canceled:
            self.assertFalse(validator.is_valid({k: v for k, v in canceled.items() if k != key}))
        receipt = json.loads((FIXTURES / "receipt-valid.json").read_text())
        self.assertFalse(validator.is_valid({"outcome": "committed", "receipt": receipt}))
        receipt["replayed"] = True
        self.assertTrue(validator.is_valid({"outcome": "committed", "receipt": receipt}))
        self.assertFalse(validator.is_valid({"outcome": "committed", "receipt": receipt, "replayed": True}))
        self.assertFalse(validator.is_valid(dict(canceled, outcome="unknown")))
        # Older backends omit the capability. A new-server fixture must advertise exactly v1.
        old = json.loads((FIXTURES / "capabilities-valid.json").read_text())
        cap = jsonschema.Draft202012Validator({"$ref": "#/$defs/capabilities", "$defs": SCHEMA["$defs"]})
        self.assertTrue(cap.is_valid(old))
        self.assertTrue(cap.is_valid(dict(old, publish_resolution_version=1)))
        self.assertFalse(cap.is_valid(dict(old, publish_resolution_version=2)))
        self.assertEqual(json.loads((FIXTURES / "capabilities-resolution-valid.json").read_text())["publish_resolution_version"], 1)

    def test_raw_ingredient_suffixes_still_allow_line_terminators(self):
        fact = {"key": "ingredient:\n", "display_name": "Synthetic compound", "state": "unknown"}
        schema = {"$ref": "#/$defs/fact", "$defs": SCHEMA["$defs"]}
        jsonschema.validate(fact, schema)
        legacy = json.loads((FIXTURES / "legacy-public-product-valid.json").read_text())["product"]
        schema = {"$ref": "#/$defs/product", "$defs": SCHEMA["$defs"]}
        self.assertFalse(jsonschema.Draft202012Validator(schema).is_valid(legacy))


if __name__ == "__main__":
    unittest.main(verbosity=2)
