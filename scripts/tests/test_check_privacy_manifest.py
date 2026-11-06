"""Tests for scripts/check_privacy_manifest.py.

Each test builds a tiny synthetic package tree in tmp_path (a HealthNutrition
app with a project.yml, a NutritionCore package with a Package.swift and Swift
sources), runs the checker as a subprocess and inspects its exit code and
one-line-per-gap output.
"""
from __future__ import annotations

import copy
import importlib.util
import plistlib
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "check_privacy_manifest.py"
_spec = importlib.util.spec_from_file_location("privacy_manifest_checker_under_test", SCRIPT)
assert _spec is not None and _spec.loader is not None
checker = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(checker)
REPO_ROOT = Path(__file__).resolve().parents[2]
SHIPPED_MANIFEST = REPO_ROOT / "ios" / "HealthNutrition" / "Resources" / "PrivacyInfo.xcprivacy"

BOOT_TIME = ("NSPrivacyAccessedAPICategorySystemBootTime", ["35F9.1"])
USER_DEFAULTS = ("NSPrivacyAccessedAPICategoryUserDefaults", ["CA92.1"])
FILE_TIMESTAMP = ("NSPrivacyAccessedAPICategoryFileTimestamp", ["C617.1"])
DISK_SPACE = ("NSPrivacyAccessedAPICategoryDiskSpace", ["E174.1"])

# The account sends these to the project's server, so the manifest must declare them, linked to the user, not
# used for tracking, for the app's own functionality.
EMAIL = "NSPrivacyCollectedDataTypeEmailAddress"
USER_ID = "NSPrivacyCollectedDataTypeUserID"
NAME = "NSPrivacyCollectedDataTypeName"
# The values of a scanned label (name, brand, barcode, nutrient amounts) are shared with the community catalog.
USER_CONTENT = "NSPrivacyCollectedDataTypeOtherUserContent"
# Barcodes and search words sent with the signed-in account.
SEARCH_HISTORY = "NSPrivacyCollectedDataTypeSearchHistory"
# The hCaptcha human check on email sign-in.
PRODUCT_INTERACTION = "NSPrivacyCollectedDataTypeProductInteraction"
ACCOUNT_DATA = [
    {
        "NSPrivacyCollectedDataType": data_type,
        "NSPrivacyCollectedDataTypeLinked": True,
        "NSPrivacyCollectedDataTypeTracking": False,
        "NSPrivacyCollectedDataTypePurposes": ["NSPrivacyCollectedDataTypePurposeAppFunctionality"],
    }
    for data_type in (EMAIL, USER_ID, NAME, USER_CONTENT, SEARCH_HISTORY, PRODUCT_INTERACTION)
]

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
    declared: list[tuple[str, list[object]]] | None = None,
    collected: list[dict] | None = None,
) -> str:
    if declared is None:
        declared = [BOOT_TIME]
    payload = {
        "NSPrivacyTracking": tracking,
        "NSPrivacyTrackingDomains": [],
        "NSPrivacyCollectedDataTypes": copy.deepcopy(ACCOUNT_DATA) if collected is None else collected,
        "NSPrivacyAccessedAPITypes": [
            {
                "NSPrivacyAccessedAPIType": category,
                "NSPrivacyAccessedAPITypeReasons": reasons,
            }
            for category, reasons in declared
        ],
    }
    return plistlib.dumps(payload).decode("utf-8")


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
        check=False,
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


def test_long_nonstring_hash_run_is_scanned_once_under_an_outer_deadline(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "NutritionCore/Sources/NutritionProviders/HashRun.swift": (
                ("#" * 500_000) + "\nfunc value() -> Int { 1 }\n"
            )
        },
        manifest=manifest_xml(declared=[BOOT_TIME]),
    )
    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--root",
            str(root),
            "--manifest",
            str(root / "HealthNutrition/Resources/PrivacyInfo.xcprivacy"),
        ],
        capture_output=True,
        text=True,
        timeout=5,
    )
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


def test_literal_text_after_an_interpolation_is_not_code(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "HealthNutrition/Sources/Settings.swift": (
                "import Foundation\n"
                'let label = "\\(value) UserDefaults"\n'
            )
        },
        manifest=manifest_xml(declared=[]),
    )
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr


