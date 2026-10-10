import Foundation

/// The Supabase project the community client talks to. The values come from the build settings
/// that the signed build copies into Info.plist, so no project address or key is committed here.
public struct CommunityConfig: Sendable {
    public let baseURL: URL
    public let anonKey: String

    private static let hostSuffix = ".supabase.co"

    /// Nil when either value is blank, the URL is not https with a plain Supabase host, or the key is missing.
    public init?(infoDictionary: [String: Any]?) {
        let urlText = (infoDictionary?["SUPABASE_URL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = (infoDictionary?["SUPABASE_ANON_KEY"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty,
              let url = URL(string: urlText),
              url.scheme == "https",
              url.port == nil,
              url.user == nil,
              let host = url.host?.lowercased(),
              host.hasSuffix(Self.hostSuffix),
              host.count > Self.hostSuffix.count,
              let base = URL(string: "https://\(host)")
        else {
            return nil
        }
        self.baseURL = base
        self.anonKey = key
    }
}
