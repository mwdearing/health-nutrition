import Foundation
import XCTest
import NutritionDomain
import NutritionProviders
@testable import NutritionJournal
@testable import NutritionUI

final class CustomProductEditorTests: XCTestCase {
    @MainActor func testNameOnlyEveryKindSavesWithoutIntakeOrPublication() async throws {
        for kind in ProductKind.allCases {
            let store = ProductEditorStorePort()
            let model = CustomProductEditorViewModel(store: store)
            model.name = "Synthetic product"; model.kind = kind
            let saved = try model.save(now: Date(timeIntervalSince1970: 1))
            XCTAssertEqual(saved.content.kind, kind)
            XCTAssertNil(saved.content.barcode)
            XCTAssertTrue(saved.content.facts.isEmpty)
            XCTAssertEqual(store.commands.count, 1)
            XCTAssertNil(store.commands[0].intake)
            XCTAssertNil(store.commands[0].publication)
            XCTAssertTrue(store.operations.isEmpty)
            XCTAssertTrue(model.missingFacts)
        }
    }
    @MainActor func testAllFactStatesIUAndExplicitServingSurviveSave() async throws {
        let store = ProductEditorStorePort()
        let model = CustomProductEditorViewModel(store: store)
        model.name = "Synthetic supplement"; model.kind = .supplement
        model.facts = [
            ProductFactInput(key: "protein", displayName: "Protein", state: .known, amount: "0", unit: .g),
            ProductFactInput(key: "iron", displayName: "Iron", state: .unknown),
            ProductFactInput(key: "fiber", displayName: "Fiber", state: .notApplicable),
            ProductFactInput(key: "sodium", displayName: "Sodium", state: .belowReportingThreshold, unit: .mg),
            ProductFactInput(key: "ingredient:activity", displayName: "Activity", state: .known, amount: "5", unit: .iu)]
        XCTAssertThrowsError(try model.save(now: Date()))
        XCTAssertTrue(store.commands.isEmpty)
        model.servingQuantity = "3"; model.servingUnit = .gummy
        let saved = try model.save(now: Date())
        XCTAssertEqual(saved.content.serving?.quantity, 3)
        XCTAssertEqual(saved.content.facts.map(\.value), [.known(0, .g), .unknown, .notApplicable, .belowReportingThreshold(.mg), .known(5, .iu)])
    }
    @MainActor func testLegacyRequiresExplicitKindAndServingWithoutFabrication() async throws {
        let store = ProductEditorStorePort()
        let snapshot = ProductDefinition(snapshotID: "synthetic", productID: "synthetic", name: "Synthetic legacy", labelBasis: "per serving", catalogOrigin: "label", catalogVersion: "1", nutrients: ["protein": .known(2, .g)])
        let model = CustomProductEditorViewModel(store: store, legacy: try CustomProductMapping.legacyDraft(from: snapshot))
        XCTAssertNil(model.kind)
        XCTAssertThrowsError(try model.save(now: Date()))
        model.kind = .food
        XCTAssertThrowsError(try model.save(now: Date()))
        model.servingQuantity = "30"; model.servingUnit = .g
        let result = try model.save(now: Date())
        XCTAssertEqual(result.content.serving?.text, "per serving")
        XCTAssertEqual(store.commands.count, 1)
        XCTAssertNil(store.commands.first?.publication)
    }
    @MainActor func testEditingKeepsLocalIdentityAndImportedAttributionWithoutUpload() async throws {
        let store = ProductEditorStorePort()
        let original = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: .init(name: "Synthetic", kind: .drink, basis: .per100mL), source: .init(productID: UUID(), representativeRevision: "1", attribution: "Community"))
        store.products = [original]
        let model = CustomProductEditorViewModel(store: store, revision: original)
        model.name = "Synthetic edited"
        let changed = try model.save(now: Date())
        XCTAssertEqual(changed.localProductID, original.localProductID)
        XCTAssertNotEqual(changed.revisionID, original.revisionID)
        XCTAssertEqual(changed.source, original.source)
        XCTAssertEqual(store.commands.last?.expectedLocalRevision, original.revisionID)
        XCTAssertTrue(store.operations.isEmpty)
    }
    @MainActor func testInvalidDecimalDoesNotPartiallyParseOrSave() async throws {
        for text in ["1e2", "1garbage", "-1", "0.0000001"] {
            let store = ProductEditorStorePort()
            let model = CustomProductEditorViewModel(store: store)
            model.name = "Synthetic"; model.kind = .food; model.basis = .per100g
            model.facts = [.init(key: "protein", displayName: "Protein", state: .known, amount: text, unit: .g)]
            XCTAssertThrowsError(try model.save(now: Date()))
            XCTAssertTrue(store.commands.isEmpty)
        }
    }
}

