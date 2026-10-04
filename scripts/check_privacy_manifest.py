#!/usr/bin/env python3
"""Check the app privacy manifest against the Swift sources.

Usage:
    python3 scripts/check_privacy_manifest.py [--root ROOT] [--manifest PATH]

``ROOT`` defaults to ``ios`` and ``PATH`` to
``<ROOT>/HealthNutrition/Resources/PrivacyInfo.xcprivacy``. Every ``*.swift``
file under ``ROOT`` is scanned for the required-reason APIs Apple lists; each
category that a source uses must be declared in the manifest together with a
reason this project is entitled to, and ``NSPrivacyTracking`` must be false.

Findings are printed one per line as ``path:line: message`` and the script
exits 1 when there is at least one finding, 0 when the tree is clean and 2 on a
usage error (missing or unreadable manifest).

Checked categories
------------------
NSPrivacyAccessedAPICategoryUserDefaults (CA92.1)
    ``UserDefaults`` and ``@AppStorage``.
NSPrivacyAccessedAPICategorySystemBootTime (35F9.1)
    ``systemUptime`` and ``mach_absolute_time``.
NSPrivacyAccessedAPICategoryFileTimestamp (C617.1)
    ``creationDate``, ``modificationDate`` and ``attributesOfItem``.
NSPrivacyAccessedAPICategoryDiskSpace (E174.1)
    ``volumeAvailableCapacity`` and ``systemFreeSize``.
NSPrivacyAccessedAPICategoryActiveKeyboards (54BD.1)
    ``activeInputModes``.

``//`` comments, ``/* */`` comments and the contents of string literals are
masked out before matching, so a mention in prose or in a message text does not
count as a use.
"""
from __future__ import annotations

import argparse
import plistlib
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ROOT = REPO_ROOT / "ios"
DEFAULT_MANIFEST_RELATIVE = Path("HealthNutrition/Resources/PrivacyInfo.xcprivacy")

# category -> (the reason this project may declare, the API spellings)
CATEGORIES: dict[str, tuple[str, tuple[str, ...]]] = {
    "NSPrivacyAccessedAPICategoryUserDefaults": ("CA92.1", (r"\bUserDefaults\b", r"@AppStorage")),
    "NSPrivacyAccessedAPICategorySystemBootTime": ("35F9.1", (r"\bsystemUptime\b", r"\bmach_absolute_time\b")),
    "NSPrivacyAccessedAPICategoryFileTimestamp": (
        "C617.1",
        (r"\bcreationDate\b", r"\bmodificationDate\b", r"\battributesOfItem\b"),
    ),
    "NSPrivacyAccessedAPICategoryDiskSpace": (
        "E174.1",
        (r"\bvolumeAvailableCapacity\w*\b", r"\bsystemFreeSize\w*\b"),
    ),
    "NSPrivacyAccessedAPICategoryActiveKeyboards": ("54BD.1", (r"\bactiveInputModes\b",)),
}

MASKED_LINE = " "


def mask(source: str) -> str:
    """Blank out comments and string contents, keeping offsets and newlines."""
    # Multiline string literals first: they may span lines.
    text = re.sub(r'"""[\s\S]*?"""', lambda m: MASKED_LINE * len(m.group(0)), source)
    # Then single-line literals, including extended (#"..."#) forms.
    text = re.sub(
        r'(#*)"(?:\\.|[^"\\\n])*"\1',
        lambda m: MASKED_LINE * len(m.group(0)),
        text,
    )
    # Line comments.
    text = re.sub(r"//[^\n]*", lambda m: MASKED_LINE * len(m.group(0)), text)
    # Block comments, which nest in Swift.
    while True:
        replaced = re.sub(
            r"/\*[\s\S]*?\*/",
            lambda m: MASKED_LINE * len(m.group(0)),
            text,
            count=1,
        )
        if replaced == text:
            break
        text = replaced
    return text


def used_categories(source: str) -> list[tuple[str, int]]:
    """Return (category, line number) for the first use of each category."""
    masked = mask(source)
    found: list[tuple[str, int]] = []
    for category, (_, patterns) in CATEGORIES.items():
        for pattern in patterns:
            match = re.search(pattern, masked)
            if match:
                found.append((category, masked.count("\n", 0, match.start()) + 1))
                break
    return found


def declared_reasons(manifest: dict) -> dict[str, list[str]]:
    declared: dict[str, list[str]] = {}
    for entry in manifest.get("NSPrivacyAccessedAPITypes", []):
        category = entry.get("NSPrivacyAccessedAPIType")
        if not isinstance(category, str):
            continue
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons", [])
        declared.setdefault(category, []).extend(r for r in reasons if isinstance(r, str))
    return declared


def load_manifest(path: Path) -> dict | None:
    try:
        return plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as exc:
        print(f"{path}: cannot read the privacy manifest ({exc})")
        return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="tree of Swift sources to scan")
    parser.add_argument("--manifest", type=Path, default=None, help="path to PrivacyInfo.xcprivacy")
    args = parser.parse_args(argv)

    root: Path = args.root
    manifest_path: Path = args.manifest if args.manifest is not None else root / DEFAULT_MANIFEST_RELATIVE
    if not root.is_dir():
        print(f"{root}: no such directory")
        return 2

    manifest = load_manifest(manifest_path)
    if manifest is None:
        return 2

    findings: list[str] = []
    if manifest.get("NSPrivacyTracking") is not False:
        findings.append(f"{manifest_path}: NSPrivacyTracking must be false in this manifest")

    declared = declared_reasons(manifest)
    used: dict[str, list[str]] = {}
    for path in sorted(root.rglob("*.swift")):
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            print(f"{path}: cannot read ({exc})")
            return 2
        for category, line in used_categories(source):
            used.setdefault(category, []).append(f"{path}:{line}")

    for category, sites in used.items():
        reason = CATEGORIES.get(category, ("<unknown>", ()))[0]
        reasons = declared.get(category, [])
        if reason not in reasons:
            findings.append(
                f"{sites[0]}: {category} is used here but the manifest does not declare reason {reason}"
            )

    if findings:
        for finding in findings:
            print(finding)
        return 1
    print(f"privacy manifest ok: {len(used)} required-reason category/categories declared, tracking off")
    return 0


if __name__ == "__main__":
    sys.exit(main())