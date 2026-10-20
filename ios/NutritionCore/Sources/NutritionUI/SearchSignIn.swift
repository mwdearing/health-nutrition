import Foundation

/// What the Search foods screen does when the person taps Sign in. Sign-in opens over the search when this build has
/// an account to sign in to; with none, no Sign in control is offered at all.
public enum SearchSignIn: Equatable {
    case unavailable
    case presentOverSearch

    public static func choose(hasAccount: Bool) -> SearchSignIn {
        hasAccount ? .presentOverSearch : .unavailable
    }

    /// The shared-products line when the search can't reach shared products. Shown only in a build with an account to
    /// sign in to, and only to a person who is not signed in. A build with no account gets no sign-in line at all.
    public enum SignedOutLine: Equatable {
        case none, signInMessage
    }

    public static func signedOutLine(hasAccount: Bool, signedIn: Bool) -> SignedOutLine {
        hasAccount && !signedIn ? .signInMessage : .none
    }
}
