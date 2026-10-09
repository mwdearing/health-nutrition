import Foundation
import NutritionDomain
import NutritionJournal

public struct RecipeValueRow: Equatable, Identifiable {
    public let id: String
    public let label: String
    /// A rounded value with its unit, or "unknown".
    public let text: String
}

@MainActor
public final class RecipeDetailViewModel: ObservableObject {
    @Published public var portionText: String = "1" {
        didSet { recalculate() }
    }
    @Published public private(set) var rows: [RecipeValueRow] = []
    @Published public private(set) var coverageTexts: [String] = []
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var logMessage: String?

    public let version: RecipeVersion

    private let journal: JournalStore
    private let timeZoneIdentifier: String
    private let makeID: () -> String
    private let totals: RecipeTotals

    public init(
        version: RecipeVersion,
        journal: JournalStore,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        makeID: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.version = version
        self.journal = journal
        self.timeZoneIdentifier = timeZoneIdentifier
        self.makeID = makeID
        self.totals = RecipeMath.totals(of: version)
        self.coverageTexts = RecipeCoverage.make(from: totals).filter { !$0.isComplete }.map {
            $0.text(nutrientName: RecipeNutrientField.label(for: $0.nutrientID).lowercased())
        }
        recalculate()
    }

    public var provenanceText: String { "Calculated from version \(version.number)" }

    public var portionUnitText: String {
        switch version.yield {
        case .servings: return "servings"
        case .total(let quantity): return quantity.unit.symbol
        }
    }

    public var portionLabel: String { "\(RecipeLabels.portionField) in \(portionUnitText)" }

    static func valueText(_ value: NutrientValue) -> String {
        switch value {
        case .known(let amount, let unit):
            return "\(DecimalFormatting.text(DisplayRounding.rounded(amount, fractionDigits: 1))) \(unit.symbol)"
        case .unknown, .notApplicable, .belowReportingThreshold:
            return "unknown"
        }
    }

    private func recalculate() {
        guard let portion = AmountParser.parseTyped(portionText) else {
            rows = []
            errorMessage = "Enter a portion greater than zero, using digits and a point."
            return
        }
        do {
            let values = try RecipeMath.perPortion(totals, yield: version.yield, portion: portion)
            rows = values.keys.sorted().map { key in
                RecipeValueRow(
                    id: key, label: RecipeNutrientField.label(for: key), text: Self.valueText(values[key] ?? .unknown))
            }
            errorMessage = nil
        } catch {
            rows = []
            errorMessage = "This portion cannot be calculated."
        }
    }

    /// Writes one intake for the portion. Unknown nutrients are left out, never written as zero.
    @discardableResult
    public func logPortion(now: Date) -> Bool {
        guard let portion = AmountParser.parseTyped(portionText) else {
            errorMessage = "Enter a portion greater than zero, using digits and a point."
            return false
        }
        do {
            try RecipeLogger.logPortion(
                store: journal, version: version, portion: portion, now: now, id: makeID(),
                timeZoneIdentifier: timeZoneIdentifier, meal: nil)
            logMessage = "Logged \(portionText) \(portionUnitText) of \(version.title)."
            errorMessage = nil
            return true
        } catch RecipeError.nothingToLog {
            errorMessage = "No nutrient value is known, so nothing was logged."
            return false
        } catch {
            errorMessage = "Could not log the portion."
            return false
        }
    }
}
