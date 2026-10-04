import Foundation
import NutritionDomain
import XCTest
@testable import NutritionJournal

/// The pure half of the HealthKit writer (NC-07). Everything here is about the plan ADR 0002
/// describes: one sync identifier per (intake, nutrient), the journal revision as the sync version,
/// and timestamps that come from the intake rather than from the clock.
final class HealthKitWritePlanTests: XCTestCase {
    private let intakeID = "0b6f7d3e-5a1c-4c52-9a2e-3f1d8c7b6a10"
    private let occurredAt = Date(timeIntervalSince1970: 1_700_000_000)

    private func plan(
        _ totals: [String: NutrientValue],
        intakeID: String? = nil,
        revision: Int = 1,
        occurredAt: Date? = nil
    ) -> [HealthKitSampleSpec] {
        HealthKitWritePlanner.plan(
            intakeID: intakeID ?? self.intakeID,
            revision: revision,
            occurredAt: occurredAt ?? self.occurredAt,
            totals: totals
        )
    }

    /// The spec the plan wrote for one nutrient, found by its sync identifier.
    private func spec(_ nutrientKey: String, in specs: [HealthKitSampleSpec]) throws -> HealthKitSampleSpec {
        try XCTUnwrap(specs.first { $0.syncIdentifier == "intake:\(intakeID):\(nutrientKey)" })
    }

    // MARK: - Sync identifier and version

    func testPlanGivesEachIntakeAndNutrientItsOwnSyncIdentifier() throws {
        let specs = plan(["water": .known(dec("250"), .mL), "protein": .known(dec("13"), .g)])

        XCTAssertEqual(specs.count, 2)
        XCTAssertEqual(specs.map(\.syncIdentifier), ["intake:\(intakeID):protein", "intake:\(intakeID):water"])
        XCTAssertEqual(Set(specs.map(\.quantityTypeIdentifier)).count, 2, "water and protein are different HealthKit types")
    }

    func testSyncIdentifierCarriesTheIntakeIDItWasPlannedFor() {
        let otherID = "3d0c1f4a-9b2e-4d1c-8f77-2b5c6d8e9a01"
        let specs = plan(["water": .known(dec("250"), .mL)], intakeID: otherID)

        XCTAssertEqual(specs.map(\.syncIdentifier), ["intake:\(otherID):water"])
    }

    func testSyncVersionIsTheJournalRevision() {
        let specs = plan(
            ["water": .known(dec("250"), .mL), "protein": .known(dec("13"), .g)],
            revision: 7
        )

        XCTAssertEqual(specs.count, 2)
        XCTAssertEqual(specs.map(\.syncVersion), [7, 7])
    }

    func testARetryOfTheSameRevisionRebuildsTheSameSpecs() {
        let totals: [String: NutrientValue] = ["water": .known(dec("250"), .mL), "protein": .known(dec("13"), .g)]

        XCTAssertEqual(plan(totals, revision: 3), plan(totals, revision: 3))
    }

    // MARK: - What is not written

    func testUnknownNotApplicableAndBelowReportingThresholdAreNotWritten() throws {
        let specs = plan([
            "protein": .known(dec("13"), .g),
            "sodium": .unknown,
            "potassium": .notApplicable,
            "calcium": .belowReportingThreshold(.mg),
        ])

        XCTAssertEqual(specs.count, 1)
        let protein = try spec("protein", in: specs)
        XCTAssertEqual(protein.amount, dec("13"))
    }

    func testNothingIsWrittenForAnEmptySetOfTotals() {
        XCTAssertTrue(plan([:]).isEmpty)
    }

    func testInternationalUnitsAreSkippedRatherThanConverted() {
        let specs = plan([
            "vitaminD": .known(dec("400"), .iu),
            "vitaminB12": .known(dec("2.4"), .mcg),
        ])

        XCTAssertEqual(specs.map(\.syncIdentifier), ["intake:\(intakeID):vitaminB12"])
    }

