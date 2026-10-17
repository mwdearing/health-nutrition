import Foundation

/// Protein, carbohydrate and fat as shares of a day's energy, the other way a person states macro
/// targets besides grams.
///
/// A split is arithmetic, not a recommendation: the three shares are whatever the person typed, and
/// the grams they turn into are the energy goal divided by the usual label factors of 4 kcal per gram
/// for protein and carbohydrate and 9 kcal per gram for fat. Nothing here picks a split for anyone.
public struct MacroSplit: Sendable, Hashable {
    public static let kcalPerGramProtein: Decimal = 4
    public static let kcalPerGramCarbohydrate: Decimal = 4
    public static let kcalPerGramFat: Decimal = 9

    public let proteinPercent: Decimal
    public let carbohydratePercent: Decimal
    public let fatPercent: Decimal

    public enum SplitError: Error, Sendable, Equatable {
        /// A share that is not a number above zero. Zero is refused because a target of 0 g is not a
        /// goal the store keeps.
        case shareNotPositive
        /// The three shares do not total exactly 100.
        case doesNotTotalHundred(total: Decimal)
        /// The energy the shares are taken of is not a number above zero.
        case energyNotPositive
        /// A share of this energy rounds to 0 g, which is not a target.
        case roundsToNothing
    }

    /// The whole-gram targets a split works out to.
    public struct Grams: Sendable, Hashable {
        public let protein: Decimal
        public let carbohydrate: Decimal
        public let fat: Decimal

        public init(protein: Decimal, carbohydrate: Decimal, fat: Decimal) {
            self.protein = protein
            self.carbohydrate = carbohydrate
            self.fat = fat
        }
    }

    /// Refuses a split a person could not have meant: a share that is not above zero, or three shares
    /// that do not total exactly 100.
    public init(proteinPercent: Decimal, carbohydratePercent: Decimal, fatPercent: Decimal) throws {
        for share in [proteinPercent, carbohydratePercent, fatPercent] {
            guard !share.isNaN, share > 0 else { throw SplitError.shareNotPositive }
        }
        let total = proteinPercent + carbohydratePercent + fatPercent
        guard total == 100 else { throw SplitError.doesNotTotalHundred(total: total) }
        self.proteinPercent = proteinPercent
        self.carbohydratePercent = carbohydratePercent
        self.fatPercent = fatPercent
    }

    /// The daily grams each share comes to for an energy goal in kcal, rounded to whole grams.
    public func grams(forEnergyKcal energy: Decimal) throws -> Grams {
        guard !energy.isNaN, energy > 0 else { throw SplitError.energyNotPositive }
        let grams = Grams(
            protein: Self.wholeGrams(energy, share: proteinPercent, kcalPerGram: Self.kcalPerGramProtein),
            carbohydrate: Self.wholeGrams(
                energy, share: carbohydratePercent, kcalPerGram: Self.kcalPerGramCarbohydrate),
            fat: Self.wholeGrams(energy, share: fatPercent, kcalPerGram: Self.kcalPerGramFat))
        guard grams.protein > 0, grams.carbohydrate > 0, grams.fat > 0 else {
            throw SplitError.roundsToNothing
        }
        return grams
    }

    /// The share of an energy goal each gram target supplies, as whole percents. The three need not
    /// total 100: gram targets set by hand, or an energy goal changed since, total whatever they do.
    /// When the exact shares total 100 but rounding each one moves the total off 100 (20.4, 50.4, 29.2
    /// shows as 20, 50, 29), the rounding is given to the shares that lost most, so the shown percents
    /// total 100 and can be typed back in as a split. Nil when the energy is not above zero.
    public static func percents(ofEnergyKcal energy: Decimal, grams: Grams) -> Grams? {
        guard !energy.isNaN, energy > 0 else { return nil }
        let exact = [
            grams.protein * kcalPerGramProtein * 100 / energy,
            grams.carbohydrate * kcalPerGramCarbohydrate * 100 / energy,
            grams.fat * kcalPerGramFat * 100 / energy,
        ]
        let rounded = exact.map { DisplayRounding.rounded($0, fractionDigits: 0) }
        let shown = totalsHundredOnlyByRounding(exact: exact, rounded: rounded) ? largestRemainder(exact) : rounded
        return Grams(protein: shown[0], carbohydrate: shown[1], fat: shown[2])
    }

    /// True when the rounded shares miss 100 only because of rounding: the exact shares total 100 once rounded.
    private static func totalsHundredOnlyByRounding(exact: [Decimal], rounded: [Decimal]) -> Bool {
        let roundedTotal = rounded.reduce(Decimal(0), +)
        let exactTotal = DisplayRounding.rounded(exact.reduce(Decimal(0), +), fractionDigits: 0)
        return roundedTotal != 100 && exactTotal == 100
    }

    /// Whole shares that total 100: each rounded down, then the points still missing go to the largest
    /// remainders. Ties go to the earlier share, so the result depends on nothing but the input.
    private static func largestRemainder(_ exact: [Decimal]) -> [Decimal] {
        let floors = exact.map { value -> Decimal in
            var source = value
            var result = Decimal()
            NSDecimalRound(&result, &source, 0, .down)
            return result
        }
        var shown = floors
        let missing = NSDecimalNumber(decimal: 100 - floors.reduce(Decimal(0), +)).intValue
        let byRemainder = exact.indices.sorted { first, second in
            let firstRemainder = exact[first] - floors[first]
            let secondRemainder = exact[second] - floors[second]
            return firstRemainder == secondRemainder ? first < second : firstRemainder > secondRemainder
        }
        for index in byRemainder.prefix(max(0, missing)) {
            shown[index] += 1
        }
        return shown
    }

    private static func wholeGrams(_ energy: Decimal, share: Decimal, kcalPerGram: Decimal) -> Decimal {
        DisplayRounding.rounded(energy * share / 100 / kcalPerGram, fractionDigits: 0)
    }
}
