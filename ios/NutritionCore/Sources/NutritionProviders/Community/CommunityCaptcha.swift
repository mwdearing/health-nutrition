import Foundation

/// Supplies the token of a human check (a CAPTCHA challenge) that the sign-in service requires before it sends a
/// one-time code or signs a person in. A token is single use, so every code request asks for a new one.
/// A thrown error means the check was not completed, for example because the person closed the challenge.
public protocol CommunityCaptcha: Sendable {
    func token() async throws -> String
}
