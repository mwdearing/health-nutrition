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

/// The vitamins and minerals choice on the results step: the reference values as they are, or the same
/// values prefilled for the person to edit.
public enum VitaminGoalChoice: Sendable, Equatable {
    case recommended, own
}

/// Backs the guided goal setup: the answers, the steps through them, the estimate and the save.
///
/// The answers live here only while the sheet is open. `clearAnswers()` empties them when it closes. Of
/// the answers, only the aim, the pace and the goal weight are saved, as the weight plan saved with the
/// targets; the rest are never written. The targets go through `GoalsViewModel` like any typed on the
/// Goals screen.
@MainActor
public final class GoalSetupViewModel: ObservableObject, Identifiable {
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    public static let privacyNotice = "Your age, sex, height and current weight stay on this device and are not saved. Your aim, pace and goal weight are saved on this device with the targets you choose."
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
    /// The notice a save gives when a field cannot be saved.
    static let fieldsNotice = "Enter a number above zero."
    public static let saveFailedNotice = "Could not save your goals. Try again."
    public static let invalidFieldNotice = "Enter a number greater than zero."
    public static let goalWeightBelowNotice = "To lose weight, your goal weight must be below your current weight."
    public static let goalWeightAboveNotice = "To gain weight, your goal weight must be above your current weight."

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
    @Published public var goalWeightKilogramsText = ""
    @Published public var goalWeightPoundsText = ""
    @Published public var activity: ActivityLevel?
    @Published public var selectedPaceKilograms: Decimal?
    /// The results as the person may edit them, one text per key in `targetKeys`.
    @Published public var draftTargets: [String: String] = [:]
    /// Nil until the person picks one; then the vitamins and minerals the save writes come from it.
    @Published public private(set) var vitaminChoice: VitaminGoalChoice?
    /// The editable vitamin and mineral values for "Set my own", prefilled from the reference values.
    @Published public var vitaminDrafts: [String: String] = [:]
    /// Set when the answers cannot be estimated, in plain words for the results screen.
    @Published public private(set) var resultError: String?
    /// The message for each result field that cannot be saved, keyed by nutrient. The fields stay on
    /// screen with their text, so the person can correct the one named.
    @Published public private(set) var fieldErrors: [String: String] = [:]
    /// Set when the estimate changed a number for a floor or the daily cap.
    @Published public private(set) var adjustmentNote: String?

    private let goals: GoalsViewModel
    /// Set once Health's height has been put in the field, so a height the person then clears stays cleared.
    private var filledHeightFromHealth = false
    private let now: () -> Date
    private let calendar: Calendar
    /// A weight shown after a unit switch: the text in the field and the exact kilograms it stands for.
    private typealias ConvertedWeight = (text: String, kilograms: Decimal)
    /// A height shown after a unit switch: the exact centimeters, and the text in the centimeter field or in
    /// the feet and inches fields that show them.
    private typealias ConvertedHeight = (centimeters: Decimal, centimetersText: String, feetText: String, inchesText: String)
    /// The unit system the weight and height fields are in. A switch while the sheet is open converts them.
    private var textUnitSystem: UnitSystem
    private var convertedCurrentWeight: ConvertedWeight?
    private var convertedGoalWeight: ConvertedWeight?
    private var convertedHeight: ConvertedHeight?
    /// Height text that did not read as a number, as it stands in each unit, so switching back shows it as typed.
    private var carriedHeight: (metric: String, feet: String, inches: String)?
    /// The drafts exactly as the last estimate wrote them, so a pace change can tell untouched drafts from edited ones.
    private var estimatedTargets: [String: String]?

    public init(goals: GoalsViewModel, now: @escaping () -> Date = { Date() }, calendar: Calendar = .current) {
        self.goals = goals
        self.now = now
        self.calendar = calendar
        self.textUnitSystem = goals.unitSystem
        fillHeightFromHealth()
    }

