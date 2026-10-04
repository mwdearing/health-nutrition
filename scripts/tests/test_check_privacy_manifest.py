"""Tests for scripts/check_privacy_manifest.py.

Each test builds a tiny synthetic tree in tmp_path (a Swift source plus a
PrivacyInfo.xcprivacy), runs the checker as a subprocess and inspects its exit
code and one-line-per-gap output.
"""
from __future__ import annotations

import plistlib
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "check_privacy_manifest.py"

BOOT_TIME = ("NSPrivacyAccessedAPICategorySystemBootTime", ["35F9.1"])
USER_DEFAULTS = ("NSPrivacyAccessedAPICategoryUserDefaults", ["CA92.1"])
FILE_TIMESTAMP = ("NSPrivacyAccessedAPICategoryFileTimestamp", ["C617.1"])


def manifest_xml(
    *,
    tracking: bool = False,
    declared: list[tuple[str, list[str]]] | None = None,
) -> str:
    if declared is None:
        declared = [BOOT_TIME]
    apis = "\n".join(
        "\t\t<dict>\n"
        "\t\t\t<key>NSPrivacyAccessedAPIType</key>\n"
        f"\t\t\t<string>{category}</string>\n"
        "\t\t\t<key>NSPrivacyAccessedAPITypeReasons</key>\n"
        "\t\t\t<array>\n"
        + "".join(f"\t\t\t\t<string>{reason}</string>\n" for reason in reasons)
        + "\t\t\t</array>\n"
        "\t\t</dict>"
        for category, reasons in declared
    )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n'
        "<dict>\n"
        "\t<key>NSPrivacyTracking</key>\n"
        f"\t<{'true' if tracking else 'false'}/>\n"
        "\t<key>NSPrivacyTrackingDomains</key>\n"
        "\t<array/>\n"
        "\t<key>NSPrivacyCollectedDataTypes</key>\n"
        "\t<array/>\n"
        "\t<key>NSPrivacyAccessedAPITypes</key>\n"
        "\t<array>\n"
        f"{apis}\n"
        "\t</array>\n"
        "</dict>\n"
        "</plist>\n"
    )


def write_tree(
    tmp_path: Path,
    swift: dict[str, str],
    *,
    manifest: str | None = None,
    manifest_name: str = "PrivacyInfo.xcprivacy",
) -> Path:
    root = tmp_path / "ios"
    for rel, body in swift.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    if manifest is not None:
        resources = root / "HealthNutrition" / "Resources"
        resources.mkdir(parents=True, exist_ok=True)
        (resources / manifest_name).write_text(manifest, encoding="utf-8")
    return root


def run(root: Path, manifest: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--root",
            str(root),
            "--manifest",
            str(manifest if manifest is not None else root / "HealthNutrition" / "Resources" / "PrivacyInfo.xcprivacy"),
        ],
        capture_output=True,
        text=True,
    )


def read_manifest(path: Path) -> dict:
    return plistlib.loads(path.read_bytes())


def test_declared_api_passes(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "NutritionCore/Sources/Providers/Client.swift": (
                "import Foundation\n"
                "func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }\n"
            )
        },
        manifest=manifest_xml(declared=[BOOT_TIME]),
    )
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr


def test_undeclared_user_defaults_fails(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "NutritionCore/Sources/App/Settings.swift": (
                "import Foundation\n"
                "let flags = UserDefaults.standard\n"
            )
        },
        manifest=manifest_xml(declared=[BOOT_TIME]),
    )
    result = run(root)
    assert result.returncode == 1
    assert "NSPrivacyAccessedAPICategoryUserDefaults" in result.stdout
    assert "CA92.1" in result.stdout
    assert len(result.stdout.strip().splitlines()) == 1


def test_declared_user_defaults_with_wrong_reason_fails(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "NutritionCore/Sources/App/Settings.swift": (
                "import Foundation\n"
                "struct S { @AppStorage(\"water\") var water = 0 }\n"
            )
        },
        manifest=manifest_xml(declared=[("NSPrivacyAccessedAPICategoryUserDefaults", ["1A2B.3"])]),
    )
    result = run(root)
    assert result.returncode == 1
    assert "CA92.1" in result.stdout


def test_system_uptime_needs_the_boot_time_reason(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "NutritionCore/Sources/Providers/Client.swift": (
                "import Foundation\n"
                "func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }\n"
            )
        },
        manifest=manifest_xml(declared=[(BOOT_TIME[0], ["C617.1"])]),
    )
    result = run(root)
    assert result.returncode == 1
    assert "35F9.1" in result.stdout


def test_tracking_must_be_false(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {"NutritionCore/Sources/Providers/Client.swift": "import Foundation\n"},
        manifest=manifest_xml(tracking=True, declared=[]),
    )
    result = run(root)
    assert result.returncode == 1
    assert "NSPrivacyTracking" in result.stdout


def test_comments_and_strings_are_ignored(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "NutritionCore/Sources/Providers/Client.swift": (
                "import Foundation\n"
                "// UserDefaults.standard.set(1, forKey: \"x\")\n"
                "/* systemUptime */\n"
                "let note = \"volumeAvailableCapacity is not read here\"\n"
            )
        },
        manifest=manifest_xml(declared=[]),
    )
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr


def test_file_timestamp_category_is_checked(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "NutritionCore/Sources/Journal/Export.swift": (
                "import Foundation\n"
                "let when = attrs[.creationDate] as? Date\n"
            )
        },
        manifest=manifest_xml(declared=[FILE_TIMESTAMP]),
    )
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr


def test_missing_manifest_is_an_error(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {"NutritionCore/Sources/Providers/Client.swift": "import Foundation\n"})
    result = run(root)
    assert result.returncode != 0
    assert "PrivacyInfo.xcprivacy" in result.stdout + result.stderr