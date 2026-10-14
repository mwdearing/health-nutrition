"""Contract tests for catalog contract v1 (NF-01 public/private boundary, NF-02 nutrient semantics).

These run offline: no network, no database. They check the contract files as
published, with a small pure-Python reference evaluator that reproduces every
golden vector exactly, in rational arithmetic, with the one rounding rule the contract states.
"""

from __future__ import annotations

import json
import re
import unicodedata
from decimal import Decimal
from fractions import Fraction
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
SWIFT_UNITS_PATH = ROOT / "ios" / "NutritionCore" / "Sources" / "NutritionDomain" / "Units.swift"
SWIFT_STANDARD_KEYS_PATH = ROOT / "ios" / "NutritionCore" / "Sources" / "NutritionDomain" / "CustomProductValidation.swift"


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
            "vitamin_d": {"state": "below_reporting_threshold", "unit": "mcg"},
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


@pytest.mark.parametrize("amount", ["-5", "-0", "-0.0", "-0.5"])
def test_a_known_amount_is_never_negative(product_validator, amount):
    doc = valid_product()
    doc["nutrients"]["protein"]["amount"] = amount
    product_rejected(product_validator, doc)


@pytest.mark.parametrize("amount", ["1234567890123", "1.1234567", "0.0000001", "9999999999999.9", "1" * 40])
def test_an_amount_is_bounded_to_twelve_integer_and_six_fraction_digits(product_validator, amount):
    doc = valid_product()
    doc["nutrients"]["protein"]["amount"] = amount
    product_rejected(product_validator, doc)

    doc = valid_product()
    doc["serving"]["amount"] = amount
    product_rejected(product_validator, doc)


def test_two_of_the_largest_wire_amounts_multiply_within_the_arithmetic_bound(product_validator):
    largest = "999999999999.999999"
    doc = valid_product()
    doc["nutrients"]["protein"]["amount"] = largest
    doc["serving"]["amount"] = largest
    product(product_validator, doc)
    assert significant_digits(exact(largest) * exact(largest)) <= SIGNIFICANT_DIGITS


@pytest.mark.parametrize("amount", ["0", "0.0", "0.25", "12", "1500.000001", "999999999999.999999"])
def test_zero_and_positive_amounts_are_accepted(product_validator, amount):
    doc = valid_product()
    doc["nutrients"]["protein"]["amount"] = amount
    product(product_validator, doc)


@pytest.mark.parametrize("amount", ["0", "0.0", "0.000", "-1", "-0.5", "00", "", 40, "1e2"])
def test_a_serving_amount_is_a_positive_decimal(product_validator, amount):
    doc = valid_product()
    doc["serving"]["amount"] = amount
    product_rejected(product_validator, doc)


@pytest.mark.parametrize(
    ("amount", "unit"),
    [("40", "g"), ("0.5", "kg"), ("0.05", "L"), ("250", "mL"), ("1", "serving"), ("2", "gummy"), ("10.0", "mg")],
)
def test_a_serving_is_a_mass_a_volume_or_a_count(product_validator, amount, unit):
    doc = valid_product()
    doc["serving"] = {"amount": amount, "unit": unit}
    product(product_validator, doc)


@pytest.mark.parametrize("unit", ["kcal", "IU", "kJ", "furlong", "ml", ""])
def test_a_serving_is_never_stated_in_energy_or_international_units(product_validator, unit):
    doc = valid_product()
    doc["serving"]["unit"] = unit
    product_rejected(product_validator, doc)


def test_unknown_unit_symbols_are_refused(product_validator, registry):
    symbols = {unit["symbol"] for unit in registry["units"]}
    assert "g" in symbols and "kcal" in symbols
    for unit in ("furlong", "G", "mcG", "", "ug", "ml", "l", "iu", "kJ"):
        doc = valid_product()
        doc["nutrients"]["protein"]["unit"] = unit
        product_rejected(product_validator, doc)


@pytest.mark.parametrize("nutrient", ["totally_fake", "vitamin_k", "Protein", "protein_", ""])
def test_only_registered_nutrient_ids_are_accepted(product_validator, nutrient):
    doc = valid_product()
    doc["nutrients"][nutrient] = {"state": "unknown"}
    product_rejected(product_validator, doc)


