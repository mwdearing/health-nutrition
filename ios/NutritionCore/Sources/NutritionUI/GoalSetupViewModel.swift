import Foundation
import NutritionDomain
import NutritionJournal

/// One screen of the goal setup, in the order a person meets them. Pace is only reached when losing or
/// gaining, and a person who just tracks meets only the aim and the end.
public enum GoalSetupStep: Sendable, Equatable {
    case aim, about, body, activity, pace, results
}

/// One pace a person can pick. The label is the words shown; the value is the same pace in kilograms.
public struct GoalPaceOption: Sendable, Equatable {
    public let label: String
    public let kilogramsPerWeek: Decimal
}

/// Backs the guided goal setup: the answers, the steps through them, the estimate and the save.
///
/// The answers live here only while the sheet is open. `clearAnswers()` empties them when it closes, and
/// nothing in this type writes an answer anywhere: the only thing saved is a target a person keeps, and
/// that goes through `GoalsViewModel` like any target typed on the Goals screen.
@MainActor
public final class GoalSetupViewModel: ObservableObject {
    public static let privacyNotice = "Your answers stay on this phone and are not saved. Only the targets you choose are."
    public static let estimateNotice = "These are estimates, not medical advice. If you are pregnant, have a medical condition or take medicines that affect weight or appetite, ask your doctor or dietitian."
    public static let replaceNotice = "This replaces your current targets for these nutrients."
    public static let adultNotice = "Goal estimates here are for adults. Ask a doctor or dietitian for advice on a target."
    public static let justTrackNotice = "Nothing was saved. Your day will show totals without targets."
    public static let justTrackUnknownNotice =
        "We could not read your current targets, so they are unchanged. Check them on the Goals screen."
    public static let saveRestoreFailedNotice =
        "Some goals may not have been put back. Check your targets on the Goals screen."
    public static let justTrackExistingNotice = "Your current targets are unchanged. You can change or remove them on the Goals screen."
    public static let genericErrorNotice = "Check your answers and try again."
    public static let saveFailedNotice = "Could not save your goals. Try again."
    public static let invalidFieldNotice = "Enter a number greater than zero."

    /// The nutrients the estimate sets, in the order the results screen lists them.
    public static let targetKeys = ["energy", "protein", "carbohydrate", "fat", "fiber"]

    /// Pounds and inches convert to centimeters and kilograms with these exact factors.
    private static let centimetersPerInch = Decimal(string: "2.54")!
    private static let kilogramsPerPound = Decimal(string: "0.45359237")!

    @Published public private(set) var step: GoalSetupStep = .aim
    @Published public var aim: GoalAim?
    @Published public var sex: GoalSex?
    @Published public var ageText = ""
    @Published public var heightCentimetersText = ""
    @Published public var heightFeetText = ""
    @Published public var heightInchesText = ""
    @Published public var weightKilogramsText = ""
    @Published public var weightPoundsText = ""
    @Published public var activity: ActivityLevel?
    @Published public var selectedPaceKilograms: Decimal?
    /// The results as the person may edit them, one text per key in `targetKeys`.
    @Published public var draftTargets: [String: String] = [:]
    /// Set when the answers cannot be estimated, in plain words for the results screen.
    @Published public private(set) var resultError: String?
    /// The message for each result field that cannot be saved, keyed by nutrient. The fields stay on
    /// screen with their text, so the person can correct the one named.
    @Published public private(set) var fieldErrors: [String: String] = [:]
    /// Set when the estimate changed a number for a floor or the daily cap.
    @Published public private(set) var adjustmentNote: String?

    private let goals: GoalsViewModel

    public init(goals: GoalsViewModel) {
        self.goals = goals
    }

    /// The unit system the answers are asked in.
    public var unitSystem: UnitSystem { goals.unitSystem }

