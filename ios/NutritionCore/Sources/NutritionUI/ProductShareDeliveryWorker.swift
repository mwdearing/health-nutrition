import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders

/// Pure request preparation and retry policy. The coordinator owns serial admission and persistence.
public enum ProductShareDeliveryWorker {
    public static func retryDelay(attempt: Int, retryAfter: String?, jitter: () -> Double) -> TimeInterval {
        let ceiling = min(3600.0, 2 * pow(2, Double(min(11, max(0, attempt - 1)))))
        let sample = jitter()
        let delay = max(0.1, ceiling * (sample.isFinite ? min(1, max(0, sample)) : 1))
        guard let retryAfter, !retryAfter.isEmpty, retryAfter.utf8.allSatisfy({ (48...57).contains($0) }) else { return delay }
        // Oversized integer strings saturate without floating-point overflow or a tight retry loop.
        let normalized = retryAfter.drop(while: { $0 == "0" })
        let seconds = normalized.count > 5 ? 86400 : min(86400, Double(normalized) ?? 0)
        return max(delay, seconds)
    }

    static func publishRequest(_ operation: ProductShareOperation) throws -> ProductPublishRequest {
        let request: ProductPublishRequest
        if let bytes = operation.envelope {
            request = try JSONDecoder().decode(ProductPublishRequest.self, from: bytes)
            guard try request.canonicalBody() == bytes else { throw CustomProductStoreError.immutableEnvelope }
        } else {
            guard let content = operation.content else { throw ProductAPIError.invalidRequest(field: nil) }
            request = ProductPublishRequest(operationID: operation.operationID.uuidString.lowercased(),
                clientRevisionID: operation.clientRevisionID.uuidString.lowercased(), productID: operation.serverProductID,
                expectedServerRevision: operation.expectedServerRevision, consentVersion: operation.consentVersion,
                consentGeneration: operation.consentGeneration, product: try ProductContentDTO(content))
        }
        guard UUID(uuidString: request.operationID) == operation.operationID,
              UUID(uuidString: request.clientRevisionID) == operation.clientRevisionID,
              request.productID == operation.serverProductID, request.expectedServerRevision == operation.expectedServerRevision,
              request.consentVersion == operation.consentVersion, request.consentGeneration == operation.consentGeneration else {
            throw CustomProductStoreError.immutableEnvelope
        }
        return request
    }

    static func withdrawalRequest(_ operation: ProductShareOperation) throws -> ProductWithdrawRequest {
        let request: ProductWithdrawRequest
        if let bytes = operation.envelope {
            request = try JSONDecoder().decode(ProductWithdrawRequest.self, from: bytes)
            guard try request.canonicalBody() == bytes else { throw CustomProductStoreError.immutableEnvelope }
        } else {
            guard let product = operation.serverProductID, let revision = operation.expectedServerRevision else { throw ProductAPIError.invalidRequest(field: nil) }
            request = ProductWithdrawRequest(operationID: operation.operationID.uuidString.lowercased(),
                clientRevisionID: operation.clientRevisionID.uuidString.lowercased(), productID: product, expectedServerRevision: revision)
        }
        guard UUID(uuidString: request.operationID) == operation.operationID,
              UUID(uuidString: request.clientRevisionID) == operation.clientRevisionID,
              request.productID == operation.serverProductID, request.expectedServerRevision == operation.expectedServerRevision else {
            throw CustomProductStoreError.immutableEnvelope
        }
        return request
    }
}
