import hashlib
import json
import os
from pathlib import Path
from typing import Any

import pytest


MANIFEST_KEYS = {
    "provider",
    "base_url",
    "api_version",
    "spec_version",
    "license",
    "license_url",
    "retrieved_on",
    "selection",
    "files",
}
LABEL_METADATA_KEYS = {"label_id", "off_market", "entry_date"}


@pytest.fixture(scope="module")
def fixture_root() -> Path:
    configured_root = os.environ.get("DSLD_FIXTURE_DIR")
    if configured_root:
        return Path(configured_root)
    return (
        Path(__file__).resolve().parents[2]
        / "contracts"
        / "providers"
        / "dsld"
    )


@pytest.fixture(scope="module")
def manifest(fixture_root: Path) -> dict[str, Any]:
    manifest_path = fixture_root / "MANIFEST.json"
    return json.loads(manifest_path.read_text(encoding="utf-8"))


def _entry_path(fixture_root: Path, entry: dict[str, Any]) -> Path:
    return fixture_root / entry["path"]


def _label_entries(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    entries = [
        entry
        for entry in manifest["files"]
        if LABEL_METADATA_KEYS.intersection(entry)
    ]
    assert entries
    return entries


def test_manifest_keys(manifest: dict[str, Any]) -> None:
    assert MANIFEST_KEYS <= manifest.keys()


def test_manifest_files_listed(
    fixture_root: Path,
    manifest: dict[str, Any],
) -> None:
    listed_paths = {entry["path"] for entry in manifest["files"]}
    fixture_paths = {
        path.relative_to(fixture_root).as_posix()
        for path in (fixture_root / "fixtures").rglob("*")
        if path.is_file()
    }

    assert fixture_paths <= listed_paths
    for entry in manifest["files"]:
        assert _entry_path(fixture_root, entry).is_file()


def test_sha256_matches(
    fixture_root: Path,
    manifest: dict[str, Any],
) -> None:
    for entry in manifest["files"]:
        file_bytes = _entry_path(fixture_root, entry).read_bytes()
        actual_sha256 = hashlib.sha256(file_bytes).hexdigest()
        assert actual_sha256 == entry["sha256"]


def test_label_structure(
    fixture_root: Path,
    manifest: dict[str, Any],
) -> None:
    for entry in _label_entries(manifest):
        label_path = _entry_path(fixture_root, entry)
        label = json.loads(label_path.read_text(encoding="utf-8"))

        assert str(label["id"]) == label_path.stem
        assert "entryDate" in label
        assert label["offMarket"] in {0, 1}

        ingredient_rows = label["ingredientRows"]
        assert isinstance(ingredient_rows, list)
        assert ingredient_rows
        for row in ingredient_rows:
            assert isinstance(row, dict)
            assert "name" in row


def test_manifest_label_metadata(
    fixture_root: Path,
    manifest: dict[str, Any],
) -> None:
    for entry in _label_entries(manifest):
        assert LABEL_METADATA_KEYS <= entry.keys()

        label_path = _entry_path(fixture_root, entry)
        label = json.loads(label_path.read_text(encoding="utf-8"))

        assert entry["label_id"] == label["id"]
        assert entry["off_market"] == label["offMarket"]
        assert entry["entry_date"] == label["entryDate"]


def test_version_json(
    fixture_root: Path,
    manifest: dict[str, Any],
) -> None:
    version_path = fixture_root / "version.json"
    version = json.loads(version_path.read_text(encoding="utf-8"))

    assert version["config"] == "production"
    assert version["version"] == manifest["api_version"]
