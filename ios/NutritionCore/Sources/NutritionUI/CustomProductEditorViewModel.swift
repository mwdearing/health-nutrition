import Foundation
import NutritionDomain
import NutritionJournal
import NutritionProviders

public struct ProductFactInput: Identifiable, Equatable {
    public let id: UUID
    public var key: String
    public var displayName: String
    public var state: ProductFactState
    public var amount: String
    public var unit: MeasureUnit?
    public init(id: UUID = UUID(), key: String = "protein", displayName: String = "Protein", state: ProductFactState = .unknown, amount: String = "", unit: MeasureUnit? = nil) {
        self.id = id; self.key = key; self.displayName = displayName; self.state = state; self.amount = amount; self.unit = unit
    }
    init(_ fact: ProductFact) {
        self.init(key: fact.key, displayName: fact.displayName)
        switch fact.value {
        case .known(let value, let unit): state = .known; amount = NSDecimalNumber(decimal: value).stringValue; self.unit = unit
        case .unknown: state = .unknown
        case .notApplicable: state = .notApplicable
        case .belowReportingThreshold(let unit): state = .belowReportingThreshold; self.unit = unit
        }
    }
    var hasReportedValue: Bool { state == .known || state == .belowReportingThreshold }
    func fact() throws -> ProductFact {
        let value: NutrientValue
        switch state {
        case .known:
            guard let unit else { throw CustomProductFieldError(field: displayName + " unit", code: .required) }
            value = .known(try CustomProductEditorViewModel.decimal(amount, field: displayName), unit)
        case .unknown: value = .unknown
        case .notApplicable: value = .notApplicable
        case .belowReportingThreshold: value = .belowReportingThreshold(unit)
        }
        return ProductFact(key: key, displayName: displayName, value: value)
    }
}

/// A nutrient the fact picker offers, shown by the name users see rather than its raw key.
public struct NutrientKeyChoice: Identifiable, Equatable {
    public let key: String
    public let name: String
    public var id: String { key }
}

@MainActor public extension CustomProductEditorViewModel {
    static let ingredientPrefix = "ingredient:"
    static let otherIngredientTag = "other-ingredient"
    static let savedTagPrefix = "saved:"
    static let nutrientChoices: [NutrientKeyChoice] = [
        NutrientKeyChoice(key: "energyKcal", name: "Calories"),
        NutrientKeyChoice(key: "fat", name: "Total fat"),
        NutrientKeyChoice(key: "saturatedFat", name: "Saturated fat"),
        NutrientKeyChoice(key: "transFat", name: "Trans fat"),
        NutrientKeyChoice(key: "cholesterol", name: "Cholesterol"),
        NutrientKeyChoice(key: "sodium", name: "Sodium"),
        NutrientKeyChoice(key: "carbohydrates", name: "Total carbohydrate"),
        NutrientKeyChoice(key: "fiber", name: "Fiber"),
        NutrientKeyChoice(key: "sugars", name: "Total sugars"),
        NutrientKeyChoice(key: "addedSugars", name: "Added sugars"),
        NutrientKeyChoice(key: "protein", name: "Protein"),
        NutrientKeyChoice(key: "vitaminD", name: "Vitamin D"),
        NutrientKeyChoice(key: "calcium", name: "Calcium"),
        NutrientKeyChoice(key: "iron", name: "Iron"),
        NutrientKeyChoice(key: "potassium", name: "Potassium"),
    ]

    /// Choices for one fact row: standard nutrients no other row uses, this row's own key (even a legacy one), and "Other ingredient…".
    func keyChoices(for fact: ProductFactInput) -> [NutrientKeyChoice] {
        let taken = Set(facts.filter { $0.id != fact.id }.map(\.key))
        var choices = CustomProductEditorViewModel.nutrientChoices.filter { $0.key == fact.key || !taken.contains($0.key) }
        let isKnown = fact.key.hasPrefix(CustomProductEditorViewModel.ingredientPrefix)
            || CustomProductEditorViewModel.nutrientChoices.contains { $0.key == fact.key }
        if !isKnown {
            let label = fact.displayName.isEmpty ? "Saved fact" : "\(fact.displayName) (saved)"
            choices.append(NutrientKeyChoice(key: CustomProductEditorViewModel.savedTag(fact.key), name: label))
        }
        choices.append(NutrientKeyChoice(key: CustomProductEditorViewModel.otherIngredientTag, name: "Other ingredient…"))
        return choices
    }

