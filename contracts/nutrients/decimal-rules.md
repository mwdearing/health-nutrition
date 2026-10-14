# Nutrient numbers

Every amount in this contract is an exact decimal carried as a JSON string. The
same rules apply to the iOS app (which stores `Decimal`) and to any service that
builds against these files.

## Decimals are strings, never JSON numbers

`"5.2"` is an amount. `5.2` is not, and a document containing it is invalid.
Binary floating point cannot hold `0.1` exactly, so a number that looks right
would not be right.

A decimal string is plain: digits, then optional fractional digits. There is no
exponent (`1e3` is refused), no thousands comma (`5,2` is refused), no `NaN`, no
infinity, and no empty string. A leading zero is refused except for the single
`0` itself, so `"05.2"` is not a spelling of `5.2`.

An amount in a published product has at most 12 integer digits and at most 6
fraction digits, so `"1234567890123"` and `"1.1234567"` are refused.

No amount in a published product is negative. A nutrient amount is zero or more,
so `"-5"` and `"-0"` are refused; a serving amount is greater than zero, so `"0"`
and `"0.0"` are refused there as well. An operation refuses a negative input:
a consumed amount below zero is `negative_amount`, and a label basis of zero or
less is `non_positive_amount`.

## Display rounding never replaces a stored amount

A stated amount is stored as stated. Scaling a label value to a consumed amount
keeps every digit an exact result has: 40 g of a 100 g basis scales `5.2 g` to
`2.08 g`, not to `2.1 g`. Rounding for display happens at the moment a number is
shown to a person, and the rounded copy never replaces the stored one.

## One rounding rule, for a division that does not terminate

Multiplying two decimals is always exact, and so is applying a unit factor,
because every factor in the registry is a power of ten. A division is the only
step whose exact result may have no finite decimal form: 1 g consumed of a 3 g
basis is `0.333...` of it. There are exactly three divisions in this contract:

- scaling divides by the label basis: `value x consumed / basis`, multiplied
  first and divided once, last;
- a mass to volume conversion divides by the density, in the canonical units
  (grams by grams per millilitre, giving millilitres), before the target unit's
  power of ten is applied;
- a mass or volume to count conversion divides by the portion amount, after the
  amount has been converted into the portion's unit.

Each of them follows the same rule, in every language:

1. If the exact quotient has a finite decimal form, that is the result, with
   every digit: `1 / 8192` is `0.0001220703125`.
2. Otherwise the exact quotient is rounded to 10 fraction digits, halves away
   from zero: `1 / 3` is `0.3333333333`, `2 / 3` is `0.6666666667`.

"Exact quotient" means the rational number, not a value already cut to some
working precision: an implementation must not let a 28 or 38 digit intermediate
decide the tenth digit. Ten fraction digits is the precision the iOS
`UnitRegistry.reciprocalFractionDigits` already uses, and halves away from zero
is its `.plain` rounding mode. Because the multiplication comes first,
`3 x 1 / 3` is exactly `1`, never `0.9999999999`. `golden.v1.json` carries
vectors for a repeating quotient in each of the three divisions, for the
multiply-first order, for a long quotient that terminates, and for the bounds
described next.

## Arithmetic is bounded: 38 significant digits, exponents within 127

Exact arithmetic needs room, and the iOS `Decimal` has room for 38 significant
digits. So the contract sets that as the bound for every implementation, and no
implementation may round or cut to stay inside it:

- Every input, every product, every sum and every result must be a decimal of at
  most 38 significant digits, counted without leading and trailing zeros. A unit
  factor is a power of ten and never adds a digit.
- The leading significant digit of every one of them must have a place value
  from 10^-127 to 10^127 (an adjusted exponent of -127 to 127, the range the app
  already enforces when it reads numbers). `0.005` has the adjusted exponent -3
  and `500` has 2. Zero has none and is always in range. A unit factor can move
  an amount out of this range even though it adds no digit.
- An operation that would break either bound fails with `amount_out_of_range`.
  It never returns a shortened number. This includes a quotient that does
  terminate, but only after more than 38 digits.

