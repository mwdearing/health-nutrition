import Foundation

/// Removes local deployment details from text that may be copied into a public repository, such as the
/// HealthKit spike transcript: the app's bundle identifier becomes `<bundle-id>` and the device name
/// `<device>`. Matching ignores case, because the identifier a system API reports can differ in case from
/// the one the app bundle declares.
public enum TranscriptRedaction {
    public static func redact(_ text: String, bundleIdentifier: String?, deviceName: String?) -> String {
        var out = text
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            out = out.replacingOccurrences(of: bundleIdentifier, with: "<bundle-id>", options: .caseInsensitive)
        }
        if let deviceName, !deviceName.isEmpty {
            out = out.replacingOccurrences(of: deviceName, with: "<device>", options: .caseInsensitive)
        }
        return out
    }
}
