import Foundation
import NutritionUI

/// Prefill is held by identity: the form itself is owned by RootView for the whole pushed route.
enum AddRoute: Hashable {
    case barcodeScanner
    case labelScanner
    case library
    case details(UUID?)
}

@MainActor
final class AddNavigationModel: ObservableObject {
    @Published var path: [AddRoute] = []

    func reset() { path = [] }
}
