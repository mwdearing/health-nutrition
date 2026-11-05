"""Guardrails for the committed journal-export contract files.

`contracts/journal-export` holds one schema and one synthetic example per export version. The Swift export
tests read byte-for-byte copies bundled under their target's `Contracts` folder, so a canonical file that
changes without its copy would leave those tests checking a stale contract. The file lists here come from
the canonical directory, so a new version is guarded without anyone remembering to add it.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
CANONICAL = ROOT / "contracts/journal-export"
BUNDLED = ROOT / "ios/NutritionCore/Tests/NutritionJournalExportTests/Contracts"
SOURCE = ROOT / "ios/NutritionCore/Sources/NutritionJournal/JournalExport.swift"
CONTRACT_NAME = re.compile(r"^(?:v\d+\.schema|example\.v\d+)\.json$")


def _contract_names(directory: Path) -> list[str]:
    return sorted(p.name for p in directory.iterdir() if CONTRACT_NAME.match(p.name))


def _versions() -> list[int]:
    return sorted(int(m.group(1)) for n in _contract_names(CANONICAL) if (m := re.match(r"v(\d+)\.schema", n)))


def test_every_version_has_a_schema_and_an_example() -> None:
    match = re.search(r"currentSchemaVersion\s*=\s*(\d+)", SOURCE.read_text())
    assert match is not None
    assert _versions() == list(range(1, int(match.group(1)) + 1))
    for version in _versions():
        assert (CANONICAL / f"example.v{version}.json").is_file(), f"example.v{version}.json is missing"


def test_bundled_copies_match_the_canonical_files() -> None:
    canonical = _contract_names(CANONICAL)
    assert _contract_names(BUNDLED) == canonical
    for name in canonical:
        assert (BUNDLED / name).read_bytes() == (CANONICAL / name).read_bytes(), (
            f"{name} has drifted from contracts/journal-export"
        )


@pytest.mark.parametrize("version", _versions())
def test_example_validates_against_its_schema(version: int) -> None:
    jsonschema = pytest.importorskip("jsonschema")
    schema = json.loads((CANONICAL / f"v{version}.schema.json").read_text())
    example_path = CANONICAL / f"example.v{version}.json"
    assert example_path.is_file(), f"example.v{version}.json is missing"
    example = json.loads(example_path.read_text())
    jsonschema.Draft202012Validator.check_schema(schema)
    assert example["schema_version"] == version
    assert list(jsonschema.Draft202012Validator(schema).iter_errors(example)) == []