@pytest.mark.parametrize(
    ("nutrient", "unit"),
    [("protein", "kcal"), ("protein", "IU"), ("protein", "mL"), ("protein", "serving"), ("energy", "g"),
     ("energy", "IU"), ("sodium", "L"), ("vitamin_c", "IU"), ("vitamin_d", "kcal"), ("vitamin_a", "mL"),
     ("vitamin_d", "IU"), ("vitamin_a", "IU"), ("cholesterol", "kcal")],
)
def test_a_nutrient_is_only_stated_in_its_own_units(product_validator, nutrient, unit):
    doc = valid_product()
    doc["nutrients"][nutrient] = {"state": "known", "amount": "1", "unit": unit}
    product_rejected(product_validator, doc)

    doc = valid_product()
    doc["nutrients"][nutrient] = {"state": "below_reporting_threshold", "unit": unit}
    product_rejected(product_validator, doc)


def test_every_registered_nutrient_is_accepted_in_each_of_its_units(product_validator, registry):
    for nutrient in registry["nutrients"]:
        for unit in nutrient["units"]:
            doc = valid_product()
            doc["nutrients"] = {nutrient["id"]: {"state": "known", "amount": "1", "unit": unit}}
            product(product_validator, doc)
            doc["nutrients"] = {nutrient["id"]: {"state": "below_reporting_threshold", "unit": unit}}
            product(product_validator, doc)


def resolve(schema, node):
    while "$ref" in node:
        node = schema["$defs"][node["$ref"].removeprefix("#/$defs/")]
    return node


def schema_units_by_nutrient(schema) -> dict[str, dict[str, list[str]]]:
    """For each nutrient id the schema accepts: the unit enum of its known and below-threshold states."""
    found = {}
    for nutrient, ref in schema["$defs"]["nutrientMap"]["properties"].items():
        states = {}
        for branch in resolve(schema, ref)["oneOf"]:
            branch = resolve(schema, branch)
            state = branch["properties"]["state"]["const"]
            if "unit" in branch["properties"]:
                states[state] = resolve(schema, branch["properties"]["unit"])["enum"]
            else:
                states[state] = None
        assert set(states) == {"known", "unknown", "not_applicable", "below_reporting_threshold"}, nutrient
        found[nutrient] = states
    return found


def test_the_schema_accepts_exactly_the_registry_nutrients_and_their_units(product_schema, registry):
    nutrient_map = product_schema["$defs"]["nutrientMap"]
    assert nutrient_map["additionalProperties"] is False
    assert "patternProperties" not in nutrient_map
    by_nutrient = schema_units_by_nutrient(product_schema)
    assert set(by_nutrient) == {nutrient["id"] for nutrient in registry["nutrients"]}
    for nutrient in registry["nutrients"]:
        states = by_nutrient[nutrient["id"]]
        assert states["known"] == nutrient["units"], nutrient
        assert states["below_reporting_threshold"] == nutrient["units"], nutrient
        assert states["unknown"] is None and states["not_applicable"] is None, nutrient


def test_the_schema_serving_units_are_the_registry_mass_volume_and_count_units(product_schema, registry):
    assert registry["serving_dimensions"] == ["mass", "volume", "count"]
    expected = [unit["symbol"] for unit in registry["units"] if unit["dimension"] in registry["serving_dimensions"]]
    serving = product_schema["$defs"]["serving"]["properties"]
    assert resolve(product_schema, serving["unit"])["enum"] == expected
    assert resolve(product_schema, serving["amount"]) is product_schema["$defs"]["positiveDecimal"]


def product_schema_unit_symbols(schema) -> set[str]:
    """Every unit symbol any enum of the schema lets through."""
    symbols = set()
    for name, definition in schema["$defs"].items():
        if name.endswith("Unit"):
            symbols |= set(definition["enum"])
    return symbols


def test_schema_units_and_registry_units_agree(product_schema, registry):
    """Every registry unit a product can carry is in the schema, and nothing else is. IU is the one
    registry unit no v1 nutrient and no serving is stated in."""
    publishable = {unit["symbol"] for unit in registry["units"] if unit["dimension"] != "international_unit"}
    assert product_schema_unit_symbols(product_schema) == publishable
    assert "IU" not in json.dumps(product_schema["$defs"]["nutrientMap"]) and "IU" not in publishable


def swift_standard_dimensions() -> dict[str, str]:
    """The app's standard panel keys and their dimensions, read from CustomProductValidation.swift."""
    text = SWIFT_STANDARD_KEYS_PATH.read_text()
    block = text[text.index("standardDimensions: [String: UnitDimension] = [") :]
    block = block[block.index("= [") : block.index("\n    ]")]
    return dict(re.findall(r'"([A-Za-z]+)": \.([a-z]+)', block))


