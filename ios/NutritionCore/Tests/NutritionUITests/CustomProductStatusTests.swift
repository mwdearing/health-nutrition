import Foundation
import XCTest
import NutritionDomain
import NutritionProviders
@testable import NutritionJournal
@testable import NutritionUI

final class CustomProductStatusTests: XCTestCase {
    @MainActor func testExplicitPreviewThenShareQueuesOnlySelectedProduct() async throws {
        let store = ProductEditorStorePort(), service = ProductSearchServicePort()
        let first = syntheticCommunityRevision(name: "Synthetic first", kind: .food)
        let other = syntheticCommunityRevision(name: "Synthetic other", kind: .supplement)
        store.products = [first, other]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        let owner = UUID(), epoch = UUID()
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true, consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))
        let model = CustomProductSharingModel(store: store, coordinator: coordinator, service: service)
        await model.review(first)
        XCTAssertNotNil(model.preview)
        XCTAssertTrue(store.operations.isEmpty)
        try model.confirmShare()
        XCTAssertEqual(store.operations.count, 1)
        XCTAssertEqual(store.operations[0].ownerID, owner)
        XCTAssertEqual(store.operations[0].localProductID, first.localProductID)
        XCTAssertEqual(store.operations[0].content, first.content)
        XCTAssertEqual(model.status(first), .waiting)
        XCTAssertThrowsError(try model.confirmShare())
        XCTAssertEqual(store.operations.count, 1)
    }
    @MainActor func testAccountSwitchInvalidatesPreviewAndSignedOutStaysLocal() async throws {
        let store = ProductEditorStorePort(), service = ProductSearchServicePort()
        let item = syntheticCommunityRevision(name: "Synthetic", kind: .food); store.products = [item]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        let model = CustomProductSharingModel(store: store, coordinator: coordinator, service: service)
        XCTAssertEqual(model.status(item), .onThisPhone)
        await model.review(item); XCTAssertNil(model.preview)
        coordinator.updateAccountContext(.init(ownerID: UUID(), profileReady: true, sharingAllowed: true, consentVersion: 2, serverGeneration: "1", localSessionEpoch: UUID(), backendSupported: true))
        await model.review(item); XCTAssertNotNil(model.preview)
        coordinator.updateAccountContext(nil)
        XCTAssertThrowsError(try model.confirmShare()); XCTAssertTrue(store.operations.isEmpty)
    }
    @MainActor func testDurableCurrentStateOverridesHistoricalAcknowledgmentAndOwnershipIsSeparate() async throws {
        let store = ProductEditorStorePort(), service = ProductSearchServicePort()
        let item = syntheticCommunityRevision(name: "Synthetic", kind: .food), owner = UUID(), epoch = UUID()
        store.products = [item]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: false, consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))
        var operation = ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(), clientRevisionID: item.revisionID, kind: .publish, content: item.content, epoch: epoch)
        operation.status = .acknowledged; operation.currentState = .withdrawn; operation.currentRevision = "3"; operation.acknowledgedRevision = "1"
        store.operations = [operation]
        let model = CustomProductSharingModel(store: store, coordinator: coordinator, service: service)
        XCTAssertEqual(model.status(item), .removed)
        operation.status = .needsReview; operation.reason = .conflict; store.operations = [operation]
        XCTAssertEqual(model.status(item), .failed)
        XCTAssertTrue(model.detail(item).contains("Review"))
        XCTAssertFalse(model.canRetry(item))
    }
}

extension CustomProductStatusTests {
    @MainActor func testCanceledReviewCannotReappearAfterSuspendedOwnStateReply() async throws {
        let store = ProductEditorStorePort(), service = ProductSearchServicePort()
        let imported = try CustomProductMapping.importedRevision(from: syntheticCommunityProduct(name: "Synthetic imported", kind: .food))
        store.products = [imported]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(.init(ownerID: UUID(), profileReady: true, sharingAllowed: true, consentVersion: 2, serverGeneration: "1", localSessionEpoch: UUID(), backendSupported: true))
        let model = CustomProductSharingModel(store: store, coordinator: coordinator, service: service)
        await service.holdContribution()
        let review = Task { await model.review(imported) }
        await service.waitForContribution()
        XCTAssertTrue(model.busy)
        model.cancelReview()
        await service.finishContribution(); await review.value
        XCTAssertNil(model.preview)
        XCTAssertThrowsError(try model.confirmShare())
        XCTAssertTrue(store.operations.isEmpty)
    }
}

