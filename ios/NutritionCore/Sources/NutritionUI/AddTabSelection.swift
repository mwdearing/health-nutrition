/// The rule for the separated Add tab: choosing it opens Add and leaves the tab that was showing selected.
public enum AddTabSelection {
    public struct Outcome<Value: Hashable>: Hashable {
        public let selection: Value
        public let opensAdd: Bool

        public init(selection: Value, opensAdd: Bool) {
            self.selection = selection
            self.opensAdd = opensAdd
        }
    }

    public static func resolve<Value: Hashable>(requested: Value, current: Value, add: Value) -> Outcome<Value> {
        requested == add ? Outcome(selection: current, opensAdd: true) : Outcome(selection: requested, opensAdd: false)
    }
}
