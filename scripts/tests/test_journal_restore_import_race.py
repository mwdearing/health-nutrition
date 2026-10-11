"""Keep superseded restores' store effects separate from current import presentation."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VIEW_MODEL = ROOT / "ios/NutritionCore/Sources/NutritionUI/ConnectionsPrivacyViewModel.swift"
EXPORT_DOCS = ROOT / "docs/journal-export.md"


def test_superseded_restore_effects_wait_for_erase_resolution_and_precede_import_presentation() -> None:
    source = VIEW_MODEL.read_text()
    outcome = source.split("private enum ImportOutcome", maxsplit=1)[1].split(
        "private enum ImportFailure", maxsplit=1
    )[0]
    assert "case .failed(.refused(.partialRestore))" in outcome

    apply = source.split("private func apply(\n", maxsplit=1)[1].split(
        "private static func importFailureText", maxsplit=1
    )[0]
    successful_erase_fence = apply.index("guard successfulEraseEpochAtStart == successfulEraseEpoch")
    defer_during_erase = apply.index("if isErasing")
    mutation_effects = apply.index("applyStoreEffects(")
    latest_import_fence = apply.index("guard generation == importGeneration")
    assert successful_erase_fence < defer_during_erase < mutation_effects < latest_import_fence

    erase = source.split("public func eraseAllData() async -> Bool {", maxsplit=1)[1].split(
        "/// Puts the display preferences", maxsplit=1
    )[0]
    assert "if failed {" in erase and "resolveDeferredImportEffectsAfterFailedErase()" in erase
    assert "resolveDeferredImportEffectsAfterSuccessfulErase()" in erase
    failed_erase = source.split("private func resolveDeferredImportEffectsAfterFailedErase()", maxsplit=1)[1].split(
        "private func resolveDeferredImportEffectsAfterSuccessfulErase()", maxsplit=1
    )[0]
    assert "applyStoreEffects(" in failed_erase
    successful_erase = source.split("private func resolveDeferredImportEffectsAfterSuccessfulErase()", maxsplit=1)[1]
    assert "successfulEraseEpoch += 1" in successful_erase
    effects = source.split("private func applyStoreEffects(", maxsplit=1)[1].split(
        "/// The sentence for a failure", maxsplit=1
    )[0]
    assert "exportRevision == exportRevisionAtStart" in effects
    assert "journalRestoreGeneration += 1" in effects
    assert "removeExportFile()" in effects


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
    warning = apply.index("applyStoreEffects(")
    latest_import_fence = apply.index("guard generation == importGeneration")
    assert warning < latest_import_fence

    effects = source.split("private func applyStoreEffects(", maxsplit=1)[1].split(
        "/// The sentence for a failure", maxsplit=1
    )[0]
    assert "if isPartialRestore" in effects
    assert "isCompleteImport, generation == importGeneration" in effects

    clear_import = source.split("public func clearImport() {", maxsplit=1)[1].split("\n    }", maxsplit=1)[0]
    assert "incompleteRestoreWarning" not in clear_import
    successful_erase = source.split("private func resolveDeferredImportEffectsAfterSuccessfulErase()", maxsplit=1)[1]
    assert "incompleteRestoreWarning = nil" in successful_erase

    settings = (ROOT / "ios/NutritionCore/Sources/NutritionUI/AppSettingsView.swift").read_text()
    assert "connections.incompleteRestoreWarning" in settings
    assert "warning != connections.importMessage" in settings