def test_escaped_quote_inside_a_literal_is_not_code(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {
            "HealthNutrition/Sources/Settings.swift": (
                "import Foundation\n"
                'let label = "say \\"UserDefaults.standard\\" only"\n'
            )
        },
        manifest=manifest_xml(declared=[]),
    )
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr


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


PUBLISHED_REASONS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1", "C56D.1", "AC6B.1"],
    "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1", "8FFB.1", "3D61.1"],
    "NSPrivacyAccessedAPICategoryFileTimestamp": ["DDA9.1", "C617.1", "3B52.1", "0A2A.1"],
    "NSPrivacyAccessedAPICategoryDiskSpace": ["85F4.1", "E174.1", "7D9E.1", "B728.1"],
    "NSPrivacyAccessedAPICategoryActiveKeyboards": ["3EC4.1", "54BD.1"],
}


@pytest.mark.parametrize(
    ("category", "reason"),
    [(category, reason) for category, reasons in PUBLISHED_REASONS.items() for reason in reasons],
)
def test_published_reason_is_accepted(tmp_path: Path, category: str, reason: str) -> None:
    """Every reason Apple publishes for every category this checker knows."""
    root = write_tree(
        tmp_path,
        {"HealthNutrition/Sources/Empty.swift": "import Foundation\n"},
        manifest=manifest_xml(declared=[(category, [reason])]),
    )
    result = run(root)
    assert result.returncode == 0, f"{category} {reason}: {result.stdout}{result.stderr}"


@pytest.mark.parametrize(
    ("category", "reason"),
    [
        ("NSPrivacyAccessedAPICategoryUserDefaults", "AC9B.1"),
        ("NSPrivacyAccessedAPICategoryFileTimestamp", "E9D9.1"),
        ("NSPrivacyAccessedAPICategoryFileTimestamp", "3D62.1"),
        ("NSPrivacyAccessedAPICategoryDiskSpace", "B728.2"),
    ],
)
def test_reason_apple_does_not_publish_is_rejected(tmp_path: Path, category: str, reason: str) -> None:
    root = write_tree(
        tmp_path,
        {"HealthNutrition/Sources/Empty.swift": "import Foundation\n"},
        manifest=manifest_xml(declared=[(category, [reason])]),
    )
    result = run(root)
    assert result.returncode == 1
    assert reason in result.stdout


def test_unknown_category_is_rejected(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {"HealthNutrition/Sources/Empty.swift": "import Foundation\n"},
        manifest=manifest_xml(declared=[("NSPrivacyAccessedAPICategoryTimeMachine", ["35F9.1"])]),
    )
    result = run(root)
    assert result.returncode == 1
    assert "NSPrivacyAccessedAPICategoryTimeMachine" in result.stdout


def test_unknown_category_with_no_reasons_is_rejected(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {"HealthNutrition/Sources/Empty.swift": "import Foundation\n"},
        manifest=manifest_xml(declared=[("NSPrivacyAccessedAPICategoryTimeMachine", [])]),
    )
    result = run(root)
    assert result.returncode == 1
    assert "NSPrivacyAccessedAPICategoryTimeMachine" in result.stdout


def test_empty_reasons_array_is_rejected(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {"HealthNutrition/Sources/Empty.swift": "import Foundation\n"},
        manifest=manifest_xml(declared=[("NSPrivacyAccessedAPICategoryUserDefaults", [])]),
    )
    result = run(root)
    assert result.returncode == 1
    assert "NSPrivacyAccessedAPICategoryUserDefaults" in result.stdout


def test_non_string_reason_is_rejected(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        {"HealthNutrition/Sources/Empty.swift": "import Foundation\n"},
        manifest=manifest_xml(declared=[("NSPrivacyAccessedAPICategoryUserDefaults", [1])]),
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
        'fstatat(AT_FDCWD, "index", &info, 0)',
        'getattrlist("index", &attrs, &count, 0)',
        "getattrlistbulk(&attrs, &count)",
        "fgetattrlist(1, &attrs, &count, 0)",
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

def test_a_source_path_outside_the_checkout_is_refused(tmp_path: Path) -> None:
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "Leak.swift").write_text("import Foundation\nlet flags = UserDefaults.standard\n", encoding="utf-8")
    escaping = PROJECT_YML.replace("      - path: Resources\n", "      - path: Resources\n      - path: ../../outside\n")
    root = write_tree(tmp_path, {}, manifest=manifest_xml(declared=[BOOT_TIME]), project_yml=escaping)
    result = run(root)
    assert result.returncode == 2, result.stdout + result.stderr
    assert "outside" in (result.stdout + result.stderr)


