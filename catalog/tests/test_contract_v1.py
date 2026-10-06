"""Contract tests for catalog contract v1 (NF-01 public/private boundary, NF-02 nutrient semantics).

These run offline: no network, no database. They check the contract files as
published, with a small pure-Python reference evaluator that reproduces every
golden vector exactly using `decimal.Decimal`.
"""

from __future__ import annotations

import json
from decimal import Decimal
from pathlib import Path

import jsonschema
import pytest

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS = ROOT / "contracts"

PRODUCT_SCHEMA_PATH = CONTRACTS / "catalog-api" / "product-version.v1.schema.json"
ERROR_SCHEMA_PATH = CONTRACTS / "catalog-api" / "error.v1.schema.json"
OPENAPI_PATH = CONTRACTS / "catalog-api" / "openapi.v1.yaml"
REGISTRY_PATH = CONTRACTS / "nutrients" / "registry.v1.json"
GOLDEN_PATH = CONTRACTS / "nutrients" / "golden.v1.json"


def load(path: Path):
    return json.loads(path.read_text())


@pytest.fixture(scope="session")
def product_schema():
    return load(PRODUCT_SCHEMA_PATH)


@pytest.fixture(scope="session")
def error_schema():
    return load(ERROR_SCHEMA_PATH)


@pytest.fixture(scope="session")
def registry():
    return load(REGISTRY_PATH)


@pytest.fixture(scope="session")
def golden():
    return load(GOLDEN_PATH)


@pytest.fixture(scope="session")
def product_validator(product_schema):
    return jsonschema.Draft202012Validator(product_schema)


@pytest.fixture(scope="session")
def error_validator(error_schema):
    return jsonschema.Draft202012Validator(error_schema)


def valid_product() -> dict:
    return {
        "product_id": "prod_0001",
        "version": 3,
        "name": "Rolled oats",
        "brand": "Example Mills",
        "barcodes": ["012345678905"],
        "serving": {"amount": "40", "unit": "g"},
        "nutrients": {
            "energy": {"state": "known", "amount": "150", "unit": "kcal"},
            "protein": {"state": "known", "amount": "5.2", "unit": "g"},
            "vitamin_d": {"state": "below_reporting_threshold", "unit": "ug"},
            "sodium": {"state": "unknown"},
            "caffeine": {"state": "not_applicable"},
        },
        "source": {
            "name": "usda_fdc",
            "licence": "CC0-1.0",
            "attribution": "USDA FoodData Central",
        },
        "status": "published",
    }


def product(validator, doc) -> None:
    errors = sorted(validator.iter_errors(doc), key=lambda e: list(e.path))
    assert not errors, "; ".join(f"{list(e.path)}: {e.message}" for e in errors)


def product_rejected(validator, doc) -> None:
    assert not validator.is_valid(doc), f"document was accepted but should be refused: {doc}"


# --------------------------------------------------------------------------- NF-01


def test_product_and_error_schemas_are_valid_2020_12(product_schema, error_schema):
    jsonschema.Draft202012Validator.check_schema(product_schema)
    jsonschema.Draft202012Validator.check_schema(error_schema)


def test_a_minimal_public_product_is_accepted(product_validator):
    product(product_validator, valid_product())


def test_optional_fields_may_be_left_out(product_validator):
    doc = valid_product()
    del doc["brand"]
    del doc["barcodes"]
    doc["nutrients"]["vitamin_d"] = {"state": "below_reporting_threshold"}
    product(product_validator, doc)


@pytest.mark.parametrize(
    "field",
    ["user_id", "intake_id", "device_id", "email", "notes", "dose", "taken_at", "healthkit_uuid"],
)
def test_private_fields_are_refused_at_the_top_level(product_validator, field):
    doc = valid_product()
    doc[field] = "x"
    product_rejected(product_validator, doc)


@pytest.mark.parametrize(
    ("parent", "field"),
    [("serving", "notes"), ("serving", "quantity_consumed"), ("source", "user_id")],
)
def test_private_fields_are_refused_inside_nested_objects(product_validator, parent, field):
    doc = valid_product()
    doc[parent][field] = "x"
    product_rejected(product_validator, doc)


def test_private_fields_are_refused_inside_a_nutrient_value(product_validator):
    doc = valid_product()
    doc["nutrients"]["protein"]["taken_at"] = "x"
    product_rejected(product_validator, doc)


@pytest.mark.parametrize("field", ["product_id", "version", "name", "serving", "nutrients", "source", "status"])
def test_required_fields_are_required(product_validator, field):
    doc = valid_product()
    del doc[field]
    product_rejected(product_validator, doc)


