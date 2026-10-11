import Foundation
import NutritionDomain

/// Wire types deliberately retain decimal and identifier spellings; no journal object is encoded.
public enum ProductFactState: String, Codable, Sendable { case known, unknown; case notApplicable = "not_applicable"; case belowReportingThreshold = "below_reporting_threshold" }
public enum ProductContributionStatus: String, Codable, Sendable { case none, active, withdrawn, rejected }
public enum ProductVerificationStatus: String, Codable, Sendable { case sharedUnverified = "shared_unverified"; case verified }
public enum LegacyProductSource: String, Codable, Sendable { case community; case ownerReviewed = "owner_reviewed" }

public struct ProductServingDTO: Codable, Sendable, Equatable {
    public let quantity: String
    public let unit: MeasureUnit
    public let text: String?
    public init(quantity: String, unit: MeasureUnit, text: String? = nil) {
        self.quantity = quantity
        self.unit = unit
        self.text = text
    }
    enum CodingKeys: String, CodingKey {
        case quantity = "quantity"
        case unit = "unit"
        case text = "text"
    }
    public init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["quantity", "unit"], allowed: ["quantity", "unit", "text"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quantity = try c.decode(String.self, forKey: .quantity)
        unit = try c.decode(MeasureUnit.self, forKey: .unit)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        try ProductWire.require(!c.contains(.text) || text != nil)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(quantity, forKey: .quantity)
        try c.encode(unit, forKey: .unit)
        try c.encodeIfPresent(text, forKey: .text)
    }
}

public struct ProductFactDTO: Codable, Sendable, Equatable {
    public let key: String
    public let displayName: String
    public let state: ProductFactState
    public let amount: String?
    public let unit: MeasureUnit?
    public init(key: String, displayName: String, state: ProductFactState, amount: String? = nil, unit: MeasureUnit? = nil) {
        self.key = key
        self.displayName = displayName
        self.state = state
        self.amount = amount
        self.unit = unit
    }
    enum CodingKeys: String, CodingKey {
        case key = "key"
        case displayName = "display_name"
        case state = "state"
        case amount = "amount"
        case unit = "unit"
    }
    public init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["key", "display_name", "state"], allowed: ["key", "display_name", "state", "amount", "unit"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        displayName = try c.decode(String.self, forKey: .displayName)
        state = try c.decode(ProductFactState.self, forKey: .state)
        amount = try c.decodeIfPresent(String.self, forKey: .amount)
        unit = try c.decodeIfPresent(MeasureUnit.self, forKey: .unit)
        switch state {
        case .known: try ProductWire.keys(decoder, required: ["key", "display_name", "state", "amount", "unit"])
        case .unknown, .notApplicable: try ProductWire.keys(decoder, required: ["key", "display_name", "state"])
        case .belowReportingThreshold:
            try ProductWire.keys(decoder, required: ["key", "display_name", "state"], allowed: ["key", "display_name", "state", "unit"])
            try ProductWire.require(!c.contains(.unit) || unit != nil)
        }
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(amount, forKey: .amount)
        try c.encodeIfPresent(unit, forKey: .unit)
    }
}

public struct ProductContentDTO: Codable, Sendable, Equatable {
    public let name: String
    public let brand: String?
    public let barcode: String?
    public let kind: ProductKind
    public let basis: ProductBasis
    public let serving: ProductServingDTO?
    public let facts: [ProductFactDTO]
    public init(name: String, brand: String? = nil, barcode: String? = nil, kind: ProductKind, basis: ProductBasis, serving: ProductServingDTO? = nil, facts: [ProductFactDTO]) {
        self.name = name
        self.brand = brand
        self.barcode = barcode
        self.kind = kind
        self.basis = basis
        self.serving = serving
        self.facts = facts
    }
    enum CodingKeys: String, CodingKey {
        case name = "name"
        case brand = "brand"
        case barcode = "barcode"
        case kind = "kind"
        case basis = "basis"
        case serving = "serving"
        case facts = "facts"
    }
    public init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["name", "brand", "barcode", "kind", "basis", "serving", "facts"], allowed: ["name", "brand", "barcode", "kind", "basis", "serving", "facts"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        brand = try c.decodeIfPresent(String.self, forKey: .brand)
        barcode = try c.decodeIfPresent(String.self, forKey: .barcode)
        kind = try c.decode(ProductKind.self, forKey: .kind)
        basis = try c.decode(ProductBasis.self, forKey: .basis)
        serving = try c.decodeIfPresent(ProductServingDTO.self, forKey: .serving)
        facts = try c.decode([ProductFactDTO].self, forKey: .facts)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(brand, forKey: .brand)
        try c.encode(barcode, forKey: .barcode)
        try c.encode(kind, forKey: .kind)
        try c.encode(basis, forKey: .basis)
        try c.encode(serving, forKey: .serving)
        try c.encode(facts, forKey: .facts)
    }
}