Two amounts within the wire bound (12 integer and 6 fraction digits, 18
significant digits) always multiply within the bound: 18 + 18 = 36. So scaling
one published value by one consumed amount and one basis never fails on the
multiplication; only a longer chain, such as a count converted through a portion
and then scaled, can reach the limit, and then it is refused rather than
rounded.

## Units: one spelling each, and energy in kcal

The wire carries the unit symbols of `registry.v1.json` and no others: `g`,
`mg`, `mcg`, `kg`, `mL`, `L`, `kcal`, `IU`, `serving`, `scoop`, `tablet`,
`capsule`, `piece` and `gummy`. Each is a symbol the iOS `UnitRegistry` knows,
spelled the same way, so a document that passes the schema always decodes in the
app. A provider's `ug`, `ml`, `l` or `iu` is normalised by the importer before a
record is published.

Energy is stated in kcal. `kJ` is not a v1 unit: the app does not know it, and
`1 kJ` in kcal has no finite decimal form. An importer that only has a kJ figure
converts it before publishing.

A nutrient is stated only in the units the registry lists for it: energy in
kcal, every other nutrient in a mass unit. A serving is a mass, a volume or a
count.

## Nutrient ids and the app's keys

The registry's nutrient ids are the wire names. The app files its nutrients
under its own keys (`fat`, `vitaminD`, `energyKcal`), so every registry nutrient
states its `app_key`, and a client translates by that table. Every standard
panel key of the app has exactly one registry nutrient with the same dimension,
and a test reads the Swift source to keep it that way. A nutrient the app has no
standard key for carries an `ingredient:` key, the namespace the app already
uses for additional compounds.

## No cross-dimension arithmetic without a stated density

Mass, volume, energy, count and international units are five different things.
Adding or comparing across dimensions is an error, not a zero.

Mass to volume, and volume to mass, need a density stated in grams per
millilitre for that product. Without one the conversion is refused. A density of
zero or less is refused as well.

Count units (serving, scoop, tablet, capsule, piece, gummy) need a stated
portion, for example 1 scoop = 5 g. The portion has to define the count unit in
the conversion: from scoops to grams, and from grams to scoops, it must be a
portion of one scoop, or the conversion is refused as
`missing_portion_definition`. Count to measure multiplies by the portion (3 scoop
= 15 g); measure to count converts into the portion's unit and divides by it
(10 g = 2 scoop). When the portion is stated in the other of mass and volume, the
density is needed on top. A portion that is not a positive mass or volume of a
count unit is refused as `invalid_portion_definition`. Two different count units
never convert into each other: a scoop is not a tablet whatever portion you
state.

## International units are not convertible

`IU` measures biological activity. It is not a mass, and no contract in this
repository converts one to the other. A provider that states an amount in IU
keeps it in IU. No v1 nutrient is published in IU, because the app keeps its
standard nutrients as masses: a label that states a vitamin only in IU is
published with that nutrient `unknown`, never with a guessed mass. `IU` stays in
the unit registry so that an operation can name it and refuse it.

## Proprietary blend splits are never inferred

A label that states a blend total and a list of members does not state each
member's amount, and nothing here will estimate one. The blend stays as its own
fact; the individual components stay unknown.

## Value states

A nutrient value is one of four states, and only one of them carries an amount:

| state | carries an amount | in a total |
| --- | --- | --- |
| `known` | yes | added |
| `unknown` | no | skipped, counted in coverage, sets `has_unknown` |
| `below_reporting_threshold` | no | skipped, counted in coverage, sets `has_below_reporting_threshold` |
| `not_applicable` | no | left out of the counts entirely |

So a total skips `unknown` and `below_reporting_threshold` values but reports
them in coverage, while `not_applicable` is excluded from coverage altogether. A
total of only `unknown` values is `unknown`, never `0`: a missing value and a
zero value are different facts. A stated `0` stays a stated `0` through scaling
and conversion.

Coverage is `known_count`, `total_count`, `has_unknown`,
`has_below_reporting_threshold` and `is_complete`, where `is_complete` means
`known_count == total_count`.
