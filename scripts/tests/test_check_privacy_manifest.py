"""Tests for scripts/check_privacy_manifest.py.

Each test builds a tiny synthetic package tree in tmp_path (a HealthNutrition
app with a project.yml, a NutritionCore package with a Package.swift and Swift
sources), runs the checker as a subprocess and inspects its exit code and
one-line-per-gap output.
"""
from __future__ import annotations

import plistlib
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "check_privacy_manifest.py"

BOOT_TIME = ("NSPrivacyAccessedAPICategorySystemBootTime", ["35F9.1"])
USER_DEFAULTS = ("NSPrivacyAccessedAPICategoryUserDefaults", ["CA92.1"])
FILE_TIMESTAMP = ("NSPrivacyAccessedAPICategoryFileTimestamp", ["C617.1"])
DISK_SPACE = ("NSPrivacyAccessedAPICategoryDiskSpace", ["E174.1"])

PROJECT_YML = """\
name: HealthNutrition

targets:
  HealthNutrition:
    type: application
    platform: iOS
    sources:
      - path: Sources
      - path: Resources
    dependencies:
      - package: NutritionCore
        product: NutritionCore
      - package: NutritionCore
        product: NutritionUI
      - package: NutritionCore
        product: NutritionJournal
      - package: NutritionCore
        product: NutritionProviders
"""

PACKAGE_SWIFT = """\
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NutritionCore",
    products: [
        .library(name: "NutritionCore", targets: ["NutritionCore"]),
        .library(name: "NutritionDomain", targets: ["NutritionDomain"]),
        .library(name: "NutritionProviders", targets: ["NutritionProviders"]),
        .library(name: "NutritionJournal", targets: ["NutritionJournal"]),
        .library(name: "NutritionUI", targets: ["NutritionUI"]),
    ],
    targets: [
        .target(name: "NutritionCore"),
        .testTarget(name: "NutritionCoreTests", dependencies: ["NutritionCore"]),
        .target(name: "NutritionDomain", path: "Sources/NutritionDomain"),
        .testTarget(name: "NutritionDomainTests", dependencies: ["NutritionDomain"]),
        .target(name: "NutritionProviders", dependencies: ["NutritionDomain"]),
        .testTarget(name: "JournalStoreSpike"),
        .target(name: "NutritionJournal", dependencies: ["NutritionDomain"]),
        .target(name: "NutritionUI", dependencies: ["NutritionCore", "NutritionJournal"]),
    ]
)
"""


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
    project_yml: str = PROJECT_YML,
    package_swift: str = PACKAGE_SWIFT,
    manifest_name: str = "PrivacyInfo.xcprivacy",
) -> Path:
    root = tmp_path / "ios"
    for rel, body in swift.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    app = root / "HealthNutrition"
    app.mkdir(parents=True, exist_ok=True)
    (app / "project.yml").write_text(project_yml, encoding="utf-8")
    package = root / "NutritionCore"
    package.mkdir(parents=True, exist_ok=True)
    (package / "Package.swift").write_text(package_swift, encoding="utf-8")
    if manifest is not None:
        resources = app / "Resources"
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
            str(
                manifest
                if manifest is not None
                else root / "HealthNutrition" / "Resources" / "PrivacyInfo.xcprivacy"
            ),
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
            "NutritionCore/Sources/NutritionProviders/Client.swift": (
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
            "HealthNutrition/Sources/Settings.swift": (
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
            "HealthNutrition/Sources/Settings.swift": (
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
            "NutritionCore/Sources/NutritionProviders/Client.swift": (
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
        {"NutritionCore/Sources/NutritionProviders/Client.swift": "import Foundation\n"},
        manifest=manifest_xml(tracking=True, declared=[]),
    )
    result = run(root)
    assert result.returncode == 1
    assert "NSPrivacyTracking" in result.stdout


def test_comments_and_strings_are_ignored(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "NutritionCore/Sources/NutritionProviders/Client.swift": (
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


def test_api_in_string_interpolation_is_code(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "HealthNutrition/Sources/Settings.swift": (
                "import Foundation\n"
                'let label = "defaults: \\(UserDefaults.standard)"\n'
            )
        },
        manifest=manifest_xml(declared=[]),
    )
    result = run(root)
    assert result.returncode == 1
    assert "NSPrivacyAccessedAPICategoryUserDefaults" in result.stdout


def test_interpolated_literal_text_is_not_code(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "HealthNutrition/Sources/Settings.swift": (
                "import Foundation\n"
                'let label = "systemUptime and activeInputModes are not read"\n'
            )
        },
        manifest=manifest_xml(declared=[]),
    )
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr


def test_hash_delimited_interpolation_is_scanned(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "HealthNutrition/Sources/Settings.swift": (
                "import Foundation\n"
                'let label = #"raw \\#(activeInputModes)"#\n'
            )
        },
        manifest=manifest_xml(declared=[]),
    )
    result = run(root)
    assert result.returncode == 1
    assert "NSPrivacyAccessedAPICategoryActiveKeyboards" in result.stdout


def test_reported_line_is_the_line_of_the_use(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "HealthNutrition/Sources/Settings.swift": (
                "import Foundation\n"
                'let note = "a literal that spans\n'
                'two lines"\n'
                "let flags = UserDefaults.standard\n"
            )
        },
        manifest=manifest_xml(declared=[]),
    )
    result = run(root)
    assert result.returncode == 1
    assert "Settings.swift:4:" in result.stdout, result.stdout


def test_nested_interpolation_is_scanned(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "HealthNutrition/Sources/Settings.swift": (
                "import Foundation\n"
                'let label = "\\("inner: \\(activeInputModes)")"\n'
            )
        },
        manifest=manifest_xml(declared=[]),
    )
    result = run(root)
    assert result.returncode == 1
    assert "NSPrivacyAccessedAPICategoryActiveKeyboards" in result.stdout