    /// Fills the height field from Apple Health when it is empty, so a person who connected Health need not
    /// type it. Runs when the sheet opens and again on the body step, in case Today's read arrived since. A
    /// height that, once rounded for the field, is outside the range the estimate accepts is left out.
    func fillHeightFromHealth() {
        guard !filledHeightFromHealth,
              heightCentimetersText.isEmpty, heightFeetText.isEmpty, heightInchesText.isEmpty,
              let centimeters = goals.latestHeightCentimeters()
        else { return }
        if unitSystem == .usCustomary {
            let totalInches = Self.rounded(centimeters / Self.centimetersPerInch, scale: 0, .plain)
            let least = Self.rounded(Decimal(120) / Self.centimetersPerInch, scale: 0, .up)
            let most = Self.rounded(Decimal(230) / Self.centimetersPerInch, scale: 0, .down)
            guard totalInches >= least, totalInches <= most else { return }
            let feet = Self.rounded(totalInches / 12, scale: 0, .down)
            heightFeetText = DecimalFormatting.text(feet)
            heightInchesText = DecimalFormatting.text(totalInches - feet * 12)
            filledHeightFromHealth = true
        } else {
            let whole = Self.rounded(centimeters, scale: 0, .plain)
            guard whole >= 120, whole <= 230 else { return }
            heightCentimetersText = DecimalFormatting.text(whole)
            filledHeightFromHealth = true
        }
    }

    /// The unit system the answers are asked in.
    public var unitSystem: UnitSystem { goals.unitSystem }

    /// Moves the typed current and goal weights and the height into the unit system now in force, so a value
    /// typed in one unit shows in the other. The sheet calls it when the unit system changes, and `save()`
    /// calls it first. Weights show one decimal place, as the Body screen shows them; the height shows whole
    /// centimeters, or whole inches with feet. The exact kilograms and centimeters are kept with the text, so a
    /// switch back or a save uses the value the person typed, not the rounded text. The selected pace moves to
    /// the nearest option in the new unit, so a pace stays selected.
    public func unitSystemDidChange() {
        let pounds = unitSystem == .usCustomary
        guard pounds != (textUnitSystem == .usCustomary) else { return }
        let wasPounds = !pounds
        let current = Self.displayed(
            Self.kilograms(
                typed: wasPounds ? weightPoundsText : weightKilogramsText, pounds: wasPounds,
                known: convertedCurrentWeight),
            pounds: pounds)
        let goal = Self.displayed(
            Self.kilograms(
                typed: wasPounds ? goalWeightPoundsText : goalWeightKilogramsText, pounds: wasPounds,
                known: convertedGoalWeight),
            pounds: pounds)
        let height = Self.displayedHeight(
            wasPounds
                ? Self.centimeters(feetText: heightFeetText, inchesText: heightInchesText, known: convertedHeight)
                : Self.centimeters(metricText: heightCentimetersText, known: convertedHeight))
        // Text that does not read as a number is carried over as typed, so the person sees it and can fix it.
        if pounds {
            weightPoundsText = current?.text ?? weightKilogramsText
            goalWeightPoundsText = goal?.text ?? goalWeightKilogramsText
            if let height {
                carriedHeight = nil
                heightFeetText = height.feetText
                heightInchesText = height.inchesText
            } else if let carried = carriedHeight, carried.metric == heightCentimetersText,
                      carried.feet == heightFeetText, carried.inches == heightInchesText {
                (heightFeetText, heightInchesText) = (carried.feet, carried.inches)
            } else {
                carriedHeight = (metric: heightCentimetersText, feet: heightCentimetersText, inches: "")
                (heightFeetText, heightInchesText) = (heightCentimetersText, "")
            }
        } else {
            weightKilogramsText = current?.text ?? weightPoundsText
            goalWeightKilogramsText = goal?.text ?? goalWeightPoundsText
            if let height {
                carriedHeight = nil
                heightCentimetersText = height.centimetersText
            } else if let carried = carriedHeight, carried.feet == heightFeetText, carried.inches == heightInchesText {
                heightCentimetersText = carried.metric
            } else {
                // The feet and inches keep their units, so the carried text never reads as centimeters.
                let metric = [(heightFeetText, "ft"), (heightInchesText, "in")].filter { !$0.0.isEmpty }
                    .map { "\($0.0) \($0.1)" }.joined(separator: " ")
                carriedHeight = (metric: metric, feet: heightFeetText, inches: heightInchesText)
                heightCentimetersText = metric
            }
        }
        convertedCurrentWeight = current
        convertedGoalWeight = goal
        convertedHeight = height
        // The pace is kilograms and the options differ by unit, so the pace becomes the option nearest to it in
        // the unit now in force. Each unit's four options are the same steps, slowest to fastest, and the
        // nearest kilogram value lands on the same step in the other unit (1 lb, 0.45 kg, is nearest 0.5 kg).
        let previousPace = selectedPaceKilograms
        if let pace = selectedPaceKilograms,
           let nearest = paceOptions.min(by: { abs($0.kilogramsPerWeek - pace) < abs($1.kilogramsPerWeek - pace) }) {
            selectedPaceKilograms = nearest.kilogramsPerWeek
        }
        textUnitSystem = unitSystem
        // At the results step the drafts were estimated for the old pace. Estimate them again for the new pace;
        // a draft the person edited (its text differs from the old estimate) is kept as typed.
        if step == .results, selectedPaceKilograms != previousPace, let estimated = estimatedTargets {
            let edited = draftTargets.filter { estimated[$0.key] != $0.value }
            let notices = (fields: fieldErrors, result: resultError)
            calculate()
            if !draftTargets.isEmpty {
                for (key, text) in edited { draftTargets[key] = text }
                // A field whose text is unchanged keeps the notice a save gave it: an edited draft, or a field
                // the estimate does not write. A draft the estimate rewrote starts without one.
                let kept = notices.fields.filter { edited[$0.key] != nil || draftTargets[$0.key] == nil }
                fieldErrors.merge(kept) { _, saved in saved }
                // The notice for fields that cannot be saved comes back only with a field it names; any other
                // notice from a save, such as a failed write, still applies after the switch.
                if resultError == nil, let result = notices.result, result != Self.fieldsNotice || !kept.isEmpty {
                    resultError = result
                }
            }
        }
    }

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

