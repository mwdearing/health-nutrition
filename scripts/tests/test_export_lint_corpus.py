"""Tests for scripts/export_lint_corpus.py.

The exporter is the bridge between the Python lint's test cases and the
SwiftSyntax spike, so what matters here is that it reads those cases faithfully
and that the corpus it writes still says what the lint says.
"""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "export_lint_corpus.py"
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
CORPUS_FILE = REPOSITORY_ROOT / "tools" / "swift-syntax-lint" / "Tests" / "corpus.json"
RULES = ("unlabeled-image", "fixed-font-size")


def load_exporter():
    """The exporter as a module, so its readers can be called directly."""
    spec = importlib.util.spec_from_file_location("export_lint_corpus", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args], capture_output=True, text=True
    )


def corpus() -> dict:
    return json.loads(CORPUS_FILE.read_text(encoding="utf-8"))


def test_the_committed_corpus_is_up_to_date() -> None:
    result = run("--check")
    assert result.returncode == 0, result.stdout + result.stderr


def test_exporting_rewrites_the_same_bytes() -> None:
    before = CORPUS_FILE.read_text(encoding="utf-8")
    result = run()
    assert result.returncode == 0, result.stdout + result.stderr
    assert CORPUS_FILE.read_text(encoding="utf-8") == before


def test_the_corpus_covers_both_rules() -> None:
    data = corpus()
    assert data["rules"] == list(RULES)
    assert set(data["messages"]) == set(RULES)
    reported = {
        finding["rule"] for case in data["cases"] for finding in case["expected"]
    }
    assert reported == set(RULES)
    for rule in RULES:
        # A rule needs several reporting cases and several clean ones, or
        # agreement over the corpus would prove very little.
        reporting = [
            case for case in data["cases"] if any(f["rule"] == rule for f in case["expected"])
        ]
        assert len(reporting) >= 3, rule
    assert len([case for case in data["cases"] if not case["expected"]]) >= 3


def test_every_case_has_snippets_and_a_readable_expectation() -> None:
    for case in corpus()["cases"]:
        assert case["lintRoot"] in {"NutritionCore", "HealthNutrition"}, case["name"]
        assert case["files"], case["name"]
        for entry in case["files"]:
            assert entry["path"].split("/")[0] in {"NutritionCore", "HealthNutrition"}
            assert entry["path"].endswith(".swift"), case["name"]
        for finding in case["expected"]:
            assert finding["rule"] in RULES
            assert finding["line"] >= 1
            written = [entry["path"] for entry in case["files"]]
            assert finding["path"] in written, case["name"]


def test_the_cases_come_from_the_lint_tests() -> None:
    names = [case["name"] for case in corpus()["cases"]]
    assert len(names) == len(set(names))
    assert all(name.startswith("test_") for name in names)
    # An icon-only button is the case the unlabeled-image rule exists for.
    assert "test_unlabeled_image_in_an_icon_only_button_is_reported" in names
    # A button that names itself is the case that has to stay quiet.
    assert "test_labelled_icon_only_button_is_clean" in names
    # A literal point size is the case the fixed-font-size rule exists for.
    assert "test_fixed_font_size_reports_system_size_in_ui" in names


def test_the_app_target_is_covered() -> None:
    cases = corpus()["cases"]
    assert [case for case in cases if case["lintRoot"] == "HealthNutrition"], "no app-target case"
    # CI only names the package root, so a run from there has to cover the app
    # target beside it, which is why its snippets live in the same cases.
    spanning = [
        case
        for case in cases
        if any(entry["path"].startswith("HealthNutrition/") for entry in case["files"])
    ]
    assert len(spanning) >= 2


def test_a_case_whose_expectation_cannot_be_read_is_an_error() -> None:
    exporter = load_exporter()
    module = exporter.ast.parse(
        "def test_unknown_shape(tmp_path):\n"
        "    result = run(root)\n"
        "    assert result.returncode == 1\n"
    )
    # A shape the reader does not know must fail loudly rather than export an
    # expectation that was never read.
    with pytest.raises(exporter.ExportError):
        exporter._read_expectation(module.body[0])


def test_a_case_that_contradicts_the_lint_is_an_error() -> None:
    exporter = load_exporter()
    case = exporter.Case("test_wrong_expectation")
    case.files[("NutritionCore", "Sources", "NutritionUI", "Row.swift")] = (
        'import SwiftUI\nText("x").font(.system(size: 14))\n'
    )
    # The case claims a clean run, so the finding the lint reports is a
    # mismatch the export has to refuse.
    case.expected = []
    with pytest.raises(exporter.ExportError):
        exporter.checked_findings(case)
