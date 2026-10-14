import Foundation
import NutritionDomain
import NutritionJournal

/// Why a typed split cannot be turned into gram goals, with the words the screen shows for it.
public enum MacroSplitProblem: Error, Equatable {
    /// No energy goal is stored, so there is nothing for the percentages to be shares of.
    case needsEnergyGoal
    /// A field is empty or is not a number above zero.
    case notNumbers
    /// The three percentages do not total 100.
    case notHundred(total: Decimal)
    /// A share of the energy goal rounds to 0 g.
    case tooSmall

    public var message: String {
        switch self {
        case .needsEnergyGoal:
            return "Set a daily energy goal first. The percentages are shares of it."
        case .notNumbers:
            return "Enter a percentage above zero for protein, carbohydrate and fat."
        case .notHundred(let total):
            return "The three percentages total \(DecimalFormatting.text(total)). They must total 100."
        case .tooSmall:
            return "A share that small comes to 0 g of your energy goal. Enter a larger percentage."
        }
    }
}

/// Macro targets stated as percentages of the energy goal.
///
/// The percentages are not stored. Applying a split writes three ordinary gram goals, so Today, the
/// Journal header, erase and export all treat them as the gram goals they are. The split shown back
/// is worked out from those stored grams and the stored energy goal each time.
extension GoalsViewModel {
    /// The keys a split writes, in the order the screen names them.
    public static let macroSplitKeys = ["protein", "carbohydrate", "fat"]

    /// The stored energy goal in kcal, or nil when none is stored or it cannot be read.
    public func macroSplitEnergyKcal() -> Decimal? {
        guard let goal = try? self.storedGoal(for: "energy"),
              let kcal = try? Quantity(value: goal.target, unit: goal.unit).converted(to: .kcal).value,
              !kcal.isNaN, kcal > 0
        else { return nil }
        return kcal
    }

    /// The whole-gram goals the typed percentages come to for the stored energy goal, or why not.
    public func macroSplitGrams(
        protein: String, carbohydrate: String, fat: String
    ) -> Result<MacroSplit.Grams, MacroSplitProblem> {
        guard let energy = self.macroSplitEnergyKcal() else { return .failure(.needsEnergyGoal) }
        guard let proteinShare = AmountParser.parseTyped(protein),
              let carbohydrateShare = AmountParser.parseTyped(carbohydrate),
              let fatShare = AmountParser.parseTyped(fat)
        else { return .failure(.notNumbers) }
        do {
            let split = try MacroSplit(
                proteinPercent: proteinShare, carbohydratePercent: carbohydrateShare, fatPercent: fatShare)
            return .success(try split.grams(forEnergyKcal: energy))
        } catch MacroSplit.SplitError.doesNotTotalHundred(let total) {
            return .failure(.notHundred(total: total))
        } catch MacroSplit.SplitError.roundsToNothing {
            return .failure(.tooSmall)
        } catch {
            return .failure(.notNumbers)
        }
    }

    /// The share of the stored energy goal each stored macro goal supplies, as whole percents, or nil
    /// unless an energy goal and all three macro goals are stored as masses.
    public func currentMacroPercents() -> MacroSplit.Grams? {
        guard let energy = self.macroSplitEnergyKcal() else { return nil }
        var grams: [Decimal] = []
        for key in Self.macroSplitKeys {
            guard let goal = try? self.storedGoal(for: key),
                  let inGrams = try? Quantity(value: goal.target, unit: goal.unit).converted(to: .g).value
            else { return nil }
            grams.append(inGrams)
        }
        return MacroSplit.percents(
            ofEnergyKcal: energy,
            grams: MacroSplit.Grams(protein: grams[0], carbohydrate: grams[1], fat: grams[2]))
    }

    /// Writes the three gram goals the typed percentages come to. All three are written or none is:
    /// when a write is refused, the goals that were there before are put back.
    ///
    /// Returns nil when the goals were written, otherwise the message to show.
    @discardableResult
    public func applyMacroSplit(protein: String, carbohydrate: String, fat: String) -> String? {
        let grams: MacroSplit.Grams
        switch self.macroSplitGrams(protein: protein, carbohydrate: carbohydrate, fat: fat) {
        case .success(let worked): grams = worked
        case .failure(let problem): return problem.message
        }
        let targets: [(key: String, grams: Decimal)] = [
            ("protein", grams.protein), ("carbohydrate", grams.carbohydrate), ("fat", grams.fat),
        ]
        var previous: [(key: String, goal: NutrientGoal?)] = []
        do {
            for target in targets {
                let stored = try self.storedGoal(for: target.key)
                previous.append((key: target.key, goal: stored))
            }
        } catch {
            return Self.saveFailedMessage
        }
        for target in targets {
            guard self.setTarget(DecimalFormatting.text(target.grams), for: target.key, unit: .g) else {
                for earlier in previous { self.restoreGoal(earlier.goal, for: earlier.key) }
                return Self.saveFailedMessage
            }
        }
        // The inline rows keep their own drafts, and a draft left from before would be committed over
        // the new goal the next time its field loses focus.
        for target in targets {
            self.draftText[target.key] = DecimalFormatting.text(target.grams)
            self.selectedUnits[target.key] = .g
        }
        return nil
    }
}