def test_every_nutrient_maps_to_the_key_the_app_files_it_under(registry):
    """A client translates a catalog nutrient id through app_key, so no contract-valid nutrient is
    dropped: every standard key of the app has exactly one nutrient, with the same dimension."""
    swift = swift_standard_dimensions()
    assert {"energyKcal", "fat", "vitaminD"} <= set(swift), "the Swift standard keys were not read"
    keys = [nutrient["app_key"] for nutrient in registry["nutrients"]]
    assert len(set(keys)) == len(keys)
    standard = {}
    for nutrient in registry["nutrients"]:
        key = nutrient["app_key"]
        if key.startswith("ingredient:"):
            assert key == f"ingredient:{nutrient['id']}", nutrient
            assert nutrient["id"] not in swift, nutrient
        else:
            standard[key] = nutrient["dimension"]
    assert standard == swift


def test_every_wire_unit_symbol_is_one_the_ios_unit_registry_knows(product_schema, registry, golden):
    """A contract-valid document must decode in the app, so the wire set is a subset of the Swift set."""
    swift = set(re.findall(r'symbol: "([^"]+)"', SWIFT_UNITS_PATH.read_text()))
    assert {"g", "mcg", "kcal", "IU"} <= swift, "the Swift unit registry was not read"
    wire = {unit["symbol"] for unit in registry["units"]} | product_schema_unit_symbols(product_schema)
    assert wire <= swift, wire - swift
    for nutrient in registry["nutrients"]:
        assert set(nutrient["units"]) <= swift, nutrient
    for case in golden["cases"]:
        if case["op"] == "reject":
            continue
        used = set(re.findall(r'"(?:unit|to|count_unit)": "([^"]*)"', json.dumps(case)))
        assert used <= swift, (case["id"], used - swift)


@pytest.mark.parametrize("field", ["name", "brand", "attribution"])
@pytest.mark.parametrize(
    "text",
    ["Éclair drink", "明治おいしい牛乳", "Müsli & Früchte 30 %", "Сырок глазированный", "x", "Crème fraîche d'Isigny",
     "Fromage 30\u202f% MG", "Lait\u00a0entier", "Oats \U0001f33e", "عصير برتقال", "Jalapen\u0303o", "한국 우유",
     # The neighbours of the noncharacters are ordinary characters.
     "Oa\ufdcfts", "Oa\ufdf0ts", "Oa\U0001fffdts", "Oa\U00020000ts"],
)
def test_display_text_may_be_in_any_script(product_validator, field, text):
    doc = valid_product()
    target = doc["source"] if field == "attribution" else doc
    target[field] = text
    product(product_validator, doc)


@pytest.mark.parametrize("field", ["name", "brand", "attribution"])
@pytest.mark.parametrize(
    "text",
    ["", " ", " Oats", "Oats ", "Oats\n", "Oa\nts", "Oa\tts", "Oa\u0000ts", "Oa\u007fts", "Oa\u0085ts",
     "\u0085Oats", "Oa\u2028ts", "Oa\u2029ts", "Oa\u202ets", "Oats\u202e", "Oa\u2066ts", "Éclair\n", "x" * 600,
     # Invisible or reordering characters: soft hyphen, Arabic letter mark, zero-width space, joiners,
     # direction marks, word joiner, byte order mark, annotation anchors, a tag character, a lone surrogate.
     "Oa\u00adts", "Oa\u061cts", "Oa\u180ets", "Oa\u200bts", "Oa\u200cts", "Oa\u200dts", "Oa\u200ets",
     "Oa\u200fts", "Oats\u200f", "Oa\u2060ts", "Oa\u2064ts", "Oa\u206fts", "Oa\ufeffts", "\ufeffOats",
     "Oa\ufff9ts", "Oa\ufffets", "Oa\uffffts", "Oa\ufdd0ts", "Oa\ufdefts", "Oa\U0001fffets",
     "Oa\U0001ffffts", "Oa\U0008fffets", "Oa\U0010fffets", "Oa\U0010ffffts", "Oa\U000e0041ts", "Oa\U000e007fts", "Oa\ud800ts",
     # Variation selectors, a Hangul filler, private use, and format controls outside the basic plane.
     "Oa\ufe0fts", "Oa\ufe00ts", "Oa\u3164ts", "Oa\u115fts", "Oa\ue000ts", "Oa\U000f0000ts", "Oa\U0001bca0ts",
     "Oa\U0001d173ts", "Oa\U000e0100ts", "Oa\u034fts", "Oa\ufff0ts", "Oa\u0600ts", "Oa\U000110bdts",
     # Any kind of space at an edge.
     "\u00a0Oats", "Oats\u00a0", "\u2003Oats", "Oats\u202f", "Oats\u3000", "\u205fOats", "\u1680Oats"],
)
def test_display_text_refuses_control_and_direction_override_characters(product_validator, field, text):
    doc = valid_product()
    target = doc["source"] if field == "attribution" else doc
    target[field] = text
    product_rejected(product_validator, doc)