    func testAnUnmappedNutrientKeyIsSkipped() {
        let specs = plan(["quercetin": .known(dec("10"), .mg), "water": .known(dec("250"), .mL)])

        XCTAssertEqual(specs.map(\.syncIdentifier), ["intake:\(intakeID):water"])
    }

    func testATotalWhoseUnitDoesNotMatchTheMappingIsSkipped() {
        // Energy in grams cannot become kilocalories, so it is dropped instead of guessed at.
        let specs = plan(["energy": .known(dec("13"), .g)])

        XCTAssertTrue(specs.isEmpty)
    }

    func testAKnownZeroIsWrittenBecauseTheLabelStatesIt() throws {
        let specs = plan(["sugar": .known(dec("0"), .g)])

        let sugar = try spec("sugar", in: specs)
        XCTAssertEqual(sugar.amount, 0)
        XCTAssertEqual(sugar.unitSymbol, "g")
    }

    // MARK: - Exact unit conversion

    func testMilligramsConvertExactlyToGrams() throws {
        let specs = plan(["protein": .known(dec("1500"), .mg)])
        let protein = try spec("protein", in: specs)

        XCTAssertEqual(protein.amount, dec("1.5"))
        XCTAssertEqual(protein.unitSymbol, "g")
    }

    func testMicrogramsConvertExactlyToMilligrams() throws {
        let specs = plan(["sodium": .known(dec("1500"), .mcg)])
        let sodium = try spec("sodium", in: specs)

        XCTAssertEqual(sodium.amount, dec("1.5"))
        XCTAssertEqual(sodium.unitSymbol, "mg")
    }

    func testAMicrogramNutrientIsWrittenInMicrograms() throws {
        let specs = plan(["vitaminD": .known(dec("0.025"), .mg)])
        let vitaminD = try spec("vitaminD", in: specs)

        XCTAssertEqual(vitaminD.amount, dec("25"))
        XCTAssertEqual(vitaminD.unitSymbol, "mcg")
    }

    func testEnergyIsWrittenInKilocalories() throws {
        let specs = plan(["energy": .known(dec("250"), .kcal)])
        let energy = try spec("energy", in: specs)

        XCTAssertEqual(energy.amount, dec("250"))
        XCTAssertEqual(energy.unitSymbol, "kcal")
        XCTAssertEqual(energy.quantityTypeIdentifier, "HKQuantityTypeIdentifierDietaryEnergyConsumed")
    }

    func testKilojoulesAreNotARegistryUnitSoAnEnergyTotalMustAlreadyBeInKilocalories() {
        // MeasureUnit knows kcal only, so the planner has no kilojoule factor to apply and a kJ
        // total cannot reach the plan as a converted amount.
        XCTAssertThrowsError(try MeasureUnit(symbol: "kJ")) { error in
            XCTAssertEqual(error as? UnitError, UnitError.unknownSymbol("kJ"))
        }
    }

    // MARK: - Water

    func testWaterFromAVolumeComponentIsWrittenInMillilitres() throws {
        let specs = plan(["water": .known(dec("250"), .mL)])
        let water = try spec("water", in: specs)

        XCTAssertEqual(water.quantityTypeIdentifier, "HKQuantityTypeIdentifierDietaryWater")
        XCTAssertEqual(water.amount, dec("250"))
        XCTAssertEqual(water.unitSymbol, "mL")
    }

    func testLitresOfWaterBecomeMillilitres() throws {
        let specs = plan(["water": .known(dec("0.25"), .L)])
        let water = try spec("water", in: specs)

        XCTAssertEqual(water.amount, dec("250"))
        XCTAssertEqual(water.unitSymbol, "mL")
    }

    // MARK: - Determinism and timestamps

