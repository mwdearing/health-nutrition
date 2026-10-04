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


def test_colour_call_split_across_lines_is_reported(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{UI}/Wrapped.swift": (
            "import SwiftUI\n"
            "let tint = Color(\n"
            "    red: 1,\n"
            "    green: 0,\n"
            "    blue: 0\n"
            ")\n"
        ),
        f"{UI}/WrappedFont.swift": (
            "import SwiftUI\n"
            "let font = Font.system(\n"
            "    size: 14\n"
            ")\n"
            'Text("x").font(\n    .system(\n        size: 14\n    )\n)\n'
        ),
    })
    result = run(root)
    assert result.returncode == 1
    assert findings(result) == [
        ("Wrapped.swift", 2, "colour-literal"),
        ("WrappedFont.swift", 2, "fixed-font"),
        # The chained call opens on line 5 and the prohibited label sits on line 7;
        # the finding is reported where the construct starts.
        ("WrappedFont.swift", 5, "fixed-font"),
    ]


def test_declaration_specific_import_is_reported(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{UI}/BadHKClass.swift": "import SwiftUI\nimport class HealthKit.HKHealthStore\n",
        f"{UI}/BadAttr.swift": "import SwiftUI\n@_implementationOnly import Network\n",
        f"{JOURNAL}/BadNetStruct.swift": "import Foundation\nimport struct Network.NWEndpoint\n",
        f"{JOURNAL}/BadNetTypealias.swift": "import Foundation\nimport typealias Network.NWProtocolTCP\n",
    })
    result = run(root)
    assert result.returncode == 1
    assert findings(result) == [
        ("BadNetStruct.swift", 2, "forbidden-import"),
        ("BadNetTypealias.swift", 2, "forbidden-import"),
        ("BadAttr.swift", 2, "forbidden-import"),
        ("BadHKClass.swift", 2, "forbidden-import"),
    ]


def test_string_interpolation_content_is_still_code(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{DOMAIN}/Interpolated.swift": (
            "import Foundation\n"
            'let text = "\\(Double(value))"\n'
            'let other = "value is \\(count) and Double is prose"\n'
            'let nested = "\\("\\(Double(1))")"\n'
        ),
        f"{UI}/Interpolated.swift": (
            "import SwiftUI\n"
            'let label = "\\(Color(red: 1, green: 0, blue: 0))"\n'
        ),
    })
    result = run(root)
    assert result.returncode == 1
    assert findings(result) == [
        ("Interpolated.swift", 2, "binary-float"),
        ("Interpolated.swift", 4, "binary-float"),
        ("Interpolated.swift", 2, "colour-literal"),
    ]


def test_nested_block_comments_are_ignored(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{DOMAIN}/Nested.swift": (
            "import Foundation\n"
            "/* outer comment\n"
            "   /* inner comment mentioning Double and URLSession */\n"
            "   still prose: Color(red: 1, green: 0, blue: 0)\n"
            "*/\n"
            "let value: Decimal\n"
        ),
        f"{UI}/Nested.swift": (
            "import SwiftUI\n"
            "/* outer\n"
            "   /* inner with Font.system(size: 9) */\n"
            "   #FF0000 and import HealthKit\n"
            "*/\n"
            'Text("x").font(.body)\n'
        ),
    })
    result = run(root)
    assert result.returncode == 0, result.stdout + result.stderr


def test_extended_string_literal_delimiters_are_honoured(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{DOMAIN}/Extended.swift": (
            "import Foundation\n"
            'let quoted = #"she said "Double" loudly"#\n'
            'let multi = ##"""\n'
            'Color(red: 1) and URLSession\n'
            'Double\n'
            '"""##\n'
            'let after = "still code"\n'
            'let value: Double\n'
        ),
        f"{UI}/Extended.swift": (
            "import SwiftUI\n"
            'let quoted = #"a "#FF0000" literal in raw text"#\n'
            'Text("x").font(.body)\n'
        ),
    })
    result = run(root)
    assert result.returncode == 1
    assert findings(result) == [
        ("Extended.swift", 8, "binary-float"),
    ]


