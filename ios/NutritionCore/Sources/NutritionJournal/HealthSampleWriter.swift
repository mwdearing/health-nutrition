import Foundation

/// Writes the samples a `HealthKitSampleSpec` describes, and takes them back again.
///
/// The protocol is the seam between the delivery decision and HealthKit itself. `NutritionJournal`
/// may not import HealthKit (see `scripts/lint_swift_sources.py`), so nothing here names a HealthKit
/// type: a quantity type is an identifier string, and the app target looks it up and builds the
/// sample. That is what lets `HealthKitDeliveryWorker` be tested on macOS against a fake writer.
///
/// The app target's implementation is `ios/HealthNutrition/Sources/HealthKitSampleWriter.swift`, and
/// the behaviour both halves follow is [ADR 0002](docs/adr/0002-healthkit-sync.md).
public protocol HealthSampleWriter: Sendable {
    /// Whether this app may write each quantity type, keyed by the identifier string the plan used.
    ///
    /// The permission sheet under-reports which types it covered (ADR 0002), so write access is asked
    /// for one type at a time and a `false` is never read as "ask again later": only a person can
    /// grant Health access.
    func canWrite(identifiers: [String]) async -> [String: Bool]

    /// The subset of these quantity types the person **explicitly denied**, as distinct from the types
    /// this app simply may not write.
    ///
    /// `canWrite` answers `false` for two different situations: a type the person turned off after
    /// granting it (`.sharingDenied`), and a type Health never asked about (`.notDetermined`). A
    /// retraction treats them differently — a denied type cannot be deleted and keeps the operation for
    /// a person, while a type that was never asked holds nothing and is skipped — so it asks this
    /// question separately. A conformer that cannot tell the two apart may use the default below.
    func deniedWriteTypes(identifiers: [String]) async -> Set<String>

    /// Writes the specs, replacing whatever sample carries the same sync identifier.
    ///
    /// A retry rebuilds the same specs from the stored revision, so writing them again replaces the
    /// same samples and is harmless.
    func save(_ specs: [HealthKitSampleSpec]) async throws

    /// Removes the samples carrying these sync identifiers that this app wrote, and reports how many
    /// went. A sample another app wrote is never touched.
    func deleteSamples(syncIdentifiers: [String]) async throws -> Int
}

extension HealthSampleWriter {
    /// A conservative default for a conformer that cannot tell a denial from a type Health never asked
    /// about: every type this app may not write is reported as denied, so a retraction keeps the
    /// operation for a person rather than deleting a type it might have been refused. The app target's
    /// writer and the tests' fake implement the distinction precisely instead.
    public func deniedWriteTypes(identifiers: [String]) async -> Set<String> {
        let allowed = await canWrite(identifiers: identifiers)
        return Set(identifiers.filter { allowed[$0] != true })
    }
}

/// The only two ways a write can fail, because the worker treats them differently.
///
/// The split is ADR 0002's: a save whose error is an authorization denial is the one failure that
/// retrying cannot fix, and every other error — an invalid sample, a restriction, a store error —
/// is a delivery error worth another attempt.
public enum HealthSampleWriterError: Error, Sendable, Equatable {
    /// Health access was refused for one of the types. The delivery needs a person, never a retry.
    case authorizationDenied
    /// Anything else, with the underlying message kept for the log.
    case transient(String)
}
