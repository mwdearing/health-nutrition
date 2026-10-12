"""The Account section's sheets are attached to the Settings form, not to a row of it.

A presentation anchored to one lazily managed Form row is dropped when that row is rebuilt, which closed the
sign-in sheet the moment it opened. The section's buttons only set flags on the model; the sheets and the
delete confirmation belong to `AccountPresentations`, which `AppSettingsView` applies to the Form.
"""

from __future__ import annotations

from pathlib import Path

UI = Path(__file__).resolve().parents[2] / "ios/NutritionCore/Sources/NutritionUI"
PRESENTERS = (".sheet(", ".confirmationDialog(", ".fullScreenCover(", ".alert(")


def test_account_section_rows_present_nothing() -> None:
    text = (UI / "AccountSectionView.swift").read_text()
    section = text[: text.index("struct AccountPresentations")]
    for presenter in PRESENTERS:
        assert presenter not in section, f"AccountSectionView must not attach {presenter}"


def test_settings_form_applies_the_account_presentations() -> None:
    text = (UI / "AppSettingsView.swift").read_text()
    assert ".accountPresentations(model.account)" in text


def test_presentations_carry_sign_in_disclosure_and_delete() -> None:
    text = (UI / "AccountSectionView.swift").read_text()
    tail = text[text.index("struct AccountPresentations") :]
    for needle in ("SignInSheet(model: model)", "SharingDisclosureSheet(model: model)", "Delete your account?"):
        assert needle in tail


def test_v2_disclosure_states_expanded_scope_automatic_creation_and_owner_only_verification() -> None:
    text = (UI / "SharingDisclosureSheet.swift").read_text()
    for wording in (
        "manually created foods, drinks and supplements, with or without a barcode",
        "Agreement is support only", "Only catalog-owner review of the exact facts verifies",
        "automatically queued to share, including when offline", "Imports, edits and older local products",
        "Photos, consumed amounts, intake times, meals, journal entries, notes and goals are never shared",
        "does not remove earlier contributions", "Remove my contribution", "version 2",
    ):
        assert wording in text
    assert "Agreement from distinct accounts and review determine verification" not in text
