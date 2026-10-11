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
