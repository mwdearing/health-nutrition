import NutritionDomain
import NutritionJournal
import SwiftUI

/// One card of the Library's saved meals row.
public struct SavedMealCard: Equatable, Identifiable {
    public let id: String
    public let name: String
    /// "3 items · 412 calories"; just the items when the calories cannot be totaled.
    public let detail: String
    /// True for the first card, which sits on the hero.
    public let isHighlight: Bool
}

/// What the row says and when it shows. Plain values, so the wording and the rule are tested without a screen.
public enum SavedMealCards {
    /// One card per meal in the order given. A calorie total that is unknown is left out, never shown as zero.
    @MainActor
    public static func make(_ meals: [SavedMeal], calories: (SavedMeal) -> Decimal?) -> [SavedMealCard] {
        meals.enumerated().map { index, saved in
            let items = SavedMealsModel.itemsText(saved.items.count)
            let detail = calories(saved).map { items + " · " + energyCaption($0) } ?? items
            return SavedMealCard(id: saved.id, name: saved.name, detail: detail, isHighlight: index == 0)
        }
    }

    /// The row shows outside pick mode, with at least one saved meal and no search text.
    public static func isShown(inPickMode: Bool, mealCount: Int, searchText: String) -> Bool {
        !inPickMode && mealCount > 0 && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The meal's energy, summed from what its products state for the amounts saved; nil when any item cannot say.
    @MainActor
    public static func kilocalories(of saved: SavedMeal, store: any JournalStore) -> Decimal? {
        var total: Decimal = 0
        for item in saved.items {
            guard let template = RepeatTemplate(favorite: item), let component = template.components.first,
                let id = template.productSnapshotID, let snapshot = (try? store.product(snapshotID: id)) ?? nil,
                case .known(let amount, _) = DailyTotalsBuilder.value(
                    for: component, snapshot: snapshot, nutrient: "energy", lookup: SnapshotNutrientFacts()),
                let factor = DailyTotalsBuilder.scalingFactor(labelBasis: snapshot.labelBasis, logged: template.components)
            else { return nil }
            total += amount * factor
        }
        return total
    }
}

/// The Library's saved meals as a row of cards: the first on the hero, the others on content cards, each with a
/// button that asks which meal and logs through the saved meals model, with Undo.
public struct SavedMealCardRow: View {
    let cards: [SavedMealCard]
    @ObservedObject var savedMeals: SavedMealsModel
    let now: () -> Date
    let onAdded: () -> Void
    @State private var mealToLog: SavedMeal?
    @ScaledMetric(relativeTo: .body) private var cardWidth: CGFloat = 160

    public init(cards: [SavedMealCard], savedMeals: SavedMealsModel, now: @escaping () -> Date = { Date() },
                onAdded: @escaping () -> Void) {
        self.cards = cards; self.savedMeals = savedMeals; self.now = now; self.onAdded = onAdded
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s) {
            SectionHeader("Saved meals")
            if let warning = savedMeals.leftoverWarning { InlineNotice(warning, tone: .failed) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DesignSpacing.cardGap) {
                    ForEach(cards) { card in
                        if card.isHighlight {
                            HeroCard { content(card, secondary: TokenColors.heroSecondaryText) }
                                .frame(width: cardWidth).frame(maxHeight: .infinity)
                        } else {
                            ContentCard { content(card, secondary: TokenColors.textSecondary) }
                                .frame(width: cardWidth).frame(maxHeight: .infinity)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog(
            mealToLog.map { "Log \($0.name)" } ?? "Log saved meal",
            isPresented: Binding(get: { mealToLog != nil }, set: { if !$0 { mealToLog = nil } }),
            titleVisibility: .visible, presenting: mealToLog
        ) { saved in
            ForEach(SavedMealsModel.mealChoices(for: saved), id: \.self) { choice in
                Button(choice.map { "Log to \($0.displayName)" } ?? "Log with no meal") {
                    if savedMeals.log(saved, as: choice, now: now()) { onAdded() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { saved in
            Text("Adds \(SavedMealsModel.itemsText(saved.items.count)) now, as new entries. Like any entry, they are written to Apple Health once it is connected.")
        }
    }

    private func content(_ card: SavedMealCard, secondary: Color) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s) {
            Text(card.name).font(.headline)
            Text(card.detail).font(.subheadline).foregroundStyle(secondary)
            Spacer(minLength: DesignSpacing.xs)
            HStack {
                Spacer()
                Button {
                    mealToLog = savedMeals.meals.first { $0.id == card.id }
                } label: {
                    Image(systemName: "plus")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(TokenColors.hero)
                        .accessibilityHidden(true)
                        .frame(width: 44, height: 44)
                        .background(TokenColors.mint, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Log \(card.name)")
                .accessibilityHint("Asks which meal to log it under")
            }
        }
    }
}