# --------------------------------------------------------------------------- registry


def test_the_registry_covers_the_required_nutrients(registry):
    ids = {nutrient["id"] for nutrient in registry["nutrients"]}
    required = {
        "energy", "protein", "total_fat", "saturated_fat", "carbohydrate", "fiber",
        "sugars", "sodium", "potassium", "calcium", "iron", "vitamin_a", "vitamin_c",
        "vitamin_d", "caffeine", "water", "trans_fat", "cholesterol", "added_sugars",
    }
    assert required == ids


def test_every_nutrient_declares_a_dimension_and_a_usable_canonical_unit(registry):
    dimensions = {"mass", "volume", "energy", "count", "international_unit"}
    units = {unit["symbol"]: unit for unit in registry["units"]}
    for nutrient in registry["nutrients"]:
        assert nutrient["dimension"] in dimensions, nutrient
        canonical = nutrient["canonical_unit"]
        assert canonical in units, nutrient
        assert units[canonical]["dimension"] == nutrient["dimension"], nutrient
        assert canonical in nutrient["units"], nutrient


def test_every_nutrient_lists_the_units_of_its_dimension(registry):
    """A nutrient's units are exactly its dimension's units, and no v1 nutrient is stated in IU."""
    for nutrient in registry["nutrients"]:
        assert nutrient["dimension"] in ("energy", "mass"), nutrient
        own = [unit["symbol"] for unit in registry["units"] if unit["dimension"] == nutrient["dimension"]]
        assert nutrient["units"] == own, nutrient


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
            # A power of ten, so applying it or undoing it is exact and never needs rounding.
            assert set(factor.replace(".", "")) <= {"0", "1"} and factor.count("1") == 1, unit
    # Energy has one unit, kcal, as in the app. kJ is not a v1 unit.
    assert by_symbol["kcal"]["factor_to_canonical"] == "1"
    assert "kJ" not in by_symbol


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


FRACTION_DIGITS = 10
SIGNIFICANT_DIGITS = 38
ADJUSTED_EXPONENT = 127


def units(registry):
    return {unit["symbol"]: unit for unit in registry["units"]}


def significant_digits(value: Fraction) -> int:
    """Digits of a finite decimal with its leading and trailing zeros removed."""
    assert terminates(value), value
    while value.denominator != 1:
        value *= 10
    return len(str(abs(value.numerator)).rstrip("0"))


def adjusted_exponent(value: Fraction) -> int:
    """The place value of the leading significant digit of a finite, non-zero decimal: 0 for 5,
    2 for 500, -3 for 0.005."""
    assert terminates(value) and value != 0, value
    magnitude, exponent = abs(value), 0
    while magnitude >= 10:
        magnitude /= 10
        exponent += 1
    while magnitude < 1:
        magnitude *= 10
        exponent -= 1
    return exponent


def bounded(value: Fraction) -> Fraction:
    """Every input, product, sum and result is checked here: it is refused, never cut, when it
    needs more significant digits than an amount may have, or lies outside the exponent range."""
    if significant_digits(value) > SIGNIFICANT_DIGITS:
        raise UnitError("amount_out_of_range")
    if value != 0 and abs(adjusted_exponent(value)) > ADJUSTED_EXPONENT:
        raise UnitError("amount_out_of_range")
    return value


def exact(text: str) -> Fraction:
    return bounded(Fraction(Decimal(text)))


def terminates(value: Fraction) -> bool:
    denominator = value.denominator
    for prime in (2, 5):
        while denominator % prime == 0:
            denominator //= prime
    return denominator == 1


def quotient(numerator: Fraction, denominator: Fraction) -> Fraction:
    """The one place a result may be rounded.

    A quotient with a finite decimal form is kept exactly. One without is rounded to
    FRACTION_DIGITS fraction digits, halves away from zero.
    """
    value = numerator / denominator
    if terminates(value):
        return bounded(value)
    scale_by = 10**FRACTION_DIGITS
    shifted = abs(value) * scale_by
    whole = (2 * shifted.numerator + shifted.denominator) // (2 * shifted.denominator)
    rounded = bounded(Fraction(whole, scale_by))
    return -rounded if value < 0 else rounded


