import Foundation
import NutritionDomain

/// The profile row of the signed-in account.
public struct CommunityProfile: Equatable, Sendable {
    public let displayName: String?
    /// Opt-out: true unless the person has turned community sharing off.
    public let shareLabels: Bool

    public init(displayName: String?, shareLabels: Bool) {
        self.displayName = displayName
        self.shareLabels = shareLabels
    }
}

/// Account and catalog calls for a signed-in person. Every call renews the session first when needed.
public struct CommunityClient: Sendable, CommunityProductServicing {
    public let auth: CommunityAuth
    private let api: CommunityAPI

    /// Nil configuration means the build has no account UI: throws `notConfigured` and makes no call.
    public static func make(
        infoDictionary: [String: Any]?,
        transport: CommunityTransport = URLSessionCommunityTransport(),
        store: CommunitySessionStore,
        captcha: (any CommunityCaptcha)? = nil
    ) throws -> CommunityClient {
        guard let config = CommunityConfig(infoDictionary: infoDictionary) else {
            throw CommunityError.notConfigured
        }
        return CommunityClient(config: config, transport: transport, store: store, captcha: captcha)
    }

    public init(
        config: CommunityConfig,
        transport: CommunityTransport,
        store: CommunitySessionStore,
        captcha: (any CommunityCaptcha)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = CommunityAPI(config: config, transport: transport)
        self.auth = CommunityAuth(config: config, transport: transport, store: store, captcha: captcha, now: now)
    }

    /// The profile of the signed-in account. A missing row (not expected) reads as the defaults.
    public func profile() async throws -> CommunityProfile {
        let session = try await auth.validSession()
        let (data, response) = try await api.send(
            "/rest/v1/profiles",
            method: "GET",
            query: Self.ownRow(session.userID, select: "display_name,share_labels"),
            bearer: session.accessToken
        )
        let rows = try CommunityAPI.decode([ProfileRow].self, from: data, status: response.statusCode)
        guard let row = rows.first else {
            return CommunityProfile(displayName: nil, shareLabels: true)
        }
        return CommunityProfile(displayName: row.displayName, shareLabels: row.shareLabels)
    }

    public func updateProfile(displayName: String?, shareLabels: Bool) async throws -> CommunityProfile {
        let session = try await auth.validSession()
        let body = try CommunityAPI.encode(ProfileUpdate(displayName: displayName, shareLabels: shareLabels))
        let (data, response) = try await api.send(
            "/rest/v1/profiles",
            method: "PATCH",
            query: Self.ownRow(session.userID, select: nil),
            bearer: session.accessToken,
            body: body,
            prefer: "return=representation"
        )
        let rows = try CommunityAPI.decode([ProfileRow].self, from: data, status: response.statusCode)
        guard let row = rows.first else {
            return CommunityProfile(displayName: displayName, shareLabels: shareLabels)
        }
        return CommunityProfile(displayName: row.displayName, shareLabels: row.shareLabels)
    }

    /// Deletes the account and everything it submitted. The local session is forgotten only after the server agrees.
    public func deleteAccount() async throws {
        let session = try await auth.validSession()
        _ = try await api.send(
            "/rest/v1/rpc/delete_my_account",
            bearer: session.accessToken,
            body: Data("{}".utf8)
        )
        await auth.discardSession()
    }

    public func submitLabel(_ submission: CommunityLabelSubmission) async throws -> CommunitySubmitResult {
        let session = try await auth.validSession()
        let body = try CommunityAPI.encode(SubmitBody(submission: submission))
        let (data, response) = try await api.send(
            "/rest/v1/rpc/submit_label",
            bearer: session.accessToken,
            body: body
        )
        return try CommunityAPI.decode(CommunitySubmitResult.self, from: data, status: response.statusCode)
    }

    public func lookupLabel(barcode: String) async throws -> [CommunityLabel] {
        let session = try await auth.validSession()
        let body = try CommunityAPI.encode(LookupBody(barcode: barcode))
        let (data, response) = try await api.send(
            "/rest/v1/rpc/lookup_label",
            bearer: session.accessToken,
            body: body
        )
        let rows = try CommunityAPI.decode([LabelRow].self, from: data, status: response.statusCode)
        return rows.map { row in
            CommunityLabel(
                barcode: barcode,
                basis: row.basis,
                servingText: row.servingText,
                productName: row.productName,
                brand: row.brand,
                nutrients: row.nutrients,
                verified: row.verified,
                supportingAccounts: row.supportingDevices
            )
        }
    }

    private var productsAPI: CommunityProductsAPI { CommunityProductsAPI(api: api, auth: auth) }

    public func publish(_ request: ProductPublishRequest, expectedOwnerID: UUID) async throws -> ProductDeliveryReceipt {
        let body: Data
        do { body = try request.canonicalBody() }
        catch let field as CustomProductFieldError { throw ProductAPIError.invalidRequest(field: field.field) }
        catch { throw ProductAPIError.invalidRequest(field: nil) }
        let receipt: ProductDeliveryReceipt = try await productsAPI.call("submit_catalog_product_v2", body: CommunityProductsAPI.wrapped(body), owner: expectedOwnerID)
        guard receipt.operationID == UUID(uuidString: request.operationID), request.productID == nil || receipt.productID == UUID(uuidString: request.productID!) else { throw ProductAPIError.unavailable }
        return receipt
    }

