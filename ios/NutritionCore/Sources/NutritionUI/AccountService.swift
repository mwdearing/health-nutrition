import Foundation
import NutritionProviders

/// What the account screens need from the community client. The view model depends on this seam and never
/// on the network, so a test can stand in a fake.
public protocol CommunityAccountServicing: Sendable {
    /// The stored session, renewed when it is near expiry. Nil when nobody is signed in or the sign-in can no
    /// longer be renewed.
    func restore() async -> CommunitySession?
    func signInWithApple(idToken: String, nonce: String) async throws -> CommunitySession
    func requestEmailCode(email: String) async throws
    func verifyEmailCode(email: String, code: String) async throws -> CommunitySession
    func signOut() async
    func profile() async throws -> CommunityProfile
    func updateProfile(displayName: String?, shareLabels: Bool) async throws -> CommunityProfile
    func deleteAccount() async throws
}

/// The community client is the service the screens use. Each call is the client's own.
extension CommunityClient: CommunityAccountServicing {
    public func restore() async -> CommunitySession? {
        try? await auth.validSession()
    }

    public func signInWithApple(idToken: String, nonce: String) async throws -> CommunitySession {
        try await auth.signInWithApple(idToken: idToken, nonce: nonce)
    }

    public func requestEmailCode(email: String) async throws {
        try await auth.requestEmailCode(email: email)
    }

    public func verifyEmailCode(email: String, code: String) async throws -> CommunitySession {
        try await auth.verifyEmailCode(email: email, code: code)
    }

    public func signOut() async {
        await auth.signOut()
    }
}
