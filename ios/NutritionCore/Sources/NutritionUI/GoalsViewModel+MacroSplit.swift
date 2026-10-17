import Foundation
import NutritionDomain
import NutritionJournal

/// Why a typed split cannot be turned into gram goals, with the words the screen shows for it.
public enum MacroSplitProblem: Error, Equatable {
    /// No energy goal is stored, so there is nothing for the percentages to be shares of.
    case needsEnergyGoal
    /// The goals cannot be read, so whether an energy goal is stored is not known.
    case readFailed
    /// The energy row holds text that is not a number above zero.
    case energyNotValid
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
        case .readFailed:
            // The same words as `GoalsViewModel.readFailedMessage`; a test keeps the two equal.
            return "Could not read the daily goals."
        case .energyNotValid:
            return "Enter an energy goal above zero first. The percentages are shares of it."
        case .notNumbers:
            return "Enter a percentage above zero for protein, carbohydrate and fat."
        case .notHundred(let total):
            return "The three percentages total \(DecimalFormatting.text(total)). They must total 100."
        case .tooSmall:
            return "A share that small comes to 0 g of your energy goal. Enter a larger percentage."
        }
    }
}

/// Where the split the macro gram goals follow is kept: a display preference, erased with the others.
/// Nil when the gram goals do not follow the energy goal.
public protocol MacroSplitPreferences: AnyObject {
    var macroSplit: MacroSplit? { get }
    func setMacroSplit(_ split: MacroSplit?)
}

/// Macro targets stated as percentages of the energy goal.
///
/// Applying a split writes three ordinary gram goals, so Today, the Journal header and erase treat them
/// as the gram goals they are, and stores the split itself. The gram goals follow the split exactly
/// while the three stored macro goals are its output for the energy goal: changing the energy goal on
/// the Goals screen then moves them to its share of the new one. That is decided from the goals each
/// time, so a gram goal changed by hand or by the setup estimate stops it, and nothing has to be kept
/// in step. Clearing all goals and erase forget the split. The share shown back is still worked out from
/// the stored grams.
extension GoalsViewModel {
    /// The keys a split writes, in the order the screen names them.
    public static let macroSplitKeys = ["protein", "carbohydrate", "fat"]

    /// Shown when a write failed and putting the earlier goals back failed too, so some of the three
    /// may hold the new value and some the old.
    public static let macroSplitRestoreFailedMessage =
        "Could not save all three macro goals, and the earlier ones could not all be put back. Check protein, carbohydrate and fat below."

    /// Shown when an apply saved a changed energy goal first and then could not write the gram goals:
    /// the energy goal stays saved, so the message must not say nothing was saved.
    public static let macroSplitEnergySavedMessage =
        "Your energy goal is saved, but protein, carbohydrate and fat could not be set from the percentages."