def decimal_string(value: Fraction) -> str:
    """The plain form the contract uses: no exponent, no trailing zeros. Only for a finite decimal."""
    assert terminates(value), value
    digits = 0
    while value.denominator != 1:
        value *= 10
        digits += 1
    text = str(abs(value.numerator)).rjust(digits + 1, "0")
    if digits:
        text = f"{text[:-digits]}.{text[-digits:]}"
    return f"-{text}" if value < 0 else text


def valid_portion(portion: dict, table) -> tuple[str, Fraction, str]:
    """Mirrors PortionDefinition.init: a count unit, a positive amount, in a mass or a volume."""
    for symbol in (portion["count_unit"], portion["unit"]):
        if symbol not in table:
            raise UnitError("unknown_symbol")
    amount = exact(portion["amount"])
    measurable = table[portion["unit"]]["dimension"] in ("mass", "volume")
    if table[portion["count_unit"]]["dimension"] != "count" or not measurable or amount <= 0:
        raise UnitError("invalid_portion_definition")
    return portion["count_unit"], amount, portion["unit"]


def mcg_per_international_unit(registry, nutrient: str | None) -> Fraction | None:
    """The fixed mass of one IU of the nutrient, or None: only vitamin D states one."""
    for entry in registry["nutrients"]:
        if entry["id"] == nutrient and "mcg_per_international_unit" in entry:
            return exact(entry["mcg_per_international_unit"])
    return None


def convert(amount: Fraction, unit: str, target: str, registry, density: Fraction | None = None,
            portion: dict | None = None, nutrient: str | None = None) -> Fraction:
    table = units(registry)
    for symbol in (unit, target):
        if symbol not in table:
            raise UnitError("unknown_symbol")
    if amount < 0:
        # Nothing an operation is given is ever less than zero.
        raise UnitError("negative_amount")
    if unit == target:
        return amount

    source, dest = table[unit], table[target]
    if source["dimension"] == dest["dimension"]:
        if source["dimension"] == "count":
            raise UnitError("incompatible_count_units")
        # Both factors are powers of ten, so this is exact.
        # A power of ten moves the decimal point; it never adds a significant digit, but it can
        # move the amount out of the exponent range.
        canonical = bounded(amount * exact(source["factor_to_canonical"]))
        return bounded(canonical / exact(dest["factor_to_canonical"]))
    if "international_unit" in (source["dimension"], dest["dimension"]):
        # Only IU into a mass converts, and only for a nutrient whose IU is one fixed mass (vitamin D).
        factor = mcg_per_international_unit(registry, nutrient)
        if factor is None or source["dimension"] != "international_unit" or dest["dimension"] != "mass":
            raise UnitError("international_unit_not_convertible")
        return convert(bounded(amount * factor), "mcg", target, registry)

    measurable = ("mass", "volume")
    if source["dimension"] == "count" and dest["dimension"] in measurable:
        # The portion must define the count unit being converted from.
        if portion is None:
            raise UnitError("missing_portion_definition")
        count_unit, portion_amount, portion_unit = valid_portion(portion, table)
        if count_unit != unit:
            raise UnitError("missing_portion_definition")
        return convert(bounded(amount * portion_amount), portion_unit, target, registry, density)
    if source["dimension"] in measurable and dest["dimension"] == "count":
        # The portion must define the count unit being converted into: the amount goes into the
        # portion's unit and is then divided by the portion.
        if portion is None:
            raise UnitError("missing_portion_definition")
        count_unit, portion_amount, portion_unit = valid_portion(portion, table)
        if count_unit != target:
            raise UnitError("missing_portion_definition")
        return quotient(convert(amount, unit, portion_unit, registry, density), portion_amount)

    if {source["dimension"], dest["dimension"]} == {"mass", "volume"}:
        if density is None:
            raise UnitError("missing_density")
        if density <= 0:
            raise UnitError("invalid_density")
        # Density is grams per millilitre. The step is made in the canonical units, then the
        # result takes the target unit's power of ten: grams divide by it, millilitres multiply.
        canonical = bounded(amount * exact(source["factor_to_canonical"]))
        if source["dimension"] == "mass":
            canonical = quotient(canonical, density)
        else:
            canonical = bounded(canonical * density)
        return bounded(canonical / exact(dest["factor_to_canonical"]))
    raise UnitError("dimension_mismatch")