def test_an_absolute_source_path_is_refused(tmp_path: Path) -> None:
    absolute = PROJECT_YML.replace("      - path: Resources\n", "      - path: Resources\n      - path: /\n")
    root = write_tree(tmp_path, {}, manifest=manifest_xml(declared=[BOOT_TIME]), project_yml=absolute)
    result = run(root)
    assert result.returncode == 2, result.stdout + result.stderr



CLEAN_SOURCE = {"NutritionCore/Sources/NutritionProviders/Client.swift": "import Foundation\n"}


def account_data_without(data_type: str) -> list[dict]:
    return [copy.deepcopy(entry) for entry in ACCOUNT_DATA if entry["NSPrivacyCollectedDataType"] != data_type]


def account_data_changed(data_type: str, key: str, value: object) -> list[dict]:
    entries = copy.deepcopy(ACCOUNT_DATA)
    for entry in entries:
        if entry["NSPrivacyCollectedDataType"] == data_type:
            entry[key] = value
    return entries


def test_an_empty_collected_data_list_fails(tmp_path: Path) -> None:
    root = write_tree(tmp_path, CLEAN_SOURCE, manifest=manifest_xml(collected=[]))
    result = run(root)
    assert result.returncode == 1
    assert EMAIL in result.stdout
    assert USER_ID in result.stdout
    assert NAME in result.stdout


@pytest.mark.parametrize("data_type", [EMAIL, USER_ID, NAME, USER_CONTENT, SEARCH_HISTORY, PRODUCT_INTERACTION])
def test_removing_a_declared_account_data_type_fails(tmp_path: Path, data_type: str) -> None:
    root = write_tree(tmp_path, CLEAN_SOURCE, manifest=manifest_xml(collected=account_data_without(data_type)))
    result = run(root)
    assert result.returncode == 1
    assert data_type in result.stdout


@pytest.mark.parametrize(
    ("key", "value"),
    [("NSPrivacyCollectedDataTypeTracking", True), ("NSPrivacyCollectedDataTypeLinked", False)],
)
def test_account_data_must_be_linked_to_the_user_and_not_used_for_tracking(
    tmp_path: Path, key: str, value: bool
) -> None:
    root = write_tree(
        tmp_path, CLEAN_SOURCE, manifest=manifest_xml(collected=account_data_changed(EMAIL, key, value))
    )
    result = run(root)
    assert result.returncode == 1
    assert EMAIL in result.stdout


def test_account_data_needs_the_app_functionality_purpose(tmp_path: Path) -> None:
    root = write_tree(
        tmp_path,
        CLEAN_SOURCE,
        manifest=manifest_xml(
            collected=account_data_changed(
                USER_ID, "NSPrivacyCollectedDataTypePurposes", ["NSPrivacyCollectedDataTypePurposeAnalytics"]
            )
        ),
    )
    result = run(root)
    assert result.returncode == 1
    assert USER_ID in result.stdout


def test_shipped_manifest_declares_the_account_data() -> None:
    manifest = read_manifest(SHIPPED_MANIFEST)
    declared = {entry.get("NSPrivacyCollectedDataType") for entry in manifest.get("NSPrivacyCollectedDataTypes", [])}
    assert {EMAIL, USER_ID, NAME, USER_CONTENT, SEARCH_HISTORY, PRODUCT_INTERACTION} <= declared
    assert manifest.get("NSPrivacyTracking") is False


def test_shipped_tree_passes_the_check() -> None:
    result = run(REPO_ROOT / "ios")
    assert result.returncode == 0, result.stdout + result.stderr