public struct ProductPublishRequest: Codable, Sendable, Equatable {
    public let operationID: String
    public let clientRevisionID: String
    public let productID: String?
    public let expectedServerRevision: String?
    public let consentVersion: Int
    public let consentGeneration: String
    public let product: ProductContentDTO
    public init(operationID: String, clientRevisionID: String, productID: String? = nil, expectedServerRevision: String? = nil, consentVersion: Int, consentGeneration: String, product: ProductContentDTO) {
        self.operationID = operationID
        self.clientRevisionID = clientRevisionID
        self.productID = productID
        self.expectedServerRevision = expectedServerRevision
        self.consentVersion = consentVersion
        self.consentGeneration = consentGeneration
        self.product = product
    }
    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case clientRevisionID = "client_revision_id"
        case productID = "product_id"
        case expectedServerRevision = "expected_server_revision"
        case consentVersion = "consent_version"
        case consentGeneration = "consent_generation"
        case product = "product"
    }
    public init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["operation_id", "client_revision_id", "product_id", "expected_server_revision", "consent_version", "consent_generation", "product"], allowed: ["operation_id", "client_revision_id", "product_id", "expected_server_revision", "consent_version", "consent_generation", "product"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try c.decode(String.self, forKey: .operationID)
        clientRevisionID = try c.decode(String.self, forKey: .clientRevisionID)
        productID = try c.decodeIfPresent(String.self, forKey: .productID)
        expectedServerRevision = try c.decodeIfPresent(String.self, forKey: .expectedServerRevision)
        consentVersion = try c.decode(Int.self, forKey: .consentVersion)
        consentGeneration = try c.decode(String.self, forKey: .consentGeneration)
        product = try c.decode(ProductContentDTO.self, forKey: .product)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operationID, forKey: .operationID)
        try c.encode(clientRevisionID, forKey: .clientRevisionID)
        try c.encode(productID, forKey: .productID)
        try c.encode(expectedServerRevision, forKey: .expectedServerRevision)
        try c.encode(consentVersion, forKey: .consentVersion)
        try c.encode(consentGeneration, forKey: .consentGeneration)
        try c.encode(product, forKey: .product)
    }
}

public struct ProductWithdrawRequest: Codable, Sendable, Equatable {
    public let operationID: String
    public let clientRevisionID: String
    public let productID: String
    public let expectedServerRevision: String
    public init(operationID: String, clientRevisionID: String, productID: String, expectedServerRevision: String) {
        self.operationID = operationID
        self.clientRevisionID = clientRevisionID
        self.productID = productID
        self.expectedServerRevision = expectedServerRevision
    }
    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case clientRevisionID = "client_revision_id"
        case productID = "product_id"
        case expectedServerRevision = "expected_server_revision"
    }
    public init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["operation_id", "client_revision_id", "product_id", "expected_server_revision"], allowed: ["operation_id", "client_revision_id", "product_id", "expected_server_revision"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try c.decode(String.self, forKey: .operationID)
        clientRevisionID = try c.decode(String.self, forKey: .clientRevisionID)
        productID = try c.decode(String.self, forKey: .productID)
        expectedServerRevision = try c.decode(String.self, forKey: .expectedServerRevision)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operationID, forKey: .operationID)
        try c.encode(clientRevisionID, forKey: .clientRevisionID)
        try c.encode(productID, forKey: .productID)
        try c.encode(expectedServerRevision, forKey: .expectedServerRevision)
    }
}

public struct ProductSupport: Codable, Sendable, Equatable {
    public let distinctAccounts: String
    public let verificationThreshold: String
    public init(distinctAccounts: String, verificationThreshold: String) {
        self.distinctAccounts = distinctAccounts
        self.verificationThreshold = verificationThreshold
    }
    enum CodingKeys: String, CodingKey {
        case distinctAccounts = "distinct_accounts"
        case verificationThreshold = "verification_threshold"
    }
    public init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["distinct_accounts", "verification_threshold"], allowed: ["distinct_accounts", "verification_threshold"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        distinctAccounts = try c.decode(String.self, forKey: .distinctAccounts)
        verificationThreshold = try c.decode(String.self, forKey: .verificationThreshold)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(distinctAccounts, forKey: .distinctAccounts)
        try c.encode(verificationThreshold, forKey: .verificationThreshold)
    }
}