def scale(case_input: dict, registry) -> dict:
    basis, consumed = case_input["basis"], case_input["consumed"]
    value = case_input["value"]
    if exact(basis["amount"]) <= 0:
        raise UnitError("non_positive_amount")
    if exact(consumed["amount"]) < 0:
        raise UnitError("negative_amount")
    consumed_in_basis = convert(
        exact(consumed["amount"]),
        consumed["unit"],
        basis["unit"],
        registry,
        exact(case_input["density"]) if "density" in case_input else None,
        case_input.get("portion"),
    )
    if value["state"] == "known" and exact(value["amount"]) < 0:
        raise UnitError("negative_amount")
    if value["state"] != "known":
        # Scaling passes a non-known value through unchanged, unit included.
        return {key: item for key, item in value.items() if key != "amount"}
    # Multiply first, divide once, last: value x consumed / basis.
    scaled = quotient(bounded(exact(value["amount"]) * consumed_in_basis), exact(basis["amount"]))
    return {"state": "known", "amount": decimal_string(scaled), "unit": value["unit"]}


def sum_values(case_input: dict, registry, nutrient: str | None = None) -> dict:
    known, total_count = [], 0
    has_unknown = has_below = False
    for value in case_input["values"]:
        if value["state"] == "known":
            known.append((exact(value["amount"]), value["unit"]))
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
    running = Fraction(0)
    for amount, unit in known:
        running = bounded(running + convert(amount, unit, target, registry, nutrient=nutrient))
    return {
        "value": {"state": "known", "amount": decimal_string(running), "unit": target},
        "coverage": coverage,
    }


def convert_case(case_input: dict, registry, nutrient: str | None = None) -> Fraction:
    return convert(
        exact(case_input["amount"]),
        case_input["unit"],
        case_input["to"],
        registry,
        exact(case_input["density"]) if "density" in case_input else None,
        case_input.get("portion"),
        nutrient,
    )


def run_case(case: dict, registry) -> dict:
    case_input = case["input"]
    if case["op"] == "convert":
        return {
            "amount": decimal_string(convert_case(case_input, registry, case.get("nutrient"))),
            "unit": case_input["to"],
        }
    if case["op"] == "scale":
        return scale(case_input, registry)
    if case["op"] == "sum":
        return sum_values(case_input, registry, case.get("nutrient"))
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
                sum_values(case["input"], registry, case.get("nutrient"))
            elif case["input"].get("basis") is not None or "basis" in case["input"]:
                scale(case["input"], registry)
            else:
                convert_case(case["input"], registry, case.get("nutrient"))
        assert raised.value.name == case["expect"]["error"]
        return
    assert run_case(case, registry) == case["expect"]


def test_every_error_the_goldens_name_is_declared_and_every_declared_error_is_exercised(golden):
    used = {case["expect"]["error"] for case in golden["cases"] if case["op"] == "reject"}
    assert used == set(golden["error_names"])


def test_every_golden_result_is_a_valid_wire_amount(golden, product_schema):
    """No golden result is negative, uses an exponent, has a trailing zero, or needs more
    significant digits than an amount may have."""
    pattern = re.compile(r"^(0|[1-9][0-9]*)(\.[0-9]+)?\Z")
    for case in golden["cases"]:
        expect = case["expect"]
        amount = expect.get("amount") or expect.get("value", {}).get("amount")
        if amount is not None:
            assert pattern.search(amount), (case["id"], amount)
            assert not amount.endswith("0") or "." not in amount, (case["id"], amount)
            assert significant_digits(Fraction(Decimal(amount))) <= SIGNIFICANT_DIGITS, (case["id"], amount)


def test_a_repeating_quotient_is_rounded_to_ten_fraction_digits_halves_away_from_zero():
    assert decimal_string(quotient(Fraction(1), Fraction(3))) == "0.3333333333"
    assert decimal_string(quotient(Fraction(2), Fraction(3))) == "0.6666666667"
    assert decimal_string(quotient(Fraction(-2), Fraction(3))) == "-0.6666666667"
    assert decimal_string(quotient(Fraction(1), Fraction(6))) == "0.1666666667"
    assert decimal_string(quotient(Fraction(1000), Fraction(7))) == "142.8571428571"
    # Just under and just over a half in the eleventh digit.
    assert decimal_string(quotient(Fraction(1), Fraction(3 * 10**10))) == "0"
    assert decimal_string(quotient(Fraction(2), Fraction(3 * 10**10))) == "0.0000000001"


DEFAULT_IGNORABLE = [
    (0x00AD, 0x00AD), (0x034F, 0x034F), (0x061C, 0x061C), (0x115F, 0x1160), (0x17B4, 0x17B5), (0x180B, 0x180F),
    (0x200B, 0x200F), (0x202A, 0x202E), (0x2060, 0x206F), (0x3164, 0x3164), (0xFE00, 0xFE0F), (0xFEFF, 0xFEFF),
    (0xFFA0, 0xFFA0), (0xFFF0, 0xFFF8), (0x1BCA0, 0x1BCA3), (0x1D173, 0x1D17A), (0xE0000, 0xE0FFF),
]