    func testOrderIsDeterministicByNutrientKey() {
        let totals: [String: NutrientValue] = [
            "water": .known(dec("250"), .mL),
            "zinc": .known(dec("3"), .mg),
            "protein": .known(dec("13"), .g),
            "energy": .known(dec("250"), .kcal),
            "sodium": .known(dec("900"), .mg),
        ]

        let first = plan(totals)
        let second = plan(totals)

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first.map { String($0.syncIdentifier.split(separator: ".").last ?? "") },
            ["energy", "protein", "sodium", "water", "zinc"],
            "specs come out sorted by nutrient key, whatever order the totals dictionary iterates in"
        )
    }

    func testTimestampsComeFromTheIntakeAndNeverFromTheClock() {
        let specs = plan(["water": .known(dec("250"), .mL)])

        XCTAssertEqual(specs.count, 1)
        XCTAssertEqual(specs[0].start, occurredAt)
        XCTAssertEqual(specs[0].end, occurredAt)
        XCTAssertNotEqual(specs[0].start.timeIntervalSinceNow, 0, accuracy: 1)
    }

    func testAnEditedIntakeMovesBothTimestampsTogether() {
        let later = occurredAt.addingTimeInterval(3_600)

        let specs = plan(["water": .known(dec("250"), .mL)], revision: 2, occurredAt: later)

        XCTAssertEqual(specs[0].start, later)
        XCTAssertEqual(specs[0].end, later)
    }

    // MARK: - Deletion

    func testDeletionReturnsTheSyncIdentifiersToRemove() {
        XCTAssertEqual(
            HealthKitWritePlanner.deletion(intakeID: intakeID, keys: ["protein", "water"]),
            ["intake:\(intakeID):protein", "intake:\(intakeID):water"]
        )
    }

    func testDeletionIsSortedAndDeduplicated() {
        XCTAssertEqual(
            HealthKitWritePlanner.deletion(intakeID: intakeID, keys: ["water", "protein", "water"]),
            ["intake:\(intakeID):protein", "intake:\(intakeID):water"]
        )
    }

    func testDeletionOfNothingIsEmpty() {
        XCTAssertTrue(HealthKitWritePlanner.deletion(intakeID: intakeID, keys: []).isEmpty)
    }

    func testDeletionCoversEveryKeyTheCallerPassesNotOnlyTheOnesThisRevisionWrites() {
        // An earlier revision may have written sodium; this revision knows it no more, so the
        // sodium sample has to be removed rather than left behind.
        let totals: [String: NutrientValue] = [
            "water": .known(dec("250"), .mL),
            "protein": .known(dec("13"), .g),
            "sodium": .unknown,
        ]
        let specs = plan(totals)
        let deletions = HealthKitWritePlanner.deletion(intakeID: intakeID, keys: ["water", "protein", "sodium"])

        XCTAssertEqual(deletions, ["intake:\(intakeID):protein", "intake:\(intakeID):sodium", "intake:\(intakeID):water"])
        XCTAssertTrue(
            deletions.count >= specs.count,
            "a delete has to cover every sample this intake may have written, not only this revision's"
        )
        for written in specs {
            XCTAssertTrue(deletions.contains(written.syncIdentifier), "missing \(written.syncIdentifier)")
        }
    }

    func testANutrientThatBecomesUnknownIsStillDeleted() {
        let first = plan(["water": .known(dec("250"), .mL), "sodium": .known(dec("900"), .mg)], revision: 1)
        let edited = plan(["water": .known(dec("500"), .mL), "sodium": .unknown], revision: 2)

        XCTAssertEqual(first.map(\.syncIdentifier), ["intake:\(intakeID):sodium", "intake:\(intakeID):water"])
        XCTAssertEqual(edited.map(\.syncIdentifier), ["intake:\(intakeID):water"], "the new revision writes no sodium sample")

        let deletions = HealthKitWritePlanner.deletion(intakeID: intakeID, keys: ["water", "sodium"])

        XCTAssertTrue(deletions.contains("intake:\(intakeID):sodium"), "the stale sodium sample from revision 1 has to go")
        XCTAssertEqual(deletions, ["intake:\(intakeID):sodium", "intake:\(intakeID):water"])
    }
}