public struct ProductSourceDTO: Codable, Sendable, Equatable {
    public let productID: UUID
    public let representativeRevision: String
    public let attribution: String
    public init(productID: UUID, representativeRevision: String, attribution: String) {
        self.productID = productID
        self.representativeRevision = representativeRevision
        self.attribution = attribution
    }
    enum CodingKeys: String, CodingKey {
        case productID = "product_id"
        case representativeRevision = "representative_revision"
        case attribution = "attribution"
    }
    public init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["product_id", "representative_revision", "attribution"], allowed: ["product_id", "representative_revision", "attribution"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        productID = try c.decode(UUID.self, forKey: .productID)
        representativeRevision = try c.decode(String.self, forKey: .representativeRevision)
        attribution = try c.decode(String.self, forKey: .attribution)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(productID, forKey: .productID)
        try c.encode(representativeRevision, forKey: .representativeRevision)
        try c.encode(attribution, forKey: .attribution)
    }
}

public struct ProductVerification: Codable, Sendable, Equatable {
    public let status: ProductVerificationStatus
    public let source: String?
    public init(status: ProductVerificationStatus, source: String? = nil) {
        self.status = status
        self.source = source
    }
    enum CodingKeys: String, CodingKey {
        case status = "status"
        case source = "source"
    }
    public init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["status", "source"], allowed: ["status", "source"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(ProductVerificationStatus.self, forKey: .status)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(source, forKey: .source)
    }
}

public struct LegacyProductLabel: Codable, Sendable, Equatable {
    public let contentType: String
    public let name: String
    public let brand: String?
    public let barcode: String
    public let kind: ProductKind?
    public let basis: CommunityBasis
    public let serving: ProductServingDTO?
    public let rawServingText: String?
    public let nutrients: [String: Decimal]
    public let legacySource: LegacyProductSource
    public init(contentType: String, name: String, brand: String? = nil, barcode: String, kind: ProductKind? = nil, basis: CommunityBasis, serving: ProductServingDTO? = nil, rawServingText: String? = nil, nutrients: [String: Decimal], legacySource: LegacyProductSource) {
        self.contentType = contentType
        self.name = name
        self.brand = brand
        self.barcode = barcode
        self.kind = kind
        self.basis = basis
        self.serving = serving
        self.rawServingText = rawServingText
        self.nutrients = nutrients
        self.legacySource = legacySource
    }
    enum CodingKeys: String, CodingKey {
        case contentType = "content_type"
        case name = "name"
        case brand = "brand"
        case barcode = "barcode"
        case kind = "kind"
        case basis = "basis"
        case serving = "serving"
        case rawServingText = "raw_serving_text"
        case nutrients = "nutrients"
        case legacySource = "legacy_source"
    }
    public init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["content_type", "name", "brand", "barcode", "kind", "basis", "serving", "raw_serving_text", "nutrients", "legacy_source"], allowed: ["content_type", "name", "brand", "barcode", "kind", "basis", "serving", "raw_serving_text", "nutrients", "legacy_source"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentType = try c.decode(String.self, forKey: .contentType)
        name = try c.decode(String.self, forKey: .name)
        brand = try c.decodeIfPresent(String.self, forKey: .brand)
        barcode = try c.decode(String.self, forKey: .barcode)
        kind = try c.decodeIfPresent(ProductKind.self, forKey: .kind)
        basis = try c.decode(CommunityBasis.self, forKey: .basis)
        serving = try c.decodeIfPresent(ProductServingDTO.self, forKey: .serving)
        rawServingText = try c.decodeIfPresent(String.self, forKey: .rawServingText)
        nutrients = try c.decode([String: Decimal].self, forKey: .nutrients)
        legacySource = try c.decode(LegacyProductSource.self, forKey: .legacySource)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(contentType, forKey: .contentType)
        try c.encode(name, forKey: .name)
        try c.encode(brand, forKey: .brand)
        try c.encode(barcode, forKey: .barcode)
        try c.encode(kind, forKey: .kind)
        try c.encode(basis, forKey: .basis)
        try c.encode(serving, forKey: .serving)
        try c.encode(rawServingText, forKey: .rawServingText)
        try c.encode(nutrients, forKey: .nutrients)
        try c.encode(legacySource, forKey: .legacySource)
    }
}

