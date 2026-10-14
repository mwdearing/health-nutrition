# nutrients

Nutrient identifiers, units and conversion rules shared by every component.

What is here for v1:

- `registry.v1.json` - the nutrient vocabulary: nineteen nutrient ids with their
  dimension, canonical unit, the units each may be stated in and the key the iOS
  app files each under (`app_key`), and every unit
  symbol with its dimension and its exact power-of-ten factor to the canonical
  unit of that dimension. Dimensions are mass, volume, energy, count and
  international_unit. The product schema accepts exactly these nutrient ids and,
  for each, exactly these units.
- `decimal-rules.md` - the numeric rules: exact decimals as strings, no negative
  amounts, display rounding that never replaces a stored amount, the one rounding
  rule for a division that does not terminate (10 fraction digits, halves away
  from zero) and why the app's journal keeps full precision instead, the bounds
  on all arithmetic (38 significant digits, adjusted exponent within 127), one
  spelling per unit and energy in kcal, no cross-dimension
  arithmetic without a stated density, portions for count units, international
  units that never convert, proprietary blend splits that are never inferred, and
  how each value state behaves in a total.
- `golden.v1.json` - reference vectors for the ops `convert`, `scale`, `sum` and
  `reject`. Every quantity is a decimal string. `catalog/tests/test_contract_v1.py`
  reproduces every one of them with a pure-Python evaluator in rational
  arithmetic.

Every unit symbol is one the iOS `UnitRegistry` knows, and a test reads
`ios/NutritionCore/Sources/NutritionDomain/Units.swift` to keep it that way: the
wire set is a subset of the app's set (the app also has `oz`, `fl oz`, `cup`,
`tbsp` and `tsp`, which are input units and never published).

The vectors follow the model of the Swift `NutritionDomain` (same operations,
same error names, same order of multiplication and division), but they are not
yet run against it. The Swift code does not round a repeating quotient to the
contract's 10 fraction digits today; the Swift/Python golden verification that
follows this contract makes the app conform and runs these vectors in Swift.
That covers the catalog operations only: the journal's own scaling keeps full
precision by design (`decimal-rules.md`, "The journal keeps full precision").
