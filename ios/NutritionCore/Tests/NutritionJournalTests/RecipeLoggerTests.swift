import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

final class RecipeLoggerTests: XCTestCase {
    private let intakeID = "0b6f7d3e-5a1c-4c52-9a2e-3f1d8c7b6a10"
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeJournal() throws -> SwiftDataJournalStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SwiftDataJournalStore(url: directory.appendingPathComponent("journal.store"))
    }

    /// The snapshot the intake's first revision names.
    private func loggedProduct(_ journal: SwiftDataJournalStore, intakeID: String? = nil) throws -> ProductDefinition {
        let snapshotID = try XCTUnwrap(try journal.revisions(of: intakeID ?? self.intakeID)[0].productSnapshotID)
        return try XCTUnwrap(try journal.product(snapshotID: snapshotID))
    }

    /// One intake, one revision, ONE component named after the recipe: the recipe the user chose,
    /// not a list of nutrients.
    func testLogCreatesOneIntakeWithOneComponentNamedAfterTheRecipe() throws {
        let journal = try makeJournal()
        let id = try RecipeLogger.logPortion(
            store: journal, version: sampleVersion(), portion: 1, now: when, id: intakeID,
            timeZoneIdentifier: "UTC", meal: "dinner")
        XCTAssertEqual(id, intakeID)
        XCTAssertEqual(try journal.activeIntakes().count, 1)
        let revisions = try journal.revisions(of: intakeID)
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(revisions[0].productSnapshotID, "recipe:recipe-1:v1")
        XCTAssertEqual(revisions[0].components.count, 1)
        XCTAssertEqual(revisions[0].components[0].name, "Oat bake")
        XCTAssertEqual(revisions[0].components[0].amount, 1)
        XCTAssertEqual(revisions[0].components[0].unit, .serving)
        let product: ProductDefinition? = try loggedProduct(journal)
        XCTAssertEqual(product?.catalogOrigin, "recipe_calculated")
        XCTAssertEqual(product?.catalogVersion, "1")
        XCTAssertEqual(product?.productID, "recipe-1")
        XCTAssertEqual(try journal.activeIntakes().first?.category, "recipe")
    }

    /// The snapshot carries the per-serving values, so a later reader resolves the recipe's nutrients
    /// from the product rather than from one component per nutrient.
    func testSnapshotCarriesThePerServingNutrients() throws {
        let journal = try makeJournal()
        let version = sampleVersion(
            ingredients: [
                sampleIngredient(
                    "oat-flour", amount: "200",
                    perUnit: ["energy": .known(dec("3.6"), .kcal), "protein": .known(dec("0.13"), .g)]),
            ], yield: .servings(4))
        try RecipeLogger.logPortion(
            store: journal, version: version, portion: 1, now: when, id: intakeID, timeZoneIdentifier: "UTC", meal: nil)
        let product = try loggedProduct(journal)
        // 200 g of oat flour over 4 servings.
        XCTAssertEqual(product.value(for: "energy"), .known(dec("180"), .kcal))
        XCTAssertEqual(product.value(for: "protein"), .known(dec("6.5"), .g))
    }

    /// An unknown nutrient is stored as unknown in the snapshot, never as a zero the totals would read.
    func testUnknownNutrientsStayUnknownInTheSnapshotAndAreNotComponents() throws {
        let journal = try makeJournal()
        let version = sampleVersion(
            ingredients: [
                sampleIngredient("a", amount: "10", perUnit: ["energy": .known(2, .kcal), "protein": .known(1, .g)]),
                sampleIngredient("b", amount: "10", perUnit: ["energy": .known(2, .kcal)]),
            ], yield: .servings(1))
        try RecipeLogger.logPortion(
            store: journal, version: version, portion: 1, now: when, id: intakeID, timeZoneIdentifier: "UTC", meal: nil)
        let revision = try journal.revisions(of: intakeID)[0]
        XCTAssertEqual(revision.components.count, 1)
        XCTAssertEqual(revision.components[0].name, "Oat bake")
        let product = try loggedProduct(journal)
        XCTAssertEqual(product.value(for: "energy"), .known(40, .kcal))
        XCTAssertEqual(product.value(for: "protein"), .unknown)
    }

    /// A known zero is a value like any other: it stays a zero in the snapshot and does not become a
    /// component with a zero amount the entry editor could not read back.
    func testKnownZeroStaysZeroInTheSnapshotAndTheComponentKeepsThePortion() throws {
        let journal = try makeJournal()
        let version = sampleVersion(
            ingredients: [sampleIngredient("a", amount: "10", perUnit: ["sodium": .known(0, .mg)])],
            yield: .servings(2))
        try RecipeLogger.logPortion(
            store: journal, version: version, portion: 1, now: when, id: intakeID, timeZoneIdentifier: "UTC", meal: nil)
        let component = try journal.revisions(of: intakeID)[0].components[0]
        XCTAssertEqual(component.amount, 1)
        XCTAssertEqual(component.unit, .serving)
        let product = try loggedProduct(journal)
        XCTAssertEqual(product.value(for: "sodium"), .known(0, .mg))
    }

    /// A total yield logs the portion in the yield's own unit, so the component reads like any other
    /// amount of food.
    func testTotalYieldLogsThePortionInTheYieldsUnit() throws {
        let journal = try makeJournal()
        let version = sampleVersion(
            ingredients: [sampleIngredient("oat-flour", amount: "800", perUnit: energyPerUnit("3.6"))],
            yield: .total(Quantity(value: dec("0.8"), unit: .kg)))
        try RecipeLogger.logPortion(
            store: journal, version: version, portion: 200, now: when, id: intakeID,
            timeZoneIdentifier: "UTC", meal: nil, portionUnit: .g)
        let component = try journal.revisions(of: intakeID)[0].components[0]
        XCTAssertEqual(component.amount, dec("0.2"))
        XCTAssertEqual(component.unit, .kg)
    }

    /// A recipe can yield a counted thing rather than a serving — a batch of 30 gummies — and the
    /// snapshot states its values per gummy. The basis has to resolve to a count for that to scale:
    /// an unresolved basis states nothing at all, so the day totals, the Health samples and the relay
    /// batch would carry no protein at all for a recipe the person did log.
    func testACountedYieldScalesByTheNumberOfGummiesLogged() async throws {
        for (basis, unit, componentUnit) in [
            ("Per gummy; yield 25 gummy", MeasureUnit.gummy, MeasureUnit.gummy),
            ("Per piece; yield 25 piece", MeasureUnit.piece, MeasureUnit.piece),
        ] {
            let journal = try makeJournal()
            let version = sampleVersion(
                ingredients: [
                    sampleIngredient("a", amount: "300", perUnit: ["protein": .known(dec("0.5"), .g)]),
                ],
                yield: .total(Quantity(value: dec("25"), unit: unit)))
            try RecipeLogger.logPortion(
                store: journal, version: version, portion: 2, now: when, id: intakeID,
                timeZoneIdentifier: "UTC", meal: nil, portionUnit: componentUnit)
            let product = try loggedProduct(journal)
            XCTAssertEqual(product.labelBasis, basis)
            // 300 g of an ingredient carrying 0.5 g of protein per g is 150 g over 25 gummies: 6 g each.
            // (25 rather than 30: the recipe math scales by the reciprocal of the yield, and 1/25 is
            // an exact decimal where 1/30 is not, so the assertion can be exact.)
            XCTAssertEqual(product.value(for: "protein"), .known(dec("6"), .g), basis)

            let totals = JournalSnapshotTotals(store: journal)
            let recorded = try await totals.totals(intakeID: intakeID, revision: 1)
            XCTAssertEqual(recorded["protein"], .known(dec("12"), .g), "two of them: \(basis)")
        }
    }

    /// A version logged before vitamin D in IU was restated keeps its snapshot, stating IU, and logging
    /// the same version again writes a new snapshot in mcg instead of colliding with it.
    func testAVersionLoggedBeforeVitaminDWasRestatedLogsAgain() throws {
        let journal = try makeJournal()
        // 100 g at 4 IU/g over 4 servings: 100 IU, which is 2.5 mcg, per serving.
        let version = sampleVersion(ingredients: [
            sampleIngredient("drops", amount: "100", perUnit: ["vitaminD": .known(dec("4"), .iu)], basis: .g),
        ])
        let earlier = ProductDefinition(
            snapshotID: "recipe:recipe-1:v1", productID: "recipe-1", name: "Oat bake",
            labelBasis: RecipeLogger.basisText(version.yield), catalogOrigin: RecipeLogger.catalogOrigin,
            catalogVersion: "1", nutrients: ["vitaminD": .known(dec("100"), .iu)])
        let earlierID = "5c1e2d3f-0a4b-4c6d-8e9f-a0b1c2d3e4f5"
        let againID = "6d2f3e4a-1b5c-4d7e-9fa0-b1c2d3e4f5a6"
        try journal.create(
            Intake(id: earlierID, category: RecipeLogger.category, occurredAt: when, timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "recipe-recipe-1", name: "Oat bake", amount: 1, unit: .serving)],
            product: earlier, now: when)

        XCTAssertNoThrow(try RecipeLogger.logPortion(
            store: journal, version: version, portion: 1, now: when, id: intakeID, timeZoneIdentifier: "UTC"))
        XCTAssertNoThrow(try RecipeLogger.logPortion(
            store: journal, version: version, portion: 1, now: when, id: againID, timeZoneIdentifier: "UTC"))

        XCTAssertEqual(try loggedProduct(journal).value(for: "vitaminD"), .known(dec("2.5"), .mcg))
        // The earlier entry keeps the snapshot it was logged with, IU and all.
        XCTAssertEqual(try loggedProduct(journal, intakeID: earlierID).snapshotID, earlier.snapshotID)
        XCTAssertEqual(try loggedProduct(journal, intakeID: earlierID).value(for: "vitaminD"), .known(dec("100"), .iu))
        XCTAssertNotEqual(try loggedProduct(journal).snapshotID, earlier.snapshotID)
        // Logged twice with the same values, the version shares one snapshot.
        XCTAssertEqual(try loggedProduct(journal, intakeID: againID).snapshotID, try loggedProduct(journal).snapshotID)
    }

    func testAnUnchangedVersionLoggedAgainKeepsItsPlainSnapshotID() throws {
        let journal = try makeJournal()
        let againID = "7e3a4f5b-2c6d-4e8f-a0b1-c2d3e4f5a6b7"
        try RecipeLogger.logPortion(
            store: journal, version: sampleVersion(), portion: 1, now: when, id: intakeID, timeZoneIdentifier: "UTC")
        try RecipeLogger.logPortion(
            store: journal, version: sampleVersion(), portion: 2, now: when, id: againID, timeZoneIdentifier: "UTC")
        XCTAssertEqual(try loggedProduct(journal).snapshotID, "recipe:recipe-1:v1")
        XCTAssertEqual(try loggedProduct(journal, intakeID: againID).snapshotID, "recipe:recipe-1:v1")
    }

    func testTheDigestIDChangesOnlyWithWhatTheSnapshotHolds() {
        let basis = "Per serving; yield 4 servings"
        let values: [String: NutrientValue] = ["vitaminD": .known(dec("2.5"), .mcg), "energy": .unknown]
        let id = RecipeLogger.digestSnapshotID(recipeID: "recipe-1", number: 1, labelBasis: basis, nutrients: values)
        XCTAssertTrue(id.hasPrefix("recipe:recipe-1:v1:"))
        XCTAssertEqual(
            id, RecipeLogger.digestSnapshotID(recipeID: "recipe-1", number: 1, labelBasis: basis, nutrients: values))
        XCTAssertNotEqual(id, RecipeLogger.digestSnapshotID(
            recipeID: "recipe-1", number: 1, labelBasis: basis,
            nutrients: ["vitaminD": .known(dec("100"), .iu), "energy": .unknown]))
        XCTAssertNotEqual(id, RecipeLogger.digestSnapshotID(
            recipeID: "recipe-1", number: 1, labelBasis: "Per serving; yield 2 servings", nutrients: values))
    }

    func testNothingKnownThrowsAndWritesNothing() throws {
        let journal = try makeJournal()
        let version = sampleVersion(ingredients: [sampleIngredient("a", amount: "10", perUnit: [:])])
        XCTAssertThrowsError(try RecipeLogger.logPortion(
            store: journal, version: version, portion: 1, now: when, id: intakeID, timeZoneIdentifier: "UTC", meal: nil)
        ) { XCTAssertEqual($0 as? RecipeError, .nothingToLog) }
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
    }

    func testLoggedIntakeKeepsVersion1AfterVersion2Exists() throws {
        let journal = try makeJournal()
        let recipes = try SwiftDataRecipeStore(url: try makeRecipeStoreURL(self))
        let v1 = sampleVersion()
        try recipes.saveNewVersion(v1)
        try RecipeLogger.logPortion(
            store: journal, version: v1, portion: 1, now: when, id: intakeID, timeZoneIdentifier: "UTC", meal: nil)
        let v2 = sampleVersion(
            number: 2,
            ingredients: [sampleIngredient("oat-flour", amount: "400", perUnit: energyPerUnit("3.6"))])
        try recipes.saveNewVersion(v2)
        let revision = try journal.revisions(of: intakeID)[0]
        XCTAssertEqual(revision.productSnapshotID, "recipe:recipe-1:v1")
        let product = try loggedProduct(journal)
        XCTAssertEqual(product.catalogVersion, "1")
        // 200 g of oat flour plus 20 g of olive oil over 4 servings.
        XCTAssertEqual(product.value(for: "energy"), .known(dec("224"), .kcal))
        XCTAssertEqual(revision.components[0].amount, 1)
        XCTAssertEqual(try recipes.version(recipeID: "recipe-1", number: 1), v1)
    }

    func testNonPositivePortionWritesNothing() throws {
        let journal = try makeJournal()
        XCTAssertThrowsError(try RecipeLogger.logPortion(
            store: journal, version: sampleVersion(), portion: 0, now: when, id: intakeID,
            timeZoneIdentifier: "UTC", meal: nil))
        XCTAssertTrue(try journal.activeIntakes().isEmpty)
    }

    /// The component id is a valid journal component id for any recipe identifier, including one
    /// whose characters are not slug characters.
    func testComponentIDIsValidForAwkwardRecipeIdentifiers() throws {
        for identifier in ["recipe-1", "Recipe 1", "recipe/one", "Ω", String(repeating: "a", count: 90)] {
            let id = RecipeLogger.componentID(for: identifier)
            XCTAssertTrue(JournalValidation.isValidComponentID(id), "\(identifier) -> \(id)")
            XCTAssertEqual(id, RecipeLogger.componentID(for: identifier))
        }
    }

    /// The journal refuses two components with the same id in one intake, which is what one-per-nutrient
    /// logging ran into. One component per logged recipe cannot collide, so two recipes logged on the
    /// same day both go in.
    func testTwoLoggedRecipesBothWriteAnIntake() throws {
        let journal = try makeJournal()
        let second = "1f8c2d64-9a3b-4f0e-8c5d-7b6e2a9d4c11"
        try RecipeLogger.logPortion(
            store: journal, version: sampleVersion(), portion: 1, now: when, id: intakeID,
            timeZoneIdentifier: "UTC", meal: nil)
        try RecipeLogger.logPortion(
            store: journal, version: sampleVersion(recipeID: "recipe-2", title: "Oat bars"), portion: 2,
            now: when, id: second, timeZoneIdentifier: "UTC", meal: nil)
        XCTAssertEqual(try journal.activeIntakes().count, 2)
        for intake in try journal.activeIntakes() {
            let components = try journal.revisions(of: intake.id)[0].components
            XCTAssertEqual(components.count, 1)
            XCTAssertEqual(Set(components.map(\.componentID)).count, 1)
        }
    }
}