def test_a_symlinked_source_file_leaving_the_checkout_is_refused(tmp_path: Path) -> None:
    outside = tmp_path / "outside"
    outside.mkdir()
    secret = outside / "Leak.swift"
    secret.write_text("import Foundation\nlet flags = UserDefaults.standard\n", encoding="utf-8")
    root = write_tree(
        tmp_path, {"HealthNutrition/Sources/App.swift": "import Foundation\n"}, manifest=manifest_xml(declared=[BOOT_TIME])
    )
    (root / "HealthNutrition" / "Sources" / "Hang.swift").symlink_to(secret)
    result = run(root)
    assert result.returncode == 2, result.stdout + result.stderr
    assert "regular file" in (result.stdout + result.stderr)


def test_an_external_package_product_in_the_app_does_not_break_the_scan(tmp_path: Path) -> None:
    # The app links a third-party SDK. Only first-party sources are scanned, so the scan must still run and pass.
    project = PROJECT_YML + "      - package: HCaptcha\n        product: HCaptcha\n"
    root = write_tree(
        tmp_path,
        {
            "NutritionCore/Sources/NutritionProviders/Client.swift": (
                "import Foundation\n"
                "func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }\n"
            )
        },
        manifest=manifest_xml(declared=[BOOT_TIME]),
        project_yml=project,
    )
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr


def test_an_even_run_of_backslashes_does_not_consume_the_closing_quote() -> None:
    # "\\" is a literal holding one backslash; the quote after it closes the literal, so the use after it is code.
    found = checker.used_categories('let s = "\\\\"; let d = UserDefaults.standard\n')
    assert [category for category, _ in found] == ["NSPrivacyAccessedAPICategoryUserDefaults"]


def test_an_escaped_backslash_before_an_interpolation_leaves_the_interpolation_as_code() -> None:
    found = checker.used_categories('let s = "\\\\\\(UserDefaults.standard)"\n')
    assert [category for category, _ in found] == ["NSPrivacyAccessedAPICategoryUserDefaults"]


def test_an_odd_run_of_backslashes_still_escapes_the_quote() -> None:
    # "\\\"" is a backslash and a quote inside the literal, which goes on to the closing quote.
    assert checker.used_categories('let s = "\\\\\\" UserDefaults"\n') == []


def test_an_escaped_backslash_at_the_end_of_a_literal_does_not_hide_the_rest_of_the_line(tmp_path: Path) -> None:
    line = 'func probe() { let sep = "\\\\"; let d = UserDefaults.standard; _ = (sep, d) }\n'
    root = write_tree(
        tmp_path, {"HealthNutrition/Sources/App.swift": line}, manifest=manifest_xml(declared=[BOOT_TIME])
    )
    result = run(root)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "NSPrivacyAccessedAPICategoryUserDefaults" in result.stdout


EMBEDDED_PROJECT_YML = PROJECT_YML.replace(
    "    dependencies:\n      - package: NutritionCore\n        product: NutritionCore\n",
    "    dependencies:\n      - target: HealthNutritionWidgets\n      - target: HealthNutritionWatch\n"
    "      - package: NutritionCore\n        product: NutritionCore\n",
    1,
).replace("      - path: Resources\n", "      - path: Resources\n      - path: Shared\n", 1) + """
  HealthNutritionWidgets:
    type: app-extension
    platform: iOS
    sources:
      - path: Widgets
        excludes:
          - Info.plist
      - path: Shared

  HealthNutritionWatch:
    type: application
    platform: watchOS
    sources:
      - path: Watch
      - path: Shared
    dependencies:
      - target: HealthNutritionWatchWidgets

  HealthNutritionWatchWidgets:
    type: app-extension
    platform: watchOS
    sources:
      - path: WatchWidgets
      - path: Shared

  HealthNutritionTests:
    type: bundle.unit-test
    platform: iOS
    sources:
      - path: Tests
    dependencies:
      - target: HealthNutrition

schemes:
  HealthNutrition:
    build:
      targets:
        HealthNutrition: all
"""

CLEAN_SWIFT = "import Foundation\n"
USES_DEFAULTS = "import Foundation\nlet probe = UserDefaults(suiteName: \"group.x\")\n"