public struct CommunityProduct: Codable, Sendable, Equatable {
    public let productID: UUID
    public let representativeRevision: String
    public let product: CommunityProductContent
    public let source: ProductSourceDTO
    public let verification: ProductVerification
    public let support: ProductSupport
    public let missingFacts: Bool
    public let alternatives: [ProductAlternative]
    public init(productID: UUID, representativeRevision: String, product: CommunityProductContent, source: ProductSourceDTO, verification: ProductVerification, support: ProductSupport, missingFacts: Bool, alternatives: [ProductAlternative]) {
        self.productID = productID
        self.representativeRevision = representativeRevision
        self.product = product
        self.source = source
        self.verification = verification
        self.support = support
        self.missingFacts = missingFacts
        self.alternatives = alternatives
    }
    enum CodingKeys: String, CodingKey {
        case productID = "product_id"
        case representativeRevision = "representative_revision"
        case product = "product"
        case source = "source"
        case verification = "verification"
        case support = "support"
        case missingFacts = "missing_facts"
        case alternatives = "alternatives"
    }
    public init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["product_id", "representative_revision", "product", "source", "verification", "support", "missing_facts", "alternatives"], allowed: ["product_id", "representative_revision", "product", "source", "verification", "support", "missing_facts", "alternatives"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        productID = try c.decode(UUID.self, forKey: .productID)
        representativeRevision = try c.decode(String.self, forKey: .representativeRevision)
        product = try c.decode(CommunityProductContent.self, forKey: .product)
        source = try c.decode(ProductSourceDTO.self, forKey: .source)
        verification = try c.decode(ProductVerification.self, forKey: .verification)
        support = try c.decode(ProductSupport.self, forKey: .support)
        missingFacts = try c.decode(Bool.self, forKey: .missingFacts)
        alternatives = try c.decode([ProductAlternative].self, forKey: .alternatives)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(productID, forKey: .productID)
        try c.encode(representativeRevision, forKey: .representativeRevision)
        try c.encode(product, forKey: .product)
        try c.encode(source, forKey: .source)
        try c.encode(verification, forKey: .verification)
        try c.encode(support, forKey: .support)
        try c.encode(missingFacts, forKey: .missingFacts)
        try c.encode(alternatives, forKey: .alternatives)
    }
}

public struct ProductDeliveryReceipt: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let productID: UUID
    public let acknowledgedRevision: String
    public let currentRevision: String
    public let currentState: ProductContributionStatus
    public let publication: CommunityProduct?
    public let replayed: Bool
    public init(operationID: UUID, productID: UUID, acknowledgedRevision: String, currentRevision: String, currentState: ProductContributionStatus, publication: CommunityProduct? = nil, replayed: Bool) {
        self.operationID = operationID
        self.productID = productID
        self.acknowledgedRevision = acknowledgedRevision
        self.currentRevision = currentRevision
        self.currentState = currentState
        self.publication = publication
        self.replayed = replayed
    }
    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case productID = "product_id"
        case acknowledgedRevision = "acknowledged_revision"
        case currentRevision = "current_revision"
        case currentState = "current_state"
        case publication = "publication"
        case replayed = "replayed"
    }
    public init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["operation_id", "product_id", "acknowledged_revision", "current_revision", "current_state", "publication", "replayed"], allowed: ["operation_id", "product_id", "acknowledged_revision", "current_revision", "current_state", "publication", "replayed"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operationID = try c.decode(UUID.self, forKey: .operationID)
        productID = try c.decode(UUID.self, forKey: .productID)
        acknowledgedRevision = try c.decode(String.self, forKey: .acknowledgedRevision)
        currentRevision = try c.decode(String.self, forKey: .currentRevision)
        currentState = try c.decode(ProductContributionStatus.self, forKey: .currentState)
        publication = try c.decodeIfPresent(CommunityProduct.self, forKey: .publication)
        replayed = try c.decode(Bool.self, forKey: .replayed)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operationID, forKey: .operationID)
        try c.encode(productID, forKey: .productID)
        try c.encode(acknowledgedRevision, forKey: .acknowledgedRevision)
        try c.encode(currentRevision, forKey: .currentRevision)
        try c.encode(currentState, forKey: .currentState)
        try c.encode(publication, forKey: .publication)
        try c.encode(replayed, forKey: .replayed)
    }
}

public struct CommunityProductPage: Codable, Sendable, Equatable {
    public let products: [CommunityProduct]
    public let nextCursor: String?
    public init(products: [CommunityProduct], nextCursor: String? = nil) {
        self.products = products
        self.nextCursor = nextCursor
    }
    enum CodingKeys: String, CodingKey {
        case products = "products"
        case nextCursor = "next_cursor"
    }
    public init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["products", "next_cursor"], allowed: ["products", "next_cursor"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        products = try c.decode([CommunityProduct].self, forKey: .products)
        nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(products, forKey: .products)
        try c.encode(nextCursor, forKey: .nextCursor)
    }
}

