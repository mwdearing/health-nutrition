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

Every scanned ``*.swift`` file is checked for the required-reason APIs Apple
lists. A category a source uses must be declared in the manifest with a reason
Apple publishes for that category, and ``NSPrivacyTracking`` must be false.

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
    ``stat``/``fstat``/``lstat``. A domain property that happens to be called
    ``creationDate`` is not an access to Apple's API, so it does not match.
NSPrivacyAccessedAPICategoryDiskSpace (E174.1)
    ``statfs``, ``statvfs``, ``fstatfs``, ``fstatvfs``, the ``getattrlist``
    family, ``volumeAvailableCapacity`` and friends, ``volumeTotalCapacityKey``
    and ``systemSize``/``systemFreeSize``.
NSPrivacyAccessedAPICategoryActiveKeyboards (54BD.1)
    ``activeInputModes``.

``//`` comments, ``/* */`` comments and the contents of string literals are
masked out before matching, so a mention in prose or in a message text does not
count as a use. An interpolated expression is code, so ``"\\(UserDefaults.standard)"``
is matched while the surrounding literal text is not.
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
MANIFEST_RELATIVE = Path("Resources/PrivacyInfo.xcprivacy")
PACKAGE_NAME = "NutritionCore"

# category -> (the reason this project needs, the API spellings, every reason
# Apple publishes for that category)
CATEGORIES: dict[str, tuple[str, tuple[str, ...], frozenset[str]]] = {
    "NSPrivacyAccessedAPICategoryUserDefaults": (
        "CA92.1",
        (r"\bUserDefaults\b", r"@AppStorage"),
        frozenset({"CA92.1", "1C8F.1", "C56D.1", "AC9B.1"}),
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
            r"\b(?:stat|fstat|lstat)\s*\(",
        ),
        frozenset({"C617.1", "0A2A.1", "E9D9.1", "3D62.1"}),
    ),
    "NSPrivacyAccessedAPICategoryDiskSpace": (
        "E174.1",
        (
            r"\b(?:statfs|fstatfs|statvfs|fstatvfs|getattrlist|getattrlistbulk|getattrlistat|fgetattrlist)\b",
            r"\bvolumeAvailableCapacity\w*\b",
            r"\bvolumeTotalCapacityKey\b",
            r"\b(?:systemSize|systemFreeSize)\b",
        ),
        frozenset({"E174.1", "85F4.1", "7D9E.1"}),
    ),
    "NSPrivacyAccessedAPICategoryActiveKeyboards": (
        "54BD.1",
        (r"\bactiveInputModes\b",),
        frozenset({"54BD.1", "3EC4.1"}),
    ),
}

BLANK = " "


class UsageError(Exception):
    """Raised when the build description or the manifest cannot be read."""


def blank(text: str) -> str:
    """Replace text with spaces, keeping newlines so line numbers survive."""
    return "".join("\n" if ch == "\n" else BLANK for ch in text)


def matching_paren(source: str, start: int) -> int:
    """Index just past the ``)`` closing the ``(`` at ``start - 1``."""
    depth = 0
    i = start
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
            run = 0
            while i + run < n and source[i + run] == "\\":
                run += 1
            marker = "\\" + "#" * hashes + "("
            if run == 1 and source.startswith(marker, i):
                out.append(blank(source[literal_start:i]))
                end = matching_paren(source, i + len(marker))
                out.append("(")
                out.append(mask(source[i + len(marker) : end - 1]))
                out.append(")")
                i = end
                literal_start = i
                continue
            i += run
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
            hashes = len(re.match(r"#+", source[i:]).group(0))  # type: ignore[union-attr]
            if source[i + hashes : i + hashes + 1] == '"':
                end, body = scan_string(source, i + hashes, hashes)
                out.append(blank(source[i:i + hashes]))
                out.append(body)
                i = end
                continue
            out.append(ch)
            i += 1
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