extension CustomProductStatusTests {
    @MainActor func testConflictReviewUsesFreshOwnCASOnlyAfterExplicitConfirmation() async throws {
        let store = ProductEditorStorePort(), service = ProductSearchServicePort()
        let item = syntheticCommunityRevision(name: "Synthetic edited", kind: .drink)
        let remote = syntheticCommunityProduct(name: "Synthetic representative", kind: .drink)
        store.products = [item]
        let owner = UUID(), epoch = UUID()
        var blocked = ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(), clientRevisionID: item.revisionID, kind: .publish, content: item.content, serverProductID: remote.productID.uuidString.lowercased(), expectedServerRevision: "3", epoch: epoch)
        blocked.status = .needsReview; blocked.reason = .conflict; blocked.storeEpoch = UUID()
        blocked.attempts = 1; blocked.envelope = Data("synthetic old request".utf8)
        store.operations = [blocked]
        await service.setContribution(.init(productID: remote.productID, currentRevision: "7", currentState: .active), product: remote)
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true, consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))
        let model = CustomProductSharingModel(store: store, coordinator: coordinator, service: service)
        await model.review(item)
        XCTAssertEqual(model.preview?.ownState?.currentRevision, "7")
        XCTAssertEqual(model.preview?.currentSharedProduct, remote)
        XCTAssertEqual(store.operations, [blocked]); XCTAssertTrue(store.reviews.isEmpty)
        try model.confirmShare()
        let command = try XCTUnwrap(store.reviews.first)
        XCTAssertEqual(command.0.blockingOperation, blocked)
        XCTAssertEqual(command.0.expectedOperationIDs, [blocked.operationID])
        XCTAssertEqual(command.0.localRevisionID, item.revisionID)
        XCTAssertEqual(command.1?.expectedServerRevision, "7")
        XCTAssertEqual(command.1?.ownerID, owner)
        XCTAssertEqual(command.1?.content, item.content)
        XCTAssertNotEqual(command.1?.operationID, blocked.operationID)
        XCTAssertThrowsError(try model.confirmShare())
        XCTAssertEqual(store.reviews.count, 1)
    }
    @MainActor func testRejectedReviewCanKeepCurrentWithoutPublicationAndLocalEditInvalidatesPreview() async throws {
        let store = ProductEditorStorePort(), service = ProductSearchServicePort()
        let item = syntheticCommunityRevision(name: "Synthetic", kind: .food), remote = syntheticCommunityProduct(name: "Synthetic representative", kind: .food)
        store.products = [item]
        let owner = UUID(), epoch = UUID()
        var blocked = ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(), clientRevisionID: item.revisionID, kind: .publish, content: item.content, serverProductID: remote.productID.uuidString.lowercased(), epoch: epoch)
        blocked.status = .needsReview; blocked.reason = .rejected; blocked.storeEpoch = UUID(); store.operations = [blocked]
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true, consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))
        let model = CustomProductSharingModel(store: store, coordinator: coordinator, service: service)
        await service.setContribution(.init(productID: remote.productID, currentRevision: "8", currentState: .rejected), product: remote)
        await model.review(item)
        XCTAssertEqual(model.preview?.canPublish, false)
        XCTAssertThrowsError(try model.confirmShare())
        try model.keepCurrentContribution()
        XCTAssertEqual(store.reviews.count, 1); XCTAssertNil(store.reviews[0].1)
        XCTAssertEqual(store.operations, [blocked])
        await service.setContribution(.init(productID: remote.productID, currentRevision: "9", currentState: .active), product: remote)
        await model.review(item)
        store.products = [.init(localProductID: item.localProductID, revisionID: UUID(), content: item.content)]
        XCTAssertThrowsError(try model.confirmShare())
        XCTAssertEqual(store.reviews.count, 1)
    }
}

