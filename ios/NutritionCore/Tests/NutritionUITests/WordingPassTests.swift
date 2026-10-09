import Foundation
import NutritionDomain
import NutritionJournal
import XCTest
@testable import NutritionUI

/// The words the design pass shows on screen. The panels are synthetic and name no real product.
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
        XCTAssertEqual(LabelCaptureRow.displayText(.belowReportingThreshold(MeasureUnit.mg)), "Less than the label reports")
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
            "Serving size 1 cup (24O mL)",
            "Calories 120",
            "Sodium 18O mg 8%",
            "Protein 3g",
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
        XCTAssertEqual(model.servingPrompt, LabelCaptureViewModel.servingQuestion(servingText))
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
