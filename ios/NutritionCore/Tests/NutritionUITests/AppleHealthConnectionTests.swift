import XCTest

@testable import NutritionUI

@MainActor
final class AppleHealthConnectionTests: XCTestCase {
    private final class FakeConnector: AppleHealthConnecting {
        var access: AppleHealthAccess
        var afterConnect: AppleHealthAccess?
        private(set) var connectCalls = 0

        init(_ access: AppleHealthAccess) { self.access = access }

        func currentAccess() -> AppleHealthAccess { access }

        func connect() async {
            connectCalls += 1
            if let afterConnect { access = afterConnect }
        }
    }

    private func access(_ undetermined: Int, _ authorized: Int, _ denied: Int) -> AppleHealthAccess {
        AppleHealthAccess(undetermined: undetermined, authorized: authorized, denied: denied)
    }

    func testAccessCountsResolveToOneState() {
        XCTAssertEqual(AppleHealthAccess.unavailable.state, .unavailable)
        XCTAssertEqual(access(15, 0, 0).state, .notConnected)
        XCTAssertEqual(access(0, 15, 0).state, .connected)
        XCTAssertEqual(access(0, 0, 15).state, .turnedOff)
        XCTAssertEqual(access(0, 14, 1).state, .partlyAllowed)
        // A build that maps more types than the one the person connected with: asked about some,
        // never about the rest, whatever they answered for the first ones.
        XCTAssertEqual(access(3, 12, 0).state, .needsReconnect)
        XCTAssertEqual(access(3, 0, 12).state, .needsReconnect)
    }

    func testOnlyAnAnsweredButIncompleteHealthOpensTheHealthApp() {
        let opens: [(AppleHealthAccess, Bool)] = [
            (access(0, 14, 1), true),
            (access(0, 0, 15), true),
            (access(15, 0, 0), false),
            (access(0, 15, 0), false),
            (access(3, 12, 0), false),
            (.unavailable, false),
        ]
        for (access, expected) in opens {
            XCTAssertEqual(AppleHealthConnectionViewModel(connector: FakeConnector(access)).opensHealthSettings, expected)
        }
    }

    func testEveryStateHasAStatusAndADetailAndOnlyActionableOnesHaveAButton() {
        let expected: [(AppleHealthAccess, String, String?)] = [
            (.unavailable, "Not available", nil),
            (access(15, 0, 0), "Not connected", "Connect Apple Health"),
            (access(3, 12, 0), "Needs your answer", "Finish connecting"),
            (access(0, 15, 0), "Connected", nil),
            (access(0, 14, 1), "Partly allowed", "Open Health settings"),
            (access(0, 0, 15), "Turned off in Health", "Open Health settings"),
        ]
        for (access, status, action) in expected {
            let model = AppleHealthConnectionViewModel(connector: FakeConnector(access))
            XCTAssertEqual(model.statusText, status)
            XCTAssertEqual(model.actionTitle, action)
            XCTAssertFalse(model.detailText.isEmpty)
            XCTAssertEqual(model.canAct, action != nil)
        }
    }

    func testWriteOnlyBuildsOfferToAllowReadingNutrition() {
        let writeOnly = AppleHealthAccess(undetermined: 0, authorized: 15, denied: 0, readAsked: false)
        let model = AppleHealthConnectionViewModel(connector: FakeConnector(writeOnly))
        XCTAssertEqual(model.statusText, "Connected")
        XCTAssertEqual(model.actionTitle, "Allow reading nutrition")
        XCTAssertTrue(model.canAct)
    }

    func testConnectingAsksOnceAndShowsHealthsNewAnswer() async {
        let connector = FakeConnector(access(15, 0, 0))
        connector.afterConnect = access(0, 15, 0)
        let model = AppleHealthConnectionViewModel(connector: connector)

        await model.connect()

        XCTAssertEqual(connector.connectCalls, 1)
        XCTAssertEqual(model.state, .connected)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.actionTitle)
    }

    func testADenialIsShownAsTurnedOffAndCanBeCheckedAgain() async {
        let connector = FakeConnector(access(15, 0, 0))
        connector.afterConnect = access(0, 0, 15)
        let model = AppleHealthConnectionViewModel(connector: connector)

        await model.connect()
        XCTAssertEqual(model.state, .turnedOff)
        XCTAssertTrue(model.detailText.contains("Health app"))

        // The person allows it in the Health app and comes back.
        connector.afterConnect = access(0, 15, 0)
        await model.connect()

        XCTAssertEqual(connector.connectCalls, 2)
        XCTAssertEqual(model.state, .connected)
    }

    func testConnectedOffersNoActionAndDoesNotAskAgain() async {
        let connector = FakeConnector(access(0, 15, 0))
        let model = AppleHealthConnectionViewModel(connector: connector)

        await model.connect()

        XCTAssertEqual(connector.connectCalls, 0)
    }

    func testRefreshPicksUpAnAnswerChangedOutsideTheApp() {
        let connector = FakeConnector(access(0, 15, 0))
        let model = AppleHealthConnectionViewModel(connector: connector)

        connector.access = access(0, 0, 15)
        model.refresh()

        XCTAssertEqual(model.state, .turnedOff)
    }

    /// A change in Health's answer is reported once, so the Diary can forget figures read under the old access
    /// (#1107); a refresh with the same answer reports nothing.
    func testRefreshReportsAStateChangeOnce() {
        let connector = FakeConnector(access(0, 15, 0))
        let model = AppleHealthConnectionViewModel(connector: connector)
        var reported: [AppleHealthConnectionState] = []
        model.onStateChange = { reported.append($0) }

        model.refresh()
        XCTAssertEqual(reported, [], "same answer, nothing reported")
        connector.access = access(0, 0, 15)
        model.refresh()
        model.refresh()
        XCTAssertEqual(reported, [.turnedOff])
    }
}