    public func withdraw(_ request: ProductWithdrawRequest, expectedOwnerID: UUID) async throws -> ProductDeliveryReceipt {
        let body: Data
        do { body = try request.canonicalBody() } catch { throw ProductAPIError.invalidRequest(field: nil) }
        let receipt: ProductDeliveryReceipt = try await productsAPI.call("withdraw_catalog_product_v2", body: CommunityProductsAPI.wrapped(body), owner: expectedOwnerID)
        guard receipt.operationID == UUID(uuidString: request.operationID), receipt.productID == UUID(uuidString: request.productID) else { throw ProductAPIError.unavailable }
        return receipt
    }

    public func searchProducts(query: String, kind: ProductKind?, cursor: String?) async throws -> CommunityProductPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...120).contains(query.unicodeScalars.count), !query.unicodeScalars.contains(where: { $0.value == 0 }) else { throw ProductAPIError.invalidRequest(field: "p_query") }
        if let cursor, cursor.utf8.count > 1024 || cursor.unicodeScalars.contains(where: { $0.value == 0 }) { throw ProductAPIError.invalidRequest(field: "p_cursor") }
        return try await productsAPI.call("search_catalog_products_v2", body: CommunityProductsAPI.body(["p_query": query, "p_kind": kind?.rawValue as Any? ?? NSNull(), "p_cursor": cursor as Any? ?? NSNull(), "p_limit": 20]))
    }

    public func product(id: UUID) async throws -> CommunityProduct {
        let response: ProductDetailResponse = try await productsAPI.call("get_catalog_product_v2", body: CommunityProductsAPI.body(["p_product_id": id.uuidString]))
        guard let product = response.product else { throw ProductAPIError.notFound }
        guard product.productID == id else { throw ProductAPIError.unavailable }
        return product
    }

    public func capabilities() async throws -> ProductCatalogCapabilities {
        try await productsAPI.call("catalog_capabilities_v2", body: Data("{}".utf8), capability: true)
    }

    public func acknowledgeConsent(version: Int, expectedOwnerID: UUID) async throws -> ProductConsentState {
        guard version == 2 else { throw ProductAPIError.invalidRequest(field: "p_version") }
        return try await productsAPI.call("acknowledge_catalog_consent_v2", body: CommunityProductsAPI.body(["p_version": version]), owner: expectedOwnerID)
    }

    public func contribution(productID: UUID, expectedOwnerID: UUID) async throws -> ProductContributionState {
        let state: ProductContributionState = try await productsAPI.call("get_my_catalog_contribution_v2", body: CommunityProductsAPI.body(["p_product_id": productID.uuidString]), owner: expectedOwnerID)
        guard state.productID == productID else { throw ProductAPIError.unavailable }
        return state
    }

    private static func ownRow(_ userID: String, select: String?) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let select {
            items.append(URLQueryItem(name: "select", value: select))
        }
        items.append(URLQueryItem(name: "id", value: "eq.\(userID)"))
        return items
    }
}

private struct ProfileRow: Decodable {
    let displayName: String?
    let shareLabels: Bool
}

private struct ProfileUpdate: Encodable {
    let displayName: String?
    let shareLabels: Bool

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case shareLabels = "share_labels"
    }

    /// A cleared name is sent as null, so the column is emptied rather than left unchanged.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(shareLabels, forKey: .shareLabels)
    }
}

private struct SubmitBody: Encodable {
    let submission: CommunityLabelSubmission

    enum CodingKeys: String, CodingKey {
        case barcode = "p_barcode"
        case basis = "p_basis"
        case servingText = "p_serving_text"
        case productName = "p_product_name"
        case brand = "p_brand"
        case nutrients = "p_nutrients"
    }

    /// Optional fields are sent as null, because the function takes every parameter by position name.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(submission.barcode, forKey: .barcode)
        try container.encode(submission.basis.rawValue, forKey: .basis)
        try container.encode(submission.servingText, forKey: .servingText)
        try container.encode(submission.productName, forKey: .productName)
        try container.encode(submission.brand, forKey: .brand)
        try container.encode(submission.nutrients, forKey: .nutrients)
    }
}

private struct LookupBody: Encodable {
    let barcode: String

    enum CodingKeys: String, CodingKey {
        case barcode = "p_barcode"
    }
}

private struct LabelRow: Decodable {
    let basis: CommunityBasis
    let servingText: String?
    let productName: String
    let brand: String?
    let nutrients: [String: Decimal]
    let supportingDevices: Int
    let verified: Bool
}

private struct ProductDetailResponse: Decodable {
    let product: CommunityProduct?
    enum CodingKeys: String, CodingKey { case product }
    init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["product"])
        product = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(CommunityProduct.self, forKey: .product)
    }
}