    /// The energy goal the split is a share of, in kcal, or nil when there is none.
    ///
    /// It is the energy the screen's energy row shows. A field commits only when focus leaves it, so an
    /// edit typed there may not be saved yet; the preview and the save both use it, and the save stores
    /// it first. Throws `MacroSplitProblem.readFailed` when the goals cannot be read, because a store
    /// that cannot be read is not a person with no energy goal, and `.energyNotValid` when the row holds
    /// text that is not a number above zero.
    public func macroSplitEnergyKcal() throws -> Decimal? {
        let stored: NutrientGoal?
        do {
            stored = try self.storedGoal(for: Self.energyKey)
        } catch {
            throw MacroSplitProblem.readFailed
        }
        if self.rows.contains(where: { $0.nutrient == Self.energyKey }), let draft = self.draftText[Self.energyKey] {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return nil }
            guard let typed = AmountParser.parseTyped(text), !typed.isNaN, typed > 0,
                  let kcal = try? Quantity(value: typed, unit: self.selectedUnits[Self.energyKey] ?? .kcal)
                      .converted(to: .kcal).value
            else { throw MacroSplitProblem.energyNotValid }
            return kcal
        }
        return Self.kcal(stored)
    }

    /// Why the section cannot offer a split yet, or nil when there is an energy goal to share out.
    public func macroSplitUnavailable() -> MacroSplitProblem? {
        do {
            return try self.macroSplitEnergyKcal() == nil ? .needsEnergyGoal : nil
        } catch let problem as MacroSplitProblem {
            return problem
        } catch {
            return .readFailed
        }
    }

    /// The whole-gram goals the typed percentages come to for the energy goal, or why not.
    public func macroSplitGrams(
        protein: String, carbohydrate: String, fat: String
    ) -> Result<MacroSplit.Grams, MacroSplitProblem> {
        self.macroSplitWorked(protein: protein, carbohydrate: carbohydrate, fat: fat).map { $0.grams }
    }

    /// The split the typed percentages state and the grams it comes to for the energy goal, or why not:
    /// the one place they are parsed, so the preview, the save and the stored split agree.
    func macroSplitWorked(
        protein: String, carbohydrate: String, fat: String
    ) -> Result<(split: MacroSplit, grams: MacroSplit.Grams), MacroSplitProblem> {
        let energy: Decimal
        do {
            guard let shown = try self.macroSplitEnergyKcal() else { return .failure(.needsEnergyGoal) }
            energy = shown
        } catch let problem as MacroSplitProblem {
            return .failure(problem)
        } catch {
            return .failure(.readFailed)
        }
        guard let shares = Self.typedShares(protein: protein, carbohydrate: carbohydrate, fat: fat)
        else { return .failure(.notNumbers) }
        let (proteinShare, carbohydrateShare, fatShare) = shares
        do {
            let split = try MacroSplit(
                proteinPercent: proteinShare, carbohydratePercent: carbohydrateShare, fatPercent: fatShare)
            return .success((split, try split.grams(forEnergyKcal: energy)))
        } catch MacroSplit.SplitError.doesNotTotalHundred(let total) {
            return .failure(.notHundred(total: total))
        } catch MacroSplit.SplitError.roundsToNothing {
            return .failure(.tooSmall)
        } catch {
            return .failure(.notNumbers)
        }
    }

    /// The three typed percentages as numbers, or nil when one is not a number. One parse for the preview,
    /// the save and the split the save stores, so they cannot read the same text differently.
    static func typedShares(protein: String, carbohydrate: String, fat: String) -> (Decimal, Decimal, Decimal)? {
        guard let proteinShare = AmountParser.parseTyped(protein),
              let carbohydrateShare = AmountParser.parseTyped(carbohydrate),
              let fatShare = AmountParser.parseTyped(fat)
        else { return nil }
        return (proteinShare, carbohydrateShare, fatShare)
    }

    /// The share of the energy goal each stored macro goal supplies, as whole percents, or nil unless
    /// there is an energy goal and all three macro goals are stored, readable and in mass units.
    public func currentMacroPercents() -> MacroSplit.Grams? {
        guard let energy = try? self.macroSplitEnergyKcal(), let macros = self.storedMacroGoals() else { return nil }
        return MacroSplit.percents(ofEnergyKcal: energy, grams: macros.grams)
    }

    /// Writes the three gram goals the typed percentages come to. All three are written or none is:
    /// when a write is refused, the goals written before it are put back, and when putting one back
    /// fails too the message says so rather than reporting a plain failed save.
    ///
    /// Returns nil when the goals were written, otherwise the message to show.
    @discardableResult
    public func applyMacroSplit(protein: String, carbohydrate: String, fat: String) -> String? {
        // Worked out before anything is written, so a split that cannot be made writes nothing.
        let grams: MacroSplit.Grams
        let split: MacroSplit
        switch self.macroSplitWorked(protein: protein, carbohydrate: carbohydrate, fat: fat) {
        case .success(let worked):
            split = worked.split
            grams = worked.grams
        case .failure(let problem): return problem.message
        }
        let targets: [(key: String, grams: Decimal)] = [
            ("protein", grams.protein), ("carbohydrate", grams.carbohydrate), ("fat", grams.fat),
        ]
        // The split is stored only once all three are written. A failed apply leaves the earlier split
        // stored, and whether the goals still follow it is decided from the goals.
        var energySaved = false
        var previous: [(key: String, goal: NutrientGoal?, draft: String?, unit: MeasureUnit?)] = []
        let storedEnergy: NutrientGoal?
        do {
            for target in targets {
                let stored = try self.storedGoal(for: target.key)
                previous.append((
                    key: target.key, goal: stored, draft: self.draftText[target.key],
                    unit: self.selectedUnits[target.key]))
            }
            storedEnergy = try self.storedGoal(for: Self.energyKey)
        } catch {
            return Self.saveFailedMessage
        }
        // The grams above are shares of the energy the row shows. When that is an edit not yet saved,
        // it is saved first, so the stored energy goal is the one the grams were worked out from.
        if self.rows.contains(where: { $0.nutrient == Self.energyKey }), let draft = self.draftText[Self.energyKey] {
            let typed = AmountParser.parseTyped(draft.trimmingCharacters(in: .whitespacesAndNewlines))
            let unit = self.selectedUnits[Self.energyKey] ?? .kcal
            if typed != storedEnergy?.target || unit != storedEnergy?.unit {
                // Saved without following: the old split must not move the grams just before the new
                // ones replace them.
                self.isApplyingMacroSplit = true
                let committed = self.commitTarget(for: Self.energyKey)
                self.isApplyingMacroSplit = false
                guard committed else {
                    return self.rowError[Self.energyKey] ?? self.errorMessage ?? Self.saveFailedMessage
                }
                energySaved = true
            }
        }
        // Each goal is written through its own row, so the row's draft, unit and any error it showed for
        // earlier text all follow the new goal in the one write. A draft left from before would
        // otherwise be committed over the new goal the next time its field loses focus.
        for (index, target) in targets.enumerated() {
            self.draftText[target.key] = DecimalFormatting.text(target.grams)
            self.selectedUnits[target.key] = .g
            guard self.commitTarget(for: target.key) else {
                // The write that failed changed nothing, so only the goals before it are put back; every
                // row touched gets its earlier draft and unit back.
                var restored = true
                for earlier in previous.prefix(index).reversed() {
                    if !self.restoreGoal(earlier.goal, for: earlier.key) { restored = false }
                }
                for earlier in previous.prefix(index + 1) {
                    // A goal that could not be put back keeps its new value, so its field is refilled
                    // from the store rather than shown the old draft it would commit back over it.
                    self.draftText[earlier.key] = restored ? earlier.draft : nil
                    self.selectedUnits[earlier.key] = restored ? earlier.unit : nil
                }
                self.load()
                // A changed energy goal saved first stays saved, and the message must say so.
                guard restored else { return Self.macroSplitRestoreFailedMessage }
                return energySaved ? Self.macroSplitEnergySavedMessage : Self.saveFailedMessage
            }
        }
        self.macroSplitPreferences?.setMacroSplit(split)
        self.refreshFollowedMacroSplit()
        self.noteMacroSplitSaved()
        return nil
    }
}
