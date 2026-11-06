#!/usr/bin/env python3
"""Check the app privacy manifest against the Swift code the app ships.

Usage:
    python3 scripts/check_privacy_manifest.py [--root ROOT] [--manifest PATH]

``ROOT`` defaults to ``ios``. The scanner derives the code that ships from the
app's own build description rather than from the tree layout: it reads
``<ROOT>/HealthNutrition/project.yml`` for the app target's source paths and the
NutritionCore products it links, then ``<ROOT>/NutritionCore/Package.swift`` for
those products' target directories and their target dependencies. Test targets
and standalone targets the app does not link (a spike, for instance) are never
scanned, so a restricted API used only there cannot demand a declaration.

The app and every application or app-extension target it embeds (the widget
extension, the Watch app and its widget extension) are separate bundles. Each
bundle's sources are checked against the ``PrivacyInfo.xcprivacy`` among that
bundle's own source directories; ``--manifest`` overrides the app's manifest only.

Every scanned ``*.swift`` file is checked for the required-reason APIs Apple
lists. A category a source uses must be declared in the manifest with a reason
Apple publishes for that category, ``NSPrivacyTracking`` must be false, and the
account's collected-data types (email address, user ID, name and shared label values) must be declared
as linked to the user, not used for tracking, for app functionality.

Findings are printed one per line as ``path:line: message`` and the script
exits 1 when there is at least one finding, 0 when the tree is clean and 2 on a
usage error (unreadable build description or manifest).

Checked categories
------------------
NSPrivacyAccessedAPICategoryUserDefaults (CA92.1)
    ``UserDefaults`` and ``@AppStorage``.
NSPrivacyAccessedAPICategorySystemBootTime (35F9.1)
    ``systemUptime`` and ``mach_absolute_time``.
NSPrivacyAccessedAPICategoryFileTimestamp (C617.1)
    File attribute and resource key access only: ``FileAttributeKey`` and
    ``URLResourceKey`` members, the timestamp resource keys, an attribute
    subscript such as ``attributes[.creationDate]``, ``attributesOfItem`` and
    the ``stat``/``fstat``/``lstat``/``fstatat`` and ``getattrlist`` families. A
    domain property that happens to be called ``creationDate`` is not an access
    to Apple's API, so it does not match.
NSPrivacyAccessedAPICategoryDiskSpace (E174.1)
    ``statfs``, ``statvfs``, ``fstatfs``, ``fstatvfs``, ``volumeAvailableCapacity``
    and friends, ``volumeTotalCapacityKey`` and ``systemSize``/``systemFreeSize``.
NSPrivacyAccessedAPICategoryActiveKeyboards (54BD.1)
    ``activeInputModes``.

``//`` comments, ``/* */`` comments and the contents of string literals are
masked out before matching, so a mention in prose or in a message text does not
count as a use. An interpolated expression is code, so ``"\\(UserDefaults.standard)"``
is matched, while the literal text before the opening parenthesis and after the
closing one is not.
"""
from __future__ import annotations

import argparse
import plistlib
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ROOT = REPO_ROOT / "ios"
APP_DIR_RELATIVE = Path("HealthNutrition")
PACKAGE_DIR_RELATIVE = Path("NutritionCore")
MANIFEST_NAME = "PrivacyInfo.xcprivacy"
MANIFEST_RELATIVE = Path("Resources") / MANIFEST_NAME
PACKAGE_NAME = "NutritionCore"