public struct ProductContributionState: Codable, Sendable, Equatable {
    public let productID: UUID
    public let currentRevision: String?
    public let currentState: ProductContributionStatus
    public init(productID: UUID, currentRevision: String? = nil, currentState: ProductContributionStatus) {
        self.productID = productID
        self.currentRevision = currentRevision
        self.currentState = currentState
    }
    enum CodingKeys: String, CodingKey {
        case productID = "product_id"
        case currentRevision = "current_revision"
        case currentState = "current_state"
    }
    public init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["product_id", "current_revision", "current_state"], allowed: ["product_id", "current_revision", "current_state"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        productID = try c.decode(UUID.self, forKey: .productID)
        currentRevision = try c.decodeIfPresent(String.self, forKey: .currentRevision)
        currentState = try c.decode(ProductContributionStatus.self, forKey: .currentState)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(productID, forKey: .productID)
        try c.encode(currentRevision, forKey: .currentRevision)
        try c.encode(currentState, forKey: .currentState)
    }
}

public struct ProductCatalogLimits: Codable, Sendable, Equatable {
    public let maxEnvelopeBytes: Int
    public let maxFacts: Int
    public let maxSearchLimit: Int
    public init(maxEnvelopeBytes: Int, maxFacts: Int, maxSearchLimit: Int) {
        self.maxEnvelopeBytes = maxEnvelopeBytes
        self.maxFacts = maxFacts
        self.maxSearchLimit = maxSearchLimit
    }
    enum CodingKeys: String, CodingKey {
        case maxEnvelopeBytes = "max_envelope_bytes"
        case maxFacts = "max_facts"
        case maxSearchLimit = "max_search_limit"
    }
    public init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["max_envelope_bytes", "max_facts", "max_search_limit"], allowed: ["max_envelope_bytes", "max_facts", "max_search_limit"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxEnvelopeBytes = try c.decode(Int.self, forKey: .maxEnvelopeBytes)
        maxFacts = try c.decode(Int.self, forKey: .maxFacts)
        maxSearchLimit = try c.decode(Int.self, forKey: .maxSearchLimit)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(maxEnvelopeBytes, forKey: .maxEnvelopeBytes)
        try c.encode(maxFacts, forKey: .maxFacts)
        try c.encode(maxSearchLimit, forKey: .maxSearchLimit)
    }
}

public struct ProductConsentAcknowledgment: Codable, Sendable, Equatable {
    public let version: Int
    public let generation: String
    public init(version: Int, generation: String) {
        self.version = version
        self.generation = generation
    }
    enum CodingKeys: String, CodingKey {
        case version = "version"
        case generation = "generation"
    }
    public init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["version", "generation"], allowed: ["version", "generation"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        generation = try c.decode(String.self, forKey: .generation)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(generation, forKey: .generation)
    }
}

public struct ProductCatalogCapabilities: Codable, Sendable, Equatable {
    public let supportedVersion: Int
    public let enabled: Bool
    public let limits: ProductCatalogLimits
    public let currentConsentVersion: Int
    public let callerAcknowledgment: ProductConsentAcknowledgment?
    public let consentGeneration: String
    public let sharingPermission: Bool
    public init(supportedVersion: Int, enabled: Bool, limits: ProductCatalogLimits, currentConsentVersion: Int, callerAcknowledgment: ProductConsentAcknowledgment? = nil, consentGeneration: String, sharingPermission: Bool) {
        self.supportedVersion = supportedVersion
        self.enabled = enabled
        self.limits = limits
        self.currentConsentVersion = currentConsentVersion
        self.callerAcknowledgment = callerAcknowledgment
        self.consentGeneration = consentGeneration
        self.sharingPermission = sharingPermission
    }
    enum CodingKeys: String, CodingKey {
        case supportedVersion = "supported_version"
        case enabled = "enabled"
        case limits = "limits"
        case currentConsentVersion = "current_consent_version"
        case callerAcknowledgment = "caller_acknowledgment"
        case consentGeneration = "consent_generation"
        case sharingPermission = "sharing_permission"
    }
    public init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["supported_version", "enabled", "limits", "current_consent_version", "caller_acknowledgment", "consent_generation", "sharing_permission"], allowed: ["supported_version", "enabled", "limits", "current_consent_version", "caller_acknowledgment", "consent_generation", "sharing_permission"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supportedVersion = try c.decode(Int.self, forKey: .supportedVersion)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        limits = try c.decode(ProductCatalogLimits.self, forKey: .limits)
        currentConsentVersion = try c.decode(Int.self, forKey: .currentConsentVersion)
        callerAcknowledgment = try c.decodeIfPresent(ProductConsentAcknowledgment.self, forKey: .callerAcknowledgment)
        consentGeneration = try c.decode(String.self, forKey: .consentGeneration)
        sharingPermission = try c.decode(Bool.self, forKey: .sharingPermission)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(supportedVersion, forKey: .supportedVersion)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(limits, forKey: .limits)
        try c.encode(currentConsentVersion, forKey: .currentConsentVersion)
        try c.encode(callerAcknowledgment, forKey: .callerAcknowledgment)
        try c.encode(consentGeneration, forKey: .consentGeneration)
        try c.encode(sharingPermission, forKey: .sharingPermission)
    }
}