def test_every_source_states_its_licence(product_validator):
    doc = valid_product()
    del doc["source"]["licence"]
    product_rejected(product_validator, doc)


def test_only_published_records_are_served(product_validator):
    for status in ("draft", "pending", "withdrawn", "deleted"):
        doc = valid_product()
        doc["status"] = status
        product_rejected(product_validator, doc)


def test_the_error_object_is_closed(error_validator):
    product(error_validator, {"code": "not_found", "message": "No such product"})
    error_validator_errors = [
        {"code": "not_found", "message": "No such product", "user_id": "u1"},
        {"code": "not_found"},
        {"code": "not_found", "message": "m", "detail": "stack trace"},
    ]
    for doc in error_validator_errors:
        product_rejected(error_validator, doc)


# --------------------------------------------------------------------------- NF-02 schema


@pytest.mark.parametrize(
    "amount",
    [150, 5.2, "1e3", "5,2", "", "NaN", "Infinity", "-0.5x", "05.2", "+5.2", " 5.2", "5."],
)
def test_only_plain_decimal_strings_are_amounts(product_validator, amount):
    doc = valid_product()
    doc["nutrients"]["protein"]["amount"] = amount
    product_rejected(product_validator, doc)


def test_amount_states_follow_the_value_states(product_validator):
    doc = valid_product()
    doc["nutrients"]["protein"] = {"state": "known", "unit": "g"}
    product_rejected(product_validator, doc)

    doc = valid_product()
    doc["nutrients"]["sodium"] = {"state": "unknown", "amount": "1", "unit": "mg"}
    product_rejected(product_validator, doc)

    doc = valid_product()
    doc["nutrients"]["caffeine"] = {"state": "not_applicable", "unit": "mg"}
    product_rejected(product_validator, doc)

    doc = valid_product()
    doc["nutrients"]["protein"] = {"state": "made_up", "amount": "1", "unit": "g"}
    product_rejected(product_validator, doc)


def test_unknown_unit_symbols_are_refused(product_validator, registry):
    symbols = {unit["symbol"] for unit in registry["units"]}
    assert "g" in symbols and "kcal" in symbols
    for unit in ("furlong", "G", "mcG", ""):
        doc = valid_product()
        doc["nutrients"]["protein"]["unit"] = unit
        product_rejected(product_validator, doc)


def test_schema_units_and_registry_units_agree(product_validator, registry):
    declared = product_schema_unit_symbols(load(PRODUCT_SCHEMA_PATH))
    assert declared == {unit["symbol"] for unit in registry["units"]}


def product_schema_unit_symbols(schema) -> set[str]:
    return set(schema["$defs"]["unitSymbol"]["enum"])


# --------------------------------------------------------------------------- registry


def test_the_registry_covers_the_required_nutrients(registry):
    ids = {nutrient["id"] for nutrient in registry["nutrients"]}
    required = {
        "energy", "protein", "total_fat", "saturated_fat", "carbohydrate", "fiber",
        "sugars", "sodium", "potassium", "calcium", "iron", "vitamin_a", "vitamin_c",
        "vitamin_d", "caffeine", "water",
    }
    assert required <= ids


def test_every_nutrient_declares_a_dimension_and_a_usable_canonical_unit(registry):
    dimensions = {"mass", "volume", "energy", "count", "international_unit"}
    units = {unit["symbol"]: unit for unit in registry["units"]}
    for nutrient in registry["nutrients"]:
        assert nutrient["dimension"] in dimensions, nutrient
        canonical = nutrient["canonical_unit"]
        assert canonical in units, nutrient
        assert units[canonical]["dimension"] == nutrient["dimension"], nutrient


def test_every_unit_declares_its_dimension_and_an_exact_factor(registry):
    by_symbol = {unit["symbol"]: unit for unit in registry["units"]}
    for symbol, unit in by_symbol.items():
        assert unit["dimension"] in registry["canonical_units_by_dimension"], unit
        factor = unit["factor_to_canonical"]
        if unit["symbol"] == registry["canonical_units_by_dimension"][unit["dimension"]]:
            assert factor == "1", unit
        if factor is not None:
            assert isinstance(factor, str), "factors are decimal strings, not numbers"
            assert Decimal(factor) > 0, unit
    # The two energy units differ by the exact thermochemical factor 1 kcal = 4.184 kJ,
    # so the energy dimension is canonical in kJ and the kcal factor is exact.
    assert Decimal(by_symbol["kcal"]["factor_to_canonical"]) == Decimal("4.184")
    assert Decimal(by_symbol["kJ"]["factor_to_canonical"]) == Decimal("1")


