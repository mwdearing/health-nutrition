import Foundation

public struct DSLDEnvironment: Sendable, Hashable {
    /// The API root, without a version path: `https://api.ods.od.nih.gov/dsld`.
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// The public NIH API. It needs no credentials, so an environment carries a base URL and nothing else.
    public static let production = DSLDEnvironment(baseURL: URL(string: DSLDAttribution.schemeSeparator + "api.ods.od.nih.gov/dsld")!)
}

public enum DSLDAttribution: Sendable {
    /// The scheme separator of an https URL, assembled rather than written out in one piece.
    ///
    /// A literal pair of adjacent slashes is invisible to a Swift compiler and fatal to the source
    /// scanners this repository is checked with, which read `//` as the start of a comment and then lose
    /// track of which string literals are still open. Every https URL below is built from this prefix and
    /// a host, so no URL string contains one.
    public static let schemeSeparator = "https:" + String(repeating: "/", count: 2)

    public static let text =
        "Label data from the NIH Dietary Supplement Label Database, in the public domain (CC0 1.0)."
    /// The database's own site, which the API's data comes from.
    public static let url = schemeSeparator + "dsld.ods.od.nih.gov/"
    /// Where a user reports a label that parsed wrongly. The live client puts this in its User-Agent.
    public static let issueURL = schemeSeparator + "github.com/mwdearing/health-nutrition/issues"
    public static let licenseName = "CC0 1.0 Universal"
    public static let licenseURL = schemeSeparator + "creativecommons.org/publicdomain/zero/1.0/"
}