// Bounded command-capture port: no SwiftData, rollback or persistence claims.
final class ProductEditorStorePort: CustomProductStore, @unchecked Sendable {
    var products: [CustomProductRevision] = []
    var commands: [CustomProductSave] = []
    var operations: [ProductShareOperation] = []
    var reviews: [(ProductContributionReview, ProductShareOperation?)] = []
    func reconcileProductContribution(_ review: ProductContributionReview, publication: ProductShareOperation?) throws {
        reviews.append((review, publication))
        if let publication { operations.append(publication) }
    }
    func saveCustomProduct(_ command: CustomProductSave, now: Date) throws -> CustomProductRevision {
        commands.append(command); products.removeAll { $0.localProductID == command.revision.localProductID }; products.append(command.revision)
        if let operation = command.publication { operations.append(operation) }
        return command.revision
    }
    func customProducts() throws -> [CustomProductRevision] { products }
    func enqueueProductOperation(_ operation: ProductShareOperation) throws { operations.append(operation) }
    func enqueueProductWithdrawal(_ operation: ProductShareOperation, expectedStoreEpoch: UUID) throws -> ProductShareOperation { operations.append(operation); return operation }
    func recordProductWithdrawalPreparation(_ update: ProductWithdrawalPreparationUpdate) throws -> ProductShareOperation { throw CustomProductStoreError.invalidOperation }
    func productOperations(ownerID: UUID) throws -> [ProductShareOperation] { operations.filter { $0.ownerID == ownerID } }
    func dueProductOperations(ownerID: UUID, now: Date) throws -> [ProductShareOperation] { try productOperations(ownerID: ownerID) }
    func productAccountEpoch(ownerID: UUID) throws -> UUID? { try productOperations(ownerID: ownerID).last?.epoch }
    func recordProductDelivery(_ update: ProductDeliveryUpdate) throws {}
    func pauseProductOperations(ownerID: UUID) throws {}
    func resumeProductOperations(ownerID: UUID, fromEpoch: UUID, toEpoch: UUID) throws {}
    var cancellationOwners: [UUID] = []
    func cancelProductPublications(ownerID: UUID) throws {
        cancellationOwners.append(ownerID)
        for index in operations.indices where operations[index].ownerID == ownerID && operations[index].kind == .publish {
            let operation = operations[index]
            if operation.reviewSettlementID == nil && ![.acknowledged, .satisfied].contains(operation.status) && operation.publicationResolution == nil {
                operations[index].status = .cancelled
            }
        }
    }
    func removeProductAccountState(ownerID: UUID) throws {}
}