def app_build_description(project: Path) -> tuple[list[Path], list[str]]:
    """Return (app source directories, linked NutritionCore products)."""
    lines = project.read_text(encoding="utf-8").splitlines()
    start = None
    for index, line in enumerate(lines):
        if re.match(r"^\s{2}\w+:\s*$", line) and index + 1 < len(lines) and "application" in "\n".join(lines[index + 1 : index + 8]):
            start = index
            break
    if start is None:
        raise UsageError(f"{project}: no application target found")
    indent = len(lines[start]) - len(lines[start].lstrip())
    body: list[tuple[int, str]] = []
    for line in lines[start + 1 :]:
        if line.strip() and (len(line) - len(line.lstrip())) <= indent:
            break
        body.append((len(line) - len(line.lstrip()), line))
    sources: list[str] = []
    products: list[str] = []
    in_sources = False
    sources_indent = 0
    for line_indent, line in body:
        stripped = line.strip()
        if re.match(r"^sources\s*:", stripped):
            in_sources = True
            sources_indent = line_indent
            continue
        if in_sources:
            if line_indent <= sources_indent and stripped and not stripped.startswith("-"):
                in_sources = False
            else:
                path = re.match(r"^-\s*path\s*:\s*(\S+)", stripped)
                if path:
                    sources.append(path.group(1).strip("\"'"))
                continue
        product = re.match(r"^product\s*:\s*(\S+)", stripped)
        if product:
            products.append(product.group(1).strip("\"'"))
    if not products:
        raise UsageError(f"{project}: the application target links no {PACKAGE_NAME} product")
    return sources, products


def shipped_directories(root: Path) -> list[Path]:
    """Directories whose Swift sources end up in the shipped app."""
    project = root / APP_DIR_RELATIVE / "project.yml"
    package = root / PACKAGE_DIR_RELATIVE / "Package.swift"
    for path in (project, package):
        if not path.is_file():
            raise UsageError(f"{path}: no such file, cannot tell which code the app ships")

    source_paths, products = app_build_description(project)
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
    if not wanted:
        raise UsageError(f"{package}: none of the linked products resolve to a target")

    app_dir = root / APP_DIR_RELATIVE
    directories = [app_dir / source for source in source_paths if (app_dir / source).is_dir()]
    for name in sorted(wanted):
        target_path = root / PACKAGE_DIR_RELATIVE / str(info[name]["path"])
        if target_path.is_dir():
            directories.append(target_path)
    return [d for d in directories if "Tests" not in d.parts]


def declared_reasons(manifest: dict) -> dict[str, list[str]]:
    declared: dict[str, list[str]] = {}
    for entry in manifest.get("NSPrivacyAccessedAPITypes", []):
        category = entry.get("NSPrivacyAccessedAPIType")
        if not isinstance(category, str):
            continue
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons", [])
        declared.setdefault(category, []).extend(r for r in reasons if isinstance(r, str))
    return declared


def load_manifest(path: Path) -> dict:
    try:
        return plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as exc:
        raise UsageError(f"{path}: cannot read the privacy manifest ({exc})") from exc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="tree holding the app and its package")
    parser.add_argument("--manifest", type=Path, default=None, help="path to PrivacyInfo.xcprivacy")
    args = parser.parse_args(argv)

    root: Path = args.root
    manifest_path: Path = args.manifest if args.manifest is not None else root / APP_DIR_RELATIVE / MANIFEST_RELATIVE
    if not root.is_dir():
        print(f"{root}: no such directory")
        return 2

    try:
        directories = shipped_directories(root)
        manifest = load_manifest(manifest_path)
    except UsageError as exc:
        print(str(exc))
        return 2

    findings: list[str] = []
    if manifest.get("NSPrivacyTracking") is not False:
        findings.append(f"{manifest_path}: NSPrivacyTracking must be false in this manifest")

    declared = declared_reasons(manifest)
    for category, reasons in sorted(declared.items()):
        published = CATEGORIES.get(category, (None, (), frozenset()))[2]
        allowed = ", ".join(sorted(published)) or "none this project knows"
        for reason in reasons:
            if reason not in published:
                findings.append(
                    f"{manifest_path}: {category} declares {reason}, which Apple does not publish "
                    f"for that category; the published reasons are {allowed}"
                )

    used: dict[str, list[str]] = {}
    for directory in directories:
        for path in sorted(directory.rglob("*.swift")):
            try:
                source = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as exc:
                print(f"{path}: cannot read ({exc})")
                return 2
            for category, line in used_categories(source):
                try:
                    shown = path.relative_to(root)
                except ValueError:
                    shown = path
                used.setdefault(category, []).append(f"{shown}:{line}")

    for category, sites in sorted(used.items()):
        reason, _, published = CATEGORIES.get(category, ("<unknown>", (), frozenset()))
        if not any(r in published for r in declared.get(category, [])):
            allowed = ", ".join(sorted(published)) or "none this project knows"
            findings.append(
                f"{sites[0]}: {category} is used here but the manifest does not declare a reason "
                f"Apple publishes for it; this app declares {reason}, and the published reasons are {allowed}"
            )

    if findings:
        for finding in findings:
            print(finding)
        return 1
    print(f"privacy manifest ok: {len(used)} required-reason category/categories declared, tracking off")
    return 0


if __name__ == "__main__":
    sys.exit(main())