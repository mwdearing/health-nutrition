import XCTest
@testable import NutritionDomain

final class ProprietaryBlendTests: XCTestCase {
    private let blendId = "synthetic-energy-blend"

    private func blend(members: [BlendMember]) throws -> ProprietaryBlend {
        try ProprietaryBlend(
            identifier: blendId,
            labelName: "Synthetic energy blend",
            total: try known("2000", .mg),
            members: members
        )
    }

    private func undisclosedMembers() -> [BlendMember] {
        [
            BlendMember(labelName: "Synthetic extract A", substanceIdentifier: "synthetic-extract-a"),
            BlendMember(labelName: "Synthetic extract B", substanceIdentifier: "synthetic-extract-b"),
            BlendMember(labelName: "Synthetic extract C", substanceIdentifier: "synthetic-extract-c"),
        ]
    }

    func testBlendGroupKeepsTotalAmount() throws {
        let group = try blend(members: undisclosedMembers())
        XCTAssertEqual(group.identifier, blendId)
        XCTAssertEqual(group.labelName, "Synthetic energy blend")
        XCTAssertEqual(group.total, try known("2000", .mg))
        XCTAssertEqual(group.members.count, 3)
        XCTAssertEqual(group.totalFact.kind, .blend)
        XCTAssertEqual(group.totalFact.role, .blendTotalOnly)
        XCTAssertEqual(group.totalFact.amount, try known("2000", .mg))
    }

    func testBlendMembersWithUndisclosedAmountStayUnknown() throws {
        let group = try blend(members: undisclosedMembers())
        for member in group.members {
            XCTAssertEqual(member.amount, NutrientValue.unknown)
        }
        XCTAssertEqual(group.undisclosedMembers.count, 3)
        XCTAssertEqual(group.total, try known("2000", .mg))
    }

    func testBlendIsNeverSplitEvenly() throws {
        let group = try blend(members: undisclosedMembers())
        for member in group.members {
            XCTAssertNotEqual(member.amount, try known("666.67", .mg))
            XCTAssertNotEqual(member.amount, try known("666.66", .mg))
            XCTAssertNil(member.amount.quantity)
        }
        let share = try SupplementTotals.total(substance: "synthetic-extract-a", basis: .compoundMass, facts: [], blends: [group])
        XCTAssertEqual(share.value, NutrientValue.unknown)
        XCTAssertNotEqual(share.value, try known("0", .mg))
    }

    func testBlendTotalCountedOnce() throws {
        let group = try blend(members: undisclosedMembers())
        let fromBlends = try SupplementTotals.total(substance: blendId, basis: .compoundMass, facts: [], blends: [group])
        XCTAssertEqual(fromBlends.value, try known("2000", .mg))
        XCTAssertEqual(fromBlends.coverage.totalCount, 1)
        let duplicated = try SupplementTotals.total(
            substance: blendId,
            basis: .compoundMass,
            facts: [group.totalFact],
            blends: [group, group]
        )
        XCTAssertEqual(duplicated.value, try known("2000", .mg))
        XCTAssertEqual(duplicated.coverage.totalCount, 1)
    }

    func testBlendMembersNotAddedToSubstanceTotals() throws {
        let members = [
            BlendMember(labelName: "Synthetic extract A", substanceIdentifier: "synthetic-extract-a", amount: try known("500", .mg)),
            BlendMember(labelName: "Synthetic extract B", substanceIdentifier: "synthetic-extract-b"),
        ]
        let group = try blend(members: members)
        let memberTotal = try SupplementTotals.total(substance: "synthetic-extract-a", basis: .compoundMass, facts: [], blends: [group])
        XCTAssertNotEqual(memberTotal.value, try known("500", .mg))
        XCTAssertEqual(memberTotal.value, NutrientValue.unknown)
        let blendTotal = try SupplementTotals.total(substance: blendId, basis: .compoundMass, facts: [], blends: [group])
        XCTAssertEqual(blendTotal.value, try known("2000", .mg))
        XCTAssertNotEqual(blendTotal.value, try known("2500", .mg))
    }

    func testBlendTotalAndNamedComponentNotDoubleCounted() throws {
        let members = [
            BlendMember(labelName: "Synthetic caffeine", substanceIdentifier: "synthetic-caffeine", amount: try known("200", .mg)),
        ]
        let group = try blend(members: members)
        let separate = try CompoundFact.nutrient(
            substanceIdentifier: "synthetic-caffeine",
            labelName: "Synthetic caffeine",
            amount: try known("200", .mg)
        )
        let caffeine = try SupplementTotals.total(
            substance: "synthetic-caffeine",
            basis: .activeNutrientMass,
            facts: [separate, group.totalFact],
            blends: [group]
        )
        XCTAssertEqual(caffeine.value, try known("200", .mg))
        XCTAssertNotEqual(caffeine.value, try known("400", .mg))
        let blendTotal = try SupplementTotals.total(
            substance: blendId,
            basis: .compoundMass,
            facts: [separate, group.totalFact],
            blends: [group]
        )
        XCTAssertEqual(blendTotal.value, try known("2000", .mg))
    }

    func testBlendMemberUnknownMakesSubstanceTotalPartial() throws {
        let group = try blend(members: [
            BlendMember(labelName: "Synthetic extract A", substanceIdentifier: "synthetic-extract-a"),
        ])
        let separate = try CompoundFact.compound(
            substanceIdentifier: "synthetic-extract-a",
            labelName: "Synthetic extract A",
            amount: try known("300", .mg),
            basis: .compoundMass
        )
        let total = try SupplementTotals.total(substance: "synthetic-extract-a", basis: .compoundMass, facts: [separate], blends: [group])
        XCTAssertEqual(total.value, try known("300", .mg))
        XCTAssertEqual(total.coverage.knownCount, 1)
        XCTAssertEqual(total.coverage.totalCount, 2)
        XCTAssertTrue(total.coverage.hasUnknown)
        XCTAssertFalse(total.coverage.isComplete)
        let onlyBlend = try SupplementTotals.total(substance: "synthetic-extract-a", basis: .compoundMass, facts: [], blends: [group])
        XCTAssertEqual(onlyBlend.value, NutrientValue.unknown)
    }

    func testBlendWithDisclosedMemberAmountStillCountedOnce() throws {
        let members = [
            BlendMember(labelName: "Synthetic extract A", substanceIdentifier: "synthetic-extract-a", amount: try known("500", .mg)),
            BlendMember(labelName: "Synthetic extract B", substanceIdentifier: "synthetic-extract-b"),
        ]
        let group = try blend(members: members)
        XCTAssertEqual(group.members[0].amount, try known("500", .mg))
        XCTAssertEqual(group.members[1].amount, NutrientValue.unknown)
        XCTAssertEqual(group.undisclosedMembers.count, 1)
        let total = try SupplementTotals.total(substance: blendId, basis: .compoundMass, facts: [group.totalFact], blends: [group])
        XCTAssertEqual(total.value, try known("2000", .mg))
        XCTAssertEqual(total.coverage.totalCount, 1)
        XCTAssertNotEqual(total.value, try known("2500", .mg))
    }
}