# category -> (the reason this project declares, the API spellings, every reason
# Apple publishes for that category)
CATEGORIES: dict[str, tuple[str, tuple[str, ...], frozenset[str]]] = {
    "NSPrivacyAccessedAPICategoryUserDefaults": (
        "CA92.1",
        (r"\bUserDefaults\b", r"@AppStorage"),
        frozenset({"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"}),
    ),
    "NSPrivacyAccessedAPICategorySystemBootTime": (
        "35F9.1",
        (r"\bsystemUptime\b", r"\bmach_absolute_time\b"),
        frozenset({"35F9.1", "8FFB.1", "3D61.1"}),
    ),
    "NSPrivacyAccessedAPICategoryFileTimestamp": (
        "C617.1",
        (
            r"\bFileAttributeKey\s*\.\s*(?:creationDate|modificationDate)\b",
            r"\bURLResourceKey\s*\.\s*(?:creationDateKey|contentModificationDateKey|contentAccessDateKey)\b",
            r"\.\s*(?:creationDate|modificationDate)\s*\]",
            r"\b(?:creationDateKey|contentModificationDateKey|contentAccessDateKey)\b",
            r"\battributesOfItem\b",
            r"\b(?:stat|fstat|lstat|fstatat|getattrlist|getattrlistbulk|getattrlistat|fgetattrlist)\s*\(",
        ),
        frozenset({"DDA9.1", "C617.1", "3B52.1", "0A2A.1"}),
    ),
    "NSPrivacyAccessedAPICategoryDiskSpace": (
        "E174.1",
        (
            r"\b(?:statfs|fstatfs|statvfs|fstatvfs)\s*\(",
            r"\bvolumeAvailableCapacity\w*\b",
            r"\bvolumeTotalCapacityKey\b",
            r"\b(?:systemSize|systemFreeSize)\b",
        ),
        frozenset({"85F4.1", "E174.1", "7D9E.1", "B728.1"}),
    ),
    "NSPrivacyAccessedAPICategoryActiveKeyboards": (
        "54BD.1",
        (r"\bactiveInputModes\b",),
        frozenset({"3EC4.1", "54BD.1"}),
    ),
}

BLANK = " "


class UsageError(Exception):
    """Raised when the build description or the manifest cannot be read."""


def blank(text: str) -> str:
    """Replace text with spaces, keeping newlines so line numbers survive."""
    return "".join("\n" if ch == "\n" else BLANK for ch in text)


def matching_paren(source: str, open_paren: int) -> int:
    """Index just past the ``)`` closing the ``(`` at ``open_paren``.

    Scanning starts inside the parenthesis, so the depth is already one: the
    closing parenthesis of the interpolation is where the scan stops, and any
    literal text after it stays literal text.
    """
    depth = 1
    i = open_paren + 1
    n = len(source)
    while i < n:
        ch = source[i]
        if ch == '"':
            i = scan_string(source, i, 0)[0]
            continue
        if source.startswith("//", i):
            i = source.find("\n", i)
            if i == -1:
                return n
            continue
        if source.startswith("/*", i):
            i = scan_block_comment(source, i)[0]
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def scan_block_comment(source: str, start: int) -> tuple[int, str]:
    """Skip a nested ``/* */`` comment from ``start``, returning its end and body."""
    depth = 1
    i = start + 2
    n = len(source)
    while i < n and depth:
        if source.startswith("/*", i):
            depth += 1
            i += 2
        elif source.startswith("*/", i):
            depth -= 1
            i += 2
        else:
            i += 1
    return i, source[start:i]


