# Nutrient numbers

Every amount in this contract is an exact decimal carried as a JSON string. The
same rules apply to the iOS app (which stores `Decimal`) and to any service that
builds against these files.

## Decimals are strings, never JSON numbers

`"5.2"` is an amount. `5.2` is not, and a document containing it is invalid.
Binary floating point cannot hold `0.1` exactly, so a number that looks right
would not be right.

A decimal string is plain: an optional minus, digits, then optional fractional
digits. There is no exponent (`1e3` is refused), no thousands comma (`5,2` is
refused), no `NaN`, no infinity, and no empty string. A leading zero is refused
except for the single `0` itself, so `"05.2"` is not a spelling of `5.2`.

## Rounding and scaling are for display

A stored amount is never rounded. Scaling a label value to a consumed amount
multiplies and divides exactly, and the result is stored as it comes out:
40 g of a 100 g basis is a factor of `0.4`, and `5.2 g` scales to `2.08 g`, not
to `2.1 g`. Rounding happens once, at the moment a number is shown to a person,
and the rounded copy never replaces the stored one.

## Energy: 1 kcal = 4.184 kJ exactly

Thermochemical kilocalorie. The factor is exact, so `627.6 kJ` converts back to
`150 kcal` and neither side accumulates error. Note that this is not the same
factor as the International Table of Calorie the food industry uses for labels;
labels state kcal, so kcal is the canonical energy unit.

## No cross-dimension arithmetic without a stated density

Mass, volume, energy, count and international units are five different things.
Adding or comparing across dimensions is an error, not a zero.

Mass to volume, and volume to mass, need a density stated in grams per
millilitre for that product. Without one the conversion is refused. A density of
zero or less is refused as well.

Count units (serving, scoop, tablet, capsule) need a stated portion, for example
1 scoop = 5 g, and a mass or volume conversion on top of that still needs the
density. Two different count units never convert into each other: a scoop is not
a tablet whatever portion you state.

## International units are not convertible

`IU` measures biological activity. It is not a mass, and no contract in this
repository converts one to the other. A provider that states an amount in IU
keeps it in IU.

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
