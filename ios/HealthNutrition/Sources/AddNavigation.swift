import Foundation
import NutritionUI
import NutritionDomain

/// Carries the exact prefilled form; identity keeps editable models out of value equality.
struct AddPrefill: Hashable {
    let model: AddIntakeViewModel

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model.formID == rhs.model.formID }
    func hash(into hasher: inout Hasher) { hasher.combine(model.formID) }
}

struct ProductEditorPrefill: Hashable {
    let model: CustomProductEditorViewModel
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model.id == rhs.model.id }
    func hash(into hasher: inout Hasher) { hasher.combine(model.id) }
}

/// The methods and their prefilled details inside the Add stack.
enum AddRoute: Hashable {
    case barcodeScanner
    case labelScanner
    case library
    case productSearch
    case productEditor(ProductEditorPrefill)
    case details(AddPrefill?)
}

@MainActor
final class AddNavigationModel: ObservableObject {
    @Published var path: [AddRoute] = []

    /// Opens the details form filled from an Open Food Facts name-search result.
    func openLookedUp(_ product: LookedUpProduct, kind: ProductKind?, home: AddHomeViewModel) {
        let model = home.makeDetails(now: Date())
        model.applyLookedUp(product)
        // The kind picked on the search screen is kept; a source with no kind of its own is food by default.
        if let kind { model.kind = kind }
        path.append(.details(AddPrefill(model: model)))
    }
    func openProduct(_ product: CustomProductRevision, home: AddHomeViewModel, now: Date) throws {
        let model = try home.makeDetails(product: product, now: now)
        path.append(.details(AddPrefill(model: model)))
    }
    func reset() { path = [] }
}