def scan_string(source: str, start: int, hashes: int) -> tuple[int, str]:
    """Scan a string literal from its opening quote, returning its end and body.

    Interpolated expressions are kept in the body (recursively masked, so a
    nested literal inside them is masked again); the literal text between them is
    masked. The body is only a by-product, for callers that need it.
    """
    n = len(source)
    closing = '"' + "#" * hashes
    multiline = source.startswith('"""', start)
    closing = '"""' + "#" * hashes if multiline else closing
    i = start + (3 if multiline else 1)
    literal_start = i
    out: list[str] = []
    while i < n:
        ch = source[i]
        if ch == "\\":
            # The escape introducer is a backslash followed by the literal's hashes (a plain backslash when there
            # are none). In a raw literal a backslash without them is ordinary text. Without hashes, backslashes
            # pair up: an even run escapes itself and leaves the next character alone, so only the last backslash
            # of an odd run escapes the character after it.
            introducer = i
            if hashes == 0:
                run = 1
                while i + run < n and source[i + run] == "\\":
                    run += 1
                if False and run % 2 == 0:
                    i += run
                    continue
                introducer = i + run - 1
            elif not source.startswith("\\" + "#" * hashes, i):
                i += 1
                continue
            marker = "\\" + "#" * hashes + "("
            if source.startswith(marker, introducer):
                out.append(blank(source[literal_start:introducer]))
                end = matching_paren(source, introducer + len(marker) - 1)
                out.append("(")
                out.append(mask(source[introducer + len(marker) : end - 1]))
                out.append(")")
                i = end
                literal_start = i
                continue
            # An escape such as \" or \n: the escaped character is consumed with the introducer, so an escaped
            # delimiter cannot end the literal.
            i = introducer + 1 + hashes + 1
            continue
        if source.startswith(closing, i):
            out.append(blank(source[literal_start:i]))
            out.append(blank(closing))
            return i + len(closing), "".join(out)
        if not multiline and ch == "\n":
            break
        i += 1
    out.append(blank(source[literal_start:i]))
    return min(i, n), "".join(out)


def mask(source: str) -> str:
    """Blank out comments and string text, keeping interpolation expressions."""
    out: list[str] = []
    i = 0
    n = len(source)
    while i < n:
        ch = source[i]
        if source.startswith("//", i):
            end = source.find("\n", i)
            end = n if end == -1 else end
            out.append(blank(source[i:end]))
            i = end
            continue
        if source.startswith("/*", i):
            end, _ = scan_block_comment(source, i)
            out.append(blank(source[i:end]))
            i = end
            continue
        if ch == "#":
            hash_end = i + 1
            while hash_end < n and source[hash_end] == "#":
                hash_end += 1
            hashes = hash_end - i
            if hash_end < n and source[hash_end] == '"':
                end, body = scan_string(source, i + hashes, hashes)
                out.append(blank(source[i:i + hashes]))
                out.append(body)
                i = end
                continue
            # Consume a nonliteral hash run in one pass instead of rescanning
            # every remaining suffix to rediscover its length.
            out.append(source[i:hash_end])
            i = hash_end
            continue
        if ch == '"':
            end, body = scan_string(source, i, 0)
            out.append(body)
            i = end
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def used_categories(source: str) -> list[tuple[str, int]]:
    """Return (category, line number) for the first use of each category."""
    masked = mask(source)
    found: list[tuple[str, int]] = []
    for category, (_, patterns, _) in CATEGORIES.items():
        for pattern in patterns:
            match = re.search(pattern, masked)
            if match:
                found.append((category, masked.count("\n", 0, match.start()) + 1))
                break
    return found


def split_calls(source: str, keyword: str) -> list[str]:
    """Return the argument text of every ``.keyword(...)`` call in source."""
    args: list[str] = []
    for match in re.finditer(rf"\.{keyword}\s*\(", source):
        start = match.end()
        depth = 1
        i = start
        n = len(source)
        while i < n and depth:
            ch = source[i]
            if ch == '"':
                i = scan_string(source, i, 0)[0]
                continue
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        args.append(source[start:i])
    return args


def quoted(text: str) -> list[str]:
    return re.findall(r'"([^"]*)"', text)


def array_argument(args: str, label: str) -> list[str]:
    match = re.search(rf"\b{label}\s*:\s*\[([^\]]*)\]", args)
    return quoted(match.group(1)) if match else []


def first_quoted(args: str) -> str:
    return (quoted(args)[:1] or [""])[0]


