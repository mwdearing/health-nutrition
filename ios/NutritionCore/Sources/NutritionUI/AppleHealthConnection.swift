import Combine
import Foundation

/// How many of the Health types this app can write are allowed, refused and not yet asked about.
///
/// Counts rather than a list, because that is all a status row needs and it keeps HealthKit's own
/// types out of this package: the app target counts them from `HKHealthStore` and hands the numbers
/// over.
public struct AppleHealthAccess: Equatable, Sendable {
    /// Types Health has never shown this app's request sheet for.
    public var undetermined: Int
    /// Types this app may write.
    public var authorized: Int
    /// Types the person turned off.
    public var denied: Int
    /// Which types are allowed, as opaque identifiers. Not shown anywhere: it is here so two answers
    /// with the same counts but a different set of allowed types (one type turned on, another turned
    /// off) still compare as a change.
    public var authorizedTypes: Set<String>
    /// Whether the request that includes nutrient read access has been shown on this device. A build that
    /// only ever asked for write access reads as not asked, so Connect stays on screen to ask for reading.
    public var readAsked: Bool

    public init(
        undetermined: Int, authorized: Int, denied: Int, authorizedTypes: Set<String> = [], readAsked: Bool = true
    ) {
        self.undetermined = undetermined
        self.authorized = authorized
        self.denied = denied
        self.authorizedTypes = authorizedTypes
        self.readAsked = readAsked
    }

    /// No Health on this device, or no type to ask about.
    public static let unavailable = AppleHealthAccess(undetermined: 0, authorized: 0, denied: 0)

    public var state: AppleHealthConnectionState {
        if undetermined + authorized + denied == 0 { return .unavailable }
        if authorized + denied == 0 { return .notConnected }
        // Some types were answered and some never asked: a build that writes more nutrients than the
        // one the person connected with. Nothing is delivered until the rest are asked about.
        if undetermined > 0 { return .needsReconnect }
        if denied == 0 { return .connected }
        if authorized == 0 { return .turnedOff }
        return .partlyAllowed
    }
}

/// What the Apple Health row in Settings says.
public enum AppleHealthConnectionState: Equatable, Sendable {
    /// Health does not exist on this device.
    case unavailable
    /// Health has not been asked yet.
    case notConnected
    /// Health was asked about some types only; the rest still need the person's answer.
    case needsReconnect
    /// Every type may be written.
    case connected
    /// Some types may be written and some were turned off.
    case partlyAllowed
    /// Every type was turned off.
    case turnedOff
}

/// The app target's side of the Apple Health row: the only thing here that reaches HealthKit.
@MainActor
public protocol AppleHealthConnecting: AnyObject {
    /// Health's current answer, read fresh on every call.
    func currentAccess() -> AppleHealthAccess
    /// Asks Health for write access where it can still be asked, then delivers what is waiting.
    func connect() async
}

/// The Apple Health row in Settings: a status, one sentence about it, and at most one action.
@MainActor
public final class AppleHealthConnectionViewModel: ObservableObject {
    public static let title = "Apple Health"
    /// Where a person changes an answer they already gave; iOS shows the request sheet only once.
    static let healthAppPath = "open the Health app, tap Sharing, then Apps, then HealthNutrition"

    @Published public private(set) var state: AppleHealthConnectionState
    @Published public private(set) var isBusy = false
    /// Whether the read request has been shown on this device; see `AppleHealthAccess.readAsked`.
    @Published private var readAsked: Bool
    private let connector: any AppleHealthConnecting

    public init(connector: any AppleHealthConnecting) {
        self.connector = connector
        let access = connector.currentAccess()
        self.state = access.state
        self.readAsked = access.readAsked
    }

    /// Reads Health's answer again. Called when the row appears and when the app comes back to the
    /// foreground, because the answer can change in the Health app while this one is in the background.
    public func refresh() {
        let access = connector.currentAccess()
        if access.state != state { state = access.state }
        readAsked = access.readAsked
    }

    public var canAct: Bool { !isBusy && actionTitle != nil }

    /// The row's one action. Ignored while a request is already in flight.
    public func connect() async {
        guard canAct else { return }
        isBusy = true
        await connector.connect()
        isBusy = false
        refresh()
    }

    public var statusText: String {
        switch state {
        case .unavailable: return "Not available"
        case .notConnected: return "Not connected"
        case .needsReconnect: return "Needs your answer"
        case .connected: return "Connected"
        case .partlyAllowed: return "Partly allowed"
        case .turnedOff: return "Turned off in Health"
        }
    }

    public var detailText: String {
        switch state {
        case .unavailable:
            return "The Health app is not available on this device."
        case .notConnected:
            return "Writes what you log to the Health app. Reads nutrition, calories burned, steps, weight and caffeine."
        case .needsReconnect:
            return "This version can write more nutrients than Health has been asked about. "
                + "Entries wait on this phone until you answer."
        case .connected:
            return "The nutrients and water of the entries you log are written to Health. "
                + "To stop, \(Self.healthAppPath)."
        case .partlyAllowed:
            return "Health gets only the nutrients you allowed. To change that, \(Self.healthAppPath), "
                + "then come back and check again."
        case .turnedOff:
            return "Nothing is written to Health. To allow it, \(Self.healthAppPath), "
                + "then come back and check again."
        }
    }

    /// True when Health is connected and the read request has been shown, so there is nothing left to ask.
    public var isComplete: Bool { state == .connected }

    /// The button under the row, or nil when there is nothing for a person to do.
    public var actionTitle: String? {
        switch state {
        case .unavailable: return nil
        case .connected: return readAsked ? nil : "Allow reading nutrition"
        case .notConnected: return "Connect Apple Health"
        case .needsReconnect: return "Finish connecting"
        case .partlyAllowed, .turnedOff: return "Check again"
        }
    }
}