    /// The steps for the aim chosen so far. Before an aim is chosen, the longest path is shown.
    public var steps: [GoalSetupStep] {
        switch aim {
        case .justTrack: return [.aim, .results]
        case .maintain: return [.aim, .about, .body, .activity, .results]
        case .lose, .gain, nil: return [.aim, .about, .body, .activity, .pace, .results]
        }
    }

    /// "Step 2 of 5", counted over the steps this aim takes.
    public var stepLabel: String {
        let list = steps
        let position = (list.firstIndex(of: step) ?? 0) + 1
        return "Step \(position) of \(list.count)"
    }

    /// Whether the screen's Next button may move on. The results screen has its own save.
    public var canGoNext: Bool {
        switch step {
        case .aim: return aim != nil
        case .about: return sex != nil && ageYears() != nil
        case .body: return heightCentimeters() != nil && weightKilograms() != nil
        case .activity: return activity != nil
        case .pace: return selectedPaceKilograms != nil
        case .results: return false
        }
    }

    public func next() {
        guard canGoNext else { return }
        let list = steps
        guard let index = list.firstIndex(of: step), index + 1 < list.count else { return }
        step = list[index + 1]
        if step == .results { calculate() }
    }

    public func back() {
        let list = steps
        guard let index = list.firstIndex(of: step), index > 0 else { return }
        if step == .results {
            draftTargets = [:]
            resultError = nil
            fieldErrors = [:]
            adjustmentNote = nil
        }
        step = list[index - 1]
    }

    /// The pace choices for the unit system: kilograms, or pounds converted exactly to kilograms.
    public var paceOptions: [GoalPaceOption] {
        if unitSystem == .usCustomary {
            return [Decimal(string: "0.5")!, 1, Decimal(string: "1.5")!, 2].map { pounds in
                GoalPaceOption(
                    label: "\(DecimalFormatting.text(pounds)) lb per week",
                    kilogramsPerWeek: pounds * Self.kilogramsPerPound)
            }
        }
        return [Decimal(string: "0.25")!, Decimal(string: "0.5")!, Decimal(string: "0.75")!, 1].map { kilograms in
            GoalPaceOption(label: "\(DecimalFormatting.text(kilograms)) kg per week", kilogramsPerWeek: kilograms)
        }
    }

    /// The answers as an estimator profile, or nil while any answer is missing or unreadable. A range
    /// problem is not caught here: the estimator reports it, and the results screen says so.
    public func makeProfile() -> GoalProfile? {
        guard let aim, let sex, let ageYears = ageYears(), let height = heightCentimeters(),
              let weight = weightKilograms(), let activity
        else { return nil }
        return GoalProfile(
            sex: sex, ageYears: ageYears, heightCentimeters: height, weightKilograms: weight,
            activity: activity, aim: aim, weeklyChangeKilograms: selectedPaceKilograms ?? 0)
    }

    /// Whether any target at all is stored, for any nutrient. The just-track result reads this, so it
    /// never promises a day without targets while some are still set.
    public var hasAnyStoredTarget: Bool {
        goals.rows.contains { $0.targetText != nil }
    }

    /// The heading of the just-track result. Without targets only when the store was read and is empty.
    public var justTrackHeading: String {
        let unreadable = goals.errorMessage == GoalsViewModel.readFailedMessage
        return unreadable || hasAnyStoredTarget ? "Your day" : "Your day, without targets"
    }

    /// The sentence the just-track result shows: the targets stay as they are when any exist.
    public var justTrackMessage: String {
        // An unreadable store is unknown, not empty: say nothing about the day showing no targets.
        if goals.errorMessage == GoalsViewModel.readFailedMessage { return Self.justTrackUnknownNotice }
        return hasAnyStoredTarget ? Self.justTrackExistingNotice : Self.justTrackNotice
    }

    /// Whether any of the targets this screen sets is already stored, so the sheet says it replaces them.
    public var hasExistingTargets: Bool {
        goals.rows.contains { Self.targetKeys.contains($0.nutrient) && $0.targetText != nil }
    }