    /// What the About step still needs before Next works, named in the words of the fields. Nil when nothing is missing.
    public var aboutMissingNotice: String? {
        switch (sex == nil, ageYears() == nil) {
        case (true, true): return Self.missingSexAndAgeNotice
        case (true, false): return Self.missingSexNotice
        case (false, true): return Self.missingAgeNotice
        case (false, false): return nil
        }
    }

    public static let missingSexNotice = "Choose your sex to continue."
    public static let missingAgeNotice = "Enter your age to continue."
    public static let missingSexAndAgeNotice = "Choose your sex and enter your age to continue."

    /// Whether the screen's Next button may move on. The results screen has its own save.
    public var canGoNext: Bool {
        switch step {
        case .aim: return aim != nil
        case .about: return sex != nil && ageYears() != nil
        case .body: return heightCentimeters() != nil && weightKilograms() != nil
        case .activity: return activity != nil
        case .pace: return selectedPaceKilograms != nil && goalWeightKilograms() != nil && goalWeightNotice == nil
        case .results: return false
        }
    }

    /// What is wrong with the goal weight, in plain words, or nil when it is fine or not asked for. Only a
    /// loss or a gain asks for one, and a blank field is not yet a problem.
    public var goalWeightNotice: String? {
        guard aim == .lose || aim == .gain else { return nil }
        let text = unitSystem == .usCustomary ? goalWeightPoundsText : goalWeightKilogramsText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let goal = goalWeightKilograms(), goal > 0 else { return Self.invalidFieldNotice }
        guard GoalEstimator.weightRangeKilograms.contains(goal) else {
            guard unitSystem == .usCustomary else { return "Check your goal weight. It must be between 30 and 300 kg." }
            let least = Self.rounded(Decimal(30) / Self.kilogramsPerPound, scale: 0, .up)
            let most = Self.rounded(Decimal(300) / Self.kilogramsPerPound, scale: 0, .down)
            return "Check your goal weight. It must be between \(DecimalFormatting.text(least)) and \(DecimalFormatting.text(most)) lb."
        }
        guard let current = weightKilograms() else { return nil }
        if aim == .lose && goal >= current { return Self.goalWeightBelowNotice }
        if aim == .gain && goal <= current { return Self.goalWeightAboveNotice }
        return nil
    }

    public static let vitaminRecommendedTitle = "Use recommended amounts"
    public static let vitaminOwnTitle = "Set my own"
    public static let vitaminSourceNotice =
        "From the Dietary Reference Intakes (NIH). Vitamins A, D and E are yours to set, since labels often list them in IU."
    public static let vitaminNoGroupNotice = "Add your age and sex to prefill these."

    /// The published reference group for the answers given, or nil without a sex (or with "unspecified") or
    /// an age the tables cover.
    public var referenceGroup: ReferenceGroup? {
        guard let age = ageYears(), let band = ReferenceAgeBand(ageYears: age) else { return nil }
        switch sex {
        case .female: return ReferenceGroup(sex: .female, ageBand: band)
        case .male: return ReferenceGroup(sex: .male, ageBand: band)
        case .unspecified, nil: return nil
        }
    }