    /// Saved keys this build does not offer get their own tag, so they can never collide with a real choice.
    static func savedTag(_ key: String) -> String { savedTagPrefix + key }

    /// The picker value that matches a row's current key.
    static func pickerTag(for fact: ProductFactInput) -> String {
        if fact.key.hasPrefix(ingredientPrefix) { return otherIngredientTag }
        if nutrientChoices.contains(where: { $0.key == fact.key }) { return fact.key }
        return savedTag(fact.key)
    }

    func chooseKey(_ tag: String, for id: UUID) {
        guard let index = facts.firstIndex(where: { $0.id == id }), !tag.hasPrefix(CustomProductEditorViewModel.savedTagPrefix) else { return }
        if tag == CustomProductEditorViewModel.otherIngredientTag {
            if !facts[index].key.hasPrefix(CustomProductEditorViewModel.ingredientPrefix) {
                facts[index].key = CustomProductEditorViewModel.ingredientPrefix
                // A standard name left over from a nutrient pick is not the ingredient's name; clear it for the user to type.
                let current = facts[index].displayName
                if CustomProductEditorViewModel.nutrientChoices.contains(where: { $0.name == current }) {
                    facts[index].displayName = ""
                }
            }
            return
        }
        facts[index].key = tag
        if let choice = CustomProductEditorViewModel.nutrientChoices.first(where: { $0.key == tag }) {
            // Fill the name only when it is blank or still a standard name, so a name the user typed survives.
            let current = facts[index].displayName
            if current.isEmpty || CustomProductEditorViewModel.nutrientChoices.contains(where: { $0.name == current }) {
                facts[index].displayName = choice.name
            }
        }
    }

    func ingredientName(for id: UUID) -> String {
        guard let fact = facts.first(where: { $0.id == id }) else { return "" }
        return String(fact.key.dropFirst(CustomProductEditorViewModel.ingredientPrefix.count))
    }

    func setIngredientName(_ name: String, for id: UUID) {
        guard let index = facts.firstIndex(where: { $0.id == id }) else { return }
        facts[index].key = CustomProductEditorViewModel.ingredientPrefix + name
    }
}

@MainActor public final class CustomProductEditorViewModel: ObservableObject, Identifiable {
    public nonisolated let id = UUID()
    @Published public var name = ""
    @Published public var brand = ""
    @Published public var barcode = ""
    @Published public var kind: ProductKind? = .food
    @Published public var basis: ProductBasis? = .perServing
    @Published public var servingQuantity = ""
    @Published public var servingUnit: MeasureUnit = .serving
    @Published public var servingText = ""
    @Published public var facts: [ProductFactInput] = []
    /// What the form held when it was first shown. Anything else changed since is unsaved.
    private var shownWith: String?
    /// Whether the person changed the product since it was first shown. Leaving then asks first.
    public var hasTypedInput: Bool { shownWith != nil && fingerprint != shownWith }
    private var fingerprint: String {
        let head = [name, brand, barcode, servingQuantity, servingText, servingUnit.symbol]
        let rows = facts.flatMap { [$0.key, $0.displayName, $0.amount, $0.unit?.symbol ?? ""] }
        return (head + rows).joined(separator: "\u{1F}")
    }
    @Published public var errorMessage: String?
    @Published public private(set) var revision: CustomProductRevision?
    private let store: any CustomProductStore
    private let sharing: ProductShareCoordinator?
    private let legacy: LegacyCustomProductDraft?
    private let localProductID: UUID
    public static let units: [MeasureUnit] = [.g, .mg, .mcg, .kg, .oz, .mL, .L, .flOz, .cup, .tablespoon, .teaspoon, .kcal, .serving, .scoop, .tablet, .capsule, .piece, .gummy, .iu]
    public static var servingUnits: [MeasureUnit] { units.filter { [.mass, .volume, .count].contains($0.dimension) } }