public struct ProductConsentState: Codable, Sendable, Equatable {
    public let version: Int
    public let generation: String
    public let acknowledged: Bool
    public init(version: Int, generation: String, acknowledged: Bool) {
        self.version = version
        self.generation = generation
        self.acknowledged = acknowledged
    }
    enum CodingKeys: String, CodingKey {
        case version = "version"
        case generation = "generation"
        case acknowledged = "acknowledged"
    }
    public init(from decoder: Decoder) throws {
        try ProductWire.keys(decoder, required: ["version", "generation", "acknowledged"], allowed: ["version", "generation", "acknowledged"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        generation = try c.decode(String.self, forKey: .generation)
        acknowledged = try c.decode(Bool.self, forKey: .acknowledged)
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(generation, forKey: .generation)
        try c.encode(acknowledged, forKey: .acknowledged)
    }
}

/// Legacy labels remain unresolved read content until an editor obtains explicit kind/serving choices.
public enum CommunityProductContent: Codable, Sendable, Equatable {
    case custom(ProductContentDTO)
    case legacyLabel(LegacyProductLabel)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ProductWire.Key.self)
        if c.contains(ProductWire.Key("content_type")) { self = .legacyLabel(try LegacyProductLabel(from: decoder)) }
        else { self = .custom(try ProductContentDTO(from: decoder)) }
    }
    public func encode(to encoder: Encoder) throws {
        switch self { case .custom(let p): try p.encode(to: encoder); case .legacyLabel(let p): try p.encode(to: encoder) }
    }
}

/// A legacy alternative owns its source and verification. Custom alternatives keep their original shape.
public struct ProductAlternative: Codable, Sendable, Equatable {
    public let representativeRevision: String
    public let product: CommunityProductContent
    public let support: ProductSupport
    public let source: ProductSourceDTO?
    public let verification: ProductVerification?
    enum CodingKeys: String, CodingKey { case representativeRevision = "representative_revision", product, support, source, verification }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        product = try c.decode(CommunityProductContent.self, forKey: .product)
        switch product {
        case .custom:
            try ProductWire.keys(decoder, required: ["representative_revision", "product", "support"])
            source = nil; verification = nil
        case .legacyLabel(let legacy):
            try ProductWire.keys(decoder, required: ["representative_revision", "product", "support", "source", "verification"])
            source = try c.decode(ProductSourceDTO.self, forKey: .source)
            verification = try c.decode(ProductVerification.self, forKey: .verification)
            try ProductWire.require(verification?.status == (legacy.legacySource == .community ? .sharedUnverified : .verified))
        }
        representativeRevision = try c.decode(String.self, forKey: .representativeRevision)
        support = try c.decode(ProductSupport.self, forKey: .support)
        try ProductWire.counter(representativeRevision, positive: true)
        if let source { try ProductWire.require(source.representativeRevision == representativeRevision) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(representativeRevision, forKey: .representativeRevision)
        try c.encode(product, forKey: .product); try c.encode(support, forKey: .support)
        try c.encodeIfPresent(source, forKey: .source); try c.encodeIfPresent(verification, forKey: .verification)
    }
}

