import Foundation
import NutritionDomain

/// Safe metadata only: never retains a server message, request body or account identity.
public enum ProductAPIError: Error, Equatable, Sendable {
    case invalidRequest(field: String?)
    case unauthorized
    case ownerMismatch
    case consentRequired(generation: String?)
    case revisionConflict(currentRevision: String?, currentState: ProductContributionStatus?)
    case operationConflict
    case rejected
    case rateLimited(retryAfterSeconds: String?)
    case unavailable
    case unsupportedBackend
    case notFound
}

public protocol CommunityProductServicing: Sendable {
    func publish(_ request: ProductPublishRequest, expectedOwnerID: UUID) async throws -> ProductDeliveryReceipt
    func resolvePublishForWithdrawal(_ request: ProductPublishRequest, expectedOwnerID: UUID) async throws -> ProductPublishResolution
    func withdraw(_ request: ProductWithdrawRequest, expectedOwnerID: UUID) async throws -> ProductDeliveryReceipt
    func searchProducts(query: String, kind: ProductKind?, cursor: String?) async throws -> CommunityProductPage
    func product(id: UUID) async throws -> CommunityProduct
    func capabilities() async throws -> ProductCatalogCapabilities
    func acknowledgeConsent(version: Int, expectedOwnerID: UUID) async throws -> ProductConsentState
    func contribution(productID: UUID, expectedOwnerID: UUID) async throws -> ProductContributionState
}

/// V2 transport uses a default decoder and explicit CodingKeys, independent of legacy snake-case decoding.
struct CommunityProductsAPI: Sendable {
    let api: CommunityAPI
    let auth: CommunityAuth

    func call<T: Decodable>(_ rpc: String, body: Data, owner: UUID? = nil, capability: Bool = false) async throws -> T {
        do {
            try Task.checkCancellation()
            let session = try await auth.validSession(expectedOwnerID: owner)
            try Task.checkCancellation()
            let (data, response) = try await api.raw("/rest/v1/rpc/" + rpc, bearer: session.accessToken, body: body)
            guard (200..<300).contains(response.statusCode) else {
                // Only a definite rejected session invalidates credentials. Permission/consent failures
                // and typed authorization errors retain them, and a delayed old token cannot clear a new one.
                if response.statusCode == 401 ||
                    (response.statusCode == 403 && (try? JSONDecoder().decode(Failure.self, from: data))?.code == "28000") {
                    try await auth.invalidateSession(matchingAccessToken: session.accessToken)
                }
                throw Self.error(status: response.statusCode, data: data, response: response, capability: capability)
            }
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw ProductAPIError.unavailable }
        } catch is CancellationError { throw CancellationError() }
        catch let error as ProductAPIError { throw error }
        catch let error as CommunityError {
            switch error {
            case .signedOut, .unauthorized: throw ProductAPIError.unauthorized
            default: throw ProductAPIError.unavailable
            }
        } catch { throw ProductAPIError.unavailable }
    }

    static func body(_ fields: [String: Any]) throws -> Data { try ProductWire.canonical(fields) }
    static func wrapped(_ operation: Data) -> Data { Data("{\"p_request\":".utf8) + operation + Data("}".utf8) }

    private struct Failure: Decodable { let code: String?; let details: String? }
    private struct Detail: Decodable {
        let code: String
        let field: String?
        let currentRevision: String?
        let currentState: ProductContributionStatus?
        let consentGeneration: String?
        let retryAfterSeconds: String?
        enum CodingKeys: String, CodingKey {
            case code, field
            case currentRevision = "current_revision", currentState = "current_state"
            case consentGeneration = "consent_generation", retryAfterSeconds = "retry_after_seconds"
        }
    }
    static func error(status: Int, data: Data, response: HTTPURLResponse, capability: Bool) -> ProductAPIError {
        if status == 401 || status == 403 { return .unauthorized }
        let failure = try? JSONDecoder().decode(Failure.self, from: data)
        if capability && (failure?.code == "PGRST202" || failure?.code == "42883") { return .unsupportedBackend }
        if failure?.code == "P0001", let details = failure?.details,
           let detail = try? JSONDecoder().decode(Detail.self, from: Data(details.utf8)) {
            // Restrict field paths before exposing them; server messages are never UI metadata.
            let field = detail.field.flatMap { value in
                value.utf8.count <= 160 && ProductWire.matches(value, "^[A-Za-z_][A-Za-z0-9_.\\[\\]]*$") ? value : nil
            }
            func counter(_ value: String?) -> String? {
                guard let value, (try? ProductWire.counter(value)) != nil else { return nil }; return value
            }
            switch detail.code {
            case "invalid_request": return .invalidRequest(field: field)
            case "unauthorized": return .unauthorized
            case "consent_required": return .consentRequired(generation: counter(detail.consentGeneration))
            case "revision_conflict": return .revisionConflict(currentRevision: counter(detail.currentRevision), currentState: detail.currentState)
            case "operation_conflict": return .operationConflict
            case "rejected": return .rejected
            case "rate_limited": return .rateLimited(retryAfterSeconds: counter(detail.retryAfterSeconds) ?? retryAfter(response))
            case "unavailable": return .unavailable
            default: break
            }
        }
        // PostgreSQL JSONB and PostgREST parameter decoders can fail before the RPC emits typed DETAIL.
        if ["22P05", "22P02", "22023", "PGRST102"].contains(failure?.code ?? "") { return .invalidRequest(field: nil) }
        switch status {
        case 400, 422: return .invalidRequest(field: nil)
        case 409: return .revisionConflict(currentRevision: nil, currentState: nil)
        case 429: return .rateLimited(retryAfterSeconds: retryAfter(response))
        default: return .unavailable
        }
    }
    private static func retryAfter(_ response: HTTPURLResponse) -> String? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if (try? ProductWire.counter(value)) != nil { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        guard let date = formatter.date(from: value) else { return nil }
        // Anchor relative delays to the server Date header when available.
        let reference = response.value(forHTTPHeaderField: "Date").flatMap(formatter.date(from:)) ?? Date()
        let seconds = max(0, date.timeIntervalSince(reference).rounded(.up))
        guard seconds.isFinite, seconds < Double(Int.max) else { return nil }
        return String(Int(seconds))
    }
}