def package_targets(package: Path) -> tuple[dict[str, list[str]], dict[str, dict[str, object]]]:
    """Return (product -> targets, target -> info) from a Package.swift."""
    text = package.read_text(encoding="utf-8")
    products = {first_quoted(args): array_argument(args, "targets") for args in split_calls(text, "library")}
    info: dict[str, dict[str, object]] = {}
    for kind, args in [("target", a) for a in split_calls(text, "target")] + [
        ("testTarget", a) for a in split_calls(text, "testTarget")
    ]:
        name = first_quoted(args)
        if not name:
            continue
        path = re.search(r'\bpath\s*:\s*"([^"]+)"', args)
        info[name] = {
            "path": path.group(1) if path else f"Sources/{name}",
            "dependencies": array_argument(args, "dependencies"),
            "test": kind == "testTarget",
        }
    return products, info


class Target:
    """One target of the build description: its type, source paths, target dependencies and linked products."""

    def __init__(self, name: str) -> None:
        self.name = name
        self.type = ""
        self.platform = ""
        self.sources: list[str] = []
        self.target_dependencies: list[str] = []
        self.products: list[str] = []


def build_targets(project: Path) -> dict[str, Target]:
    """Parse the ``targets:`` section of a project.yml into targets, in file order."""
    lines = project.read_text(encoding="utf-8").splitlines()
    targets: dict[str, Target] = {}
    in_targets = False
    current: Target | None = None
    section = ""
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0:
            in_targets = stripped.rstrip() == "targets:"
            current = None
            continue
        if not in_targets:
            continue
        if indent == 2:
            name = re.match(r"^(\w+)\s*:\s*$", stripped)
            current = Target(name.group(1)) if name else None
            if current is not None:
                targets[current.name] = current
            section = ""
            continue
        if current is None:
            continue
        if indent == 4:
            key = re.match(r"^(\w+)\s*:\s*(.*)$", stripped)
            section = key.group(1) if key else ""
            if key and section == "type":
                current.type = key.group(2).strip().strip("\"'")
            elif key and section == "platform":
                current.platform = key.group(2).strip().strip("\"'")
            continue
        if section == "sources":
            path = re.match(r"^-\s*path\s*:\s*(\S+)", stripped)
            if path:
                current.sources.append(path.group(1).strip("\"'"))
        elif section == "dependencies":
            # A dependency item starts with ``- target:`` or ``- package:``; ``product:`` belongs to the package item.
            dependency = re.match(r"^-\s*target\s*:\s*(\S+)", stripped)
            if dependency:
                current.target_dependencies.append(dependency.group(1).strip("\"'"))
                continue
            product = re.match(r"^(?:-\s*)?product\s*:\s*(\S+)", stripped)
            if product:
                current.products.append(product.group(1).strip("\"'"))
    return targets


def embedded_bundles(targets: dict[str, Target], project: Path) -> list[Target]:
    """The app (the one iOS application target) followed by every application and app-extension target it embeds.

    Embedding is followed through ``- target:`` dependencies, so the Watch app brings in its own widget extension.
    Test targets and anything the app does not depend on are not bundles of the archive.
    """
    applications = [target for target in targets.values() if target.type == "application"]
    if not applications:
        raise UsageError(f"{project}: no application target found")
    # A Watch app is an application target too and may be listed first, so the app is the iOS one. A single
    # application target is the app whatever its platform.
    if len(applications) > 1:
        applications = [target for target in applications if target.platform.lower() == "ios"]
    if len(applications) != 1:
        raise UsageError(f"{project}: cannot tell which application target is the iOS app (needs exactly one)")
    app = applications[0]
    bundles = [app]
    seen = {app.name}
    pending = [app]
    while pending:
        for name in pending.pop(0).target_dependencies:
            dependency = targets.get(name)
            if dependency is None or name in seen or dependency.type not in ("application", "app-extension"):
                continue
            seen.add(name)
            bundles.append(dependency)
            pending.append(dependency)
    return bundles


