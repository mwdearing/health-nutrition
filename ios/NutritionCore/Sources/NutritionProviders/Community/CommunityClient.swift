import Foundation

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
public struct CommunityClient: Sendable {
    public let auth: CommunityAuth
    private let api: CommunityAPI

    /// Nil configuration means the build has no account UI: throws `notConfigured` and makes no call.
    public static func make(
        infoDictionary: [String: Any]?,
        transport: CommunityTransport = URLSessionCommunityTransport(),
        store: CommunitySessionStore
    ) throws -> CommunityClient {
        guard let config = CommunityConfig(infoDictionary: infoDictionary) else {
            throw CommunityError.notConfigured
        }
        return CommunityClient(config: config, transport: transport, store: store)
    }

    public init(
        config: CommunityConfig,
        transport: CommunityTransport,
        store: CommunitySessionStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = CommunityAPI(config: config, transport: transport)
        self.auth = CommunityAuth(config: config, transport: transport, store: store, now: now)
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
