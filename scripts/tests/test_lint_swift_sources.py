"""Tests for scripts/lint_swift_sources.py.

Each test builds a tiny synthetic Swift tree in tmp_path, runs the lint over
it as a subprocess and checks the reported findings.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "lint_swift_sources.py"

UI = "Sources/NutritionUI"
DOMAIN = "Sources/NutritionDomain"
JOURNAL = "Sources/NutritionJournal"
PROVIDERS = "Sources/NutritionProviders"


def write_tree(tmp_path: Path, files: dict[str, str]) -> Path:
    root = tmp_path / "ios" / "NutritionCore"
    for rel, body in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
    return root


def run(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(root)],
        capture_output=True,
        text=True,
    )


def findings(result: subprocess.CompletedProcess[str]) -> list[tuple[str, int, str]]:
    """Parse `path:line: rule: message` output into (name, line, rule) tuples."""
    parsed = []
    for line in result.stdout.splitlines():
        path, lineno, rule, _ = line.split(":", 3)
        parsed.append((Path(path).name, int(lineno), rule.strip()))
    return parsed


def test_colour_literal_red_in_ui_reports_file_and_line(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{UI}/BadColor.swift": "import SwiftUI\nstruct BadColor {\n    let tint = Color(red: 1, green: 0, blue: 0)\n}\n",
    })
    result = run(root)
    assert result.returncode == 1
    assert findings(result) == [("BadColor.swift", 3, "colour-literal")]


def test_colour_literal_hex_in_ui_reports_file_and_line(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{UI}/BadHex.swift": 'import SwiftUI\nlet tint = Color(hex: "#FF0000")\nlet other = "#00FF00"\n',
    })
    result = run(root)
    assert result.returncode == 1
    # The bare hex string on line 3 is string content, not a colour literal.
    assert findings(result) == [("BadHex.swift", 2, "colour-literal")]


def test_fixed_font_in_ui_reports_file_and_line(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{UI}/BadFont.swift": "import SwiftUI\nstruct BadFont {\n    let font = Font.system(size: 14)\n}\n",
        f"{UI}/BadFontCall.swift": "import SwiftUI\nText(\"x\").font(.system(size: 14))\n",
    })
    result = run(root)
    assert result.returncode == 1
    assert findings(result) == [
        ("BadFont.swift", 3, "fixed-font"),
        ("BadFontCall.swift", 2, "fixed-font"),
    ]


def test_forbidden_import_and_urlsession_report_file_and_line(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{UI}/BadHK.swift": "import SwiftUI\nimport HealthKit\n",
        f"{JOURNAL}/BadNet.swift": "import Foundation\nlet session = URLSession.shared\n",
        f"{JOURNAL}/BadNetImport.swift": "import Network\n",
    })
    result = run(root)
    assert result.returncode == 1
    # Paths are walked in sorted order, so NutritionJournal comes before NutritionUI.
    assert findings(result) == [
        ("BadNet.swift", 2, "forbidden-import"),
        ("BadNetImport.swift", 1, "forbidden-import"),
        ("BadHK.swift", 2, "forbidden-import"),
    ]


def test_binary_float_in_domain_reports_file_and_line(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{DOMAIN}/BadDouble.swift": "struct Amount {\n    let value: Double\n    let ratio: Float\n}\n",
        f"{JOURNAL}/BadDouble.swift": "struct Entry {\n    let grams: Double\n}\n",
    })
    result = run(root)
    assert result.returncode == 1
    assert findings(result) == [
        ("BadDouble.swift", 2, "binary-float"),
        ("BadDouble.swift", 3, "binary-float"),
        ("BadDouble.swift", 2, "binary-float"),
    ]


def test_comments_and_string_literals_do_not_trigger(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{UI}/Fine.swift": (
            "import SwiftUI\n"
            "// Color(red: 1, green: 0, blue: 0) in a line comment\n"
            "/* Font.system(size: 14) in a block comment */\n"
            'let sample = "#FF0000 stays text"\n'
            'let label = """\nColor(hex: "#00FF00")\nDouble\n"""\n'
            'Text("x").font(.body)\n'
        ),
        f"{DOMAIN}/Fine.swift": '// Double is forbidden in prose only\nlet value = 3\n',
    })
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout == ""


def test_token_colors_is_exempt_from_colour_literal(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{UI}/TokenColors.swift": (
            "import SwiftUI\n"
            "enum TokenColors {\n"
            '    static let accent = Color(hex: "#FF0000")\n'
            "    static let warm = UIColor(red: 1, green: 0, blue: 0)\n"
            "}\n"
        ),
    })
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr


def test_other_files_in_ui_are_not_exempt(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{UI}/Palette.swift": 'let tint = Color(hex: "#FF0000")\n',
    })
    result = run(root)
    assert result.returncode == 1
    assert findings(result) == [("Palette.swift", 1, "colour-literal")]


def test_lint_allow_comment_skips_the_named_rule(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{UI}/Allowed.swift": (
            "import SwiftUI\n"
            "let tint = Color(red: 1, green: 0, blue: 0) // lint-allow: colour-literal\n"
        ),
        f"{UI}/NotAllowed.swift": (
            "import SwiftUI\n"
            "let tint = Color(red: 1, green: 0, blue: 0) // lint-allow: fixed-font\n"
        ),
    })
    result = run(root)
    assert result.returncode == 1
    assert findings(result) == [("NotAllowed.swift", 2, "colour-literal")]


def test_lint_allow_comment_is_line_scoped(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{UI}/Allowed.swift": (
            "import SwiftUI\n"
            "let tint = Color(red: 1, green: 0, blue: 0) // lint-allow: colour-literal\n"
            "let other = Color(red: 0, green: 1, blue: 0)\n"
        ),
    })
    result = run(root)
    assert result.returncode == 1
    assert findings(result) == [("Allowed.swift", 3, "colour-literal")]


def test_clean_tree_exits_zero(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{UI}/TodayView.swift": (
            "import SwiftUI\n"
            "struct TodayView: View {\n"
            '    var body: some View { Text("hello").font(.body).foregroundStyle(TokenColors.accent) }\n'
            "}\n"
        ),
        f"{DOMAIN}/Quantity.swift": "import Foundation\nstruct Quantity {\n    let amount: Decimal\n}\n",
        f"{JOURNAL}/JournalTypes.swift": "import Foundation\nstruct Entry {\n    let grams: Decimal\n}\n",
        "Sources/NutritionCore/NutritionTokens.swift": "let accentHex = \"#FF0000\"\n",
    })
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout == ""


def test_rules_do_not_fire_outside_their_scopes(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{PROVIDERS}/Transport.swift": (
            "import Foundation\nimport Network\n"
            "let session = URLSession(configuration: .default)\n"
            "let ratio = Double(1) / 2\n"
            'let tint = Color(hex: "#FF0000")\n'
        ),
    })
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr


def test_missing_root_is_reported_as_an_error(tmp_path: Path) -> None:
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(tmp_path / "nope")],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 2


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(pytest.main([__file__]))