extension ProductServingDTO {
    func validate() throws { try ProductWire.decimal(quantity, positive: true); try ProductWire.require([UnitDimension.mass, .volume, .count].contains(unit.dimension)); if let text { try ProductWire.text(text, limit: 80) } }
}
extension ProductFactDTO {
    func validate() throws {
        switch state {
        case .known: try ProductWire.require(amount != nil && unit != nil); try ProductWire.decimal(amount!)
        case .unknown, .notApplicable: try ProductWire.require(amount == nil && unit == nil)
        case .belowReportingThreshold: try ProductWire.require(amount == nil)
        }
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key.utf8.elementsEqual(rhs.key.utf8) && lhs.displayName == rhs.displayName && lhs.state == rhs.state && lhs.amount == rhs.amount && lhs.unit == rhs.unit
    }
    var domain: ProductFact {
        let value: NutrientValue
        switch state {
        case .known: value = .known(Decimal(string: amount!, locale: Locale(identifier: "en_US_POSIX"))!, unit!)
        case .unknown: value = .unknown
        case .notApplicable: value = .notApplicable
        case .belowReportingThreshold: value = .belowReportingThreshold(unit)
        }
        return ProductFact(key: key, displayName: displayName, value: value)
    }
    public init(_ fact: ProductFact) {
        key = fact.key; displayName = fact.displayName
        switch fact.value {
        case .known(let value, let unit): state = .known; amount = NSDecimalNumber(decimal: value).stringValue; self.unit = unit
        case .unknown: state = .unknown; amount = nil; unit = nil
        case .notApplicable: state = .notApplicable; amount = nil; unit = nil
        case .belowReportingThreshold(let unit): state = .belowReportingThreshold; amount = nil; self.unit = unit
        }
    }
}
extension ProductContentDTO {
    public init(_ content: CustomProductContent) throws {
        try CustomProductValidation.validate(content)
        self.init(name: content.name, brand: content.brand, barcode: content.barcode, kind: content.kind, basis: content.basis,
                  serving: content.serving.map { ProductServingDTO(quantity: NSDecimalNumber(decimal: $0.quantity).stringValue, unit: $0.unit, text: $0.text) }, facts: content.facts.map(ProductFactDTO.init))
        try validate()
    }
    public func domainContent() throws -> CustomProductContent {
        try validate()
        return CustomProductContent(name: name, brand: brand, barcode: barcode, kind: kind, basis: basis,
            serving: serving.map { ProductServing(quantity: Decimal(string: $0.quantity, locale: Locale(identifier: "en_US_POSIX"))!, unit: $0.unit, text: $0.text) }, facts: facts.map(\.domain))
    }
    func validate() throws {
        try serving?.validate(); try facts.forEach { try $0.validate() }
        try CustomProductValidation.validate(CustomProductContent(name: name, brand: brand, barcode: barcode, kind: kind, basis: basis,
            serving: serving.map { ProductServing(quantity: Decimal(string: $0.quantity, locale: Locale(identifier: "en_US_POSIX"))!, unit: $0.unit, text: $0.text) }, facts: facts.map(\.domain)))
    }
}
extension ProductPublishRequest {
    func validate() throws {
        try ProductWire.uuid(operationID); try ProductWire.uuid(clientRevisionID)
        try ProductWire.require((productID == nil) == (expectedServerRevision == nil))
        if let productID { try ProductWire.uuid(productID) }
        if let expectedServerRevision { try ProductWire.counter(expectedServerRevision, positive: true) }
        try ProductWire.require(consentVersion == 2); try ProductWire.counter(consentGeneration); try product.validate()
    }
    public func canonicalBody() throws -> Data { try validate(); return try ProductWire.envelope(self) }
}
extension ProductWithdrawRequest {
    func validate() throws { try ProductWire.uuid(operationID); try ProductWire.uuid(clientRevisionID); try ProductWire.uuid(productID); try ProductWire.counter(expectedServerRevision, positive: true) }
    public func canonicalBody() throws -> Data { try validate(); return try ProductWire.envelope(self) }
}
extension ProductSupport { func validate() throws { try ProductWire.counter(distinctAccounts); try ProductWire.counter(verificationThreshold) } }
extension ProductSourceDTO {
    func validate() throws { try ProductWire.counter(representativeRevision, positive: true); try ProductWire.require(!attribution.unicodeScalars.contains { $0.value == 0 }) }
    public var domainSource: CommunityProductSource { CommunityProductSource(productID: productID, representativeRevision: representativeRevision, attribution: attribution) }
}
extension ProductVerification { func validate() throws { try ProductWire.require(status == .verified ? source == "owner_reviewed" : source == nil) } }
extension LegacyProductLabel {
    func validate() throws {
        try ProductWire.require(contentType == "legacy_label" && kind == nil && serving == nil)
        try ProductWire.text(name, limit: 120, required: true); if let brand { try ProductWire.text(brand, limit: 80) }
        if let rawServingText { try ProductWire.text(rawServingText, limit: 80) }
        try ProductWire.require([8,13].contains(barcode.utf8.count) && barcode.utf8.allSatisfy { (48...57).contains($0) })
        let allowed: Set<String> = ["energyKcal", "protein", "carbohydrates", "sugars", "fat", "saturatedFat", "fiber", "salt", "sodium"]
        try ProductWire.require(nutrients.count >= 3 && Set(nutrients.keys).isSubset(of: allowed))
        for (key,value) in nutrients { try ProductWire.require(!value.isNaN && value >= 0 && value <= (key == "energyKcal" ? 9000 : key == "sodium" ? 100000 : 1000)) }
    }
}
extension CommunityProduct {
    func validate() throws {
        try ProductWire.counter(representativeRevision, positive: true)
        try ProductWire.require(source.productID == productID && source.representativeRevision == representativeRevision)
        let hasKnownFacts: Bool
        switch product {
        case .custom(let custom): hasKnownFacts = custom.facts.contains { $0.state == .known }
        case .legacyLabel(let legacy):
            hasKnownFacts = !legacy.nutrients.isEmpty
            try ProductWire.require(verification.status == (legacy.legacySource == .community ? .sharedUnverified : .verified))
        }
        try ProductWire.require(missingFacts == !hasKnownFacts && (verification.status != .verified || hasKnownFacts))
        for alternative in alternatives { if let source = alternative.source { try ProductWire.require(source.productID == productID) } }
    }
}
extension ProductDeliveryReceipt {
    func validate() throws { try ProductWire.counter(acknowledgedRevision, positive: true); try ProductWire.counter(currentRevision, positive: true); try ProductWire.require(currentState != .none); if let publication { try ProductWire.require(publication.productID == productID) } }
}
extension CommunityProductPage { func validate() throws { try ProductWire.require(products.count <= 20); if let nextCursor { try ProductWire.require(!nextCursor.unicodeScalars.contains { $0.value == 0 }) } } }
extension ProductContributionState { func validate() throws { try ProductWire.require((currentState == .none) == (currentRevision == nil)); if let currentRevision { try ProductWire.counter(currentRevision, positive: true) } } }
extension ProductCatalogLimits { func validate() throws { try ProductWire.require(maxEnvelopeBytes == 16384 && maxFacts == 64 && maxSearchLimit == 20) } }
extension ProductConsentAcknowledgment { func validate() throws { try ProductWire.require(version == 2); try ProductWire.counter(generation) } }
extension ProductCatalogCapabilities { func validate() throws { try ProductWire.require(supportedVersion == 2 && currentConsentVersion == 2); try ProductWire.counter(consentGeneration) } }
extension ProductConsentState { func validate() throws { try ProductWire.require(version == 2 && acknowledged); try ProductWire.counter(generation) } }

