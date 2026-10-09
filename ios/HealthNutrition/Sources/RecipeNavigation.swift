import Foundation
import NutritionJournal

/// Where the recipe screens navigate to inside their own stack.
enum RecipeRoute: Hashable {
    case detail(RecipeVersion)
    /// nil while creating a new recipe, a version while editing one.
    case editor(RecipeVersion?)
}

/// The recipe sheet's navigation state, held on its own object rather than as view state.
///
/// The erase on the Connections and privacy screen has to close the recipe sheet and drop every route
/// in it: a detail or an editor screen holds its own copy of a recipe, so an erased recipe would
/// otherwise stay on screen and could still be logged. That reaction is behavior, not layout, so it
/// lives here where a test can call it. `RootView` owns this object for its whole lifetime and calls
/// `reset()` from its erase handler; the sheet and the stack read the published properties, so the
/// screen behaves exactly as it did with plain view state.
@MainActor
final class RecipeNavigation: ObservableObject {
    /// Whether the recipes sheet is presented.
    @Published var showingRecipes = false
    /// The routes pushed over the recipe list. Empty when the list is the only screen.
    @Published var path: [RecipeRoute] = []

    /// Opens the recipes sheet from a clean stack, so a recipe left open earlier is not behind it.
    func open() {
        path = []
        showingRecipes = true
    }

    /// After an erase: close the sheet and drop every route in it.
    ///
    /// Both together, and in this order: clearing the path alone would leave the sheet showing an
    /// empty list over erased data, and closing alone would leave the routes waiting for the next time
    /// the sheet opened.
    func reset() {
        path = []
        showingRecipes = false
    }
}
