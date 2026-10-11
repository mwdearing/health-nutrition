import Foundation
import NutritionDomain

public enum CustomProductStoreError: Error, Equatable {
    case localRevisionConflict, invalidOperation, obsoleteOperation, immutableEnvelope, barcodeBindingRequiresReview
}

public struct ProductIntakeDraft: Sendable {
    public let intake: Intake
    public let components: [IntakeComponent]
    public let snapshot: ProductDefinition
    public init(intake: Intake, components: [IntakeComponent], snapshot: ProductDefinition) {
        self.intake = intake; self.components = components; self.snapshot = snapshot
    }
}

public struct CustomProductSave: Sendable {
    public let revision: CustomProductRevision
    public let expectedLocalRevision: UUID?
    public let intake: ProductIntakeDraft?
    public let publication: ProductShareOperation?
    public init(revision: CustomProductRevision, expectedLocalRevision: UUID? = nil, intake: ProductIntakeDraft? = nil, publication: ProductShareOperation? = nil) {
        self.revision = revision; self.expectedLocalRevision = expectedLocalRevision
        self.intake = intake; self.publication = publication
    }
}

public enum ProductOperationKind: String, Codable, Sendable { case publish, withdraw }
public enum ProductOperationStatus: String, Codable, Sendable { case pending, sending, paused, acknowledged, failed, cancelled, needsReview }
public enum ProductAccountState: String, Codable, Sendable { case none, active, withdrawn, rejected }
/// Closed codes only: server error text and personal information never enter the queue.
public enum ProductDeliveryReason: String, Codable, Sendable { case network, authentication, consent, rateLimited, invalidInput, conflict, rejected, unavailable }

/// Durable transport-independent intent. Envelope bytes are produced at the UI/provider boundary,
/// committed with `.sending` before transport, and reused byte-for-byte after any attempted send.
public struct ProductShareOperation: Codable, Sendable, Equatable {
    public let ownerID: UUID
    public let localProductID: UUID
    public let operationID: UUID
    public let clientRevisionID: UUID
    public let kind: ProductOperationKind
    public let content: CustomProductContent?
    public let consentVersion: Int
    public let consentGeneration: String
    /// Session generation; explicitly rebound on a validated sign-in resume.
    public internal(set) var epoch: UUID
    /// Persisted mapping generation, assigned by the store and never rebound on resume.
    public internal(set) var storeEpoch: UUID?
    public internal(set) var serverProductID: String?
    public internal(set) var expectedServerRevision: String?
    public internal(set) var predecessorOperationID: UUID?
    public internal(set) var envelope: Data?
    public internal(set) var status: ProductOperationStatus
    public internal(set) var attempts: Int
    public internal(set) var nextAttemptAt: Date?
    public internal(set) var reason: ProductDeliveryReason?
    public internal(set) var acknowledgedProductID: String?
    public internal(set) var acknowledgedRevision: String?
    public internal(set) var currentRevision: String?
    public internal(set) var currentState: ProductAccountState?

    public init(ownerID: UUID, localProductID: UUID, operationID: UUID, clientRevisionID: UUID,
                kind: ProductOperationKind, content: CustomProductContent? = nil,
                serverProductID: String? = nil, expectedServerRevision: String? = nil,
                consentVersion: Int = 2, consentGeneration: String = "0", epoch: UUID) {
        self.ownerID = ownerID; self.localProductID = localProductID; self.operationID = operationID
        self.clientRevisionID = clientRevisionID; self.kind = kind; self.content = content
        self.serverProductID = serverProductID; self.expectedServerRevision = expectedServerRevision
        self.consentVersion = consentVersion; self.consentGeneration = consentGeneration; self.epoch = epoch
        status = .pending; attempts = 0
    }
}

public struct ProductDeliveryUpdate: Sendable {
    public let operationID: UUID
    public let ownerID: UUID
    public let epoch: UUID
    public let storeEpoch: UUID
    public let status: ProductOperationStatus
    public let envelope: Data?
    public let serverProductID: String?
    public let expectedServerRevision: String?
    public let acknowledgedRevision: String?
    public let currentRevision: String?
    public let currentState: ProductAccountState?
    public let reason: ProductDeliveryReason?
    public let nextAttemptAt: Date?
    public init(operationID: UUID, ownerID: UUID, epoch: UUID, storeEpoch: UUID, status: ProductOperationStatus,
                envelope: Data? = nil, serverProductID: String? = nil, expectedServerRevision: String? = nil,
                acknowledgedRevision: String? = nil, currentRevision: String? = nil,
                currentState: ProductAccountState? = nil, reason: ProductDeliveryReason? = nil, nextAttemptAt: Date? = nil) {
        self.operationID = operationID; self.ownerID = ownerID; self.epoch = epoch; self.storeEpoch = storeEpoch; self.status = status
        self.envelope = envelope; self.serverProductID = serverProductID; self.expectedServerRevision = expectedServerRevision
        self.acknowledgedRevision = acknowledgedRevision; self.currentRevision = currentRevision
        self.currentState = currentState; self.reason = reason; self.nextAttemptAt = nextAttemptAt
    }
}