def write_embedded_tree(
    tmp_path: Path,
    swift: dict[str, str],
    *,
    declared: dict[str, list[tuple[str, list[object]]]] | None = None,
) -> Path:
    """An app with a widget, a Watch app and a Watch widget, each with its own manifest."""
    declared = declared or {}
    root = write_tree(
        tmp_path,
        {
            "HealthNutrition/Sources/App.swift": CLEAN_SWIFT,
            "HealthNutrition/Shared/Snapshot.swift": CLEAN_SWIFT,
            "HealthNutrition/Widgets/Today.swift": CLEAN_SWIFT,
            "HealthNutrition/Watch/Watch.swift": CLEAN_SWIFT,
            "HealthNutrition/WatchWidgets/Complication.swift": CLEAN_SWIFT,
            "HealthNutrition/Tests/AppTests.swift": CLEAN_SWIFT,
            **swift,
        },
        manifest=manifest_xml(declared=[BOOT_TIME, USER_DEFAULTS]),
        project_yml=EMBEDDED_PROJECT_YML,
    )
    for folder in ("Widgets", "Watch", "WatchWidgets"):
        manifest = manifest_xml(declared=declared.get(folder, []), collected=[])
        (root / "HealthNutrition" / folder / "PrivacyInfo.xcprivacy").write_text(manifest, encoding="utf-8")
    return root


def test_the_embedded_fixture_tree_passes_when_every_manifest_matches(tmp_path: Path) -> None:
    root = write_embedded_tree(tmp_path, {"HealthNutrition/Watch/Watch.swift": USES_DEFAULTS}, declared={"Watch": [USER_DEFAULTS]})
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr


def test_a_widget_source_using_user_defaults_needs_the_widget_manifest_to_declare_it(tmp_path: Path) -> None:
    # The app manifest declares UserDefaults, which used to satisfy the check for the widget as well.
    root = write_embedded_tree(tmp_path, {"HealthNutrition/Widgets/Today.swift": USES_DEFAULTS})
    result = run(root)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "NSPrivacyAccessedAPICategoryUserDefaults" in result.stdout
    assert "Widgets/Today.swift" in result.stdout
    assert "Widgets/PrivacyInfo.xcprivacy" in result.stdout


def test_a_shared_source_using_user_defaults_is_checked_against_each_bundle_that_compiles_it(tmp_path: Path) -> None:
    root = write_embedded_tree(
        tmp_path,
        {"HealthNutrition/Shared/Snapshot.swift": USES_DEFAULTS},
        declared={"Watch": [USER_DEFAULTS]},
    )
    result = run(root)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "Widgets/PrivacyInfo.xcprivacy" in result.stdout
    assert "WatchWidgets/PrivacyInfo.xcprivacy" in result.stdout
    assert "Watch/PrivacyInfo.xcprivacy" not in result.stdout.replace("WatchWidgets/PrivacyInfo", "")


@pytest.mark.parametrize(
    ("rel", "manifest_hint"),
    [
        ("HealthNutrition/Watch/Watch.swift", "Watch/PrivacyInfo.xcprivacy"),
        ("HealthNutrition/WatchWidgets/Complication.swift", "WatchWidgets/PrivacyInfo.xcprivacy"),
    ],
)
def test_watch_bundle_sources_are_scanned_against_their_own_manifest(
    tmp_path: Path, rel: str, manifest_hint: str
) -> None:
    root = write_embedded_tree(tmp_path, {rel: USES_DEFAULTS})
    result = run(root)
    assert result.returncode == 1, result.stdout + result.stderr
    assert manifest_hint in result.stdout


def test_a_widget_file_timestamp_use_is_not_hidden_by_other_manifests(tmp_path: Path) -> None:
    probe = 'import Foundation\nlet t = try? FileManager.default.attributesOfItem(atPath: "/")\n'
    root = write_embedded_tree(tmp_path, {"HealthNutrition/Widgets/Today.swift": probe})
    result = run(root)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "NSPrivacyAccessedAPICategoryFileTimestamp" in result.stdout


def test_an_embedded_bundle_without_a_manifest_is_an_error(tmp_path: Path) -> None:
    root = write_embedded_tree(tmp_path, {})
    (root / "HealthNutrition" / "Widgets" / "PrivacyInfo.xcprivacy").unlink()
    result = run(root)
    assert result.returncode == 2, result.stdout + result.stderr
    assert "HealthNutritionWidgets" in result.stdout


