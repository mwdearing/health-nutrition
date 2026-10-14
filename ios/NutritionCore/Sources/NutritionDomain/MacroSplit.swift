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
    /// Nil when the energy is not above zero.
    public static func percents(ofEnergyKcal energy: Decimal, grams: Grams) -> Grams? {
        guard !energy.isNaN, energy > 0 else { return nil }
        return Grams(
            protein: DisplayRounding.rounded(
                grams.protein * kcalPerGramProtein * 100 / energy, fractionDigits: 0),
            carbohydrate: DisplayRounding.rounded(
                grams.carbohydrate * kcalPerGramCarbohydrate * 100 / energy, fractionDigits: 0),
            fat: DisplayRounding.rounded(grams.fat * kcalPerGramFat * 100 / energy, fractionDigits: 0))
    }

    private static func wholeGrams(_ energy: Decimal, share: Decimal, kcalPerGram: Decimal) -> Decimal {
        DisplayRounding.rounded(energy * share / 100 / kcalPerGram, fractionDigits: 0)
    }
}
