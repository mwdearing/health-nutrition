import Foundation

/// What Find products does when the person taps Sign in. Sign-in opens over the search when this build has
/// an account to sign in to; with none, no Sign in control is offered at all.
public enum SearchSignIn: Equatable {
    case unavailable
    case presentOverSearch

    public static func choose(hasAccount: Bool) -> SearchSignIn {
        hasAccount ? .presentOverSearch : .unavailable
    }
}
