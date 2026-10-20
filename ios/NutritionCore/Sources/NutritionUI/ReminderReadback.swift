import Foundation

/// The system's pending notification requests, read back after an erase. The app supplies the system center; tests
/// supply a fake.
public protocol PendingReminderCenter: Sendable {
    /// The identifiers of every request the system still holds as pending.
    func pendingRequestIdentifiers() async -> [String]
}

/// Names the reminder stores that still have a pending request on the phone after an erase.
///
/// Removing a request is asynchronous, so a single read straight after the removal can still see it. The readback
/// reads again until the requests are gone or the reads run out, and names a store only if its request is still
/// there at the last read.
public enum ReminderReadback {
    /// The prefix of every custom reminder's request identifier.
    public static let customPrefix = "custom-reminder-"

    /// How many reads the readback makes in all. A request still pending on the last read counts as still on the phone.
    public static let settleReads = 1

    /// How long the readback waits between two reads, in nanoseconds.
    public static let settleIntervalNanoseconds: UInt64 = 100_000_000

    public static func namesStillPending(
        in center: PendingReminderCenter,
        pause: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(nanoseconds: ReminderReadback.settleIntervalNanoseconds)
        }
    ) async -> [String] {
        var stillPending = namesPending(in: await center.pendingRequestIdentifiers())
        var readsLeft = settleReads - 1
        while !stillPending.isEmpty, readsLeft > 0 {
            await pause()
            stillPending = namesPending(in: await center.pendingRequestIdentifiers())
            readsLeft -= 1
        }
        return stillPending
    }

    private static func namesPending(in identifiers: [String]) -> [String] {
        var names: [String] = []
        if identifiers.contains(ReminderIdentifier.daily) { names.append("reminders") }
        if identifiers.contains(where: { $0.hasPrefix(customPrefix) }) { names.append("custom reminders") }
        return names
    }
}