def test_inferred_floating_point_literal_is_reported(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{DOMAIN}/Inferred.swift": (
            "import Foundation\n"
            "let grams = 0.1\n"
            "let scaled = grams * 2.5\n"
            "let exact = Decimal(string: \"0.25\")\n"
            "let hash: UInt64 = 0xcbf2_9ce4_8422_2325\n"
            "let count = 42\n"
        ),
        f"{JOURNAL}/Inferred.swift": "import Foundation\nlet share = 1e-3\n",
    })
    result = run(root)
    assert result.returncode == 1
    assert findings(result) == [
        ("Inferred.swift", 2, "binary-float"),
        ("Inferred.swift", 3, "binary-float"),
        ("Inferred.swift", 2, "binary-float"),
    ]


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


def test_access_level_import_is_reported(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{UI}/PrivateHK.swift": "private import HealthKit\n",
        f"{JOURNAL}/InternalNet.swift": "internal import Network\n",
        f"{UI}/Preconcurrency.swift": "@preconcurrency public import HealthKit\n",
    })
    result = run(root)
    assert result.returncode == 1
    assert findings(result) == [
        ("InternalNet.swift", 1, "forbidden-import"),
        ("Preconcurrency.swift", 1, "forbidden-import"),
        ("PrivateHK.swift", 1, "forbidden-import"),
    ]


def test_hexadecimal_float_literal_is_reported(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{DOMAIN}/Hex.swift": (
            "let scaled = 0x1.fp2\n"
            "let tiny = 0x1p-2\n"
            "let mask = 0xFF\n"
            "let other = 0x1F\n"
        ),
    })
    result = run(root)
    assert result.returncode == 1
    # A hex float is a Double; a hex integer is not a floating-point literal.
    assert findings(result) == [
        ("Hex.swift", 1, "binary-float"),
        ("Hex.swift", 2, "binary-float"),
    ]


def test_extended_string_interpolation_content_is_still_code(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{DOMAIN}/ExtendedInterpolation.swift": (
            'let value = #"result: \\#(Double(input))"#\n'
            'let prose = #"a plain \\(Double) stays text"#\n'
            'let nested = ##"result: \\##(Float(input))"##\n'
        ),
    })
    result = run(root)
    assert result.returncode == 1
    assert findings(result) == [
        ("ExtendedInterpolation.swift", 1, "binary-float"),
        ("ExtendedInterpolation.swift", 3, "binary-float"),
    ]


def test_regex_literal_contents_are_not_code(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{DOMAIN}/Regex.swift": (
            "let pattern = #/Double|Float/#\n"
            "let bare = /Double/\n"
            "let ratio: Double = 1\n"
        ),
    })
    result = run(root)
    assert result.returncode == 1
    assert findings(result) == [("Regex.swift", 3, "binary-float")]


def test_division_is_not_mistaken_for_a_regex_literal(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{DOMAIN}/Division.swift": (
            "let half = total / 2\n"
            "let third = total / 3 / 4\n"
            "let scaled = total /= 2\n"
            "let value: Double = 1\n"
        ),
    })
    result = run(root)
    assert result.returncode == 1
    assert findings(result) == [("Division.swift", 4, "binary-float")]


def test_postfix_force_unwrap_before_a_slash_is_not_a_regex_opener(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{DOMAIN}/Postfix.swift": (
            "let a = foo!/Double(n)/2\n"
            "let b = value! / 2\n"
            "let c = ok? / Double(2)\n"
            "let d = /Double/\n"
        ),
    })
    result = run(root)
    assert result.returncode == 1
    # `foo!` ends an operand, so the slash on line 1 divides and its `Double`
    # counts. Line 4 is a real pattern, so its text is not code.
    assert findings(result) == [
        ("Postfix.swift", 1, "binary-float"),
        ("Postfix.swift", 3, "binary-float"),
    ]


