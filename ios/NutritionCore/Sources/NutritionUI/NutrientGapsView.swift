import NutritionDomain
import SwiftUI

/// Today's vitamins and minerals against the published reference values for the group a person picks.
///
/// The screen states comparisons and nothing else: below, reached, above an upper limit, or not known.
/// It gives no advice and no score, and it says plainly that the values are population references.
public struct NutrientGapsView: View {
    @StateObject private var model: NutrientGapsViewModel
    private let now: () -> Date

    /// `makeModel` is called once for the life of the screen, so returning to it keeps the same model.
    public init(makeModel: @escaping () -> NutrientGapsViewModel, now: @escaping () -> Date = { Date() }) {
        _model = StateObject(wrappedValue: makeModel())
        self.now = now
    }

    public var body: some View {
        List {
            Section {
                Picker("Compare with", selection: Binding(
                    get: { model.referenceGroup },
                    set: { model.chooseReferenceGroup($0) })) {
                    Text("Nothing").tag(ReferenceGroup?.none)
                    ForEach(ReferenceGroup.all, id: \.self) { group in
                        Text(group.label).tag(ReferenceGroup?.some(group))
                    }
                }
                .accessibilityHint("Chooses whose published reference values today is compared with")
                Text(NutrientGapsCopy.intro(hasGroup: model.referenceGroup != nil))
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
            }
            if let message = model.errorMessage {
                InlineNotice(message, tone: .failed)
            }
            if let notice = model.skippedNotice {
                InlineNotice(notice, tone: .waiting)
            }
            ForEach(model.sections) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        NutrientGapRowView(row: row)
                    }
                }
            }
            Section {
                Text(NutrientGapsCopy.footer)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(TokenColors.background)
        .navigationTitle("Vitamins and minerals")
        .onAppear { model.load(now: now()) }
    }
}

/// The screen's fixed sentences, in one place so a test can read them.
public enum NutrientGapsCopy {
    public static func intro(hasGroup: Bool) -> String {
        hasGroup
            ? "Today's amounts beside the published adult values for this group."
            : "Pick a group to see today's amounts beside its published adult values."
    }

    public static let footer = "Reference values are the published adult RDA (Recommended Dietary Allowance) "
        + "or AI (Adequate Intake) and upper limit, from the NIH Office of Dietary Supplements. They describe "
        + "populations, not you, and are not advice. They do not cover anyone under 19. "
        + "Unknown means an entry does not state the nutrient, not that it has none."
}

/// One nutrient: its name and the day's figure, a bar against the reference when there is one, and
/// the lines that say what the figure is made of. Read as one element.
struct NutrientGapRowView: View {
    let row: NutrientGapRow

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.label)
                    .font(.subheadline)
                    .foregroundStyle(TokenColors.textPrimary)
                Spacer(minLength: DesignSpacing.s)
                Text(row.amountText)
                    .font(.subheadline)
                    .foregroundStyle(row.tally.known > 0 ? TokenColors.textPrimary : TokenColors.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
            if row.foodFraction != nil {
                track
            }
            if let status = row.statusText {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(row.status == .aboveUpperLimit ? TokenColors.warning : TokenColors.textPrimary)
            }
            if let reference = row.referenceText {
                Text(reference)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
            }
            ForEach(row.detailLines, id: \.self) { line in
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityText)
    }

    /// Food then supplements, side by side along one track, against the reference.
    private var track: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let food = GoalBar.drawingWidth(of: row.foodFraction ?? 0, in: width)
            let supplements = GoalBar.drawingWidth(of: row.supplementFraction ?? 0, in: width)
            ZStack(alignment: .leading) {
                Capsule().fill(TokenColors.track)
                HStack(spacing: 0) {
                    Rectangle().fill(TokenColors.accent).frame(width: food)
                    Rectangle().fill(TokenColors.mint).frame(width: min(supplements, max(width - food, 0)))
                }
                .clipShape(Capsule())
                if let marker = row.referenceMarker {
                    Rectangle()
                        .fill(TokenColors.textPrimary)
                        .frame(width: 2)
                        .offset(x: GoalBar.drawingWidth(of: marker, in: width) - 1)
                }
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}
