import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The words the screens show for captured, looked-up and logged values. The panels are synthetic and name no real product.
@MainActor
final class WordingPassTests: XCTestCase {
    /// A capture whose sodium the parser read with a letter `O` in it, so the row is flagged.
    private var panelWithFlaggedSodium: [String] {
        [
            "Nutrition Facts",
            "Synthetic Soup, invented for tests",
            "Serving size 1 cup (240mL)",
            "Amount per serving",
            "Calories 180",
            "Total Fat 4g 6%",
            "Sodium 18O mg 8%",
            "Protein 8g 16%",
        ]
    }

    // MARK: Label review words

    func testDisplayTextUsesTheLabelWords() {
        XCTAssertEqual(LabelCaptureRow.displayText(.known(Decimal(180), MeasureUnit.mg)), "180 mg")
        XCTAssertEqual(LabelCaptureRow.displayText(.unknown), "Not on the label")
        XCTAssertEqual(LabelCaptureRow.displayText(.notApplicable), "Does not apply")
        XCTAssertEqual(LabelCaptureRow.displayText(.belowReportingThreshold(MeasureUnit.mg)), "Less than the label reports (mg)")
        XCTAssertEqual(LabelCaptureRow.displayText(.belowReportingThreshold(nil)), "Less than the label reports")
    }

    /// The old words are stored in snapshot ids and row ids, so the signature functions must keep them.
    func testSignatureDescribeIsUnchangedForLabelRowsAndLookups() {
        XCTAssertEqual(LabelCaptureRow.describe(.known(Decimal(180), MeasureUnit.mg)), "180 mg")
        XCTAssertEqual(LabelCaptureRow.describe(.unknown), "not on the panel")
        XCTAssertEqual(LabelCaptureRow.describe(.notApplicable), "not applicable")
        XCTAssertEqual(LabelCaptureRow.describe(.belowReportingThreshold(MeasureUnit.mg)), "below reporting threshold mg")

        XCTAssertEqual(LookedUpProduct.describe(.known(Decimal(180), MeasureUnit.mg)), "180 mg")
        XCTAssertEqual(LookedUpProduct.describe(.unknown), "unknown")
        XCTAssertEqual(LookedUpProduct.describe(.notApplicable), "not applicable")
        XCTAssertEqual(LookedUpProduct.describe(.belowReportingThreshold(MeasureUnit.mg)), "below reporting threshold mg")
    }

    func testShownTextUsesTheLabelWordsForLookedUpValues() {
        XCTAssertEqual(LookedUpProduct.shownText(.known(Decimal(180), MeasureUnit.mg)), "180 mg")
        XCTAssertEqual(LookedUpProduct.shownText(.unknown), "Not on the label")
        XCTAssertEqual(LookedUpProduct.shownText(.notApplicable), "Does not apply")
        XCTAssertEqual(LookedUpProduct.shownText(.belowReportingThreshold(MeasureUnit.mg)), "Less than the label reports (mg)")
        XCTAssertEqual(LookedUpProduct.shownText(.belowReportingThreshold(nil)), "Less than the label reports")
    }

    /// An unreadable capture asks for nothing: the user retakes it, so the title stays neutral.
    func testPrimaryActionTitleStaysNeutralForAnUnreadableCapture() {
        let model = LabelCaptureViewModel()
        model.load(lines: ["Synthetic Brand, invented for tests", "Best before 2027"])
        XCTAssertTrue(model.isUnreadable)
        XCTAssertFalse(model.canApply)
        XCTAssertEqual(model.primaryActionTitle, "Use these values")
        XCTAssertEqual(LabelCaptureViewModel().primaryActionTitle, "Use these values")
    }

    /// A value the product states but the amount cannot be scaled to reads as a sentence, not "Not on the label".
    func testThisAddsSaysWhenAnAmountCannotBeWorkedOut() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let model = AddIntakeViewModel(
            store: try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store")),
            now: Date(timeIntervalSince1970: 1_700_000_000))
        model.applyLabelProduct(ProductDefinition(snapshotID: "wording-label", productID: "example-oats",
            name: "Example oats", labelBasis: "per serving", catalogOrigin: "label", catalogVersion: "1",
            nutrients: ["protein": .known(13, .g)]))
        model.amountText = "40"

        let protein = try XCTUnwrap(model.thisAdds.first { $0.key == "protein" })
        XCTAssertEqual(protein.cannotScale, true)
        XCTAssertEqual(protein.text, "Can't be worked out for this amount")