def test_the_registry_holds_no_json_numbers(registry):
    def walk(node):
        if isinstance(node, dict):
            for value in node.values():
                yield from walk(value)
        elif isinstance(node, list):
            for value in node:
                yield from walk(value)
        else:
            yield node

    for leaf in walk(registry):
        assert not isinstance(leaf, float), f"{leaf!r} is a JSON float"


def test_every_nutrient_id_used_in_the_goldens_exists(registry, golden):
    ids = {nutrient["id"] for nutrient in registry["nutrients"]}
    named = {case["nutrient"] for case in golden["cases"] if "nutrient" in case}
    assert named, "the goldens must say which registry nutrient each case is about"
    assert named <= ids, named - ids


# --------------------------------------------------------------------------- reference evaluator


class UnitError(Exception):
    """Mirrors the Swift UnitError cases the contract names."""

    def __init__(self, name: str) -> None:
        super().__init__(name)
        self.name = name


def units(registry):
    return {unit["symbol"]: unit for unit in registry["units"]}


def convert(amount: Decimal, unit: str, target: str, registry, density: Decimal | None = None,
            portion: dict | None = None) -> Decimal:
    table = units(registry)
    for symbol in (unit, target):
        if symbol not in table:
            raise UnitError("unknown_symbol")
    if unit == target:
        return amount

    source, dest = table[unit], table[target]
    if source["dimension"] == dest["dimension"]:
        if source["dimension"] == "count":
            raise UnitError("incompatible_count_units")
        return amount * Decimal(source["factor_to_canonical"]) / Decimal(dest["factor_to_canonical"])
    if "international_unit" in (source["dimension"], dest["dimension"]):
        raise UnitError("international_unit_not_convertible")

    if source["dimension"] == "count" or dest["dimension"] == "count":
        # A count unit needs a stated portion, and the portion must name this count unit.
        if portion is None or portion["count_unit"] not in (unit, target):
            raise UnitError("missing_portion_definition")
        if source["dimension"] == "count" and dest["dimension"] == "count":
            raise UnitError("incompatible_count_units")
        portion_amount = Decimal(portion["amount"]) * amount
        return convert(portion_amount, portion["unit"], target, registry, density)

    if {source["dimension"], dest["dimension"]} == {"mass", "volume"}:
        if density is None:
            raise UnitError("missing_density")
        if density <= 0:
            raise UnitError("invalid_density")
        # Density is grams per millilitre: mass divides by it, volume multiplies by it.
        in_grams = amount * Decimal(source["factor_to_canonical"])
        if source["dimension"] == "mass":
            in_grams = in_grams / density
        else:
            in_grams = in_grams * density
        return in_grams / Decimal(dest["factor_to_canonical"])
    raise UnitError("dimension_mismatch")


def scale(case_input: dict, registry) -> dict:
    basis, consumed = case_input["basis"], case_input["consumed"]
    value = case_input["value"]
    if Decimal(basis["amount"]) <= 0:
        raise UnitError("non_positive_amount")
    if Decimal(consumed["amount"]) < 0:
        raise UnitError("negative_amount")
    consumed_in_basis = convert(
        Decimal(consumed["amount"]), consumed["unit"], basis["unit"], registry
    )
    if value["state"] != "known":
        # Scaling passes a non-known value through unchanged, unit included.
        return {key: item for key, item in value.items() if key != "amount"}
    factor = consumed_in_basis / Decimal(basis["amount"])
    return {"state": "known", "amount": str(Decimal(value["amount"]) * factor), "unit": value["unit"]}


def sum_values(case_input: dict, registry) -> dict:
    known, total_count = [], 0
    has_unknown = has_below = False
    for value in case_input["values"]:
        if value["state"] == "known":
            known.append((Decimal(value["amount"]), value["unit"]))
            total_count += 1
        elif value["state"] == "unknown":
            has_unknown = True
            total_count += 1
        elif value["state"] == "below_reporting_threshold":
            has_below = True
            total_count += 1
        elif value["state"] == "not_applicable":
            continue
        else:
            raise AssertionError(f"unknown state {value['state']!r}")

    coverage = {
        "known_count": len(known),
        "total_count": total_count,
        "has_unknown": has_unknown,
        "has_below_reporting_threshold": has_below,
        "is_complete": len(known) == total_count,
    }

    if not known:
        if has_unknown:
            state = {"state": "unknown"}
        elif has_below:
            state = {"state": "below_reporting_threshold"}
        else:
            state = {"state": "unknown"} if not case_input["values"] else {"state": "not_applicable"}
        return {"value": state, "coverage": coverage}

    target = case_input.get("unit") or known[0][1]
    running = Decimal(0)
    for amount, unit in known:
        running += convert(amount, unit, target, registry)
    return {
        "value": {"state": "known", "amount": decimal_string(running), "unit": target},
        "coverage": coverage,
    }


