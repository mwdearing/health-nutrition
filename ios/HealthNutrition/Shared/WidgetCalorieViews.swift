import SwiftUI

extension WidgetSnapshot {
    /// The figures as Today words them. A figure that is absent is nil, never "0": Remaining is hidden without a goal
    /// and Burned without a burned value. Over goal is a plain negative number.
    var remainingText: String? { WidgetFigure.groupedWholeNumber(remainingKcal) }
    var burnedText: String? { WidgetFigure.groupedWholeNumber(burnedKcal) }

    /// Food, "N+" on a day where some entries have no calories: the known part, which is at least that.
    var foodText: String? {
        foodNumber.map { isPartial("energy") ? $0 + "+" : $0 }
    }

    private var foodNumber: String? { WidgetFigure.groupedWholeNumber(energyKcal) }

    /// Remaining is an upper bound when some entries have no calories, and says so ("Up to N") while there is
    /// something left. At or below zero it stays a plain number: being over already points the right way.
    var remainingIsUpperBound: Bool {
        remainingIsPartial == true && (remainingKcal?.rounded() ?? 0) > 0
    }

    /// Over goal: the positive count, captioned "Calories over goal" (#501).
    var remainingIsOver: Bool { (remainingKcal ?? 0) < 0 }

    /// The caption under the Remaining figure.
    var remainingCaption: String { remainingIsOver ? "Calories over goal" : "Calories remaining" }

    /// The Remaining figure as drawn: the positive count when over, "Up to N" on a partial day with something left,
    /// otherwise the number.
    var remainingDisplay: String? {
        if remainingIsOver { return WidgetFigure.groupedWholeNumber(-(remainingKcal ?? 0)) }
        return remainingText.map { remainingIsUpperBound ? "Up to \($0)" : $0 }
    }

    /// The one figure a small gauge holds: Food ("N+" when partial). The ring is the share of the goal eaten, so its
    /// centre is what was eaten, as before; Remaining is on the larger families and in the inline text.
    var gaugeHeadline: String? { foodText }

    /// Remaining for a single line of text: "up to N" on a partial day with something left, otherwise the number.
    var remainingInlineText: String? {
        if remainingIsOver { return WidgetFigure.groupedWholeNumber(-(remainingKcal ?? 0)).map { "\($0) over goal" } }
        return remainingText.map { remainingIsUpperBound ? "up to \($0)" : $0 }
    }

    /// What VoiceOver reads for the calorie block, in Today's order.
    var calorieSpoken: String {
        let parts = [
            remainingIsOver
                ? WidgetFigure.groupedWholeNumber(-(remainingKcal ?? 0)).map { "\($0) calories over goal" }
                : remainingText.map { (remainingIsUpperBound ? "up to " : "") + "\($0) calories remaining" },
            foodNumber.map { "Food, \(isPartial("energy") ? "at least " : "")\($0) calories" },
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
            if let remaining = snapshot?.remainingDisplay {
                Text(remaining)
                    .font(.title2.weight(.semibold))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .privacySensitive()
                Text(snapshot?.remainingCaption ?? "Calories remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .privacySensitive()
            }
            WidgetFoodBurned(snapshot: snapshot, vertical: verticalDetails)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot?.calorieSpoken ?? "Calories unknown")
    }
}
