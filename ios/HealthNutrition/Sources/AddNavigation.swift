import Foundation
import NutritionUI

/// Carries the exact prefilled form; identity keeps editable models out of value equality.
struct AddPrefill: Hashable {
    let model: AddIntakeViewModel

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model.formID == rhs.model.formID }
    func hash(into hasher: inout Hasher) { hasher.combine(model.formID) }
}

/// The methods and their prefilled details inside the Add stack.
enum AddRoute: Hashable {
    case barcodeScanner
    case labelScanner
    case library
    case details(AddPrefill?)
}

@MainActor
final class AddNavigationModel: ObservableObject {
    @Published var path: [AddRoute] = []

    func reset() { path = [] }
}