    /// "Prefilled for men 31 to 50. You can change any of them.", or nil without a group or with nothing left
    /// to prefill (every covered vitamin and mineral already has a goal).
    public var vitaminPrefillNotice: String? {
        guard let label = referenceGroup?.label, !vitaminPrefill.isEmpty else { return nil }
        return "Prefilled for \(label.prefix(1).lowercased() + label.dropFirst()). You can change any of them."
    }

    /// Whether to ask for the answers the prefill needs: only when age or sex is missing. Someone who answered
    /// "unspecified" did answer, and the tables publish no row for them, so nothing is asked and no section shows.
    public var vitaminShowsNoGroupNotice: Bool {
        sex == nil || ageYears() == nil
    }

    /// The reference values the step offers: one per covered vitamin or mineral without a goal already, read
    /// from the Goals screen's rows and from the store itself, so a goal is skipped even when the rows did not load.
    public var vitaminPrefill: [NutrientGoal] {
        let existing = Set(goals.rows.compactMap { $0.targetText == nil ? nil : $0.nutrient })
        return ReferenceGoalPrefill.goals(for: referenceGroup, existingGoalKeys: existing)
            .filter { !storeHoldsGoal(for: $0.nutrient) }
    }

    /// Whether the store holds a goal for this nutrient under its own key or an alias (`vitamin-c`). For what
    /// the step shows, a store that cannot be read counts as holding one, so nothing is offered over a goal that
    /// may exist; the save reads again with `storedGoalExists(for:)` and fails instead.
    private func storeHoldsGoal(for nutrient: String) -> Bool {
        (try? storedGoalExists(for: nutrient)) ?? true
    }

    /// The same check, throwing when the store cannot be read.
    private func storedGoalExists(for nutrient: String) throws -> Bool {
        for key in HealthKitWritePlanner.acceptedKeys(for: nutrient) {
            if try goals.storedGoal(for: key) != nil { return true }
        }
        return false
    }

    /// Picks how vitamins and minerals are saved. "Set my own" fills the fields with the reference values
    /// the first time, and keeps any edits after that.
    public func chooseVitamins(_ choice: VitaminGoalChoice) {
        vitaminChoice = choice
        if choice == .own, vitaminDrafts.isEmpty {
            vitaminDrafts = Dictionary(
                uniqueKeysWithValues: vitaminPrefill.map { ($0.nutrient, DecimalFormatting.text($0.target)) })
        }
    }

