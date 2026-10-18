import SwiftUI

extension WidgetSnapshot {
    /// The figures as Today words them. A figure that is absent is nil, never "0": Remaining is hidden without a goal
    /// and Burned without a burned value. Over goal is a plain negative number.
    var remainingText: String? { WidgetFigure.groupedWholeNumber(remainingKcal) }
    var foodText: String? { WidgetFigure.groupedWholeNumber(energyKcal) }
    var burnedText: String? { WidgetFigure.groupedWholeNumber(burnedKcal) }

    /// What VoiceOver reads for the calorie block, in Today's order.
    var calorieSpoken: String {
        let parts = [
            remainingText.map { "\($0) calories remaining" },
            foodText.map { "Food, \($0) calories" },
            burnedText.map { "Burned, \($0) calories" },
        ].compactMap { $0 }
        return parts.isEmpty ? "Calories unknown" : parts.joined(separator: ", ")
    }
}

/// Food and Burned, each with its icon, as Today shows them: a fork and knife for food, a flame for burned. Burned
/// is left out when there is none; Food shows a dash when nothing is known.
struct WidgetFoodBurned: View {
    let snapshot: WidgetSnapshot?
    var vertical = false

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Label {
                Text("\(snapshot?.foodText ?? "—") Food")
            } icon: {
                Image(systemName: "fork.knife")
            }
            if let burned = snapshot?.burnedText {
                Label {
                    Text("\(burned) Burned")
                } icon: {
                    Image(systemName: "flame")
                }
            }
        }
        .font(.footnote)
        .privacySensitive()
    }
}

/// Remaining in large type with "Calories remaining" under it, then Food and Burned, as Today lays them out.
/// Without a Remaining only Food and Burned are shown.
struct WidgetCalorieSummary: View {
    let snapshot: WidgetSnapshot?
    var verticalDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let remaining = snapshot?.remainingText {
                Text(remaining)
                    .font(.title2.weight(.semibold))
                    .privacySensitive()
                Text("Calories remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            WidgetFoodBurned(snapshot: snapshot, vertical: verticalDetails)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot?.calorieSpoken ?? "Calories unknown")
    }
}