        // Energy is not stated, so it has no line to word.
        XCTAssertFalse(model.thisAdds.contains { $0.key == "energyKcal" })
    }

    func testPrimaryActionTitleCountsPendingValues() {
        let none = LabelCaptureViewModel()
        none.load(lines: ["Serving size 1 cup (240mL)", "Calories 120", "Protein 3g"])
        XCTAssertEqual(none.pendingCount, 0)
        XCTAssertTrue(none.canApply)
        XCTAssertEqual(none.primaryActionTitle, "Use these values")

        let one = LabelCaptureViewModel()
        one.load(lines: panelWithFlaggedSodium)
        XCTAssertEqual(one.pendingCount, 1)
        XCTAssertFalse(one.canApply)
        XCTAssertEqual(one.primaryActionTitle, "Confirm 1 value first")

        // A flagged serving size and a flagged sodium are two values waiting for the user.
        let two = LabelCaptureViewModel()
        two.load(lines: [
            "Nutrition Facts",
            "Synthetic Soup, invented for tests",
            "Serving size 1 cup (24O mL)",
            "Amount per serving",
            "Calories 120",
            "Sodium 18O mg 8%",
            "Protein 3g 6%",
        ])
        XCTAssertEqual(two.pendingCount, 2)
        XCTAssertFalse(two.canApply)
        XCTAssertEqual(two.primaryActionTitle, "Confirm 2 values first")
    }

    func testServingPromptAsksInPlainWords() throws {
        XCTAssertEqual(LabelCaptureViewModel.servingQuestion("240 mL"), "We read this as 240 mL. Is that right?")

        let model = LabelCaptureViewModel()
        model.load(lines: [
            "Serving size 1 cup (24O mL)",
            "Calories 120",
            "Protein 3g",
        ])
        XCTAssertTrue(model.servingNeedsReview)
        let servingText = try XCTUnwrap(model.servingText)
        XCTAssertEqual(model.servingPrompt, LabelCaptureViewModel.servingQuestion(
            LabelCaptureViewModel.servingReading(quantity: model.servingQuantity, text: servingText)))
    }

    /// The serving question names the quantity the parser settled on, so a serving printed as "24O mL"
    /// is asked about as 240 mL, and a serving with no quantity is asked about as its own words.
    func testServingQuestionShowsTheCorrectedQuantity() throws {
        XCTAssertEqual(
            LabelCaptureViewModel.servingReading(quantity: Quantity(value: 240, unit: .mL), text: "1 cup (240 mL)"),
            "240 mL")
        XCTAssertEqual(
            LabelCaptureViewModel.servingReading(quantity: nil, text: "  1 cup (240 mL)  "),
            "1 cup (240 mL)")
        XCTAssertEqual(LabelCaptureViewModel.servingReading(quantity: nil, text: "   "), "this serving size")
        XCTAssertEqual(LabelCaptureViewModel.servingReading(quantity: nil, text: nil), "this serving size")

        let model = LabelCaptureViewModel()
        model.load(lines: [
            "Serving size 1 cup (24O mL)",
            "Calories 120",
            "Protein 3g",
        ])
        let quantity = try XCTUnwrap(model.servingQuantity)
        XCTAssertEqual(quantity.value, Decimal(240))
        XCTAssertEqual(quantity.unit, MeasureUnit.mL)
        XCTAssertEqual(model.servingPrompt, LabelCaptureViewModel.servingQuestion("240 mL"))
    }

    // MARK: Entry words

    /// A label-capture entry whose snapshot states one nutrient below the reporting threshold. Synthetic.
    func testEntryScreenShowsABoundInTheLabelWords() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try SwiftDataJournalStore(url: try uiTempURL(self, "wording-entry.store"))
        let product = ProductDefinition(
            snapshotID: "wording-threshold", productID: "label_capture", name: "Example bar",
            labelBasis: "per serving (30 g)", catalogOrigin: ProductOrigin.label_capture, catalogVersion: "unknown",
            nutrients: [
                "creatine-monohydrate": .known(Decimal(3), MeasureUnit.g),
                "synthetic-trace": .belowReportingThreshold(MeasureUnit.mg),
            ])
        let id = UUID().uuidString.lowercased()
        try store.create(
            Intake(id: id, category: "food", occurredAt: now, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "example-oats", name: "Example oats", amount: 40, unit: .g)],
            product: product, now: now)

        let model = EntryDetailViewModel(store: store, intakeID: id, timeZoneIdentifier: "UTC")
        model.load(now: now)

        let trace = model.allValues.first { $0.key == "synthetic-trace" }
        XCTAssertEqual(trace?.amountText, "Less than the label reports (mg)")
    }

    // MARK: Recipe words

    func testRecipeLabelsSayMakesAndCountedAs() {
        XCTAssertEqual(RecipeLabels.yieldAmountField, "How much it makes")
        XCTAssertEqual(RecipeLabels.yieldKindPicker, "Counted as")
    }

    func testRecipeProblemSentencesUseTheMakesWords() throws {
        let store = try SwiftDataRecipeStore(url: try uiTempURL(self, "wording-recipes.store"))
        func filledModel() -> RecipeEditorViewModel {
            let model = RecipeEditorViewModel(store: store, makeID: { "recipe-wording" })
            model.title = "Oat bake"
            model.ingredients[0].name = "Oat flour"
            model.ingredients[0].amountText = "200"
            model.yieldAmountText = "4"
            return model
        }

        let density = filledModel()
        density.ingredients[0].densityText = "heavy"
        XCTAssertFalse(density.save(now: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertTrue(density.messages.contains(
            "Ingredient 1: weight per mL must be greater than zero, using digits and a point."))

        let unit = filledModel()
        unit.yieldKind = .total
        unit.yieldUnitSymbol = "pinch"
        XCTAssertFalse(unit.save(now: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertTrue(unit.messages.contains("Choose a known unit for what the recipe makes."))

        let amount = filledModel()
        amount.yieldAmountText = "0"
        XCTAssertFalse(amount.save(now: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertTrue(amount.messages.contains(
            "Enter how much the recipe makes, greater than zero, using digits and a point."))
        XCTAssertEqual(
            RecipeEditorViewModel.message(for: .nonPositiveYield),
            "Enter how much the recipe makes, greater than zero, using digits and a point.")

        XCTAssertEqual(
            RecipeEditorViewModel.message(for: .duplicateIngredientID("oat-flour")),
            "Two ingredients are the same entry. Remove one and add it again.")
    }
}