def contained(root: Path, base: Path, relative: str) -> Path:
    """`base / relative`, refused unless it is a relative path that stays inside the checkout at `root`.

    The build descriptions are files a pull request can edit, so a source path of `/` or `../..` must not make
    the checker read and walk the machine it runs on.
    """
    if Path(relative).is_absolute() or relative.startswith(("~", "/")):
        raise UsageError(f"{relative}: a source path must be relative to the checkout")
    resolved = (base / relative).resolve()
    if not resolved.is_relative_to(root.resolve()):
        raise UsageError(f"{relative}: a source path leaves the checkout (outside {root})")
    return resolved


class Bundle:
    """A bundle of the archive: its Swift source directories and the privacy manifest it ships."""

    def __init__(self, name: str, directories: list[Path], manifest: Path | None) -> None:
        self.name = name
        self.directories = directories
        self.manifest = manifest


def package_directories(root: Path, products: list[str], package: Path, *, require: bool) -> list[Path]:
    """Directories of the NutritionCore targets the given products link, transitively."""
    product_targets, info = package_targets(package)
    wanted: set[str] = set()
    pending = [target for product in products for target in product_targets.get(product, [])]
    while pending:
        name = pending.pop()
        if name in wanted:
            continue
        target = info.get(name)
        if target is None or target["test"]:
            continue
        wanted.add(name)
        pending.extend(target["dependencies"])  # type: ignore[arg-type]
    if require and not wanted:
        raise UsageError(f"{package}: none of the linked products resolve to a target")
    directories = []
    for name in sorted(wanted):
        target_path = contained(root, root / PACKAGE_DIR_RELATIVE, str(info[name]["path"]))
        if target_path.is_dir():
            directories.append(target_path)
    return directories


def shipped_bundles(root: Path) -> list[Bundle]:
    """One entry per bundle the archive embeds, each with the code compiled into it and its own manifest.

    The first entry is the app. A bundle's manifest is the ``PrivacyInfo.xcprivacy`` among its own source
    directories, so a widget's code is checked against the widget's manifest and never the app's.
    """
    project = root / APP_DIR_RELATIVE / "project.yml"
    package = root / PACKAGE_DIR_RELATIVE / "Package.swift"
    for path in (project, package):
        if not path.is_file():
            raise UsageError(f"{path}: no such file, cannot tell which code the app ships")

    targets = build_targets(project)
    bundles_found = embedded_bundles(targets, project)
    app_dir = root / APP_DIR_RELATIVE
    bundles: list[Bundle] = []
    for index, target in enumerate(bundles_found):
        if index == 0 and not target.products:
            raise UsageError(f"{project}: the application target links no {PACKAGE_NAME} product")
        directories: list[Path] = []
        for source in target.sources:
            candidate = contained(root, app_dir, source)
            if candidate.is_dir():
                directories.append(candidate)
        source_directories = [d for d in directories if "Tests" not in d.parts]
        if target.products:
            directories.extend(package_directories(root, target.products, package, require=index == 0))
        directories = [d for d in directories if "Tests" not in d.parts]
        manifests = sorted(
            set(
            candidate
            for directory in source_directories
            for candidate in directory.rglob(MANIFEST_NAME)
            if candidate.is_file() or candidate.is_symlink()
            )
        )
        for candidate in manifests:
            # Same containment as the Swift sources: a symlinked manifest, or one that resolves outside the
            # checkout, must not be read.
            if candidate.is_symlink() or not candidate.resolve().is_relative_to(root.resolve()):
                raise UsageError(f"{candidate}: not a regular file inside the checkout")
        if len(manifests) > 1:
            listed = ", ".join(str(m) for m in manifests)
            raise UsageError(f"{project}: {target.name} has more than one {MANIFEST_NAME} ({listed}); it needs exactly one")
        bundles.append(Bundle(target.name, directories, manifests[0] if manifests else None))
    return bundles


