/// What the shell does when the tab selection changes onto a tab that only opens something.
///
/// The Settings tab shows no screen of its own: choosing it opens the settings sheet and puts the selection
/// back on the tab the person came from. Kept apart from the view so the rule can be tested.
enum SettingsTabRedirect<Tab: Hashable> {
    struct Outcome: Equatable {
        /// The tab the shell should be showing after the change.
        let selection: Tab
        /// Whether the settings sheet should open.
        let opensSettings: Bool
    }

    /// - Parameters:
    ///   - previous: the tab shown before the change.
    ///   - current: the tab just chosen.
    ///   - settings: the tab that only opens settings.
    ///   - fallback: where to land when settings was already the previous tab, so it can never stay selected.
    static func resolve(previous: Tab, current: Tab, settings: Tab, fallback: Tab) -> Outcome {
        guard current == settings else { return Outcome(selection: current, opensSettings: false) }
        return Outcome(selection: previous == settings ? fallback : previous, opensSettings: true)
    }
}
