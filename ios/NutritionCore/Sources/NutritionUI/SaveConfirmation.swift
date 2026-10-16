import SwiftUI

/// One successful save. A new value each time (new id), so saving twice in a row confirms twice.
public struct SaveNotice: Equatable {
    public let id = UUID()
    public let message: String

    public init(_ message: String) { self.message = message }
}

public extension View {
    /// Shows a brief "Saved" line when `notice` changes, with a success haptic and a VoiceOver announcement.
    /// Attach it to the screen that stays on screen after the save, or to the screen the editor returns to.
    func saveConfirmation(_ notice: SaveNotice?) -> some View {
        modifier(SaveConfirmationModifier(notice: notice))
    }
}

private struct SaveConfirmationModifier: ViewModifier {
    let notice: SaveNotice?
    @State private var shown: SaveNotice?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let shown {
                    Label(shown.message, systemImage: "checkmark.circle.fill")
                        .font(.body.weight(.medium))
                        .foregroundStyle(TokenColors.textPrimary)
                        .padding(DesignSpacing.m)
                        .background(TokenColors.accentTint, in: RoundedRectangle(cornerRadius: DesignRadius.control))
                        .padding(DesignSpacing.m)
                        // VoiceOver hears the announcement posted below, so the visual line stays silent.
                        .accessibilityHidden(true)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: shown?.id)
            .sensoryFeedback(.success, trigger: notice?.id) { _, new in new != nil }
            .onChange(of: notice) { _, new in
                guard let new else { return }
                shown = new
                #if os(iOS)
                AccessibilityNotification.Announcement(new.message).post()
                #endif
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    if shown == new { shown = nil }
                }
            }
    }
}

/// The confirmation line for each save. Nutrient, supplement and goals wording needs Mike's approval before it ships.
public enum SaveLabels {
    public static let productSaved = "Product saved"
    public static let entrySaved = "Entry saved"
    public static let loggedToDiary = "Logged to Diary"
    public static let recipeSaved = "Recipe saved"
    public static let mealSaved = "Meal saved"
    public static let goalsSaved = "Goals saved"          // proposed, pending Mike
    public static let scheduleSaved = "Schedule saved"    // proposed, pending Mike
    public static let nutrientSaved = "Nutrient saved"    // proposed, pending Mike
}
