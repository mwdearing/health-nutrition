import Foundation
import XCTest
import NutritionDomain
import NutritionJournal
import NutritionProviders
@testable import NutritionUI

final class CustomProductMappingTests: XCTestCase {
    func testServingIsLabelQuantityNotConsumedQuantity() throws {
        let content = CustomProductContent(name: "Synthetic gummies", kind: .supplement, basis: .perServing,
            serving: ProductServing(quantity: 3, unit: .gummy), facts: [
                ProductFact(key: "protein", displayName: "Protein", value: .known(2, .g)),
                ProductFact(key: "iron", displayName: "Iron", value: .unknown)])
        let revision = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: content)
        let snapshot = try CustomProductMapping.snapshot(for: revision)
        XCTAssertEqual(snapshot.nutrients["protein"], .known(2, .g))
        XCTAssertEqual(snapshot.nutrients["iron"], .unknown)
        XCTAssertEqual(IntakeContextSnapshotBasis.scalingFactor(labelBasis: snapshot.labelBasis,
            logged: [IntakeComponent(componentID: "portion", name: "Portion", amount: 6, unit: .gummy)]), 2)
        XCTAssertEqual(revision.content.serving?.quantity, 3)
    }

    func testIngredientKeysKeepExactUTF8IdentityAndDisplayNames() throws {
        let content = CustomProductContent(name: "Synthetic", kind: .supplement, basis: .per100g, facts: [
            ProductFact(key: "ingredient:é", displayName: "First", value: .known(1, .mg)),
            ProductFact(key: "ingredient:e\u{301}", displayName: "Second", value: .known(2, .mg))])
        let snapshot = try CustomProductMapping.snapshot(for: CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: content))
        XCTAssertEqual(snapshot.nutrients.count, 2)
        XCTAssertEqual(Set(snapshot.nutrientDisplayNames.values), ["First", "Second"])
        XCTAssertTrue(snapshot.nutrients.keys.allSatisfy { $0.hasPrefix("customfact_utf8_") })
    }

    func testExplicitMassAndVolumeServingScaleWithoutRoundingLabel() throws {
        for (quantity, unit, logged, loggedUnit) in [(Decimal(30), MeasureUnit.g, Decimal(60), MeasureUnit.g), (250, .mL, 1, .L)] {
            let revision = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content:
                CustomProductContent(name: "Synthetic", kind: .food, basis: .perServing,
                    serving: ProductServing(quantity: quantity, unit: unit), facts: [ProductFact(key: "protein", displayName: "Protein", value: .known(1, .g))]))
            let snapshot = try CustomProductMapping.snapshot(for: revision)
            XCTAssertEqual(snapshot.nutrients["protein"], .known(1, .g))
            XCTAssertEqual(IntakeContextSnapshotBasis.scalingFactor(labelBasis: snapshot.labelBasis,
                logged: [IntakeComponent(componentID: "portion", name: "Portion", amount: logged, unit: loggedUnit)]), unit == .g ? 2 : 4)
        }
    }

    func testLegacyStagingRetainsSaltSourceAndMissingChoices() throws {
        let id = UUID()
        let legacy = LegacyProductLabel(contentType: "legacy_label", name: "Synthetic", barcode: "0012345678905",
            basis: .perServing, rawServingText: "one small spoon", nutrients: ["salt": Decimal(string: "0.6")!], legacySource: .community)
        let product = CommunityProduct(productID: id, representativeRevision: "7", product: .legacyLabel(legacy),
            source: ProductSourceDTO(productID: id, representativeRevision: "7", attribution: "Community"),
            verification: ProductVerification(status: .sharedUnverified), support: ProductSupport(distinctAccounts: "1", verificationThreshold: "3"), missingFacts: false, alternatives: [])
        XCTAssertThrowsError(try CustomProductMapping.importedRevision(from: product))
        let staged = try CustomProductMapping.stagedDraft(from: product)
        XCTAssertNil(staged.kind)
        XCTAssertNil(staged.serving)
        XCTAssertEqual(staged.legacyLabel, legacy)
        let completed = try staged.completed(kind: .food, basis: .perServing, serving: ProductServing(quantity: 5, unit: .g))
        XCTAssertEqual(completed.source?.productID, id)
        XCTAssertEqual(completed.content.serving?.text, "one small spoon")
        XCTAssertEqual(completed.content.facts.first?.key, "ingredient:salt")
        XCTAssertEqual(completed.content.facts.first?.value, .known(Decimal(string: "0.6")!, .g))
    }
    func testNameOnlyAndEveryFactStateRemainMissingOrExplicit() throws {
        let facts: [ProductFact] = [
            ProductFact(key: "protein", displayName: "Protein", value: .known(0, .g)),
            ProductFact(key: "iron", displayName: "Iron", value: .unknown),
            ProductFact(key: "fiber", displayName: "Fiber", value: .notApplicable),
            ProductFact(key: "sodium", displayName: "Sodium", value: .belowReportingThreshold(.mg)),
            ProductFact(key: "ingredient:activity", displayName: "Activity", value: .known(5, .iu))]
        let revision = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: CustomProductContent(name: "Synthetic", kind: .supplement, basis: .per100g, facts: facts))
        let snapshot = try CustomProductMapping.snapshot(for: revision)
        XCTAssertEqual(snapshot.nutrients["protein"], .known(0, .g))
        XCTAssertEqual(snapshot.nutrients["iron"], .unknown)
        XCTAssertEqual(snapshot.nutrients["fiber"], .notApplicable)
        XCTAssertEqual(snapshot.nutrients["sodium"], .belowReportingThreshold(.mg))
        let staged = try CustomProductMapping.legacyDraft(from: snapshot)
        XCTAssertEqual(staged.kind, .supplement)
        XCTAssertEqual(Set(staged.facts), Set(facts))
        let empty = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: CustomProductContent(name: "Name only", kind: .food, basis: .perServing))
        XCTAssertTrue(try CustomProductMapping.snapshot(for: empty).nutrients.isEmpty)
    }

    func testServingCannotConvertUnlikeCountsOrIUToMass() {
        let cases: [(String, MeasureUnit)] = [("per serving (3 gummy)", .tablet), ("per serving (30 g)", .iu), ("per serving (250 mL)", .g)]
        for (basis, unit) in cases {
            XCTAssertNil(IntakeContextSnapshotBasis.scalingFactor(labelBasis: basis,
                logged: [IntakeComponent(componentID: "portion", name: "Portion", amount: 6, unit: unit)]))
        }
    }

    #if canImport(SwiftData)
    func testRawUnicodeFactsAndSnapshotSurviveRealStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("synthetic.store")
        let revision = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content:
            CustomProductContent(name: "Synthetic", kind: .supplement, basis: .per100g, facts: [
                ProductFact(key: "ingredient:é", displayName: "First", value: .known(1, .mg)),
                ProductFact(key: "ingredient:e\u{301}", displayName: "Second", value: .known(2, .mg))]))
        let snapshot = try CustomProductMapping.snapshot(for: revision)
        let store = try SwiftDataJournalStore(url: path)
        let intake = ProductIntakeDraft(intake: Intake(id: UUID().uuidString.lowercased(), category: "supplement", occurredAt: Date(timeIntervalSince1970: 1_700_000_000), timeZoneIdentifier: "UTC"),
            components: [IntakeComponent(componentID: "portion", name: "Portion", amount: 1, unit: .g)], snapshot: snapshot)
        try store.saveCustomProduct(CustomProductSave(revision: revision, intake: intake), now: Date(timeIntervalSince1970: 1_700_000_000))
        store.close()
        let reopened = try SwiftDataJournalStore(url: path)
        XCTAssertEqual(try reopened.customProducts().first, revision)
        XCTAssertEqual(try reopened.product(snapshotID: snapshot.snapshotID), snapshot)
        XCTAssertEqual(try reopened.product(snapshotID: snapshot.snapshotID)?.nutrients.count, 2)
        XCTAssertEqual(try reopened.product(snapshotID: snapshot.snapshotID)?.nutrientDisplayNames, snapshot.nutrientDisplayNames)
    }
    #endif

}
