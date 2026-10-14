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
/// as the gram goals they are, and stores the split itself. While it is stored, changing the energy goal
/// on the Goals screen moves the three gram goals to the split's share of the new energy goal. Setting
/// any of the three by hand, the setup estimate, removing the energy goal or clearing all goals stops
/// that and forgets the split. The share shown back is still worked out from the stored grams.
extension GoalsViewModel {
    /// The split the macro gram goals follow, or nil when they do not follow the energy goal.
    public var followedMacroSplit: MacroSplit? { macroSplitPreferences?.macroSplit }

    /// The keys a split writes, in the order the screen names them.
    public static let macroSplitKeys = ["protein", "carbohydrate", "fat"]

    /// Shown when a write failed and putting the earlier goals back failed too, so some of the three
    /// may hold the new value and some the old.
    public static let macroSplitRestoreFailedMessage =
        "Could not save all three macro goals, and the earlier ones could not all be put back. Check protein, carbohydrate and fat below."

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
            stored = try self.storedGoal(for: "energy")
        } catch {
            throw MacroSplitProblem.readFailed
        }
        if self.rows.contains(where: { $0.nutrient == "energy" }), let draft = self.draftText["energy"] {
            let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return nil }
            guard let typed = AmountParser.parseTyped(text), !typed.isNaN, typed > 0,
                  let kcal = try? Quantity(value: typed, unit: self.selectedUnits["energy"] ?? .kcal)
                      .converted(to: .kcal).value
            else { throw MacroSplitProblem.energyNotValid }
            return kcal
        }
        guard let goal = stored,
              let kcal = try? Quantity(value: goal.target, unit: goal.unit).converted(to: .kcal).value,
              !kcal.isNaN, kcal > 0
        else { return nil }
        return kcal
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
        let energy: Decimal
        do {
            guard let shown = try self.macroSplitEnergyKcal() else { return .failure(.needsEnergyGoal) }
            energy = shown
        } catch let problem as MacroSplitProblem {
            return .failure(problem)
        } catch {
            return .failure(.readFailed)
        }
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

    /// The share of the energy goal each stored macro goal supplies, as whole percents, or nil unless
    /// there is an energy goal and all three macro goals are stored, readable and in mass units.
    public func currentMacroPercents() -> MacroSplit.Grams? {
        guard let energy = try? self.macroSplitEnergyKcal() else { return nil }
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
    /// when a write is refused, the goals written before it are put back, and when putting one back
    /// fails too the message says so rather than reporting a plain failed save.
    ///
    /// Returns nil when the goals were written, otherwise the message to show.
    @discardableResult
    public func applyMacroSplit(protein: String, carbohydrate: String, fat: String) -> String? {
        // Worked out before anything is written, so a split that cannot be made writes nothing.
        let grams: MacroSplit.Grams
        switch self.macroSplitGrams(protein: protein, carbohydrate: carbohydrate, fat: fat) {
        case .success(let worked): grams = worked
        case .failure(let problem): return problem.message
        }
        let targets: [(key: String, grams: Decimal)] = [
            ("protein", grams.protein), ("carbohydrate", grams.carbohydrate), ("fat", grams.fat),
        ]
        // The split the grams came from, stored once all three are written. Until then no split is
        // stored, so saving the energy edit below has nothing to follow and a failed write leaves none.
        let split = AmountParser.parseTyped(protein).flatMap { p in
            AmountParser.parseTyped(carbohydrate).flatMap { c in
                AmountParser.parseTyped(fat).flatMap { f in
                    try? MacroSplit(proteinPercent: p, carbohydratePercent: c, fatPercent: f)
                }
            }
        }
        // A failed apply puts back the split that was followed before, when the goals it rolls back to
        // are still that split's output.
        let previousSplit = self.followedMacroSplit
        self.macroSplitPreferences?.setMacroSplit(nil)
        var previous: [(key: String, goal: NutrientGoal?, draft: String?, unit: MeasureUnit?)] = []
        let storedEnergy: NutrientGoal?
        do {
            for target in targets {
                let stored = try self.storedGoal(for: target.key)
                previous.append((
                    key: target.key, goal: stored, draft: self.draftText[target.key],
                    unit: self.selectedUnits[target.key]))
            }
            storedEnergy = try self.storedGoal(for: "energy")
        } catch {
            return Self.saveFailedMessage
        }
        // The grams above are shares of the energy the row shows. When that is an edit not yet saved,
        // it is saved first, so the stored energy goal is the one the grams were worked out from.
        if self.rows.contains(where: { $0.nutrient == "energy" }), let draft = self.draftText["energy"] {
            let typed = AmountParser.parseTyped(draft.trimmingCharacters(in: .whitespacesAndNewlines))
            let unit = self.selectedUnits["energy"] ?? .kcal
            if typed != storedEnergy?.target || unit != storedEnergy?.unit {
                guard self.commitTarget(for: "energy") else {
                    return self.rowError["energy"] ?? self.errorMessage ?? Self.saveFailedMessage
                }
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
                    self.draftText[earlier.key] = earlier.draft
                    self.selectedUnits[earlier.key] = earlier.unit
                }
                if restored { self.restoreMacroSplit(previousSplit) }
                return restored ? Self.saveFailedMessage : Self.macroSplitRestoreFailedMessage
            }
        }
        self.macroSplitPreferences?.setMacroSplit(split)
        return nil
    }
}
