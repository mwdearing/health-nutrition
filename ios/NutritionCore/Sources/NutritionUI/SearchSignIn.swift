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

    /// Whether the Shared products section is on screen. It is hidden only when the search has nothing to say about
    /// shared products: signed out in a build with no account, so there is no sign-in line either.
    public static func showsSharedProducts(state: CommunityProductSearchState, hasAccount: Bool, signedIn: Bool) -> Bool {
        guard state == .signInRequired else { return true }
        return signedOutLine(hasAccount: hasAccount, signedIn: signedIn) == .signInMessage
    }
}