    /// Saves the results as they now read. A blank result removes that target, the same as a blank
    /// field on the Goals screen. Returns false when nothing was saved, which includes "just track".
    ///
    /// The save is all or nothing: each affected goal is captured before anything is written, and if a
    /// write fails, the goals already changed are put back exactly as they were read.
    @discardableResult
    public func save() -> Bool {
        guard aim != .justTrack, step == .results, !draftTargets.isEmpty else { return false }
        fieldErrors = [:]
        for key in Self.targetKeys {
            let text = (draftTargets[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if let value = AmountParser.parseTyped(text), value > 0 { continue }
            fieldErrors[key] = Self.invalidFieldNotice
        }
        guard fieldErrors.isEmpty else {
            resultError = "Enter a number above zero."
            return false
        }
        resultError = nil
        var before: [(nutrient: String, goal: NutrientGoal?)] = []
        do {
            for key in Self.targetKeys {
                let original = try goals.storedGoal(for: key)
                before.append((nutrient: key, goal: original))
            }
        } catch {
            resultError = Self.saveFailedNotice
            return false
        }
        var attempted: [(nutrient: String, goal: NutrientGoal?)] = []
        for (index, key) in Self.targetKeys.enumerated() {
            let text = (draftTargets[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            attempted.append(before[index])
            let saved = text.isEmpty
                ? goals.removeTarget(for: key)
                : goals.setTarget(text, for: key, unit: goals.unit(for: key))
            guard saved else {
                var restored = true
                // The write that failed changed nothing, so only the ones before it are put back.
                for entry in attempted.dropLast().reversed() {
                    if !goals.restoreGoal(entry.goal, for: entry.nutrient) { restored = false }
                }
                resultError = restored ? Self.saveFailedNotice : Self.saveRestoreFailedNotice
                return false
            }
        }
        for key in Self.targetKeys {
            let text = (draftTargets[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // The Goals screen keeps its own text and unit per field. Set both to what was stored, so
            // leaving that field later neither reads the empty text as a request to remove the new goal
            // nor saves the number again in a unit the picker held before (150 g as 150 mg).
            goals.draftText[key] = text.isEmpty ? "" : DecimalFormatting.text(AmountParser.parseTyped(text) ?? 0)
            if !text.isEmpty { goals.selectedUnits[key] = goals.unit(for: key) }
            // An error the row showed for earlier text no longer describes what is stored.
            goals.clearRowError(for: key)
        }
        return true
    }

    /// Empties every answer and returns to the first step. Called when the sheet closes, so nothing a
    /// person typed outlives the sheet.
    public func clearAnswers() {
        step = .aim
        aim = nil
        sex = nil
        ageText = ""
        heightCentimetersText = ""
        heightFeetText = ""
        heightInchesText = ""
        weightKilogramsText = ""
        weightPoundsText = ""
        activity = nil
        selectedPaceKilograms = nil
        draftTargets = [:]
        resultError = nil
        fieldErrors = [:]
        adjustmentNote = nil
    }

    /// Estimates the results from the answers, filling the drafts the person may then edit.
    private func calculate() {
        draftTargets = [:]
        resultError = nil
        fieldErrors = [:]
        adjustmentNote = nil
        guard let profile = makeProfile() else { return }
        do {
            guard let estimate = try GoalEstimator.estimate(profile) else { return }
            draftTargets = [
                "energy": DecimalFormatting.text(estimate.energyKcal),
                "protein": DecimalFormatting.text(estimate.proteinGrams),
                "carbohydrate": DecimalFormatting.text(estimate.carbohydrateGrams),
                "fat": DecimalFormatting.text(estimate.fatGrams),
                "fiber": DecimalFormatting.text(estimate.fiberGrams),
            ]
            adjustmentNote = estimate.adjustmentNote
        } catch let error as GoalEstimateError {
            resultError = message(for: error)
        } catch {
            resultError = Self.genericErrorNotice
        }
    }

    /// The plain sentence for a range or adult error, in the person's unit system. The bounds read in
    /// feet and inches, pounds and pounds a week are rounded inward (the least up, the most down), so
    /// every value the sentence names is one the estimate accepts.
    private func message(for error: GoalEstimateError) -> String {
        let usCustomary = unitSystem == .usCustomary
        switch error {
        case .underAge:
            return Self.adultNotice
        case .outOfRange(.age):
            return "Check your age. The estimate is for ages 18 to 100."
        case .outOfRange(.height):
            guard usCustomary else { return "Check your height. It must be between 120 and 230 cm." }
            let least = Self.rounded(Decimal(120) / Self.centimetersPerInch, scale: 0, .up)
            let most = Self.rounded(Decimal(230) / Self.centimetersPerInch, scale: 0, .down)
            return "Check your height. It must be between \(Self.feetAndInches(inches: least)) and \(Self.feetAndInches(inches: most))."
        case .outOfRange(.weight):
            guard usCustomary else { return "Check your weight. It must be between 30 and 300 kg." }
            let least = Self.rounded(Decimal(30) / Self.kilogramsPerPound, scale: 0, .up)
            let most = Self.rounded(Decimal(300) / Self.kilogramsPerPound, scale: 0, .down)
            return "Check your weight. It must be between \(DecimalFormatting.text(least)) and \(DecimalFormatting.text(most)) lb."
        case .outOfRange(.weeklyChange):
            guard usCustomary else { return "Check your pace. It must be between 0.1 and 1 kg a week." }
            let least = Self.rounded(Decimal(string: "0.1")! / Self.kilogramsPerPound, scale: 1, .up)
            let most = Self.rounded(Decimal(1) / Self.kilogramsPerPound, scale: 1, .down)
            return "Check your pace. It must be between \(DecimalFormatting.text(least)) and \(DecimalFormatting.text(most)) lb a week."
        }
    }

    /// Rounds to a number of decimal places in one direction, exactly.
    private static func rounded(_ value: Decimal, scale: Int, _ mode: NSDecimalNumber.RoundingMode) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, scale, mode)
        return output
    }

    /// Whole inches as feet and inches, such as "5 ft 10 in".
    private static func feetAndInches(inches: Decimal) -> String {
        let total = NSDecimalNumber(decimal: inches).intValue
        return "\(total / 12) ft \(total % 12) in"
    }

    private func ageYears() -> Int? {
        Int(ageText.trimmingCharacters(in: .whitespaces))
    }

    private func heightCentimeters() -> Decimal? {
        if unitSystem == .usCustomary {
            guard let feet = Self.wholeOrZero(heightFeetText),
                  let inches = Self.inchesOrNone(heightInchesText)
            else { return nil }
            return (feet * 12 + inches) * Self.centimetersPerInch
        }
        return AmountParser.parseTyped(heightCentimetersText)
    }

    /// Feet typed as a number, where zero is read as zero rather than refused.
    private static func wholeOrZero(_ text: String) -> Decimal? {
        if let typed = AmountParser.parseTyped(text) { return typed }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Only a typed zero ("0" or "0.0") counts; anything else with a zero in it is refused.
        let isZero = trimmed.contains("0") && trimmed.allSatisfy { $0 == "0" || $0 == "." }
        return isZero ? 0 : nil
    }

    /// Inches are optional: a blank field or a zero reads as no inches, so "5 ft" alone is a height.
    private static func inchesOrNone(_ text: String) -> Decimal? {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return 0 }
        return wholeOrZero(text)
    }

    private func weightKilograms() -> Decimal? {
        if unitSystem == .usCustomary {
            guard let pounds = AmountParser.parseTyped(weightPoundsText) else { return nil }
            return pounds * Self.kilogramsPerPound
        }
        return AmountParser.parseTyped(weightKilogramsText)
    }
}