@pytest.mark.parametrize(
    "call",
    [
        "statfs(&info)",
        "statvfs(&info)",
        "fstatfs(1, &info)",
        "fstatvfs(1, &info)",
        'getattrlist("/tmp", &attrs, &count, 0)',
        "getattrlistbulk(&attrs, &count)",
        "fgetattrlist(1, &attrs, &count, 0)",
        "getattrlistat(AT_FDCWD, \"/tmp\", &attrs)",
        "URLResourceValues.volumeAvailableCapacityForImportantUsage",
        "values.volumeAvailableCapacity",
        "let key = URLResourceKey.volumeTotalCapacityKey",
        "let size = processInfo.systemSize",
        "let free = processInfo.systemFreeSize",
    ],
)
def test_full_disk_space_api_set_is_detected(tmp_path: Path, call: str) -> None:
    root = write_tree(
        tmp_path,
        {"HealthNutrition/Sources/Disk.swift": f"import Foundation\nlet probe = {call}\n"},
        manifest=manifest_xml(declared=[BOOT_TIME]),
    )
    result = run(root)
    assert result.returncode == 1
    assert "NSPrivacyAccessedAPICategoryDiskSpace" in result.stdout
    assert "E174.1" in result.stdout


def test_test_targets_are_not_scanned(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "NutritionCore/Tests/NutritionCoreTests/DefaultsTests.swift": (
                "import Foundation\n"
                "let flags = UserDefaults.standard\n"
            )
        },
        manifest=manifest_xml(declared=[BOOT_TIME]),
    )
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr


def test_standalone_spike_target_is_not_scanned(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "NutritionCore/Sources/JournalStoreSpike/JournalStore.swift": (
                "import Foundation\n"
                "let flags = UserDefaults.standard\n"
            )
        },
        manifest=manifest_xml(declared=[BOOT_TIME]),
    )
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize(
    "rel",
    [
        "HealthNutrition/Sources/AppServices.swift",
        "NutritionCore/Sources/NutritionCore/NutritionCore.swift",
        "NutritionCore/Sources/NutritionDomain/Quantity.swift",
        "NutritionCore/Sources/NutritionProviders/BarcodeValidator.swift",
        "NutritionCore/Sources/NutritionJournal/RecipeStore.swift",
        "NutritionCore/Sources/NutritionUI/JournalView.swift",
    ],
)
def test_every_target_the_app_links_is_scanned(tmp_path: Path, rel: str) -> None:
    root = write_tree(
        tmp_path,
        {rel: "import Foundation\nlet flags = UserDefaults.standard\n"},
        manifest=manifest_xml(declared=[BOOT_TIME]),
    )
    result = run(root)
    assert result.returncode == 1, f"{rel} was not scanned: {result.stdout}"
    assert "NSPrivacyAccessedAPICategoryUserDefaults" in result.stdout


