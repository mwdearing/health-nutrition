import Foundation

/// Why a community call failed. Cases carry no text, so a token, key or email can never end up in a message.
public enum CommunityError: Error, Equatable, Sendable {
    /// The build has no project settings, so there is no account UI and no calls are made.
    case notConfigured
    /// No signed-in account, or the sign-in ended and cannot be renewed.
    case signedOut
    /// The person has turned community sharing off in Settings.
    case sharingOff
    case invalid
    case rateLimited
    case unauthorized
    /// The request never got a reply.
    case network
    /// The reply had an unexpected HTTP status.
    case server(Int)
    /// The session could not be written to the Keychain.
    case storage

    /// Maps a failed reply. The body is read only for a PostgREST error code (SQLSTATE) and is not kept.
    static func from(status: Int, body: Data) -> CommunityError {
        if let code = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.code {
            switch code {
            case "28000": return .signedOut
            case "42501": return .sharingOff
            case "22023": return .invalid
            case "53400": return .rateLimited
            default: break
            }
        }
        switch status {
        case 400, 422: return .invalid
        case 401, 403: return .unauthorized
        case 429: return .rateLimited
        default: return .server(status)
        }
    }

    private struct ErrorBody: Decodable {
        let code: String?
    }
}