extension CustomProductEditorTests {
    @MainActor func testImportOpenLogAndFavoriteNeverUploadAndProductListDoesNotDuplicate() async throws {
        let products = ProductEditorStorePort(), journal = ProductIntakeCommandPort(), favorites = ProductFavoritePort(), uploader = ProductLabelPort()
        let original = syntheticCommunityProduct(name: "Synthetic drink", kind: .drink)
        let service = ProductSearchServicePort(); await service.setPages([.init(products: [original], nextCursor: nil)])
        let search = CommunityProductSearchViewModel(store: products, service: service, isSignedIn: { true })
        await search.search(query: "Synthetic", kind: nil)
        let imported = try search.select(original)
        let home = AddHomeViewModel(store: journal, labelSubmitter: uploader, isSharingAllowed: { true })
        let details = try home.makeDetails(product: imported, now: Date())
        XCTAssertEqual(journal.createCount, 0); XCTAssertTrue(products.operations.isEmpty)
        XCTAssertEqual(details.amountText, "")
        details.amountText = "2"; XCTAssertTrue(details.save(now: Date()))
        await details.uploadTask?.value
        XCTAssertEqual(journal.createCount, 1)
        let uploads = await uploader.count; XCTAssertEqual(uploads, 0)
        XCTAssertTrue(products.operations.isEmpty)
        let library = LibraryViewModel(store: journal, favorites: favorites, productStore: products)
        library.load(); library.segment = .recent
        let recent = try XCTUnwrap(library.visibleItems.first)
        XCTAssertEqual(try library.standaloneProduct(for: recent), imported, "Editing a logged custom product must preserve its local identity")
        library.addFavorite(recent)
        XCTAssertEqual(favorites.values.count, 1)
        XCTAssertEqual(journal.createCount, 1); XCTAssertTrue(products.operations.isEmpty)
        library.segment = .products
        XCTAssertEqual(library.filteredProducts, [imported])
        XCTAssertTrue(library.visibleItems.isEmpty, "Standalone product must not also appear as a legacy journal product")
    }
}

private actor ProductLabelPort: CommunityLabelSubmitting {
    var count = 0
    func submit(_ submission: CommunityLabelSubmission) async { count += 1 }
}
private final class ProductFavoritePort: FavoritesStore, @unchecked Sendable {
    var values: [FavoriteTemplate] = []
    func add(_ favorite: FavoriteTemplate) throws { values.append(favorite) }
    func remove(id: String) throws { values.removeAll { $0.id == id } }
    func list() throws -> [FavoriteTemplate] { values }
    func contains(id: String) throws -> Bool { values.contains { $0.id == id } }
    func close() {}
}
private final class ProductIntakeCommandPort: JournalStore, @unchecked Sendable {
    var createCount = 0
    var failNextSaveForTesting = false
    var intakes: [Intake] = []
    var savedRevisions: [IntakeRevision] = []
    var snapshots: [ProductDefinition] = []
    func create(_ intake: Intake, components: [IntakeComponent], product: ProductDefinition?, now: Date) throws -> IntakeRevision {
        createCount += 1; intakes.append(intake)
        if let product { snapshots.append(product) }
        let revision = IntakeRevision(intakeID: intake.id, number: 1, components: components, productSnapshotID: product?.snapshotID, changeReason: "Created", createdAt: now)
        savedRevisions.append(revision); return revision
    }
    func edit(intakeID: String, components: [IntakeComponent], product: ProductDefinition?, changeReason: String, now: Date, occurredAt: Date?, timeZoneIdentifier: String?) throws -> IntakeRevision { throw CustomProductStoreError.invalidOperation }
    func delete(intakeID: String, now: Date) throws { intakes.removeAll { $0.id == intakeID } }
    func activeIntakes() throws -> [Intake] { intakes }
    func revisions(of intakeID: String) throws -> [IntakeRevision] { savedRevisions.filter { $0.intakeID == intakeID } }
    func projections(of intakeID: String) throws -> [DestinationProjection] { [] }
    func pendingOutbox() throws -> [OutboxOperation] { [] }
    func product(snapshotID: String) throws -> ProductDefinition? { snapshots.first { $0.snapshotID == snapshotID } }
    func activeIntakesFromBackground() async throws -> [Intake] { intakes }
    func close() {}
}