# The data types the account sends to the project's server. Each must be declared as linked to the user, not used
# for tracking and used for the app's own functionality. Apple's identifiers, not free text.
REQUIRED_COLLECTED_TYPES = (
    "NSPrivacyCollectedDataTypeEmailAddress",
    "NSPrivacyCollectedDataTypeUserID",
    "NSPrivacyCollectedDataTypeName",
    # The values of a scanned label shared with the community catalog.
    "NSPrivacyCollectedDataTypeOtherUserContent",
    # Barcodes and search words sent with the signed-in account to the project's server.
    "NSPrivacyCollectedDataTypeSearchHistory",
    # The hCaptcha human check on email sign-in; its token travels in the same request as the email.
    "NSPrivacyCollectedDataTypeProductInteraction",
)
APP_FUNCTIONALITY = "NSPrivacyCollectedDataTypePurposeAppFunctionality"


def collected_findings(manifest: dict, manifest_path: Path) -> list[str]:
    """Findings for the collected-data declarations the account needs."""
    entries = manifest.get("NSPrivacyCollectedDataTypes")
    if not isinstance(entries, list):
        return [f"{manifest_path}: NSPrivacyCollectedDataTypes must be an array"]
    by_type: dict[str, dict] = {}
    findings: list[str] = []
    for entry in entries:
        data_type = entry.get("NSPrivacyCollectedDataType") if isinstance(entry, dict) else None
        if not isinstance(data_type, str):
            findings.append(f"{manifest_path}: a collected-data entry has no NSPrivacyCollectedDataType")
            continue
        by_type.setdefault(data_type, entry)
    for required in REQUIRED_COLLECTED_TYPES:
        entry = by_type.get(required)
        if entry is None:
            findings.append(
                f"{manifest_path}: {required} is not declared, but the account sends it to the project's server"
            )
            continue
        if entry.get("NSPrivacyCollectedDataTypeLinked") is not True:
            findings.append(f"{manifest_path}: {required} must be declared as linked to the user (true)")
        if entry.get("NSPrivacyCollectedDataTypeTracking") is not False:
            findings.append(f"{manifest_path}: {required} must not be used for tracking (false)")
        purposes = entry.get("NSPrivacyCollectedDataTypePurposes")
        if not isinstance(purposes, list) or APP_FUNCTIONALITY not in purposes:
            findings.append(f"{manifest_path}: {required} must list {APP_FUNCTIONALITY} as a purpose")
    return findings


def declared_entries(manifest: dict) -> list[tuple[object, object]]:
    """Return (category, reasons) pairs as written, without filtering."""
    entries = manifest.get("NSPrivacyAccessedAPITypes", [])
    if not isinstance(entries, list):
        return []
    return [(entry.get("NSPrivacyAccessedAPIType"), entry.get("NSPrivacyAccessedAPITypeReasons"))
            if isinstance(entry, dict) else (entry, None) for entry in entries]


def declared_reasons(manifest: dict) -> dict[str, list[str]]:
    """category -> the string reasons declared for it."""
    declared: dict[str, list[str]] = {}
    for category, reasons in declared_entries(manifest):
        if not isinstance(category, str) or not isinstance(reasons, list):
            continue
        declared.setdefault(category, []).extend(r for r in reasons if isinstance(r, str))
    return declared


def load_manifest(path: Path) -> dict:
    try:
        return plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as exc:
        raise UsageError(f"{path}: cannot read the privacy manifest ({exc})") from exc


def manifest_findings(manifest: dict, manifest_path: Path) -> list[str]:
    """Findings for the tracking flag and the accessed-API declarations of one manifest."""
    findings: list[str] = []
    if manifest.get("NSPrivacyTracking") is not False:
        findings.append(f"{manifest_path}: NSPrivacyTracking must be false in this manifest")
    for category, reasons in declared_entries(manifest):
        if not isinstance(category, str):
            findings.append(f"{manifest_path}: an accessed-API entry has no usable NSPrivacyAccessedAPIType")
            continue
        published = CATEGORIES.get(category)
        if published is None:
            findings.append(
                f"{manifest_path}: {category} is not an API category Apple publishes; a declaration "
                "needs a known category and at least one reason"
            )
            continue
        codes = published[2]
        allowed = ", ".join(sorted(codes))
        if not isinstance(reasons, list) or not reasons:
            findings.append(
                f"{manifest_path}: {category} declares no reason; it needs at least one of {allowed}"
            )
            continue
        strings = [r for r in reasons if isinstance(r, str)]
        if len(strings) != len(reasons):
            findings.append(
                f"{manifest_path}: every reason of {category} has to be a string, such as {allowed}"
            )
            continue
        for reason in strings:
            if reason not in codes:
                findings.append(
                    f"{manifest_path}: {category} declares {reason}, which Apple does not publish "
                    f"for that category; the published reasons are {allowed}"
                )
    return findings