extension CustomProductStatusTests {
    @MainActor func testAcknowledgedWithdrawalCanExplicitlyReviewOtherDeviceActiveRevision() async throws {
        for sharingAllowed in [true, false] {
            let store = ProductEditorStorePort(), service = ProductSearchServicePort()
            let item = syntheticCommunityRevision(name: "Synthetic saved", kind: .food), remote = syntheticCommunityProduct(name: "Synthetic current", kind: .food)
            store.products = [item]
            let owner = UUID(), epoch = UUID()
            var withdrawal = ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(), clientRevisionID: item.revisionID, kind: .withdraw, serverProductID: remote.productID.uuidString.lowercased(), expectedServerRevision: "1", epoch: epoch)
            withdrawal.status = .acknowledged; withdrawal.attempts = 1; withdrawal.envelope = Data("synthetic withdrawal".utf8)
            withdrawal.currentRevision = "2"; withdrawal.currentState = .withdrawn; withdrawal.acknowledgedRevision = "2"; withdrawal.storeEpoch = UUID()
            store.operations = [withdrawal]
            await service.setContribution(.init(productID: remote.productID, currentRevision: "3", currentState: .active), product: remote)
            let coordinator = ProductShareCoordinator(store: store, service: service)
            coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: sharingAllowed, consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))
            let model = CustomProductSharingModel(store: store, coordinator: coordinator, service: service)
            await model.review(item)
            XCTAssertEqual(model.preview?.ownState?.currentRevision, "3")
            XCTAssertEqual(model.preview?.reconciliation?.blockingOperation, withdrawal)
            XCTAssertEqual(store.operations, [withdrawal]); XCTAssertTrue(store.reviews.isEmpty)
            if sharingAllowed { try model.confirmShare(); XCTAssertEqual(store.reviews.first?.1?.expectedServerRevision, "3") }
            else { try model.keepCurrentContribution(); XCTAssertNil(store.reviews.first?.1) }
            XCTAssertEqual(store.reviews.count, 1)
            XCTAssertThrowsError(try model.confirmShare())
        }
    }
    @MainActor func testPendingDescendantDoesNotHidePersistedConflictAncestor() async throws {
        let store = ProductEditorStorePort(), service = ProductSearchServicePort()
        let item = syntheticCommunityRevision(name: "Synthetic saved", kind: .food), remote = syntheticCommunityProduct(name: "Synthetic current", kind: .food)
        store.products = [item]
        let owner = UUID(), epoch = UUID()
        var blocked = ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(), clientRevisionID: item.revisionID, kind: .publish, content: item.content, serverProductID: remote.productID.uuidString.lowercased(), expectedServerRevision: "1", epoch: epoch)
        blocked.status = .needsReview; blocked.reason = .conflict; blocked.storeEpoch = UUID(); blocked.attempts = 1; blocked.envelope = Data("synthetic conflict".utf8)
        var pending = ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(), clientRevisionID: item.revisionID, kind: .publish, content: item.content, epoch: epoch)
        pending.predecessorOperationID = blocked.operationID; pending.storeEpoch = blocked.storeEpoch
        store.operations = [blocked, pending]
        await service.setContribution(.init(productID: remote.productID, currentRevision: "3", currentState: .active), product: remote)
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true, consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))
        let model = CustomProductSharingModel(store: store, coordinator: coordinator, service: service)
        await model.review(item)
        XCTAssertEqual(model.status(item), .failed)
        XCTAssertFalse(model.canRetry(item))
        XCTAssertTrue(model.detail(item).contains("Review"))
        XCTAssertEqual(model.preview?.reconciliation?.blockingOperation, blocked)
        XCTAssertEqual(model.preview?.reconciliation?.expectedOperationIDs, [blocked.operationID, pending.operationID])
        XCTAssertEqual(store.operations, [blocked, pending]); XCTAssertTrue(store.reviews.isEmpty)
        try model.confirmShare()
        XCTAssertEqual(store.reviews.first?.1?.expectedServerRevision, "3")
        pending.status = .sending; pending.attempts = 1; pending.envelope = Data("synthetic live work".utf8); store.operations = [blocked, pending]
        await model.review(item); XCTAssertNil(model.preview)
    }
}