def test_an_embedded_manifest_with_tracking_on_fails(tmp_path: Path) -> None:
    root = write_embedded_tree(tmp_path, {})
    (root / "HealthNutrition" / "Widgets" / "PrivacyInfo.xcprivacy").write_text(
        manifest_xml(tracking=True, declared=[], collected=[]), encoding="utf-8"
    )
    result = run(root)
    assert result.returncode == 1, result.stdout + result.stderr
    assert "Widgets/PrivacyInfo.xcprivacy" in result.stdout


def test_test_targets_and_unembedded_targets_are_not_bundles(tmp_path: Path) -> None:
    root = write_embedded_tree(tmp_path, {"HealthNutrition/Tests/AppTests.swift": USES_DEFAULTS})
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr


def test_a_bundle_with_two_manifests_is_an_error(tmp_path: Path) -> None:
    root = write_embedded_tree(tmp_path, {})
    extra = root / "HealthNutrition" / "Widgets" / "Extra"
    extra.mkdir()
    (extra / "PrivacyInfo.xcprivacy").write_text(manifest_xml(declared=[], collected=[]), encoding="utf-8")
    result = run(root)
    assert result.returncode == 2, result.stdout + result.stderr
    assert "HealthNutritionWidgets" in result.stdout
    assert "more than one" in result.stdout


def test_a_watch_app_listed_before_the_ios_app_is_not_taken_for_the_app(tmp_path: Path) -> None:
    marker = "\n  HealthNutritionWidgets:"
    start = EMBEDDED_PROJECT_YML.index("  HealthNutrition:")
    split = EMBEDDED_PROJECT_YML.index(marker)
    watch_start = EMBEDDED_PROJECT_YML.index("\n  HealthNutritionWatch:")
    tests_start = EMBEDDED_PROJECT_YML.index("\n  HealthNutritionTests:")
    app_block = EMBEDDED_PROJECT_YML[start:split]
    widgets_block = EMBEDDED_PROJECT_YML[split:watch_start]
    watch_blocks = EMBEDDED_PROJECT_YML[watch_start:tests_start]
    # Watch app and its widgets first, the iOS app last.
    reordered = (
        EMBEDDED_PROJECT_YML[:start] + watch_blocks.lstrip("\n") + widgets_block + "\n" + app_block
        + EMBEDDED_PROJECT_YML[tests_start:]
    )
    assert reordered.index("HealthNutritionWatch:") < reordered.index("  HealthNutrition:")
    root = write_embedded_tree(tmp_path, {})
    (root / "HealthNutrition" / "project.yml").write_text(reordered, encoding="utf-8")
    # The app declares UserDefaults and the Watch app (listed first) declares nothing; none of them uses it.
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "across 4 bundle(s)" in result.stdout


def test_two_ios_application_targets_are_ambiguous(tmp_path: Path) -> None:
    root = write_embedded_tree(tmp_path, {})
    yml = (root / "HealthNutrition" / "project.yml").read_text(encoding="utf-8")
    yml = yml.replace("    type: application\n    platform: watchOS", "    type: application\n    platform: iOS")
    (root / "HealthNutrition" / "project.yml").write_text(yml, encoding="utf-8")
    result = run(root)
    assert result.returncode == 2, result.stdout + result.stderr


def test_the_success_line_counts_each_category_once(tmp_path: Path) -> None:
    root = write_embedded_tree(
        tmp_path,
        {"HealthNutrition/Shared/Snapshot.swift": USES_DEFAULTS},
        declared={"Widgets": [USER_DEFAULTS], "Watch": [USER_DEFAULTS], "WatchWidgets": [USER_DEFAULTS]},
    )
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "1 required-reason category/categories used and declared across 4 bundle(s)" in result.stdout


def test_a_symlinked_privacy_manifest_leaving_the_checkout_is_refused(tmp_path: Path) -> None:
    outside = tmp_path / "outside.xcprivacy"
    outside.write_text(manifest_xml(declared=[], collected=[]), encoding="utf-8")
    root = write_embedded_tree(tmp_path, {})
    link = root / "HealthNutrition" / "Widgets" / "PrivacyInfo.xcprivacy"
    link.unlink()
    link.symlink_to(outside)
    result = run(root)
    assert result.returncode == 2, result.stdout + result.stderr
    assert "regular file" in result.stdout