    public init(store: any CustomProductStore, revision: CustomProductRevision? = nil, legacy: LegacyCustomProductDraft? = nil, sharing: ProductShareCoordinator? = nil) {
        self.sharing = sharing
        self.store = store; self.revision = revision; self.legacy = legacy; localProductID = revision?.localProductID ?? UUID()
        if let content = revision?.content {
            name = content.name; brand = content.brand ?? ""; barcode = content.barcode ?? ""; kind = content.kind; basis = content.basis
            facts = content.facts.map(ProductFactInput.init); fillServing(content.serving)
        } else if let legacy {
            name = legacy.name; brand = legacy.brand ?? ""; barcode = legacy.barcode ?? ""; kind = legacy.kind; basis = legacy.basis
            facts = legacy.facts.map(ProductFactInput.init); fillServing(legacy.serving); servingText = legacy.rawServingText ?? servingText
        }
        shownWith = fingerprint
    }
    private func fillServing(_ serving: ProductServing?) {
        guard let serving else { return }
        servingQuantity = NSDecimalNumber(decimal: serving.quantity).stringValue; servingUnit = serving.unit; servingText = serving.text ?? ""
    }
    public var missingFacts: Bool { !facts.contains(where: \.hasReportedValue) }
    public var historicalIntakeReference: [String] { legacy?.historicalIntakeReference ?? [] }
    public var legacyServingText: String? { legacy?.rawServingText }
    public func content() throws -> CustomProductContent {
        guard let kind, let basis else { throw CustomProductMappingError.requiresExplicitChoices }
        let serving: ProductServing?
        if servingQuantity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard servingText.isEmpty, legacy?.rawServingText == nil else { throw CustomProductFieldError(field: "serving", code: .servingRequired) }
            serving = nil
        } else {
            serving = ProductServing(quantity: try Self.decimal(servingQuantity, field: "serving"), unit: servingUnit, text: legacy?.rawServingText ?? Self.optional(servingText))
        }
        let value = CustomProductContent(name: name.trimmingCharacters(in: .whitespacesAndNewlines), brand: Self.optional(brand), barcode: Self.optional(barcode), kind: kind, basis: basis, serving: serving, facts: try facts.map { try $0.fact() })
        try CustomProductValidation.validate(value)
        return value
    }
    @discardableResult public func save(now: Date) throws -> CustomProductRevision {
        do {
            if let original = revision, original.source != nil,
               (kind != original.content.kind || Self.optional(barcode) != original.content.barcode) {
                throw CustomProductMappingError.sourcedIdentityIsFixed
            }
            let result = CustomProductRevision(localProductID: localProductID, revisionID: UUID(), content: try content(), source: revision?.source ?? legacy?.source)
            var publication: ProductShareOperation?
            if revision == nil, legacy == nil, let sharing, let eligibility = try sharing.newProductEligibility(using: store) {
                publication = try sharing.newProductPublication(result, eligibility: eligibility, using: store)
            }
            // No suspension separates current eligibility from the atomic revision/mapping/operation save.
            let saved = try store.saveCustomProduct(CustomProductSave(revision: result, expectedLocalRevision: revision?.revisionID, publication: publication), now: now)
            if publication != nil {
                Task { await sharing?.runDueOperations(now: now) }
            }
            revision = saved; errorMessage = nil
            return saved
        } catch {
            errorMessage = Self.message(for: error); throw error
        }
    }
    nonisolated static func decimal(_ text: String, field: String) throws -> Decimal {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^[0-9]+(?:\\.[0-9]{1,6})?$", options: .regularExpression) != nil,
              let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")), value <= 1_000_000_000 else {
            throw CustomProductFieldError(field: field, code: .invalidAmount)
        }
        return value
    }
    private static func optional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines); return trimmed.isEmpty ? nil : trimmed
    }
    public static func message(for error: Error) -> String {
        if let field = error as? CustomProductFieldError { return "Check \(field.field): \(field.code.rawValue)." }
        if error as? CustomProductMappingError == .sourcedIdentityIsFixed { return "This imported product's kind and barcode are fixed. Keep them to edit this product." }
        if error is CustomProductMappingError { return "Choose a product kind, facts basis and explicit serving before saving." }
        if error as? CustomProductStoreError == .barcodeBindingRequiresReview { return "This shared product's barcode is fixed. Keep its barcode to edit this product." }
        if error as? CustomProductStoreError == .localRevisionConflict { return "This product changed. Reopen its latest version before editing." }
        return "Could not save this product. Try again."
    }
}

public struct CustomProductSharePreview: Identifiable {
    public let id = UUID()
    public let revision: CustomProductRevision
    public let context: ProductShareAccountContext
    public let ownState: ProductContributionState?
    public let reconciliation: ProductContributionReview?
    public let currentSharedProduct: CommunityProduct?
    public var canPublish: Bool { context.sharingAllowed && context.consentVersion == 2 && ownState?.currentState != .rejected && (ownState?.currentState != .active || currentSharedProduct != nil) }
}

