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
        saveFeedback(notice).saveConfirmationLine(notice)
    }

    /// The success haptic and the VoiceOver announcement for each new notice, once. No visual.
    func saveFeedback(_ notice: SaveNotice?) -> some View {
        modifier(SaveFeedbackModifier(notice: notice))
    }

    /// The brief visual line for each new notice, resting at the bottom of the view it is attached to.
    /// Attach it inside a tab so the line sits above the tab bar.
    func saveConfirmationLine(_ notice: SaveNotice?) -> some View {
        modifier(SaveConfirmationLineModifier(notice: notice))
    }
}

private struct SaveFeedbackModifier: ViewModifier {
    let notice: SaveNotice?

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.success, trigger: notice?.id) { _, new in new != nil }
            .onChange(of: notice) { _, new in
                guard let new else { return }
                #if os(iOS)
                AccessibilityNotification.Announcement(new.message).post()
                #endif
            }
    }
}

private struct SaveConfirmationLineModifier: ViewModifier {
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
                        .glassEffect(.regular, in: Capsule())
                        .padding(DesignSpacing.m)
                        // VoiceOver hears the announcement posted by saveFeedback, so the visual line stays silent.
                        .accessibilityHidden(true)
                        // The line is information only, so taps on the controls behind it still reach them.
                        .allowsHitTesting(false)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: shown?.id)
            .onChange(of: notice) { _, new in
                guard let new else { return }
                shown = new
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    if shown == new { shown = nil }
                }
            }
    }
}

/// The confirmation line for each save. Wording approved by Mike on 2026-10-16 ("Ok and merge"): the recommended lines below.
public enum SaveLabels {
    public static let productSaved = "Product saved"
    /// The product was saved on this device only because the screen's share promise no longer held.
    public static let productSavedOnDeviceOnly = "Saved on this device only; sharing isn't available right now"
    /// The confirmation after the product editor saves.
    public static func productSaved(afterSharePromiseLost lost: Bool) -> String { lost ? productSavedOnDeviceOnly : productSaved }
    public static let entrySaved = "Entry saved"
    public static let loggedToDiary = "Logged to Diary"
    public static let recipeSaved = "Recipe saved"
    public static let mealSaved = "Meal saved"
    public static let goalsSaved = "Goals saved"
    public static let scheduleSaved = "Schedule saved"
    public static let nutrientSaved = "Nutrient saved"
}
