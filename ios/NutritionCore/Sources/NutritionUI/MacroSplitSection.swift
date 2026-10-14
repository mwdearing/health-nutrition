import SwiftUI
import NutritionDomain

/// The Goals screen's section for setting protein, carbohydrate and fat as percentages of the energy
/// goal. It writes ordinary gram goals, so the rows below and the bars on Today show the result.
struct MacroSplitSection: View {
    @ObservedObject var model: GoalsViewModel
    @State private var proteinText = ""
    @State private var carbohydrateText = ""
    @State private var fatText = ""
    @State private var failure: String?

    var body: some View {
        Section("Macros by percent") {
            if let unavailable = self.model.macroSplitUnavailable() {
                Text(unavailable.message)
                    .font(.body)
                    .foregroundStyle(TokenColors.textSecondary)
            } else {
                Text("Enter protein, carbohydrate and fat as percentages of your energy goal. They must total 100.")
                    .font(.body)
                    .foregroundStyle(TokenColors.textSecondary)
                if let current = self.model.currentMacroPercents() {
                    Text(
                        "Your gram goals now: protein \(DecimalFormatting.text(current.protein))%, "
                            + "carbohydrate \(DecimalFormatting.text(current.carbohydrate))%, "
                            + "fat \(DecimalFormatting.text(current.fat))% of your energy goal."
                    )
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
                }
                self.percentField("Protein percent", text: self.$proteinText)
                self.percentField("Carbohydrate percent", text: self.$carbohydrateText)
                self.percentField("Fat percent", text: self.$fatText)
                if let preview = self.previewText {
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(TokenColors.textSecondary)
                }
                Button("Set gram goals from percentages") {
                    self.failure = self.model.applyMacroSplit(
                        protein: self.proteinText, carbohydrate: self.carbohydrateText, fat: self.fatText)
                }
                .disabled(!self.canApply)
                if let failure = self.failure {
                    InlineNotice(failure, tone: .failed)
                }
                Text("If you change your energy goal later, set the percentages again to update the grams.")
                    .font(.footnote)
                    .foregroundStyle(TokenColors.textSecondary)
            }
        }
    }

    private var isEmpty: Bool {
        [self.proteinText, self.carbohydrateText, self.fatText].allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var canApply: Bool {
        if case .success = self.model.macroSplitGrams(
            protein: self.proteinText, carbohydrate: self.carbohydrateText, fat: self.fatText)
        {
            return true
        }
        return false
    }

    /// What the typed percentages come to, or what is wrong with them. Nothing while all are empty.
    private var previewText: String? {
        guard !self.isEmpty else { return nil }
        switch self.model.macroSplitGrams(
            protein: self.proteinText, carbohydrate: self.carbohydrateText, fat: self.fatText)
        {
        case .success(let grams):
            return "That is \(DecimalFormatting.text(grams.protein)) g protein, "
                + "\(DecimalFormatting.text(grams.carbohydrate)) g carbohydrate and "
                + "\(DecimalFormatting.text(grams.fat)) g fat a day."
        case .failure(let problem):
            return problem.message
        }
    }

    private func percentField(_ label: String, text: Binding<String>) -> some View {
        LabeledField(label) { focus in
            TextField(text: text, prompt: Text("0")) {
                Text(label)
            }
            .labelsHidden()
            .font(.body)
            .foregroundStyle(TokenColors.textPrimary)
            .percentKeyboard()
            .focused(focus)
        }
    }
}

private extension View {
    @ViewBuilder
    func percentKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}