/// Closed JSON adapter: scalar ordering and control escapes follow the RPC canonical body contract.
enum ProductWire {
    struct Key: CodingKey { let stringValue: String; var intValue: Int? { nil }; init(_ value: String) { stringValue = value }; init?(stringValue: String) { self.init(stringValue) }; init?(intValue: Int) { return nil } }
    static func require(_ valid: Bool) throws { guard valid else { throw ProductAPIError.invalidRequest(field: nil) } }
    static func keys(_ decoder: Decoder, required: Set<String>, allowed: Set<String>? = nil) throws {
        let c = try decoder.container(keyedBy: Key.self); let keys = Set(c.allKeys.map(\.stringValue))
        try require(required.isSubset(of: keys) && keys.isSubset(of: allowed ?? required))
    }
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
    }
    static func counter(_ value: String, positive: Bool = false) throws {
        try require(matches(value, positive ? "^[1-9][0-9]*$" : "^(0|[1-9][0-9]*)$"))
    }
    static func uuid(_ value: String) throws {
        try require(matches(value, "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$") && UUID(uuidString: value) != nil)
    }
    static func decimal(_ value: String, positive: Bool = false) throws {
        try require(matches(value, "^(0|[1-9][0-9]*)(\\.[0-9]{1,6})?$"))
        guard let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else { throw ProductAPIError.invalidRequest(field: nil) }
        try require(!number.isNaN && number <= 1_000_000_000 && (!positive || number > 0))
    }
    static func text(_ value: String, limit: Int, required: Bool = false) throws {
        try require(!value.unicodeScalars.contains { $0.value == 0 } && value.unicodeScalars.count <= limit)
        try require(!required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        guard let nfc = value.applyingTransform(StringTransform("NFC"), reverse: false) else { throw ProductAPIError.invalidRequest(field: nil) }
        try require(nfc.unicodeScalars.count <= limit)
    }
    static func envelope<T: Encodable>(_ value: T) throws -> Data {
        let data = try canonical(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)))
        try require(data.count <= 16384); return data
    }
    static func canonical(_ value: Any) throws -> Data {
        func quote(_ value: String) -> String {
            var result = "\""
            for scalar in value.unicodeScalars {
                switch scalar.value {
                case 34: result += "\\\""
                case 92: result += "\\\\"
                case 0...31: result += String(format: "\\u%04x", scalar.value)
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result + "\""
        }
        func render(_ value: Any) throws -> String {
            if value is NSNull { return "null" }
            if let s = value as? String { return quote(s) }
            if let array = value as? [Any] { return "[" + (try array.map(render)).joined(separator: ",") + "]" }
            if let object = value as? [String: Any] {
                let keys = object.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
                return "{" + (try keys.map { quote($0) + ":" + (try render(object[$0]!)) }).joined(separator: ",") + "}"
            }
            if let n = value as? NSNumber { return String(cString: n.objCType) == "c" ? (n.boolValue ? "true" : "false") : n.stringValue }
            throw ProductAPIError.invalidRequest(field: nil)
        }
        return Data(try render(value).utf8)
    }
}