def decimal_string(value: Decimal) -> str:
    """Normalise a Decimal to the plain form the contract uses: no exponent, no trailing zeros."""
    normalised = value.normalize()
    text = format(normalised, "f")
    return text


def run_case(case: dict, registry) -> dict:
    case_input = case["input"]
    if case["op"] == "convert":
        converted = convert(
            Decimal(case_input["amount"]),
            case_input["unit"],
            case_input["to"],
            registry,
            Decimal(case_input["density"]) if "density" in case_input else None,
            case_input.get("portion"),
        )
        return {"amount": decimal_string(converted), "unit": case_input["to"]}
    if case["op"] == "scale":
        scaled = scale(case_input, registry)
        if scaled.get("state") == "known":
            scaled["amount"] = decimal_string(Decimal(scaled["amount"]))
        return scaled
    if case["op"] == "sum":
        return sum_values(case_input, registry)
    raise AssertionError(f"unknown op {case['op']!r}")


# --------------------------------------------------------------------------- goldens


def test_the_goldens_are_well_formed(golden):
    assert golden["version"] == 1
    cases = golden["cases"]
    assert len(cases) >= 20
    assert len({case["id"] for case in cases}) == len(cases)
    assert {"convert", "scale", "sum", "reject"} <= {case["op"] for case in cases}


def test_the_goldens_contain_no_json_floats(golden):
    def walk(node):
        if isinstance(node, dict):
            for value in node.values():
                yield from walk(value)
        elif isinstance(node, list):
            for value in node:
                yield from walk(value)
        else:
            yield node

    for leaf in walk(golden):
        assert not isinstance(leaf, float), f"{leaf!r} is a JSON float; decimals must be strings"


@pytest.mark.parametrize("case", load(GOLDEN_PATH)["cases"], ids=lambda case: case["id"])
def test_the_reference_evaluator_reproduces_every_golden(case, registry):
    if case["op"] == "reject":
        with pytest.raises(UnitError) as raised:
            if case["id"].startswith("reject_sum"):
                sum_values(case["input"], registry)
            elif case["input"].get("basis") is not None or "basis" in case["input"]:
                scale(case["input"], registry)
            else:
                convert(
                    Decimal(case["input"]["amount"]),
                    case["input"]["unit"],
                    case["input"]["to"],
                    registry,
                    Decimal(case["input"]["density"]) if "density" in case["input"] else None,
                    case["input"].get("portion"),
                )
        assert raised.value.name == case["expect"]["error"]
        return
    assert run_case(case, registry) == case["expect"]


def test_scaling_never_rounds_a_stored_amount(golden):
    """The 40 g of a 100 g basis case must be exact, not 2.1."""
    case = next(c for c in golden["cases"] if c["id"] == "scale_a_serving_of_a_hundred_gram_basis")
    assert run_case(case, load(REGISTRY_PATH))["amount"] == "2.08"


def test_an_unknown_total_is_never_zero(golden, registry):
    case = next(c for c in golden["cases"] if c["id"] == "sum_of_only_unknown_values_is_unknown")
    assert run_case(case, registry)["value"] == {"state": "unknown"}


def test_ten_tenths_are_exactly_one_gram(golden, registry):
    case = next(c for c in golden["cases"] if c["id"] == "sum_decimal_repeating_addition_has_no_binary_drift")
    assert run_case(case, registry)["value"]["amount"] == "1"


# --------------------------------------------------------------------------- openapi


def test_the_openapi_skeleton_is_read_only_and_needs_a_token():
    text = OPENAPI_PATH.read_text()
    operations = [line.strip() for line in text.splitlines() if line.strip().startswith(("get:", "post:", "put:", "patch:", "delete:"))]
    assert operations and all(op == "get:" for op in operations), operations
    assert text.count("bearerAuth: []") >= 4, "every operation needs bearer auth"
    for forbidden in ("user_id", "userId", "email", "device_id", "intake_id", "taken_at", "healthkit"):
        assert forbidden not in text, f"{forbidden} must not appear in the catalog API"