def test_display_text_refuses_every_invisible_code_point_of_unicode(product_schema):
    """Walks all of Unicode: whatever this Python's Unicode data calls a control, format, surrogate,
    private-use or line/paragraph separator character, and every default-ignorable code point, is
    refused anywhere in the text; every space separator is refused at an edge and allowed inside;
    every letter, mark, number, punctuation and symbol that is not default-ignorable is accepted."""
    pattern = re.compile(product_schema["$defs"]["shortText"]["pattern"])
    ignorable = {cp for low, high in DEFAULT_IGNORABLE for cp in range(low, high + 1)}
    noncharacters = set(range(0xFDD0, 0xFDF0)) | {p * 0x10000 + low for p in range(17) for low in (0xFFFE, 0xFFFF)}
    refused = accepted = 0
    for code_point in range(0x110000):
        character = chr(code_point)
        category = unicodedata.category(character)
        inside = pattern.search(f"a{character}b") is not None
        at_edges = pattern.search(f"{character}b") is not None or pattern.search(f"a{character}") is not None
        if category in ("Cc", "Cf", "Cs", "Co", "Zl", "Zp") or code_point in ignorable or code_point in noncharacters:
            assert not inside and not at_edges, hex(code_point)
            refused += 1
        elif category == "Zs":
            assert inside and not at_edges, hex(code_point)
        elif category[0] in "LMNPS":
            assert inside and at_edges, hex(code_point)
            accepted += 1
    assert refused > 140000 and accepted > 140000


def test_display_text_refuses_every_unicode_noncharacter(product_schema):
    pattern = re.compile(product_schema["$defs"]["shortText"]["pattern"])
    noncharacters = list(range(0xFDD0, 0xFDF0))
    for plane in range(17):
        noncharacters += [plane * 0x10000 + 0xFFFE, plane * 0x10000 + 0xFFFF]
    assert len(noncharacters) == 66
    for code_point in noncharacters:
        for text in (f"a{chr(code_point)}b", f"{chr(code_point)}b", f"a{chr(code_point)}"):
            assert not pattern.search(text), hex(code_point)


def test_a_result_beyond_thirty_eight_significant_digits_is_refused_not_cut(registry):
    assert bounded(Fraction(10**38 - 1)) == 10**38 - 1
    assert bounded(Fraction(10**60)) == 10**60, "trailing zeros are not significant"
    assert bounded(Fraction(10**127)) == 10**127 and bounded(Fraction(1, 10**127)) == Fraction(1, 10**127)
    assert bounded(Fraction(0)) == 0
    assert [adjusted_exponent(Fraction(Decimal(text))) for text in ("5", "500", "0.005", "9.99", "10")] == [0, 2, -3, 0, 1]
    for outside in (Fraction(10**128), Fraction(1, 10**128), Fraction(-(10**128))):
        with pytest.raises(UnitError) as raised:
            bounded(outside)
        assert raised.value.name == "amount_out_of_range"
    with pytest.raises(UnitError) as raised:
        bounded(Fraction(10**38 + 1))
    assert raised.value.name == "amount_out_of_range"
    with pytest.raises(UnitError) as raised:
        quotient(Fraction(1), Fraction(2**130))
    assert raised.value.name == "amount_out_of_range"


def test_a_terminating_quotient_is_never_rounded():
    assert decimal_string(quotient(Fraction(1), Fraction(8192))) == "0.0001220703125"
    assert decimal_string(quotient(exact("5.2") * 40, Fraction(100))) == "2.08"
    assert decimal_string(quotient(Fraction(1), exact("0.000000000001"))) == "1000000000000"
    assert decimal_string(Fraction(0)) == "0"


def test_a_measure_converts_into_counts_without_recursing(registry):
    portion = {"count_unit": "scoop", "amount": "5", "unit": "g"}
    assert convert(Fraction(10), "g", "scoop", registry, portion=portion) == 2
    assert convert(Fraction(2), "scoop", "mg", registry, portion=portion) == 10000
    # A portion stated as a volume needs the density to reach a mass.
    by_volume = {"count_unit": "scoop", "amount": "10", "unit": "mL"}
    assert convert(Fraction(16), "g", "scoop", registry, exact("0.8"), by_volume) == 2
    with pytest.raises(UnitError) as raised:
        convert(Fraction(16), "g", "scoop", registry, portion=by_volume)
    assert raised.value.name == "missing_density"


