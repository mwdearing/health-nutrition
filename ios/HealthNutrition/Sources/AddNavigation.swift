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

    func openProduct(_ product: CustomProductRevision, home: AddHomeViewModel, now: Date) throws {
        let model = try home.makeDetails(product: product, now: now)
        path.append(.details(AddPrefill(model: model)))
    }
    func reset() { path = [] }
}
