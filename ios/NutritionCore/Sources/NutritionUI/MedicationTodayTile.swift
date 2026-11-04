import SwiftUI

/// The lines the Medications tile on Today shows: one plain fact per active medication, at most three, and a
/// count of any left over. The site and the note of a dose are never read or shown.
public struct MedicationTodayTileContent: Equatable {
    /// The lines to show, in display order.
    public let lines: [String]

    /// Creates the content from the lines to show.
    /// - Parameter lines: The lines, already formatted for display.
    public init(lines: [String]) {
        self.lines = lines
    }

    /// The most medication lines the tile shows before it counts the rest.
    public static let lineLimit = 3

    /// The heading of the tile.
    public static let title = "Medications"

    /// The hint read after the tile's label, describing what a tap does.
    public static let accessibilityHint = "Opens your medication log"

    /// The text VoiceOver reads for the whole tile: the title followed by every line.
    public var accessibilityText: String {
        ([Self.title] + lines).joined(separator: ", ")
    }

    /// One line per medication row, each giving the name and its standing: the schedule standing when there is
    /// one, otherwise the days since the last dose, otherwise the time of the last dose.
    /// - Parameter rows: The medication rows to describe, in the order given.
    /// - Returns: One line for each row. No row is left out.
    public static func lines(for rows: [MedicationRow]) -> [String] {
        rows.map { row in
            let standing = row.statusText ?? row.daysSinceText ?? row.lastDoseText
            return "\(row.name): \(standing)"
        }
    }

    /// The tile's content for the current state of the Medication log.
    /// - Parameter model: The Medication log view model that supplies the rows and the switch.
    /// - Returns: `nil` while the Medication log is off. Otherwise a line for each of the first ``lineLimit``
    ///   medications, a count of the rest, or a prompt when there are no medications or the log could not be read.
    @MainActor
    public static func make(from model: MedicationLogViewModel) -> MedicationTodayTileContent? {
        guard model.isOn else { return nil }
        guard !model.rows.isEmpty else {
            let text = model.errorMessage != nil ? "Could not read the medication log." : "Add a medication"
            return MedicationTodayTileContent(lines: [text])
        }
        let all = lines(for: model.rows)
        var shown = Array(all.prefix(lineLimit))
        let left = all.count - lineLimit
        if left > 0 {
            shown.append("\(left) more")
        }
        return MedicationTodayTileContent(lines: shown)
    }
}

/// Today's way into the medication log: the medications with their standing, and a tap opens the log.
struct MedicationsTodayTile: View {
    /// The Medication log view model that supplies the rows and the switch.
    @ObservedObject var model: MedicationLogViewModel

    var body: some View {
        if let content = MedicationTodayTileContent.make(from: model) {
            NavigationLink {
                MedicationLogView(model: model)
            } label: {
                Card {
                    HStack(spacing: DesignSpacing.m) {
                        Image(systemName: "cross.case")
                            .foregroundStyle(TokenColors.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
                            Text(MedicationTodayTileContent.title)
                                .font(.headline)
                                .foregroundStyle(TokenColors.textPrimary)
                            ForEach(Array(content.lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.footnote)
                                    .foregroundStyle(TokenColors.textSecondary)
                            }
                        }
                        Spacer(minLength: DesignSpacing.s)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(TokenColors.textSecondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content.accessibilityText)
            .accessibilityHint(MedicationTodayTileContent.accessibilityHint)
            .onAppear { model.load() }
        } else {
            EmptyView()
        }
    }
}