def test_scaling_never_rounds_a_stored_amount(golden):
    """The 40 g of a 100 g basis case must be exact, not 2.1."""
    case = next(c for c in golden["cases"] if c["id"] == "scale_a_serving_of_a_hundred_gram_basis")
    assert run_case(case, load(REGISTRY_PATH))["amount"] == "2.08"


def test_an_unknown_total_is_never_zero(golden, registry):
    case = next(c for c in golden["cases"] if c["id"] == "sum_of_only_unknown_values_is_unknown")
    assert run_case(case, registry)["value"] == {"state": "unknown"}


def test_scaling_multiplies_before_it_divides(golden, registry):
    case = next(c for c in golden["cases"] if c["id"] == "scale_multiplies_before_it_divides")
    assert run_case(case, registry)["amount"] == "1"


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


@pytest.mark.parametrize(
    "url",
    ["https://data.example.org/food-details/100001/nutrients", "https://catalog.example.net/product/0000000000000",
     "https://example.org", "https://example.org/", "https://a.b.example.co.uk/p/%C3%A9clair?x=1&y=%20#top",
     "https://xn--bcher-kva.example/a_b~c"],
)
def test_a_source_url_is_a_real_https_url(product_validator, url):
    doc = valid_product()
    doc["source"]["url"] = url
    product(product_validator, doc)


@pytest.mark.parametrize(
    "url",
    ["https://", "https://?", "https://#x", "https:///path", "https://%ZZ", "https://example.org/%ZZ",
     "https://example.org/%2", "https://example.org/a b", "https://example.org/a%", "http://example.org",
     "https://localhost", "https://example", "https://.example.org", "https://example..org", "https://-a.example.org",
     "https://a-.example.org", "https://user@example.org", "https://user:pw@example.org/", "https://example.org:8443/",
     "https://127.0.0.1/", "https://[::1]/", "https://EXAMPLE.org/", "https://example.org/\n", "https://example.org\n",
     "https://example.org/<x>", "https://example.org/a\\b", "https://exa_mple.org", "https://example.org/é",
     "javascript:alert(1)", "https://" + "a" * 64 + ".org", "https://" + ".".join(["a" * 60] * 5) + ".org"],
)
def test_a_source_url_that_is_not_a_usable_https_url_is_refused(product_validator, url):
    doc = valid_product()
    doc["source"]["url"] = url
    product_rejected(product_validator, doc)


def test_the_openapi_version_prefix_is_stated_once():
    """The version lives in the paths, so the server URL must not repeat it."""
    text = OPENAPI_PATH.read_text()
    servers = re.findall(r"^  - url: (\S+)$", text, flags=re.M)
    assert servers == ["https://catalog.example.invalid"], servers
    paths = re.findall(r"^  (/\S*):$", text, flags=re.M)
    assert paths == ["/v1/products/{product_id}", "/v1/barcodes/{barcode}", "/v1/search"], paths


def test_no_operation_accepts_a_negative_amount(registry):
    for amount in ("-1", "-0.000001"):
        with pytest.raises(UnitError) as raised:
            convert(exact(amount), "g", "g", registry)
        assert raised.value.name == "negative_amount"
    assert convert(exact("-0"), "g", "mg", registry) == 0, "minus zero is zero"


def test_the_canonical_intermediate_of_a_conversion_is_bounded(registry):
    """10^127 kg is in range, and so would be the 10^124 L it converts to at a density of 1000,
    but the 10^130 g in between is not."""
    with pytest.raises(UnitError) as raised:
        convert(Fraction(10**127), "kg", "L", registry, Fraction(1000))
    assert raised.value.name == "amount_out_of_range"


def test_only_vitamin_d_states_a_mass_per_international_unit(registry):
    """The vitamin D exception is the only one: an IU of vitamin A or E has no single mass."""
    stated = {entry["id"]: entry["mcg_per_international_unit"] for entry in registry["nutrients"]
              if "mcg_per_international_unit" in entry}
    assert stated == {"vitamin_d": "0.025"}


def test_vitamin_d_converts_only_from_international_units_into_a_mass(registry):
    assert convert(Fraction(400), "IU", "mcg", registry, nutrient="vitamin_d") == Fraction(10)
    assert convert(Fraction(400), "IU", "mg", registry, nutrient="vitamin_d") == Fraction(1, 100)
    with pytest.raises(UnitError) as raised:
        convert(Fraction(10), "mcg", "IU", registry, nutrient="vitamin_d")
    assert raised.value.name == "international_unit_not_convertible"
    with pytest.raises(UnitError) as raised:
        convert(Fraction(400), "IU", "mcg", registry)
    assert raised.value.name == "international_unit_not_convertible"

