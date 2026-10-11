"""Keep superseded restores' store effects separate from current import presentation."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VIEW_MODEL = ROOT / "ios/NutritionCore/Sources/NutritionUI/ConnectionsPrivacyViewModel.swift"
EXPORT_DOCS = ROOT / "docs/journal-export.md"


def test_superseded_restore_effects_run_after_the_erase_fence_and_before_the_import_fence() -> None:
    source = VIEW_MODEL.read_text()
    outcome = source.split("private enum ImportOutcome", maxsplit=1)[1].split(
        "private enum ImportFailure", maxsplit=1
    )[0]
    assert "case .failed(.refused(.partialRestore))" in outcome

    apply = source.split("private func apply(\n", maxsplit=1)[1].split(
        "private static func importFailureText", maxsplit=1
    )[0]
    erase_fence = apply.index("guard !isErasing, eraseGenerationAtStart == eraseGeneration")
    mutation_effects = apply.index("if outcome.changedJournal")
    latest_import_fence = apply.index("guard generation == importGeneration")
    assert erase_fence < mutation_effects < latest_import_fence
    assert "journalRestoreGeneration += 1" in apply
    assert "removeExportFile()" in apply


def test_journal_export_docs_describe_partial_restore_in_the_error_contract() -> None:
    docs = EXPORT_DOCS.read_text()
    normalized = " ".join(docs.split())
    assert "instead of writing part of a file" not in docs
    assert "| `partialRestore` |" in docs
    assert "inspect the journal before trying that file again" in normalized


def test_superseded_partial_restore_warning_is_separate_and_visible() -> None:
    source = VIEW_MODEL.read_text()
    assert "var incompleteRestoreWarning: String?" in source
    apply = source.split("private func apply(\n", maxsplit=1)[1].split(
        "private static func importFailureText", maxsplit=1
    )[0]
    warning = apply.index("if outcome.isPartialRestore")
    latest_import_fence = apply.index("guard generation == importGeneration")
    assert warning < latest_import_fence
    assert "else if case .imported = outcome" in apply

    clear_import = source.split("public func clearImport() {", maxsplit=1)[1].split("\n    }", maxsplit=1)[0]
    assert "incompleteRestoreWarning" not in clear_import
    assert "if !failed { incompleteRestoreWarning = nil }" in source

    settings = (ROOT / "ios/NutritionCore/Sources/NutritionUI/AppSettingsView.swift").read_text()
    assert "connections.incompleteRestoreWarning" in settings
    assert "warning != connections.importMessage" in settings
