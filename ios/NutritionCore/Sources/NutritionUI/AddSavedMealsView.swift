import NutritionJournal
import SwiftUI

/// What the saved meals list on Add does: logs with Add's meal choice, or asks which meal when Add has none.
@MainActor
public final class AddSavedMealsViewModel: ObservableObject {
    public let savedMeals: SavedMealsModel
    /// The meal chosen on Add; nil when none is chosen.
    public let meal: MealLabel?
    /// The saved meal waiting for an answer to "which meal"; nil when nothing is asked.
    @Published public private(set) var mealToAsk: SavedMeal?
    private let now: () -> Date

    public init(savedMeals: SavedMealsModel, meal: MealLabel?, now: @escaping () -> Date = { Date() }) {
        self.savedMeals = savedMeals; self.meal = meal; self.now = now
    }

    /// The Saved meal tile shows only when at least one saved meal exists.
    public nonisolated static func showsTile(savedMealCount: Int) -> Bool { savedMealCount > 0 }

    /// The choices offered when a meal is asked for, the same as on the Library cards.
    public var mealChoices: [MealLabel?] { mealToAsk.map { SavedMealsModel.mealChoices(for: $0) } ?? [] }

    /// A tap on a saved meal: logs it now with Add's meal, or asks which meal when Add has none.
    /// True when it was logged.
    @discardableResult
    public func choose(_ saved: SavedMeal) -> Bool {
        guard let meal else { mealToAsk = saved; return false }
        return log(saved, as: meal)
    }

    /// Logs through the saved meals model, which offers Undo for exactly what it wrote.
    @discardableResult
    public func log(_ saved: SavedMeal, as choice: MealLabel?) -> Bool {
        mealToAsk = nil
        return savedMeals.log(saved, as: choice, now: now())
    }

    public func cancelAsk() { mealToAsk = nil }
}

/// The saved meals on Add: one row per meal, a tap logs it with Add's meal and offers Undo.
public struct AddSavedMealsView: View {
    @StateObject private var model: AddSavedMealsViewModel
    @ObservedObject private var savedMeals: SavedMealsModel
    private let calories: (SavedMeal) -> Decimal?
    private let onLogged: () -> Void

    public init(savedMeals: SavedMealsModel, meal: MealLabel?, now: @escaping () -> Date = { Date() },
                calories: @escaping (SavedMeal) -> Decimal?, onLogged: @escaping () -> Void) {
        _model = StateObject(wrappedValue: AddSavedMealsViewModel(savedMeals: savedMeals, meal: meal, now: now))
        self.savedMeals = savedMeals; self.calories = calories; self.onLogged = onLogged
    }

    public var body: some View {
        let cards = SavedMealCards.make(savedMeals.meals, calories: calories)
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSpacing.m) {
                if let warning = savedMeals.leftoverWarning { InlineNotice(warning, tone: .failed) }
                if let notice = savedMeals.notice, savedMeals.noticeIsFailure { InlineNotice(notice, tone: .failed) }
                if let error = savedMeals.loadError { InlineNotice(error, tone: .failed) }
                ContentCard {
                    VStack(spacing: 0) {
                        ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                            if index > 0 { Divider() }
                            row(card)
                        }
                    }
                }
            }
            .padding(DesignSpacing.m)
        }
        .background(TokenColors.page)
        .navigationTitle("Saved meals")
        .onAppear { savedMeals.load() }
        .safeAreaInset(edge: .bottom) { SavedMealUndoBar(model: savedMeals) }
        .confirmationDialog(
            model.mealToAsk.map { "Log \($0.name)" } ?? "Log saved meal",
            isPresented: Binding(get: { model.mealToAsk != nil }, set: { if !$0 { model.cancelAsk() } }),
            titleVisibility: .visible, presenting: model.mealToAsk
        ) { saved in
            ForEach(model.mealChoices, id: \.self) { choice in
                Button(choice.map { "Log to \($0.displayName)" } ?? "Log with no meal") {
                    if model.log(saved, as: choice) { onLogged() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { saved in
            Text("Adds \(SavedMealsModel.itemsText(saved.items.count)) now, as new entries. Like any entry, they are written to Apple Health once it is connected.")
        }
    }

    private func row(_ card: SavedMealCard) -> some View {
        Button {
            guard let saved = savedMeals.meals.first(where: { $0.id == card.id }) else { return }
            if model.choose(saved) { onLogged() }
        } label: {
            VStack(alignment: .leading) {
                Text(card.name).font(.headline)
                Text(card.detail).font(.subheadline).foregroundStyle(TokenColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44)
            .foregroundStyle(TokenColors.textPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Log \(card.name), \(card.detail)")
        .accessibilityHint("Logs it now, with Undo for ten seconds")
    }
}