def test_transitive_library_dependency_is_scanned(tmp_path: Path) -> None:
    # NutritionDomain is a dependency of the linked libraries, not a product the
    # app lists itself, and it still ships in the app.
    root = write_tree(
        tmp_path,
        {
            "NutritionCore/Sources/NutritionDomain/Quantity.swift": (
                "import Foundation\n"
                "let flags = UserDefaults.standard\n"
            )
        },
        manifest=manifest_xml(declared=[BOOT_TIME]),
    )
    result = run(root)
    assert result.returncode == 1
    assert "NSPrivacyAccessedAPICategoryUserDefaults" in result.stdout


def test_unknown_reason_code_is_rejected(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "NutritionCore/Sources/NutritionProviders/Client.swift": (
                "import Foundation\n"
                "func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }\n"
            )
        },
        manifest=manifest_xml(declared=[("NSPrivacyAccessedAPICategorySystemBootTime", ["35F9.1", "BOGUS"])]),
    )
    result = run(root)
    assert result.returncode == 1
    assert "BOGUS" in result.stdout


def test_reason_from_another_category_is_rejected(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "NutritionCore/Sources/NutritionProviders/Client.swift": (
                "import Foundation\n"
                "func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }\n"
            )
        },
        manifest=manifest_xml(declared=[("NSPrivacyAccessedAPICategorySystemBootTime", ["35F9.1", "CA92.1"])]),
    )
    result = run(root)
    assert result.returncode == 1
    assert "CA92.1" in result.stdout


def test_another_published_reason_for_the_same_category_is_allowed(tmp_path: Path) -> None:
    # 3D61.1 is a published SystemBootTime reason; the checker must not reject a
    # manifest for using it instead of 35F9.1.
    root = write_tree(
        tmp_path,
        {
            "NutritionCore/Sources/NutritionProviders/Client.swift": (
                "import Foundation\n"
                "func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }\n"
            )
        },
        manifest=manifest_xml(declared=[("NSPrivacyAccessedAPICategorySystemBootTime", ["3D61.1"])]),
    )
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr


def test_domain_property_named_creation_date_is_not_a_file_timestamp_api(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "NutritionCore/Sources/NutritionJournal/JournalTypes.swift": (
                "import Foundation\n"
                "public struct Event {\n"
                "    public let creationDate: Date\n"
                "    public let modificationDate: Date\n"
                "    public init(creationDate: Date, modificationDate: Date) {\n"
                "        self.creationDate = creationDate\n"
                "        self.modificationDate = modificationDate\n"
                "    }\n"
                "}\n"
            )
        },
        manifest=manifest_xml(declared=[BOOT_TIME]),
    )
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.parametrize(
    "access",
    [
        "let key = FileAttributeKey.creationDate",
        "let key = FileAttributeKey.modificationDate",
        "let when = attributes[.creationDate] as? Date",
        "let key = URLResourceKey.contentModificationDateKey",
        "let key = URLResourceKey.creationDateKey",
        "let attrs = try FileManager.default.attributesOfItem(atPath: path)",
        'stat("index", &info)',
        "fstat(1, &info)",
        'lstat("index", &info)',
    ],
)
def test_real_file_timestamp_access_is_detected(tmp_path: Path, access: str) -> None:
    root = write_tree(
        tmp_path,
        {"HealthNutrition/Sources/Files.swift": f"import Foundation\nlet probe = {access}\n"},
        manifest=manifest_xml(declared=[BOOT_TIME]),
    )
    result = run(root)
    assert result.returncode == 1
    assert "NSPrivacyAccessedAPICategoryFileTimestamp" in result.stdout
    assert "C617.1" in result.stdout


def test_resource_values_timestamps_are_detected(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "HealthNutrition/Sources/Files.swift": (
                "import Foundation\n"
                "let values = try url.resourceValues(forKeys: [.contentModificationDateKey])\n"
                "let when = values.contentModificationDate\n"
                "let values2 = try url.resourceValues(forKeys: [.creationDateKey])\n"
                "let created = values2.creationDate\n"
            )
        },
        manifest=manifest_xml(declared=[FILE_TIMESTAMP]),
    )
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr


def test_missing_manifest_is_an_error(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {"NutritionCore/Sources/NutritionCore/NutritionCore.swift": "import Foundation\n"})
    result = run(root)
    assert result.returncode != 0
    assert "PrivacyInfo.xcprivacy" in result.stdout + result.stderr


def test_missing_project_file_is_an_error(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {"NutritionCore/Sources/NutritionProviders/Client.swift": "import Foundation\n"},
        manifest=manifest_xml(),
        project_yml="",
    )
    result = run(root)
    assert result.returncode != 0