    /// The vitamin and mineral goals a save writes: the reference values, or the person's own text with a
    /// cleared field left out. Nothing without a choice.
    private func vitaminGoalsToSave() -> [(nutrient: String, text: String, unit: MeasureUnit)] {
        guard let choice = vitaminChoice else { return [] }
        return vitaminPrefill.compactMap { goal -> (nutrient: String, text: String, unit: MeasureUnit)? in
            switch choice {
            case .recommended:
                return (goal.nutrient, DecimalFormatting.text(goal.target), goal.unit)
            case .own:
                let text = (vitaminDrafts[goal.nutrient] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : (goal.nutrient, text, goal.unit)
            }
        }
    }

    /// Forgets the vitamins and minerals choice and its fields, for answers that may have changed the group.
    private func clearVitaminChoice() {
        vitaminChoice = nil
        vitaminDrafts = [:]
    }

    public func next() {
        guard canGoNext else { return }
        let list = steps
        guard let index = list.firstIndex(of: step), index + 1 < list.count else { return }
        step = list[index + 1]
        if step == .body { fillHeightFromHealth() }
        if step == .results { calculate() }
    }

    public func back() {
        let list = steps
        guard let index = list.firstIndex(of: step), index > 0 else { return }
        if step == .results {
            clearVitaminChoice()
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
        unitSystemDidChange()
        guard aim != .justTrack, step == .results, !draftTargets.isEmpty else { return false }
        fieldErrors = [:]
        for key in Self.targetKeys {
            let text = (draftTargets[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if let value = AmountParser.parseTyped(text), value > 0 { continue }
            fieldErrors[key] = Self.invalidFieldNotice
        }
        // A goal the store holds, under the key or an alias, is never overwritten; checked again here because the
        // store may have changed since the step was shown. A store that cannot be read fails the whole save.
        let vitamins: [(nutrient: String, text: String, unit: MeasureUnit)]
        do {
            vitamins = try vitaminGoalsToSave().filter { try !storedGoalExists(for: $0.nutrient) }
        } catch {
            resultError = Self.saveFailedNotice
            return false
        }
        for entry in vitamins {
            if let value = AmountParser.parseTyped(entry.text), value > 0 { continue }
            fieldErrors[entry.nutrient] = Self.invalidFieldNotice
        }
        guard fieldErrors.isEmpty else {
            resultError = Self.fieldsNotice
            return false
        }
        resultError = nil
        let planStore = goals.weightPlanStore
        let plan = planStore == nil ? nil : makeWeightPlan()
        if let plan {
            // The goal is checked against the weight as it reads now, so a weight changed after the
            // results cannot leave a plan the estimate was not made for. Nothing is written before this.
            guard let current = weightKilograms() else {
                resultError = Self.genericErrorNotice
                return false
            }
            do {
                try plan.validate(currentKilograms: current)
            } catch WeightPlanError.goalNotBelowCurrent {
                resultError = Self.goalWeightBelowNotice
                return false
            } catch WeightPlanError.goalNotAboveCurrent {
                resultError = Self.goalWeightAboveNotice
                return false
            } catch {
                resultError = Self.genericErrorNotice
                return false
            }
        }
        var before: [(nutrient: String, goal: NutrientGoal?)] = []
        do {
            for key in Self.targetKeys + vitamins.map({ $0.nutrient }) {
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
        for (offset, entry) in vitamins.enumerated() {
            attempted.append(before[Self.targetKeys.count + offset])
            guard goals.setTarget(entry.text, for: entry.nutrient, unit: entry.unit) else {
                var restored = true
                // The write that failed changed nothing, so only the ones before it are put back.
                for earlier in attempted.dropLast().reversed() {
                    if !goals.restoreGoal(earlier.goal, for: earlier.nutrient) { restored = false }
                }
                resultError = restored ? Self.saveFailedNotice : Self.saveRestoreFailedNotice
                return false
            }
        }
        if let plan, let planStore {
            do {
                try planStore.setWeightPlan(plan)
            } catch {
                // The plan is the last write, so every target written above is put back, newest first.
                var restored = true
                for entry in before.reversed() {
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
        for entry in vitamins {
            goals.draftText[entry.nutrient] = DecimalFormatting.text(AmountParser.parseTyped(entry.text) ?? 0)
            goals.selectedUnits[entry.nutrient] = entry.unit
            goals.clearRowError(for: entry.nutrient)
        }
        return true
    }

    /// The weight plan for the aim as it is saved: a loss or gain keeps the typed goal and pace, a
    /// maintenance keeps neither, and just tracking keeps no plan.
    private func makeWeightPlan() -> WeightPlan? {
        guard let aim else { return nil }
        switch aim {
        case .lose, .gain:
            return WeightPlan(aim: aim, goalKilograms: goalWeightKilograms(), weeklyPaceKilograms: selectedPaceKilograms)
        case .maintain:
            return WeightPlan(aim: aim, goalKilograms: nil, weeklyPaceKilograms: nil)
        case .justTrack:
            return nil
        }
    }

    /// Empties every answer and returns to the first step. Called when the sheet closes, so nothing a
    /// person typed outlives the sheet.
    public func clearAnswers() {
        step = .aim
        carriedHeight = nil
        aim = nil
        sex = nil
        ageText = ""
        heightCentimetersText = ""
        heightFeetText = ""
        heightInchesText = ""
        weightKilogramsText = ""
        weightPoundsText = ""
        goalWeightKilogramsText = ""
        goalWeightPoundsText = ""
        convertedCurrentWeight = nil
        convertedGoalWeight = nil
        convertedHeight = nil
        textUnitSystem = unitSystem
        activity = nil
        selectedPaceKilograms = nil
        clearVitaminChoice()
        draftTargets = [:]
        resultError = nil
        fieldErrors = [:]
        adjustmentNote = nil
        // A cleared sheet is a fresh start, so Health's height may fill it again.
        filledHeightFromHealth = false
        fillHeightFromHealth()
    }

    /// Estimates the results from the answers, filling the drafts the person may then edit.
    private func calculate() {
        draftTargets = [:]
        estimatedTargets = nil
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
            estimatedTargets = draftTargets
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
            return Self.centimeters(feetText: heightFeetText, inchesText: heightInchesText, known: convertedHeight)
        }
        return Self.centimeters(metricText: heightCentimetersText, known: convertedHeight)
    }

    /// The centimeters a centimeter field stands for. A field still showing the text of a switch keeps the exact
    /// centimeters that text was converted from; any other text is read as typed.
    private static func centimeters(metricText: String, known: ConvertedHeight?) -> Decimal? {
        if let known, known.centimetersText == metricText { return known.centimeters }
        return AmountParser.parseTyped(metricText)
    }

    /// The centimeters that feet and inches stand for. A field still showing the text of a switch keeps the exact
    /// centimeters that text was converted from; any other text is read as feet and inches.
    private static func centimeters(feetText: String, inchesText: String, known: ConvertedHeight?) -> Decimal? {
        if let known, known.feetText == feetText, known.inchesText == inchesText { return known.centimeters }
        guard let feet = wholeOrZero(feetText), let inches = inchesOrNone(inchesText) else { return nil }
        return (feet * 12 + inches) * centimetersPerInch
    }

    /// A height shown in the unit system now in force, with the centimeters it was converted from. Centimeters
    /// round to whole centimeters, and inches round to whole inches, as the height from Health does.
    private static func displayedHeight(_ centimeters: Decimal?) -> ConvertedHeight? {
        guard let centimeters else { return nil }
        let totalInches = rounded(centimeters / centimetersPerInch, scale: 0, .plain)
        let feet = rounded(totalInches / 12, scale: 0, .down)
        return (
            centimeters: centimeters,
            centimetersText: DecimalFormatting.text(rounded(centimeters, scale: 0, .plain)),
            feetText: DecimalFormatting.text(feet),
            inchesText: DecimalFormatting.text(totalInches - feet * 12))
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

    /// "Plan reaches 75 kg on Jun 24, 2026" for the pace step: the day the chosen pace reaches the goal
    /// weight, counted from today in the calendar's time zone. Nil until a loss or gain has a pace, a valid
    /// goal weight and a day that can be reached.
    public var paceGoalDayText: String? {
        guard aim == .lose || aim == .gain, let pace = selectedPaceKilograms,
              let current = weightKilograms(), let goal = goalWeightKilograms(), goalWeightNotice == nil
        else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: now())
        guard let today = CalendarDay(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0),
              let day = PlanProjection.goalDay(
                currentKilograms: current, goalKilograms: goal, weeklyPaceKilograms: pace, from: today)
        else { return nil }
        let typed = unitSystem == .usCustomary ? goalWeightPoundsText : goalWeightKilogramsText
        guard let amount = AmountParser.parseTyped(typed) else { return nil }
        let goalText = BodyActivityViewModel.oneDecimal(amount) + (unitSystem == .usCustomary ? " lb" : " kg")
        return "Plan reaches \(goalText) on \(BodyActivityViewModel.dayText(day))"
    }

    private func weightKilograms() -> Decimal? {
        let pounds = unitSystem == .usCustomary
        return Self.kilograms(
            typed: pounds ? weightPoundsText : weightKilogramsText, pounds: pounds, known: convertedCurrentWeight)
    }

    /// The goal weight in kilograms, read in the unit system's field, with no range check.
    private func goalWeightKilograms() -> Decimal? {
        let pounds = unitSystem == .usCustomary
        return Self.kilograms(
            typed: pounds ? goalWeightPoundsText : goalWeightKilogramsText, pounds: pounds, known: convertedGoalWeight)
    }

    /// The kilograms a weight field stands for. A field still showing the text of a switch keeps the exact
    /// kilograms that text was converted from; any other text is read in the field's unit.
    private static func kilograms(typed text: String, pounds: Bool, known: ConvertedWeight?) -> Decimal? {
        if let known, known.text == text { return known.kilograms }
        guard let value = AmountParser.parseTyped(text) else { return nil }
        return pounds ? value * kilogramsPerPound : value
    }

    /// A weight shown in the unit system now in force, with the kilograms it was converted from.
    private static func displayed(_ kilograms: Decimal?, pounds: Bool) -> ConvertedWeight? {
        guard let kilograms else { return nil }
        let shown = pounds ? kilograms / kilogramsPerPound : kilograms
        return (text: BodyActivityViewModel.oneDecimal(shown), kilograms: kilograms)
    }
}
