import Foundation
import XCTest
@testable import NutritionDomain

/// The catalog's nutrient arithmetic reproduces every vector in `contracts/nutrients/golden.v1.json`, as the Python
/// reference evaluator in `catalog/tests/test_contract_v1.py` does (NF-03). One file, two languages, the same answers.
final class ContractGoldenTests: XCTestCase {
    private typealias JSON = [String: Any]

    private static func contractFile(_ name: String, file: StaticString = #filePath) -> URL? {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("contracts/nutrients/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
        return nil
    }

    private func load(_ name: String) throws -> JSON {
        let url = try XCTUnwrap(Self.contractFile(name), "contracts/nutrients/\(name) is missing")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? JSON)
    }

    private func portion(_ input: JSON) -> ContractArithmetic.Portion? {
        guard let p = input["portion"] as? JSON else { return nil }
        return ContractArithmetic.Portion(
            countUnit: p["count_unit"] as? String ?? "", amount: p["amount"] as? String ?? "",
            unit: p["unit"] as? String ?? "")
    }

    private func value(_ json: JSON) -> ContractArithmetic.Value {
        ContractArithmetic.Value(
            state: json["state"] as? String ?? "", amount: json["amount"] as? String, unit: json["unit"] as? String)
    }

    private func valueJSON(_ value: ContractArithmetic.Value) -> JSON {
        var json: JSON = ["state": value.state]
        if let amount = value.amount { json["amount"] = amount }
        if let unit = value.unit { json["unit"] = unit }
        return json
    }

    private func convert(_ input: JSON, nutrient: String?) throws -> String {
        try ContractArithmetic.convert(
            amount: input["amount"] as? String ?? "", unit: input["unit"] as? String ?? "",
            to: input["to"] as? String ?? "", density: input["density"] as? String, portion: portion(input),
            nutrient: nutrient)
    }

    private func scale(_ input: JSON) throws -> ContractArithmetic.Value {
        let basis = input["basis"] as? JSON ?? [:]
        let consumed = input["consumed"] as? JSON ?? [:]
        return try ContractArithmetic.scale(
            basisAmount: basis["amount"] as? String ?? "", basisUnit: basis["unit"] as? String ?? "",
            consumedAmount: consumed["amount"] as? String ?? "", consumedUnit: consumed["unit"] as? String ?? "",
            value: value(input["value"] as? JSON ?? [:]), density: input["density"] as? String, portion: portion(input))
    }

    private func sum(_ input: JSON, nutrient: String?) throws -> JSON {
        let values = (input["values"] as? [JSON] ?? []).map(value)
        let (total, coverage) = try ContractArithmetic.sum(values, unit: input["unit"] as? String, nutrient: nutrient)
        return [
            "value": valueJSON(total),
            "coverage": [
                "known_count": coverage.knownCount, "total_count": coverage.totalCount,
                "has_unknown": coverage.hasUnknown, "has_below_reporting_threshold": coverage.hasBelowReportingThreshold,
                "is_complete": coverage.isComplete,
            ] as JSON,
        ]
    }

    func testEveryGoldenVectorIsReproduced() throws {
        let golden = try load("golden.v1.json")
        let cases = try XCTUnwrap(golden["cases"] as? [JSON])
        XCTAssertGreaterThanOrEqual(cases.count, 74)
        for testCase in cases {
            let id = testCase["id"] as? String ?? "?"
            let op = testCase["op"] as? String ?? ""
            let input = testCase["input"] as? JSON ?? [:]
            let expect = testCase["expect"] as? JSON ?? [:]
            let nutrient = testCase["nutrient"] as? String
            switch op {
            case "convert":
                do {
                    let amount = try convert(input, nutrient: nutrient)
                    XCTAssertEqual(amount, expect["amount"] as? String, id)
                    XCTAssertEqual(input["to"] as? String, expect["unit"] as? String, id)
                } catch {
                    XCTFail("\(id): threw \(error)")
                }
            case "scale":
                do {
                    XCTAssertEqual(valueJSON(try scale(input)) as NSDictionary, expect as NSDictionary, id)
                } catch {
                    XCTFail("\(id): threw \(error)")
                }
            case "sum":
                do {
                    XCTAssertEqual(try sum(input, nutrient: nutrient) as NSDictionary, expect as NSDictionary, id)
                } catch {
                    XCTFail("\(id): threw \(error)")
                }
            case "reject":
                let expected = expect["error"] as? String
                do {
                    if id.hasPrefix("reject_sum") {
                        _ = try sum(input, nutrient: nutrient)
                    } else if input["basis"] != nil {
                        _ = try scale(input)
                    } else {
                        _ = try convert(input, nutrient: nutrient)
                    }
                    XCTFail("\(id): expected \(expected ?? "?"), got a result")
                } catch let failure as ContractArithmetic.Failure {
                    XCTAssertEqual(failure.rawValue, expected, id)
                } catch {
                    XCTFail("\(id): threw \(error)")
                }
            default:
                XCTFail("\(id): unknown op \(op)")
            }
        }
    }

    /// Every error the goldens name is one the Swift arithmetic can raise, and the other way round.
    func testTheGoldenErrorNamesAreTheSwiftFailures() throws {
        let golden = try load("golden.v1.json")
        let names = Set(try XCTUnwrap(golden["error_names"] as? [String]))
        XCTAssertEqual(names, Set(ContractArithmetic.Failure.allCases.map(\.rawValue)))
    }

    /// The Swift unit table and vitamin D factor are the registry's, so the two cannot drift apart.
    func testTheUnitTableIsTheRegistrys() throws {
        let registry = try load("registry.v1.json")
        let units = try XCTUnwrap(registry["units"] as? [JSON]).map {
            ContractArithmetic.WireUnit(
                symbol: $0["symbol"] as? String ?? "", dimension: $0["dimension"] as? String ?? "",
                factorToCanonical: $0["factor_to_canonical"] as? String)
        }
        XCTAssertEqual(units, ContractArithmetic.wireUnits)
        var factors: [String: String] = [:]
        for nutrient in try XCTUnwrap(registry["nutrients"] as? [JSON]) {
            if let factor = nutrient["mcg_per_international_unit"] as? String, let id = nutrient["id"] as? String {
                factors[id] = factor
            }
        }
        XCTAssertEqual(factors, ContractArithmetic.mcgPerInternationalUnit)
    }

    /// A very long amount is refused as out of range before its digits are parsed, so it cannot cost much work.
    func testAnOverlongAmountIsRefusedBeforeItIsParsed() {
        let long = "1" + String(repeating: "0", count: 100_000)
        XCTAssertThrowsError(try ContractArithmetic.exact(long)) {
            XCTAssertEqual($0 as? ContractArithmetic.Failure, .amountOutOfRange)
        }
    }

    func testARepeatingQuotientRoundsToTenFractionDigitsHalvesAwayFromZero() throws {
        XCTAssertEqual(
            ContractArithmetic.decimalString(try ContractArithmetic.quotient(
                ContractArithmetic.exact("1"), ContractArithmetic.exact("3"))),
            "0.3333333333")
        XCTAssertEqual(
            ContractArithmetic.decimalString(try ContractArithmetic.quotient(
                ContractArithmetic.exact("2"), ContractArithmetic.exact("3"))),
            "0.6666666667")
    }
}