extension CustomProductStatusTests {
    @MainActor func testNeverAttemptedShareOffOnAllowsNewExplicitReviewWithoutRevivingCanceledWork() async throws {
        let store = ProductEditorStorePort(), service = ProductSearchServicePort()
        let item = syntheticCommunityRevision(name: "Synthetic offline product", kind: .food); store.products = [item]
        let owner = UUID(), epoch = UUID()
        let enabled = ProductShareAccountContext(ownerID: owner, profileReady: true, sharingAllowed: true, consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true)
        let disabled = ProductShareAccountContext(ownerID: owner, profileReady: true, sharingAllowed: false, consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true)
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(enabled)
        let model = CustomProductSharingModel(store: store, coordinator: coordinator, service: service)
        await model.review(item); try model.confirmShare()
        let original = try XCTUnwrap(store.operations.first)
        XCTAssertEqual(original.attempts, 0); XCTAssertNil(original.envelope)
        coordinator.closeGate(reason: .sharingDisabled); coordinator.updateAccountContext(disabled)
        let canceled = try XCTUnwrap(store.operations.first)
        XCTAssertEqual(canceled.status, .cancelled); XCTAssertEqual(store.cancellationOwners.first, owner)
        coordinator.updateAccountContext(enabled)
        XCTAssertEqual(store.operations, [canceled])
        await model.review(item)
        XCTAssertNotNil(model.preview)
        XCTAssertEqual(store.operations, [canceled], "Review must not enqueue or revive the canceled intent")
        try model.confirmShare()
        XCTAssertEqual(store.operations.count, 2)
        XCTAssertEqual(store.operations.first, canceled)
        XCTAssertNotEqual(store.operations.last?.operationID, original.operationID)
        XCTAssertEqual(store.operations.last?.status, .pending)
    }
    @MainActor func testInertCanceledHistoryDoesNotBlockAcknowledgedAuthorityReviewButAttemptedCancellationDoes() async throws {
        let store = ProductEditorStorePort(), service = ProductSearchServicePort()
        let item = syntheticCommunityRevision(name: "Synthetic saved", kind: .food), remote = syntheticCommunityProduct(name: "Synthetic current", kind: .food)
        store.products = [item]
        let owner = UUID(), epoch = UUID(), storeEpoch = UUID()
        var canceled = ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(), clientRevisionID: item.revisionID, kind: .publish, content: item.content, epoch: epoch)
        canceled.status = .cancelled; canceled.storeEpoch = storeEpoch
        var acknowledged = ProductShareOperation(ownerID: owner, localProductID: item.localProductID, operationID: UUID(), clientRevisionID: item.revisionID, kind: .withdraw, serverProductID: remote.productID.uuidString.lowercased(), expectedServerRevision: "1", epoch: epoch)
        acknowledged.status = .acknowledged; acknowledged.attempts = 1; acknowledged.envelope = Data("synthetic withdrawn request".utf8)
        acknowledged.currentRevision = "2"; acknowledged.acknowledgedRevision = "2"; acknowledged.currentState = .withdrawn; acknowledged.storeEpoch = storeEpoch
        store.operations = [canceled, acknowledged]
        await service.setContribution(.init(productID: remote.productID, currentRevision: "3", currentState: .active), product: remote)
        let coordinator = ProductShareCoordinator(store: store, service: service)
        coordinator.updateAccountContext(.init(ownerID: owner, profileReady: true, sharingAllowed: true, consentVersion: 2, serverGeneration: "1", localSessionEpoch: epoch, backendSupported: true))
        let model = CustomProductSharingModel(store: store, coordinator: coordinator, service: service)
        await model.review(item)
        XCTAssertEqual(model.preview?.reconciliation?.blockingOperation, acknowledged)
        XCTAssertEqual(model.preview?.reconciliation?.expectedOperationIDs, [canceled.operationID, acknowledged.operationID])
        XCTAssertTrue(store.reviews.isEmpty)
        try model.confirmShare()
        XCTAssertEqual(store.reviews.first?.1?.expectedServerRevision, "3")
        for attempts in [0, 1] {
            var unresolved = canceled; unresolved.attempts = attempts; unresolved.envelope = Data("synthetic unresolved request".utf8)
            store.operations = [unresolved, acknowledged]
            await model.review(item)
            XCTAssertNil(model.preview, "Never settle an attempted or envelope-bearing cancellation")
            XCTAssertThrowsError(try model.confirmShare())
        }
    }
}