/// Product-only review and explicit operations. Reading, editing and importing never call this model's confirm action.
@MainActor public final class CustomProductSharingModel: ObservableObject {
    @Published public private(set) var preview: CustomProductSharePreview?
    @Published public private(set) var busy = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var refreshID = UUID()
    private let store: any CustomProductStore
    private let coordinator: ProductShareCoordinator?
    private let service: (any CommunityProductServicing)?
    private var reviewGeneration = UUID()
    private var observedOperations: [ProductShareOperation]?
    private var observedContext: ProductShareAccountContext?
    private var observedPause: ProductSharePauseReason?
    public init(store: any CustomProductStore, coordinator: ProductShareCoordinator?, service: (any CommunityProductServicing)?) {
        self.store = store; self.coordinator = coordinator; self.service = service
    }
    public var canShare: Bool {
        guard let coordinator, let context = coordinator.accountContext else { return false }
        return context.profileReady && context.backendSupported && context.freshPublicationSupported && context.sharingAllowed && context.consentVersion == 2 && coordinator.pauseReason == nil && !coordinator.sharingBlocked
    }
    public var eligibilityText: String {
        guard let coordinator, let context = coordinator.accountContext else { return "Sign in in Settings to share. Products remain available on this device." }
        if !context.backendSupported || !context.freshPublicationSupported { return "Sharing is unavailable on this server. You can still edit products on this device." }
        return "Enable product sharing and review the current sharing disclosure in Settings."
    }
    /// This product's operations from one read, so each answer below is worked out from a single snapshot and
    /// a read that fails part-way can't mix with a later one (#775). Empty without an account; nil when the
    /// read fails, which pauses sharing.
    private func snapshot(_ item: CustomProductRevision) -> [ProductShareOperation]? {
        guard let owner = coordinator?.accountContext?.ownerID else { return [] }
        return coordinator?.operations(ownerID: owner)?.filter { $0.localProductID == item.localProductID }
    }
    private func latest(_ item: CustomProductRevision) -> ProductShareOperation? { snapshot(item)?.last }
    private func reviewBlocker(in mine: [ProductShareOperation]) -> ProductShareOperation? {
        mine.last { !isSettled($0) && [.failed, .needsReview].contains($0.status) }
    }
    public func status(_ item: CustomProductRevision) -> ProductShareStatus {
        if coordinator?.operationsReadFailed == true { return .paused }
        guard let mine = snapshot(item) else { return .paused }
        return status(item, in: mine)
    }
    private func status(_ item: CustomProductRevision, in mine: [ProductShareOperation]) -> ProductShareStatus {
        if let last = mine.last, last.clientRevisionID != item.revisionID { return .localChanges }
        if reviewBlocker(in: mine) != nil { return .failed }
        if let last = mine.last, last.reviewSettlementID != nil {
            switch last.reviewedCurrentState {
            case .active: return .shared
            case .some(.withdrawn), .some(.none): return .removed
            default: return .failed
            }
        }
        return coordinator?.status(localProductID: item.localProductID) ?? .onThisPhone
    }
    public func detail(_ item: CustomProductRevision) -> String {
        guard coordinator?.operationsReadFailed != true, let mine = snapshot(item) else { return ProductShareStatus.paused.rawValue }
        guard let operation = mine.last else { return "No contribution from this account." }
        if operation.clientRevisionID != item.revisionID { return "The edited facts are saved on this device; this revision has not been shared." }
        if reviewBlocker(in: mine) != nil { return "Review the current contribution before sharing again. Your local product is saved." }
        if let retry = operation.nextAttemptAt { return "Retry available after \(retry.formatted(date: .abbreviated, time: .shortened))." }
        if let state = operation.reviewedCurrentState ?? operation.currentState, let revision = operation.reviewedCurrentRevision ?? operation.currentRevision { return "Current contribution: \(state.rawValue), revision \(revision)." }
        return status(item).rawValue
    }
    public func canRetry(_ item: CustomProductRevision) -> Bool {
        guard coordinator?.operationsReadFailed != true, let mine = snapshot(item), let last = mine.last else { return false }
        return last.clientRevisionID == item.revisionID && last.status == .pending && reviewBlocker(in: mine) == nil
    }
    public func canWithdraw(_ item: CustomProductRevision) -> Bool {
        // Withdrawal stops only on a failed read, as approved (#775); a write failure doesn't block removal.
        guard coordinator?.operationsReadFailed != true, let context = coordinator?.accountContext, context.profileReady,
              context.backendSupported, coordinator?.pauseReason == nil, let mine = snapshot(item),
              let operation = mine.last, operation.storeEpoch != nil else { return false }
        let current = status(item, in: mine)
        return current != .removed && current != .removalPending
    }
    public func canReview(_ item: CustomProductRevision) -> Bool {
        if canShare { return true }
        guard let context = coordinator?.accountContext, context.profileReady, context.backendSupported,
              coordinator?.pauseReason == nil, coordinator?.sharingBlocked == false,
              let operation = latest(item), operation.storeEpoch != nil else { return false }
        return operation.serverProductID != nil || operation.acknowledgedProductID != nil || canWithdraw(item)
    }
    private func isSettled(_ operation: ProductShareOperation) -> Bool {
        operation.reviewSettlementID != nil || [.acknowledged, .satisfied].contains(operation.status) ||
            (operation.status == .cancelled && (operation.publicationResolution != nil ||
                (operation.kind == .publish && operation.attempts == 0 && operation.envelope == nil)))
    }
    public func review(_ item: CustomProductRevision) async {
        guard !busy else { return }
        reviewGeneration = UUID(); let token = reviewGeneration
        preview = nil; errorMessage = nil
        guard canReview(item), let context = coordinator?.accountContext else { errorMessage = eligibilityText; return }
        busy = true; defer { busy = false }
        do {
            guard try store.customProducts().contains(item) else { throw CustomProductStoreError.localRevisionConflict }
            let last = latest(item)
            let ownHistory = try store.productOperations(ownerID: context.ownerID).filter { $0.localProductID == item.localProductID }
            let remoteID = ownHistory.reversed().compactMap { ($0.serverProductID ?? $0.acknowledgedProductID).flatMap(UUID.init(uuidString:)) }.first ?? item.source?.productID
            let blocker = ownHistory.last { !isSettled($0) && [.failed, .needsReview].contains($0.status) }
            for operation in ownHistory where !isSettled(operation) {
                if [.failed, .needsReview].contains(operation.status) { continue }
                let replaceableInitialPublication = blocker == nil && operation.kind == .publish && operation.attempts == 0 &&
                    operation.envelope == nil && operation.serverProductID == nil && operation.expectedServerRevision == nil &&
                    operation.predecessorOperationID == nil && [.pending, .paused].contains(operation.status)
                if replaceableInitialPublication { continue }
                guard blocker != nil, operation.kind == .publish, operation.attempts == 0,
                      operation.envelope == nil, operation.serverProductID == nil, operation.expectedServerRevision == nil,
                      operation.predecessorOperationID != nil, [.pending, .paused, .cancelled].contains(operation.status) else {
                    throw ProductAPIError.operationConflict
                }
            }
            var state: ProductContributionState?
            var sharedProduct: CommunityProduct?
            if let remoteID {
                guard let service else { throw ProductAPIError.unsupportedBackend }
                state = try await service.contribution(productID: remoteID, expectedOwnerID: context.ownerID)
                guard state?.productID == remoteID else { throw ProductAPIError.ownerMismatch }
                guard !Task.isCancelled, reviewGeneration == token, coordinator?.accountContext == context else { throw CustomProductStoreError.obsoleteOperation }
                do { sharedProduct = try await service.product(id: remoteID) }
                catch ProductAPIError.notFound { sharedProduct = nil }
                if let sharedProduct, sharedProduct.productID != remoteID { throw ProductAPIError.ownerMismatch }
            }
            guard !Task.isCancelled, reviewGeneration == token, coordinator?.accountContext == context, canReview(item), try store.customProducts().contains(item) else { throw CustomProductStoreError.obsoleteOperation }
            var reconciliation: ProductContributionReview?
            let expectedRevision = last?.reviewedCurrentRevision ?? last?.currentRevision
            let expectedState = last?.reviewedCurrentState ?? last?.currentState
            let authorityChanged = state.map { $0.currentRevision != expectedRevision || $0.currentState.rawValue != expectedState?.rawValue } ?? false
            if let anchor = blocker ?? (authorityChanged ? last : nil), let state, let storeEpoch = anchor.storeEpoch {
                reconciliation = ProductContributionReview(ownerID: context.ownerID, localProductID: item.localProductID, epoch: context.localSessionEpoch, storeEpoch: storeEpoch, blockingOperation: anchor, localRevisionID: item.revisionID, serverProductID: state.productID.uuidString.lowercased(), currentRevision: state.currentRevision, currentState: ProductAccountState(rawValue: state.currentState.rawValue)!, expectedOperationIDs: ownHistory.map(\.operationID))
            } else if let state {
                // Imported attribution alone cannot adopt another device's account authority.
                guard state.currentRevision == expectedRevision, state.currentState != .rejected else { throw ProductAPIError.revisionConflict(currentRevision: state.currentRevision, currentState: state.currentState) }
            }
            if blocker != nil && reconciliation == nil { throw ProductAPIError.operationConflict }
            preview = CustomProductSharePreview(revision: item, context: context, ownState: state, reconciliation: reconciliation, currentSharedProduct: sharedProduct)
        } catch {
            if reviewGeneration == token { errorMessage = "Could not prepare sharing review. Retry when connected. If this account already contributed on another device, this device cannot yet adopt that sharing history. Remove an unresolved pending contribution before reviewing again." }
        }
    }
    public func cancelReview() { reviewGeneration = UUID(); preview = nil }
    public func confirmShare() throws {
        guard let preview, preview.canPublish, canShare, coordinator?.accountContext == preview.context,
              try store.customProducts().contains(preview.revision) else { throw CustomProductStoreError.obsoleteOperation }
        let item = preview.revision, context = preview.context
        let operation = ProductShareOperation(ownerID: context.ownerID, localProductID: item.localProductID, operationID: UUID(), clientRevisionID: item.revisionID, kind: .publish, content: item.content, serverProductID: preview.ownState?.productID.uuidString.lowercased(), expectedServerRevision: preview.ownState?.currentRevision, consentVersion: context.consentVersion, consentGeneration: context.serverGeneration, epoch: context.localSessionEpoch)
        if let review = preview.reconciliation { try store.reconcileProductContribution(review, publication: operation) }
        else { try store.enqueueProductOperation(operation) }
        self.preview = nil; refreshID = UUID()
    }
    /// Keep the reviewed server state without publishing the edited local facts.
    public func keepCurrentContribution() throws {
        guard let preview, let review = preview.reconciliation, coordinator?.accountContext == preview.context,
              try store.customProducts().contains(preview.revision) else { throw CustomProductStoreError.obsoleteOperation }
        try store.reconcileProductContribution(review, publication: nil)
        self.preview = nil; refreshID = UUID()
    }
    public func withdraw(_ item: CustomProductRevision) throws {
        guard canWithdraw(item), let coordinator, let context = coordinator.accountContext,
              let last = latest(item), let epoch = last.storeEpoch else { throw CustomProductStoreError.obsoleteOperation }
        let operation = ProductShareOperation(ownerID: context.ownerID, localProductID: item.localProductID, operationID: UUID(), clientRevisionID: item.revisionID, kind: .withdraw, serverProductID: last.serverProductID ?? last.acknowledgedProductID, expectedServerRevision: last.reviewedCurrentRevision ?? last.currentRevision, epoch: context.localSessionEpoch)
        try coordinator.requestWithdrawal(operation, expectedStoreEpoch: epoch); refreshID = UUID()
    }
    public func retry(_ item: CustomProductRevision) async {
        if let operation = latest(item), operation.clientRevisionID == item.revisionID, canRetry(item) {
            await coordinator?.retry(operationID: operation.operationID)
        }
        refreshID = UUID()
    }
    /// Views observe durable changes even when delivery came from a foreground/connectivity trigger.
    @discardableResult public func refreshFromStore() -> Bool {
        let context = coordinator?.accountContext
        let operations = context.flatMap { coordinator?.operations(ownerID: $0.ownerID) }
        let pause = coordinator?.pauseReason
        guard operations != observedOperations || context != observedContext || pause != observedPause else { return false }
        observedOperations = operations; observedContext = context; observedPause = pause
        refreshID = UUID(); return true
    }
    public func observeStatus() async {
        while !Task.isCancelled {
            refreshFromStore()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    public func deliver() async { await coordinator?.runDueOperations(now: Date()); refreshID = UUID() }
}