def scan_directories(root: Path, directories: list[Path]) -> dict[str, list[str]]:
    """category -> the ``path:line`` sites that use it, over every Swift file under the directories.

    Raises UsageError for a file that is not a regular file inside the checkout or cannot be read.
    """
    used: dict[str, list[str]] = {}
    seen: set[Path] = set()
    for directory in directories:
        for path in sorted(directory.rglob("*.swift")):
            if path in seen:
                continue
            seen.add(path)
            # A pull request can add a symlink named like a Swift file. Only a regular file that stays inside the
            # checkout is read, so the check cannot be pointed at the machine it runs on.
            if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
                raise UsageError(f"{path}: not a regular file inside the checkout")
            try:
                source = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as exc:
                raise UsageError(f"{path}: cannot read ({exc})") from exc
            for category, line in used_categories(source):
                try:
                    shown = path.relative_to(root)
                except ValueError:
                    shown = path
                used.setdefault(category, []).append(f"{shown}:{line}")
    return used


def undeclared_findings(used: dict[str, list[str]], manifest: dict, manifest_path: Path) -> list[str]:
    declared = declared_reasons(manifest)
    findings: list[str] = []
    for category, sites in sorted(used.items()):
        reason, _, published = CATEGORIES.get(category, ("<unknown>", (), frozenset()))
        if not any(r in published for r in declared.get(category, [])):
            allowed = ", ".join(sorted(published)) or "none this project knows"
            findings.append(
                f"{sites[0]}: {category} is used here but {manifest_path} does not declare a reason "
                f"Apple publishes for it; this app declares {reason}, and the published reasons are {allowed}"
            )
    return findings


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="tree holding the app and its package")
    parser.add_argument(
        "--manifest", type=Path, default=None, help="path to the app's PrivacyInfo.xcprivacy (embedded bundles use their own)"
    )
    args = parser.parse_args(argv)

    root: Path = args.root
    if not root.is_dir():
        print(f"{root}: no such directory")
        return 2

    findings: list[str] = []
    used_categories_seen: set[str] = set()
    try:
        bundles = shipped_bundles(root)
        for index, bundle in enumerate(bundles):
            is_app = index == 0
            if is_app:
                manifest_path = args.manifest if args.manifest is not None else (
                    bundle.manifest or root / APP_DIR_RELATIVE / MANIFEST_RELATIVE
                )
            elif bundle.manifest is not None:
                manifest_path = bundle.manifest
            else:
                raise UsageError(
                    f"{root / APP_DIR_RELATIVE}: {bundle.name} is embedded in the app but none of its source "
                    f"directories holds a {MANIFEST_NAME}"
                )
            manifest = load_manifest(manifest_path)
            findings.extend(manifest_findings(manifest, manifest_path))
            if is_app:
                findings.extend(collected_findings(manifest, manifest_path))
            used = scan_directories(root, bundle.directories)
            findings.extend(undeclared_findings(used, manifest, manifest_path))
            used_categories_seen.update(used)
    except UsageError as exc:
        print(str(exc))
        return 2

    if findings:
        for finding in findings:
            print(finding)
        return 1
    print(
        f"privacy manifest ok: {len(used_categories_seen)} required-reason category/categories used and declared "
        f"across {len(bundles)} bundle(s), tracking off"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
