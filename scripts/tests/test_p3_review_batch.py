"""Minor findings from the pre-release code review (#1221 items 3, 4, 8, 9, 10, 21, 22, 29).

- A stated zero on a supplement label stays a known zero instead of becoming unknown.
- An oversized community reply is reported as too large, not as a network failure.
- The Open Food Facts staging environment exists only in debug builds.
- An unstorable decimal is refused instead of being saved and then dropped on read.
- The unit tests for every item exist.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "ios/NutritionCore/Sources"
TESTS = ROOT / "ios/NutritionCore/Tests"


def test_a_stated_zero_on_a_label_is_known() -> None:
    text = (SRC / "NutritionProviders/DSLDLabelAdapter.swift").read_text()
    start = text.find("private static func amount(from quantity:")
    assert start >= 0, "missing amount(from:)"
    body = text[start:start + 1500]
    assert not re.search(r"value\s*>\s*0\b", body), "a stated 0 is a known amount, not unknown"


def test_an_oversized_reply_is_not_a_network_error() -> None:
    text = (SRC / "NutritionProviders/Community/CommunityError.swift").read_text()
    assert re.search(r"case responseTooLarge\b", text), "CommunityError names an oversized reply"
    api = (SRC / "NutritionProviders/Community/CommunityAPI.swift").read_text()
    assert "CommunityError.responseTooLarge" in api or ".responseTooLarge" in api.split("catch is CancellationError")[-1], \
        "the community client maps an oversized reply to responseTooLarge"


def test_staging_is_debug_only() -> None:
    text = (SRC / "NutritionProviders/OpenFoodFactsEnvironment.swift").read_text()
    at = text.find("static func staging(")
    assert at >= 0, "missing staging(authorization:)"
    before = text[:at]
    assert before.rfind("#if DEBUG") > before.rfind("#endif"), "staging(authorization:) sits inside #if DEBUG"


def test_an_unstorable_value_is_not_kept_as_is() -> None:
    text = (SRC / "NutritionJournal/StoredDecimal.swift").read_text()
    assert "is kept as it is rather than" not in text, "an unroundable value is refused, not kept unchanged"


def test_the_unit_tests_exist() -> None:
    names = {
        "NutritionUITests/P3ReviewBatchTests.swift": [
            "testAnIntakeWithoutItsCurrentRevisionCountsAsUnknown",
            "testNutrientGapsCountsAMissingRevisionAsUnknown",
            "testAnUnreadableSnapshotIsNotCountedAsFoodOnToday",
            "testAFailedProductReadDoesNotDuplicateALibraryRow",
        ],
        "NutritionJournalTests/StoredDecimalRefusalTests.swift": ["testAnUnstorableValueIsRefused"],
        "NutritionProvidersTests/P3ProviderBatchTests.swift": [
            "testAStatedZeroOnALabelIsKnownZero", "testAnOversizedReplyIsNotANetworkError"],
    }
    for path, funcs in names.items():
        text = (TESTS / path).read_text()
        for f in funcs:
            assert f"func {f}(" in text, f"{path} has {f}"