def test_ternary_question_mark_opens_a_regex_literal(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{DOMAIN}/Ternary.swift": (
            "let r = flag ? /Double/ : /Float/\n"
            "let s = ok ? /Double/ : /Float/\n"
            "let z: Double = 1\n"
        ),
    })
    result = run(root)
    assert result.returncode == 1
    # The ternary `?` is infix and takes whitespace on both sides, so the slash
    # after it opens a pattern rather than dividing. Line 3 is still code.
    assert findings(result) == [("Ternary.swift", 3, "binary-float")]


def test_postfix_question_mark_before_a_slash_is_not_a_regex_opener(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{DOMAIN}/OptionalChain.swift": (
            "let v = a?.b / Double(c) / d\n"
            "let w = a!.b / Double(c)\n"
            "let z: Double = 1\n"
        ),
    })
    result = run(root)
    assert result.returncode == 1
    # A `?` attached to the previous token is postfix, so the operand ended and
    # the slash divides. The `Double` on both lines is real code.
    assert findings(result) == [
        ("OptionalChain.swift", 1, "binary-float"),
        ("OptionalChain.swift", 2, "binary-float"),
        ("OptionalChain.swift", 3, "binary-float"),
    ]


def test_interpolation_inside_an_extended_regex_is_still_code(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{DOMAIN}/RegexInterpolation.swift": (
            'let r = #/[0-9]+\\#(Double(input)!)/#\n'
            'let prose = #/Double \\(Double) stays text/#\n'
            'let plain = /Double/\n'
        ),
    })
    result = run(root)
    assert result.returncode == 1
    # The interpolated expression is compiled Swift; a plain `\(` needs the same
    # number of hashes to be one, and line 3 is a pattern, so neither counts.
    assert findings(result) == [
        ("RegexInterpolation.swift", 1, "binary-float"),
    ]


def test_multiline_hash_regex_spans_lines(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{DOMAIN}/MultilineRegex.swift": (
            "let r = #/\n"
            "  Double | Float\n"
            "  /#\n"
            "let x: Double = 1\n"
        ),
    })
    result = run(root)
    assert result.returncode == 1
    # The scan runs to the closing /#, so the pattern text is never inspected
    # and the code after the literal is still checked.
    assert findings(result) == [("MultilineRegex.swift", 4, "binary-float")]


def test_hex_float_literal_with_underscored_exponent_is_reported(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{DOMAIN}/HexUnderscore.swift": (
            "let a = 0x1p1_0\n"
            "let b = 0x1.fp2_0\n"
            "let c = 0x1_000\n"
        ),
    })
    result = run(root)
    assert result.returncode == 1
    # Underscores are allowed in a hex float exponent; a hex integer is not a
    # floating-point literal even with underscores.
    assert findings(result) == [
        ("HexUnderscore.swift", 1, "binary-float"),
        ("HexUnderscore.swift", 2, "binary-float"),
    ]


def test_hash_delimited_regex_may_start_with_a_space(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{DOMAIN}/LeadingSpace.swift": (
            "let r = #/ Double /#\n"
            "let q = x / Double(2)\n"
        ),
    })
    result = run(root)
    assert result.returncode == 1
    # Only a bare `/` needs the pattern to start at the slash; with hash
    # delimiters a leading space is part of the pattern.
    assert findings(result) == [("LeadingSpace.swift", 2, "binary-float")]


def test_lint_allow_text_inside_a_string_does_not_allow(tmp_path: Path) -> None:
    root = write_tree(tmp_path, {
        f"{DOMAIN}/Doc.swift": (
            'let doc = """\n'
            "    \\(Double(value)) // lint-allow: binary-float\n"
            '    """\n'
            "let ok: Double = 1 // lint-allow: binary-float\n"
        ),
    })
    result = run(root)
    assert result.returncode == 1
    # Only the real trailing comment on line 4 counts as an exemption.
    assert findings(result) == [("Doc.swift", 2, "binary-float")]


def test_missing_root_is_reported_as_an_error(tmp_path: Path) -> None:
    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(tmp_path / "nope")],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 2


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(pytest.main([__file__]))