import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import NutritionDomain
import NutritionProviders
@testable import NutritionJournal
@testable import NutritionUI

final class CustomProductEditorTests: XCTestCase {
    @MainActor func testEligibleNewCreationAtomicallyIncludesPublicationForEveryKind() async throws {
        for kind in ProductKind.allCases {
            let store = ProductEditorStorePort()
            let coordinator = ProductShareCoordinator(store: store, service: ProductSearchServicePort())
            let owner = UUID(), epoch = UUID()
            coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true,
                consentVersion: 2, serverGeneration: "3", localSessionEpoch: epoch, backendSupported: true))
            let model = CustomProductEditorViewModel(store: store, sharing: coordinator)
            model.name = "Synthetic automatic"; model.kind = kind
            let saved = try model.save(now: Date())
            let command = try XCTUnwrap(store.commands.first)
            let publication = try XCTUnwrap(command.publication)
            XCTAssertEqual(publication.ownerID, owner)
            XCTAssertEqual(publication.epoch, epoch)
            XCTAssertEqual(publication.consentGeneration, "3")
            XCTAssertEqual(publication.content, saved.content)
            XCTAssertEqual(publication.clientRevisionID, saved.revisionID)
            XCTAssertEqual(store.operations.count, 1)
            _ = try model.save(now: Date())
            XCTAssertNil(store.commands.last?.publication, "editing is explicit sharing, not new creation")
        }
    }
    @MainActor func testSaveKicksDeliveryOnlyAfterSuccessfulEligibleCreation() async throws {
        let store = ProductEditorStorePort(), service = ProductSearchServicePort()
        let coordinator = ProductShareCoordinator(store: store, service: service)
        let owner = UUID(), epoch = UUID()
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true,
            consentVersion: 2, serverGeneration: "0", localSessionEpoch: epoch, backendSupported: true))
        await service.setDeliveryConsent(generation: "0")
        let editor = CustomProductEditorViewModel(store: store, sharing: coordinator)
        editor.name = "Synthetic automatic"

        store.failSaving = true
        XCTAssertThrowsError(try editor.save(now: Date()))
        let failedSaveCalls = await service.publishCallCount()
        XCTAssertEqual(failedSaveCalls, 0, "failed save must not start delivery")
        XCTAssertTrue(store.operations.isEmpty)

        let publishExpectation = expectation(description: "Eligible Save starts delivery")
        await service.expectPublish(publishExpectation)
        store.failSaving = false
        _ = try editor.save(now: Date())
        await fulfillment(of: [publishExpectation], timeout: 2)
        let successfulSaveCalls = await service.publishCallCount()
        XCTAssertEqual(successfulSaveCalls, 1, "successful eligible Save starts delivery without waiting for lifecycle or connectivity")

        let localStore = ProductEditorStorePort()
        let localEditor = CustomProductEditorViewModel(store: localStore)
        localEditor.name = "Synthetic local"
        _ = try localEditor.save(now: Date())
        XCTAssertTrue(localStore.operations.isEmpty)
    }
    @MainActor func testNewSaveReadsCurrentAccountAndRejectsObsoleteAdmissionOrStore() async throws {
        let store = ProductEditorStorePort(), service = ProductSearchServicePort()
        let coordinator = ProductShareCoordinator(store: store, service: service)
        let first = UUID(), second = UUID()
        coordinator.updateAccountContext(.init(ownerID: first, profileReady: true, sharingAllowed: true, consentVersion: 2, serverGeneration: "1", localSessionEpoch: UUID(), backendSupported: true))
        let editor = CustomProductEditorViewModel(store: store, sharing: coordinator)
        editor.name = "Synthetic transition"
        let captured = try XCTUnwrap(coordinator.newProductEligibility(using: store))
        coordinator.closeGate(reason: .erase)
        let revision = syntheticCommunityRevision(name: "Synthetic", kind: .food)
        XCTAssertThrowsError(try coordinator.newProductPublication(revision, eligibility: captured, using: store))
        XCTAssertNil(try coordinator.newProductEligibility(using: ProductEditorStorePort()))
        coordinator.updateAccountContext(.init(ownerID: second, profileReady: true, sharingAllowed: true, consentVersion: 2, serverGeneration: "2", localSessionEpoch: UUID(), backendSupported: true))
        store.failSaving = true
        XCTAssertThrowsError(try editor.save(now: Date()))
        XCTAssertNil(editor.revision); XCTAssertTrue(store.products.isEmpty); XCTAssertTrue(store.operations.isEmpty)
        store.failSaving = false
        _ = try editor.save(now: Date())
        XCTAssertEqual(store.operations.first?.ownerID, second)
        XCTAssertEqual(store.operations.first?.consentGeneration, "2")
    }
    @MainActor func testIneligibleCreationStaysLocalAndNeverBackfillsAfterConsent() async throws {
        for missing in ["profile", "sharing", "consent", "bounded"] {
            let store = ProductEditorStorePort()
            let bound = ProductShareCoordinator(store: store, service: ProductSearchServicePort())
            let owner = UUID(), epoch = UUID()
            bound.updateAccountContext(.init(ownerID: owner, profileReady: missing != "profile", sharingAllowed: missing != "sharing", consentVersion: missing == "consent" ? 0 : 2, serverGeneration: "0", localSessionEpoch: epoch, backendSupported: true, freshPublicationSupported: missing != "bounded"))
            let editor = CustomProductEditorViewModel(store: store, sharing: bound)
            editor.name = "Synthetic local"
            _ = try editor.save(now: Date())
            XCTAssertTrue(store.operations.isEmpty)
            bound.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true, consentVersion: 2, serverGeneration: "0", localSessionEpoch: epoch, backendSupported: true))
            _ = try editor.save(now: Date())
            XCTAssertTrue(store.operations.isEmpty)
        }
    }
    @MainActor func testSelectedManualTemplateRequiresChoicesAndNeverCopiesConsumedAmountsIntoFacts() async throws {
        let template = RepeatTemplate(displayName: "Synthetic historical item", category: "food", components: [.init(componentID: "synthetic", name: "Historical amount", amount: 42, unit: .g)])
        let library = LibraryViewModel(store: ProductIntakeCommandPort(), favorites: ProductFavoritePort())
        let item = LibraryItem(id: "synthetic", title: template.displayName, detail: "Historical intake", isFavorite: false, template: template)
        XCTAssertTrue(library.canCompleteProduct(item))
        let draft = try library.legacyDraft(item)
        XCTAssertNil(draft.kind); XCTAssertNil(draft.basis); XCTAssertNil(draft.serving); XCTAssertTrue(draft.facts.isEmpty)
        XCTAssertEqual(draft.historicalIntakeReference, ["Historical amount: 42 g consumed"])
        let store = ProductEditorStorePort()
        let coordinator = ProductShareCoordinator(store: store, service: ProductSearchServicePort())
        coordinator.updateAccountContext(.init(ownerID: UUID(), profileReady: true, sharingAllowed: true, consentVersion: 2, serverGeneration: "0", localSessionEpoch: UUID(), backendSupported: true))
        let editor = CustomProductEditorViewModel(store: store, legacy: draft, sharing: coordinator)
        XCTAssertThrowsError(try editor.save(now: Date()))
        editor.kind = .food; editor.basis = .per100g
        let saved = try editor.save(now: Date())
        XCTAssertTrue(saved.content.facts.isEmpty); XCTAssertNil(saved.content.serving)
        XCTAssertNil(store.commands.first?.publication)
        XCTAssertEqual(template.components.first?.amount, 42)
    }
    func testPreviewFactIDsPreserveRawComposedAndDecomposedKeys() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let request = try JSONDecoder().decode(ProductPublishRequest.self, from: Data(contentsOf: root.appendingPathComponent("contracts/catalog-api/fixtures/shared-products-v2/key-identity-valid.json")))
        let keys = request.product.facts.map(\.key)
        XCTAssertEqual(keys[0], keys[1])
        let facts = keys.map { ProductFact(key: $0, displayName: "Synthetic", value: .unknown) }
        XCTAssertEqual(Set(facts.map(\.rawKeyIdentity)).count, keys.count)
        XCTAssertEqual(Set(facts.map { ProductFactDTO($0).rawKeyIdentity }).count, keys.count)
    }
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
    var failSaving = false
    private let storeEpoch = UUID()
    var operations: [ProductShareOperation] = []
    var reviews: [(ProductContributionReview, ProductShareOperation?)] = []
    func reconcileProductContribution(_ review: ProductContributionReview, publication: ProductShareOperation?) throws {
        reviews.append((review, publication))
        if let publication { operations.append(publication) }
    }
    func saveCustomProduct(_ command: CustomProductSave, now: Date) throws -> CustomProductRevision {
        if failSaving { throw CustomProductStoreError.invalidOperation }
        commands.append(command); products.removeAll { $0.localProductID == command.revision.localProductID }; products.append(command.revision)
        if var operation = command.publication {
            operation.storeEpoch = storeEpoch
            operations.append(operation)
        }
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

extension CustomProductEditorTests {
    @MainActor func testSelectedIdentityReviewPersistsOwnNullCASAndWorkerSendsItToRealClient() async throws {
        let owner = UUID(), epoch = UUID(), service = ProductSearchServicePort()
        let store: any CustomProductStore
        #if canImport(SwiftData)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("synthetic.store")
        let realStore = try SwiftDataJournalStore(url: path)
        store = realStore
        #else
        store = ProductEditorStorePort() // Portable command/worker evidence only; Apple branch proves reopen.
        #endif
        let shared = syntheticCommunityProduct(name: "Synthetic selected", kind: .food)
        let imported = try CustomProductMapping.importedRevision(from: shared)
        try store.saveCustomProduct(.init(revision: imported), now: Date())
        await service.setContribution(.init(productID: shared.productID, currentState: .none), product: shared)
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true, consentVersion: 2, serverGeneration: "0", localSessionEpoch: epoch, backendSupported: true))
        let model = CustomProductSharingModel(store: store, coordinator: coordinator, service: service)
        await model.review(imported); XCTAssertNotNil(model.preview)
        try model.confirmShare()
        let operation: ProductShareOperation
        #if canImport(SwiftData)
        realStore.close()
        let reopened = try SwiftDataJournalStore(url: path)
        operation = try XCTUnwrap(try reopened.productOperations(ownerID: owner).first)
        XCTAssertNotNil(operation.storeEpoch)
        #else
        operation = try XCTUnwrap(try store.productOperations(ownerID: owner).first)
        #endif
        XCTAssertEqual(operation.serverProductID, shared.productID.uuidString.lowercased())
        XCTAssertNil(operation.expectedServerRevision)
        let request = try ProductShareDeliveryWorker.publishRequest(operation)
        let body = try request.canonicalBody()
        let transport = SelectedIdentityTransport()
        let config = try XCTUnwrap(CommunityConfig(infoDictionary: ["SUPABASE_URL": "https://synthetic.supabase.co", "SUPABASE_ANON_KEY": "synthetic-public-key"]))
        let session = CommunitySession(accessToken: "synthetic-A", refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600), userID: owner.uuidString, email: nil)
        let client = CommunityClient(config: config, transport: transport, store: InMemoryCommunitySessionStore(session))
        do { _ = try await client.publish(request, expectedOwnerID: owner); XCTFail("server stale CAS must remain authoritative") }
        catch { XCTAssertEqual(error as? ProductAPIError, .revisionConflict(currentRevision: "7", currentState: .active)) }
        let transported = await transport.body()
        let sent = try XCTUnwrap(transported)
        let wrapped = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
        let decoded = try JSONDecoder().decode(ProductPublishRequest.self, from: JSONSerialization.data(withJSONObject: try XCTUnwrap(wrapped["p_request"])))
        XCTAssertEqual(try decoded.canonicalBody(), body)
        XCTAssertEqual(decoded.productID, shared.productID.uuidString.lowercased()); XCTAssertNil(decoded.expectedServerRevision)
    }
    #if canImport(SwiftData)
    @MainActor func testAutomaticEditorSaveRollsBackMappingAndReopensCommittedPublication() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("synthetic.store"), owner = UUID(), epoch = UUID()
        let store = try SwiftDataJournalStore(url: path)
        let coordinator = ProductShareCoordinator(store: store, service: ProductSearchServicePort())
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true, consentVersion: 2, serverGeneration: "0", localSessionEpoch: epoch, backendSupported: true))
        let editor = CustomProductEditorViewModel(store: store, sharing: coordinator)
        editor.name = "Synthetic atomic creation"
        store.failNextSaveForTesting = true
        XCTAssertThrowsError(try editor.save(now: Date()))
        XCTAssertTrue(try store.customProducts().isEmpty); XCTAssertTrue(try store.productOperations(ownerID: owner).isEmpty)
        XCTAssertNil(try store.productAccountEpoch(ownerID: owner)); XCTAssertNil(editor.revision)
        let saved = try editor.save(now: Date()); store.close()
        let reopened = try SwiftDataJournalStore(url: path)
        XCTAssertEqual(try reopened.customProducts(), [saved])
        let operation = try XCTUnwrap(try reopened.productOperations(ownerID: owner).first)
        XCTAssertEqual(operation.clientRevisionID, saved.revisionID); XCTAssertNotNil(operation.storeEpoch)
        XCTAssertEqual(try reopened.productAccountEpoch(ownerID: owner), epoch)
    }
    #endif
}
private actor SelectedIdentityTransport: CommunityTransport {
    var sent: Data?
    func body() -> Data? { sent }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent = request.httpBody
        return (Data(#"{"code":"P0001","details":"{\"code\":\"revision_conflict\",\"current_revision\":\"7\",\"current_state\":\"active\"}"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: [:])!)
    }
}