extension CustomProductEditorTests {
    func testImportRetainsIndependentVerificationEvidenceForLibrary() throws {
        let remote = syntheticCommunityProduct(name: "Synthetic reviewed", kind: .food, verification: .init(status: .verified, source: "owner_reviewed"))
        let imported = try CustomProductMapping.importedRevision(from: remote)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(imported)) as? [String: Any])
        XCTAssertNotNil(object["importVerification"], "Persist the DTO evidence separately; source attribution and sharing receipts cannot prove verification")
    }
}

extension CustomProductEditorTests {
    @MainActor func testLibraryVerificationIsHistoricalIndependentAndInvalidatedByEditing() throws {
        let verified = try CustomProductMapping.importedRevision(from: syntheticCommunityProduct(name: "Synthetic reviewed", kind: .food, verification: .init(status: .verified, source: "owner_reviewed")))
        XCTAssertEqual(LibraryProductPresentation(verified).verificationText, "Verified by owner review at import")
        let unverified = try CustomProductMapping.importedRevision(from: syntheticCommunityProduct(name: "Synthetic supported", kind: .food, verification: .init(status: .verified), support: "100"))
        XCTAssertEqual(LibraryProductPresentation(unverified).verificationText, "Not verified at import")
        let unknown = CustomProductRevision(localProductID: UUID(), revisionID: UUID(), content: verified.content, source: verified.source)
        XCTAssertEqual(LibraryProductPresentation(unknown).verificationText, "Verification not checked")
        let store = ProductEditorStorePort(); store.products = [verified]
        let editor = CustomProductEditorViewModel(store: store, revision: verified); editor.name = "Synthetic edited"
        let edited = try editor.save(now: Date())
        XCTAssertEqual(edited.source, verified.source)
        XCTAssertNil(edited.importVerification)
        XCTAssertEqual(LibraryProductPresentation(edited).verificationText, "Verification not checked")
        let mismatched = CustomProductRevision(localProductID: verified.localProductID, revisionID: UUID(), content: edited.content, source: verified.source, importVerification: verified.importVerification)
        XCTAssertEqual(LibraryProductPresentation(mismatched).verificationText, "Verification not checked")
        let otherSource = CommunityProductSource(productID: UUID(), representativeRevision: "9", attribution: "Community")
        let changedSource = CustomProductRevision(localProductID: verified.localProductID, revisionID: UUID(), content: verified.content, source: otherSource, importVerification: verified.importVerification)
        XCTAssertEqual(LibraryProductPresentation(changedSource).verificationText, "Verification not checked")
    }
    func testImportedVerificationRoundTripAndOldRevisionDecode() throws {
        let imported = try CustomProductMapping.importedRevision(from: syntheticCommunityProduct(name: "Synthetic reviewed", kind: .food, verification: .init(status: .verified, source: "owner_reviewed")))
        let bytes = try JSONEncoder().encode(imported)
        XCTAssertEqual(try JSONDecoder().decode(CustomProductRevision.self, from: bytes), imported)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any]); old.removeValue(forKey: "importVerification")
        let decoded = try JSONDecoder().decode(CustomProductRevision.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.importVerification)
        XCTAssertEqual(decoded.source, imported.source)
        XCTAssertEqual(LibraryProductPresentation(decoded).verificationText, "Verification not checked")
    }
    @MainActor func testThresholdOnlyCompletenessAgreesAcrossEditorAndLibrary() throws {
        let store = ProductEditorStorePort(), editor = CustomProductEditorViewModel(store: ProductEditorStorePort())
        editor.name = "Synthetic threshold"; editor.basis = .per100g
        editor.facts = [.init(key: "protein", displayName: "Protein", state: .belowReportingThreshold, unit: .g)]
        XCTAssertFalse(editor.missingFacts)
        let saved = try editor.save(now: Date()); store.products = [saved]
        XCTAssertFalse(LibraryProductPresentation(saved).missingFacts)
        editor.facts = [.init(key: "protein", displayName: "Protein", state: .unknown)]
        XCTAssertTrue(editor.missingFacts)
        XCTAssertTrue(LibraryProductPresentation(try editor.save(now: Date())).missingFacts)
    }
}
