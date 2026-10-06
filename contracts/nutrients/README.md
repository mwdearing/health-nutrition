# nutrients

Nutrient identifiers, units and conversion rules shared by every component.

What is here for v1:

- `registry.v1.json` - the nutrient vocabulary: sixteen nutrient ids with their
  dimension and canonical unit, and every unit symbol with its dimension and its
  exact decimal factor to the canonical unit of that dimension. Dimensions are
  mass, volume, energy, count and international_unit.
- `decimal-rules.md` - the numeric rules: exact decimals as strings, rounding and
  scaling for display only, 1 kcal = 4.184 kJ exactly, no cross-dimension
  arithmetic without a stated density, international units that never convert,
  proprietary blend splits that are never inferred, and how each value state
  behaves in a total.
- `golden.v1.json` - exact reference vectors for the ops `convert`, `scale`,
  `sum` and `reject`. Every quantity is a decimal string. These mirror the Swift
  `NutritionDomain` behaviour, and `catalog/tests/test_contract_v1.py` reproduces
  every one of them with a pure-Python `Decimal` evaluator.

One difference from the Swift domain is deliberate: energy is canonical in kJ so
that the kcal factor can be the exact 4.184, while labels state kcal, so the
`energy` nutrient's own canonical unit is kcal.
