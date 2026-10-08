#!/usr/bin/env python3
"""Build the Claude Design "Design System" file tree from the Swift sources.

Everything is derived from the repository, so a new screen, text style or colour shows up the
next time this runs:

  * colour tokens   from ios/NutritionCore/Sources/NutritionCore/NutritionTokens.swift
  * text styles     from the `.font(.x)` calls in the SwiftUI views
  * spacing         from the `spacing:` and `.padding` values in the views
  * screens         one page per non-private `struct X: View` (name, title, sections, text,
                    controls, symbols, fonts, token colours), as a static outline preview

Usage:
  build_design_system.py OUT_DIR [--title TITLE] [--no-index] [--check]
                         [--screenshots DIR] [--blobs FILE]

Writes OUT_DIR/project/... (publish those files to the artifact) and keeps OUT_DIR/screens.json
from the previous run, so the run prints which screens are new, removed or changed.
--check writes nothing and exits 1 when a screen has no extractable content or a font style is
unknown, so a new kind of view cannot slip through uncovered.
--screenshots DIR   PNGs named <ViewName>-light.png and <ViewName>-dark.png (from the screenshots
                    workflow). Screens with both get their picture; the run lists the screens without
                    one. With --check, a screen with no screenshot fails the check unless it is exempt
                    (SCREENSHOT_EXEMPT: the camera sheets) or a small component.
--blobs FILE        JSON {"<ViewName>-light.png": "/_blob/<id>", ...} from uploading the PNGs to the
                    artifact; the previews reference those urls. Without an entry a screen keeps its
                    outline.
--no-index skips design-system.json; use it when updating an existing artifact.

Screen pages are an outline generated from source, not a pixel render of the app.
"""
import argparse
import datetime
import html
import json
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOKENS_SWIFT = ROOT / "ios/NutritionCore/Sources/NutritionCore/NutritionTokens.swift"
SWIFT_ROOTS = ["ios/NutritionCore/Sources/NutritionUI", "ios/HealthNutrition/Sources"]
SKIP_DIRS = {"Debug"}

TOKEN_RE = re.compile(
    r'Token\(name:\s*"([A-Za-z0-9]+)",\s*light:\s*"(#[0-9A-Fa-f]{6})",\s*dark:\s*"(#[0-9A-Fa-f]{6})"\)'
)

USAGE = {
    "AccentColor": "Brand accent for controls and links. Teal on light, mint on dark.",
    "RelayAccentInk": "Deep teal ink for emphasis on light surfaces.",
    "RelayMint": "Fill colour only. Never use it as text on a light surface (1.48:1 on white). Put RelayOnMint on top.",
    "RelayOnMint": "Text and icons on a RelayMint fill.",
    "RelayReadyInk": "Text for a ready state, on RelayReadyTint.",
    "RelayReadyTint": "Background tint for a ready state.",
    "RelayWaitingInk": "Text for a waiting state, on RelayWaitingTint.",
    "RelayWaitingTint": "Background tint for a waiting state.",
    "RelayFailedInk": "Text for a failed state, on RelayFailedTint.",
    "RelayFailedTint": "Background tint for a failed state.",
    "RelaySecondaryText": "Secondary text on background and surface.",
    "background": "Screen background.",
    "surface": "Grouped rows and cards sitting on the background.",
    "border": "Decorative separator. Not text, so not held to 4.5:1.",
    "textPrimary": "Primary text on background and surface.",
    "textSecondary": "Secondary text. Equals RelaySecondaryText.",
    "accent": "Semantic accent. Equals AccentColor.",
    "success": "Success text. Equals RelayReadyInk.",
    "warning": "Warning text. Equals RelayWaitingInk.",
    "error": "Error text. Equals RelayFailedInk.",
}

# iOS Dynamic Type styles at the default content size: name -> (size, line height, weight, usage).
IOS_TEXT_STYLES = {
    "largeTitle": ("34px", "41px", 400, "Large navigation titles."),
    "title": ("28px", "34px", 400, "Top-level titles."),
    "title2": ("22px", "28px", 400, "Screen section titles."),
    "title3": ("20px", "25px", 400, "Sub-section titles."),
    "headline": ("17px", "22px", 600, "Row titles and section headers."),
    "body": ("17px", "22px", 400, "Default text and buttons."),
    "callout": ("16px", "21px", 400, "Callouts."),
    "subheadline": ("15px", "20px", 400, "Supporting lines under a row title."),
    "footnote": ("13px", "18px", 400, "Captions, coverage notes and totals detail."),
    "caption": ("12px", "16px", 400, "Small captions."),
    "caption2": ("11px", "13px", 400, "Smallest captions."),
}
STYLE_ORDER = list(IOS_TEXT_STYLES)

STRUCT_RE = re.compile(
    r"^(?P<vis>public |internal |private |fileprivate )?struct (?P<name>\w+)(?:<[^\n{]*>)?\s*:\s*(?P<conf>[^{]*)\{", re.M)
STRING = r'"(?:[^"\\]|\\.)*"'
ELEMENT_RE = re.compile(
    "|".join(
        [
            r'\.navigationTitle\((?P<nav>' + STRING + r')',
            r'\bSection\((?:header:\s*Text\()?(?P<sec>' + STRING + r')',
            r'\bLabel\((?P<lab>' + STRING + r'),\s*systemImage:\s*(?P<labi>' + STRING + r')',
            r'\b(?P<ctlk>Button|TextField|SecureField|Toggle|Picker|DatePicker|Stepper|NavigationLink|Menu|Link)\((?P<ctl>' + STRING + r')',
            r'\bText\((?P<txt>' + STRING + r')\)',
            r'\bImage\(systemName:\s*(?P<img>' + STRING + r')',
        ]
    )
)
FONT_RE = re.compile(r"\.font\(\.(\w+)")
COLOR_RE = re.compile(r"TokenColors\.(\w+)")
SPACING_RE = re.compile(r"\bspacing:\s*(\d+(?:\.\d+)?)")
PADDING_RE = re.compile(r"\.padding\((?:[^)]*,\s*)?(\d+(?:\.\d+)?)\)")
# `Button { action } label: { Text("...") }`: the label is the button's text.
CLOSURE_LABEL_RE = re.compile(r"\blabel:\s*\{\s*Text\((?P<text>" + STRING + r")\)\s*\}")
# `public static var mint: Color { color(named: "RelayMint") }` maps a TokenColors accessor to its token.
ACCESSOR_RE = re.compile(r'static var (\w+):\s*Color\s*\{\s*color\(named:\s*"(\w+)"\)')


def unq(text):
    """Swift string literal -> display text. Interpolations become an ellipsis."""
    body = text[1:-1]
    body = re.sub(r"\\\([^)]*\)", "…", body)
    return body.replace('\\"', '"').replace("\\n", " ")


def read_tokens(path):
    found = {}
    for name, light, dark in TOKEN_RE.findall(path.read_text()):
        found[name] = (light.lower(), dark.lower())
    if len(found) < 20:
        sys.exit(f"expected at least 20 tokens in {path}, parsed {len(found)}")
    return found


def swift_files(root=ROOT):
    for sub in SWIFT_ROOTS:
        for path in sorted((root / sub).rglob("*.swift")):
            if SKIP_DIRS & set(path.relative_to(root).parts):
                continue
            yield path


DESIGN_ENUM_RE = re.compile(r"enum Design(Spacing|Radius)\s*\{(.*?)\n\}", re.S)
DESIGN_VALUE_RE = re.compile(r"static let (\w+):\s*CGFloat\s*=\s*(\d+(?:\.\d+)?)")


def scan_design_scales(root=ROOT):
    """Named spacing and radius steps from `enum DesignSpacing` and `enum DesignRadius`."""
    scales = {"Spacing": {}, "Radius": {}}
    for path in swift_files(root):
        for kind, body in DESIGN_ENUM_RE.findall(path.read_text()):
            for name, value in DESIGN_VALUE_RE.findall(body):
                scales[kind][name] = value
    return scales


def scan_color_aliases(root=ROOT):
    """TokenColors accessor name -> the colour token it returns (`mint` -> `RelayMint`)."""
    path = root / "ios/NutritionCore/Sources/NutritionUI/TokenColors.swift"
    return dict(ACCESSOR_RE.findall(path.read_text())) if path.exists() else {}


def element_list(body):
    """The outline elements in a view body, in source order."""
    labels = [(m.start(), m.end(), unq(m.group("text"))) for m in CLOSURE_LABEL_RE.finditer(body)]
    found = []
    for e in ELEMENT_RE.finditer(body):
        if any(a <= e.start() < b for a, b, _ in labels):
            continue  # the text inside a closure label is recorded as the button below
        g = e.groupdict()
        if g["nav"]:
            found.append((e.start(), ("title", unq(g["nav"]))))
        elif g["sec"]:
            found.append((e.start(), ("section", unq(g["sec"]))))
        elif g["lab"]:
            found.append((e.start(), ("label", unq(g["lab"]), unq(g["labi"]))))
        elif g["ctl"] is not None:
            found.append((e.start(), (g["ctlk"].lower(), unq(g["ctl"]))))
        elif g["txt"]:
            found.append((e.start(), ("text", unq(g["txt"]))))
        elif g["img"]:
            found.append((e.start(), ("symbol", unq(g["img"]))))
    found += [(a, ("button", text)) for a, _, text in labels]
    return [el for _, el in sorted(found, key=lambda item: item[0])]


def nested_colors(name, bodies, aliases, seen=frozenset()):
    """Token colours a view uses, including those of the views it renders (`QuietCapsule(...)`)."""
    colors = {aliases.get(c, c) for c in COLOR_RE.findall(bodies[name])}
    for other in bodies:
        if other != name and other not in seen and re.search(rf"\b{other}\(", bodies[name]):
            colors |= nested_colors(other, bodies, aliases, seen | {name})
    return colors


def scan_screens(root=ROOT):
    """Return (screens, fonts, spacings). A screen is a non-private struct conforming to View."""
    screens, fonts, spacings, bodies = {}, set(), set(), {}
    aliases = scan_color_aliases(root)
    for path in swift_files(root):
        text = path.read_text()
        fonts.update(FONT_RE.findall(text))
        spacings.update(SPACING_RE.findall(text))
        spacings.update(PADDING_RE.findall(text))
        matches = list(STRUCT_RE.finditer(text))
        for i, m in enumerate(matches):
            conf = [c.strip() for c in m.group("conf").split(",")]
            if "View" not in conf:
                continue
            end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
            name = m.group("name")
            bodies[name] = text[m.start():end]
            if m.group("vis") in ("private ", "fileprivate "):
                continue
            body = bodies[name]
            elements = element_list(body)
            has_page_chrome = any(e[0] in ("title", "section") for e in elements)
            screens[name] = {
                "name": name,
                "source": str(path.relative_to(root)),
                "group": ("App" if "HealthNutrition/Sources" in str(path)
                          else "Screens" if has_page_chrome or len(elements) >= 3 else "Components"),
                "elements": elements,
                "fonts": sorted(set(FONT_RE.findall(body)), key=lambda f: STYLE_ORDER.index(f) if f in STYLE_ORDER else 99),
                "colors": [],
            }
    for name, screen in screens.items():
        screen["colors"] = sorted(nested_colors(name, bodies, aliases))
    return screens, fonts, spacings


def humanize(name):
    words = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", name).split()
    if len(words) > 1 and words[-1] == "View":
        words.pop()
    return " ".join(words)


def tokens_json(tokens, title, fonts, spacings, scales=None):
    scales = scales or {"Spacing": {}, "Radius": {}}
    styles = [
        {"name": n, "fontSize": IOS_TEXT_STYLES[n][0], "lineHeight": IOS_TEXT_STYLES[n][1],
         "fontWeight": IOS_TEXT_STYLES[n][2], "usage": IOS_TEXT_STYLES[n][3]}
        for n in STYLE_ORDER if n in fonts
    ]
    spacing = [
        {"name": f"space-{n}", "value": f"{v}px", "usage": f"DesignSpacing.{n}."}
        for n, v in sorted(scales["Spacing"].items(), key=lambda kv: float(kv[1]))
    ]
    named = set(scales["Spacing"].values())
    spacing += [
        {"name": f"space-{v}", "value": f"{v}px", "usage": "A spacing or padding value the views use."}
        for v in sorted({s for s in spacings} - named, key=float)
    ]
    radius = [
        {"name": f"radius-{n}", "value": f"{v}px", "usage": f"DesignRadius.{n}."}
        for n, v in sorted(scales["Radius"].items(), key=lambda kv: float(kv[1]))
    ]
    return {
        "name": title,
        "version": 1,
        "color": {
            "themes": [{"id": "light", "name": "Light"}, {"id": "dark", "name": "Dark"}],
            "tokens": [
                {"name": n, "value": {"light": l, "dark": d}, "usage": USAGE.get(n, "")}
                for n, (l, d) in tokens.items()
            ],
        },
        "type": {
            "fonts": [],
            "families": {"sans": "-apple-system, \"SF Pro Text\", system-ui, \"Helvetica Neue\", Arial, sans-serif"},
            "groups": [{"name": "iOS text styles", "family": "sans", "styles": styles}],
        },
        "spacing": {"tokens": spacing},
        **({"radius": {"tokens": radius}} if radius else {}),
        "meta": {"source": "repo", "paths": {"tokens": [str(TOKENS_SWIFT.relative_to(ROOT))],
                                             "screens": SWIFT_ROOTS}},
    }


def readme(title, screens, pictured=frozenset()):
    names = ", ".join(humanize(n) for n in screens)
    outline = ("The previews are outlines generated from the Swift source, not renders of the app."
               if not pictured else
               "Screens with a simulator capture show the rendered screen in light and dark. The others are "
               "outlines generated from the Swift source, not renders of the app.")
    return f"""# {title}

A white, clean light layout with teal and mint accents, and a dark mode designed to match it
rather than inverted from it. The app is native SwiftUI for iOS. This system documents its colour
tokens, text styles, spacing and screens so designs match the shipped app.

## Colour

- Use the semantic roles in screens: `background`, `surface`, `border`, `textPrimary`,
  `textSecondary`, `accent`, `success`, `warning`, `error`. The `Relay*` tokens are the audited
  HealthRelay values the roles are built from.
- Normal text needs 4.5:1 against what it sits on, in light and dark. Large text and meaningful
  graphics need 3:1.
- `RelayMint` is a fill. Never set it as text on a light surface. Use `RelayOnMint` on top of it.
- State colours come in pairs: `RelayReadyInk` on `RelayReadyTint`, `RelayWaitingInk` on
  `RelayWaitingTint`, `RelayFailedInk` on `RelayFailedTint`.
- Do not add a colour without a contrast check against `background` and `surface`.

## Type

Text is the iOS system font at Dynamic Type styles only. Never use fixed point sizes; the lint in
the app repo rejects them.

## Screens

{names}. Each has a page under Components with its source file, sections, text, controls and the
tokens it uses. {outline}
See the Screens section for the full table.

## Not synced

Web components: the app is SwiftUI, so there is no component bundle. Shadow tokens do not exist in
the source.
"""


def screens_md(screens):
    lines = ["# Screens", "",
             "Generated from the SwiftUI sources. Private helper views are not listed.", "",
             "| Screen | Source | Title | Fonts | Token colours |", "|---|---|---|---|---|"]
    for s in screens.values():
        title = next((e[1] for e in s["elements"] if e[0] == "title"), "")
        lines.append(f"| {humanize(s['name'])} | `{s['source']}` | {title} | {', '.join(s['fonts'])} | {', '.join(s['colors'])} |")
    return "\n".join(lines) + "\n"


def screen_readme(s, pictured=False):
    out = [f"{humanize(s['name'])} is a {'sheet or root view in the app target' if s['group'] == 'App' else 'screen'} defined in `{s['source']}`.", ""]
    title = [e[1] for e in s["elements"] if e[0] == "title"]
    if title:
        out += [f"Navigation title: {title[0]}", ""]
    sections = [e[1] for e in s["elements"] if e[0] == "section"]
    if sections:
        out += ["## Sections", ""] + [f"- {x}" for x in sections] + [""]
    controls = [e for e in s["elements"] if e[0] in ("button", "textfield", "securefield", "toggle", "picker", "datepicker", "stepper", "navigationlink", "menu", "link")]
    if controls:
        out += ["## Controls", ""] + [f"- {e[0]}: {e[1]}" for e in controls] + [""]
    symbols = sorted({e[2] if e[0] == "label" else e[1] for e in s["elements"] if e[0] in ("label", "symbol")})
    if symbols:
        out += ["## SF Symbols", "", ", ".join(f"`{x}`" for x in symbols), ""]
    if s["fonts"]:
        out += ["## Text styles", "", ", ".join(f"`{x}`" for x in s["fonts"]), ""]
    if s["colors"]:
        out += ["## Token colours", "", ", ".join(f"`{x}`" for x in s["colors"]), ""]
    if pictured:
        out += ["The preview is a simulator capture of this screen in light and dark.", ""]
    else:
        out += ["The preview is an outline built from the source text, not a render.", ""]
    return "\n".join(out)


def esc(text):
    return html.escape(text, quote=True)


# The camera cannot run on the simulator, so these sheets keep their outline.
SCREENSHOT_EXEMPT = {"BarcodeScannerSheet", "LabelCaptureSheet"}


def find_screenshots(directory):
    """Screen names that have both a light and a dark PNG in `directory`."""
    if not directory:
        return set()
    found = {p.name for p in Path(directory).glob("*.png")}
    return {n[: -len("-light.png")] for n in found if n.endswith("-light.png")
            and n.replace("-light.png", "-dark.png") in found}


def missing_screenshots(screens, shots):
    return sorted(n for n, s in screens.items()
                  if s["group"] != "Components" and n not in SCREENSHOT_EXEMPT and n not in shots)


def screenshot_preview(s, blobs):
    name = s["name"]
    return f"""<!-- @dsCard group="{s['group']}" height=880 subtitle="Simulator capture of {esc(s['source'])}" -->
<style>
  html, body {{ margin: 0; background: var(--background); }}
  .shot {{ display: block; width: 393px; max-width: 100%; height: auto; margin: 12px auto; }}
  .dark {{ display: none; }}
  [data-theme="dark"] .light {{ display: none; }}
  [data-theme="dark"] .dark {{ display: block; }}
</style>
<img class="shot light" src="{esc(blobs[name + '-light.png'])}" alt="{esc(humanize(name))}, light appearance">
<img class="shot dark" src="{esc(blobs[name + '-dark.png'])}" alt="{esc(humanize(name))}, dark appearance">
"""


def screen_preview(s, blobs=None):
    blobs = blobs or {}
    if f"{s['name']}-light.png" in blobs and f"{s['name']}-dark.png" in blobs:
        return screenshot_preview(s, blobs)
    rows, height = [], 60
    title = ""
    for e in s["elements"]:
        kind = e[0]
        if kind == "title" and not title:
            title = e[1]
        elif kind == "section":
            rows.append(f'<div class="sec">{esc(e[1])}</div>')
            height += 34
        elif kind == "text":
            rows.append(f'<div class="row txt">{esc(e[1])}</div>')
            height += 44
        elif kind == "label":
            rows.append(f'<div class="row"><span class="sym">{esc(e[2])}</span>{esc(e[1])}</div>')
            height += 44
        elif kind in ("button", "navigationlink", "link", "menu"):
            rows.append(f'<div class="row act">{esc(e[1])}</div>')
            height += 44
        elif kind in ("textfield", "securefield", "picker", "datepicker", "stepper"):
            rows.append(f'<div class="row fld"><span>{esc(e[1])}</span><i></i></div>')
            height += 44
        elif kind == "toggle":
            rows.append(f'<div class="row fld"><span>{esc(e[1])}</span><b></b></div>')
            height += 44
    if not rows:
        rows.append('<div class="row txt">No literal text in this view.</div>')
        height += 44
    height = max(120, min(height, 1600))
    return f"""<!-- @dsCard group="{s['group']}" height={height} subtitle="Outline from {esc(s['source'])}" -->
<style>
  html, body {{ margin: 0; background: var(--background); color: var(--textPrimary); font: 400 17px/22px var(--font-sans); }}
  .phone {{ box-sizing: border-box; width: 360px; margin: 12px auto; border: 1px solid var(--border); background: var(--background); }}
  .nav {{ padding: 12px 16px; font: 600 17px/22px var(--font-sans); border-bottom: 1px solid var(--border); }}
  .sec {{ padding: 12px 16px 4px; font: 400 13px/18px var(--font-sans); color: var(--textSecondary); text-transform: uppercase; letter-spacing: .04em; }}
  .row {{ box-sizing: border-box; min-height: 44px; display: flex; align-items: center; gap: 8px; padding: 8px 16px; background: var(--surface); border-bottom: 1px solid var(--border); }}
  .act {{ color: var(--accent); }}
  .fld {{ justify-content: space-between; }}
  .fld i {{ width: 120px; height: 24px; border: 1px solid var(--border); background: var(--background); }}
  .fld b {{ width: 40px; height: 24px; background: var(--RelayMint); }}
  .sym {{ font: 400 13px/18px var(--font-sans); color: var(--textSecondary); }}
</style>
<div class="phone"><div class="nav">{esc(title or humanize(s['name']))}</div>{''.join(rows)}</div>
"""


def cover(title):
    words = title.split()
    line1, line2 = (words[0], " ".join(words[1:])) if len(words) > 1 else (title, "")
    return f"""<!-- @dsCard height=288 -->
<style>
  html, body {{ margin: 0; background: var(--background); }}
  svg {{ display: block; width: 960px; height: 288px; }}
  .accent {{ fill: var(--AccentColor); }}
  .mint {{ fill: var(--RelayMint); }}
  .ink {{ fill: var(--RelayAccentInk); }}
  .ready {{ fill: var(--RelayReadyTint); }}
  .wait {{ fill: var(--RelayWaitingTint); }}
  .name {{ font: 600 76px/0.95 var(--font-sans); fill: var(--textPrimary); }}
  .tag {{ font: 400 14px var(--font-sans); fill: var(--textSecondary); }}
</style>
<svg viewBox="0 0 960 288" role="img" aria-label="{esc(title)}">
  <!-- derivation: blocks AccentColor slab 192, RelayMint disc 96, RelayAccentInk pill 288x96,
       RelayReadyTint disc 96, RelayWaitingTint disc 48. Arrangement: staggered cluster right of
       x=480 bleeding off the right edge. Pattern: discs and pills, soft rounded iOS controls.
       Radii: half the short side. -->
  <rect class="accent" x="528" y="48" width="192" height="192" rx="96"/>
  <rect class="ink" x="672" y="144" width="288" height="96" rx="48"/>
  <circle class="mint" cx="816" cy="96" r="48"/>
  <circle class="ready" cx="600" cy="48" r="48"/>
  <circle class="wait" cx="912" cy="24" r="24"/>
  <circle class="mint" cx="504" cy="240" r="24"/>
  <text class="name" x="32" y="170">{esc(line1)}</text>
  <text class="name" x="32" y="240">{esc(line2)}</text>
  <text class="tag" x="32" y="268">Daily nutrition log for iOS</text>
</svg>
"""


def summarize(screens):
    return {n: {"source": s["source"], "elements": len(s["elements"]),
                "digest": json.dumps([s["elements"], s["fonts"], s["colors"], s["source"], s["group"]], sort_keys=True)}
            for n, s in screens.items()}


def report_changes(old, new):
    added = sorted(set(new) - set(old))
    removed = sorted(set(old) - set(new))
    changed = sorted(n for n in set(new) & set(old) if new[n]["digest"] != old[n]["digest"])
    for label, names in (("new screens", added), ("removed screens", removed), ("changed screens", changed)):
        print(f"{label}: {', '.join(names) if names else 'none'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("out_dir")
    parser.add_argument("--title", default="Health Nutrition")
    parser.add_argument("--no-index", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--screenshots", metavar="DIR")
    parser.add_argument("--blobs", metavar="FILE")
    args = parser.parse_args()

    tokens = read_tokens(TOKENS_SWIFT)
    screens, fonts, spacings = scan_screens()
    blobs = json.loads(Path(args.blobs).read_text()) if args.blobs else {}
    unknown = sorted(f for f in fonts if f not in IOS_TEXT_STYLES)
    empty = sorted(n for n, s in screens.items() if not s["elements"] and s["group"] != "Components")
    unmapped = sorted({c for s in screens.values() for c in s["colors"]} - set(tokens))
    shots = find_screenshots(args.screenshots)
    uncovered = missing_screenshots(screens, shots) if args.screenshots else []
    pictured = frozenset(n for n in screens if f"{n}-light.png" in blobs and f"{n}-dark.png" in blobs)
    if args.check:
        for n in uncovered:
            print(f"screen with no screenshot: {n}")
        for n in empty:
            print(f"screen with no extractable content: {n}")
        for f in unknown:
            print(f"unknown font style: {f}")
        for c in unmapped:
            print(f"colour used but not in the tokens: {c}")
        print(f"{len(screens)} screens, {len(tokens)} colour tokens, {len(fonts)} text styles")
        sys.exit(1 if empty or unknown or uncovered or unmapped else 0)
    if unknown:
        print(f"warning: unknown font styles skipped: {', '.join(unknown)}", file=sys.stderr)
    if unmapped:
        print(f"warning: colours not in the tokens, left out of the pages: {', '.join(unmapped)}", file=sys.stderr)

    out = Path(args.out_dir)
    project = out / "project"
    state = out / "screens.json"
    old = json.loads(state.read_text()) if state.exists() else {}
    new = summarize(screens)
    (project / "components/Cover").mkdir(parents=True, exist_ok=True)
    # Pages for screens the last run wrote and this one no longer finds are removed, not left behind.
    for gone in sorted(set(old) - set(screens)):
        shutil.rmtree(project / "components" / gone, ignore_errors=True)
    (project / "tokens.json").write_text(json.dumps(tokens_json(tokens, args.title, fonts, spacings, scan_design_scales()), indent=2) + "\n")
    (project / "README.md").write_text(readme(args.title, screens, pictured))
    (project / "Screens.md").write_text(screens_md(screens))
    (project / "components/Cover/preview.html").write_text(cover(args.title))
    for n, s in screens.items():
        d = project / "components" / n
        d.mkdir(parents=True, exist_ok=True)
        (d / "README.md").write_text(screen_readme(s, n in pictured))
        (d / "preview.html").write_text(screen_preview(s, blobs))

    report_changes(old, new)
    state.write_text(json.dumps(new, indent=2, sort_keys=True) + "\n")

    if not args.no_index:
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        index = {
            "v": 3, "layout": "files", "createdOnFiles": {"v": 1, "at": now}, "title": args.title,
            "namespace": "HealthNutrition", "libraries": [], "sections": {}, "groups": [], "assetGroups": {},
            "blobs": {}, "docs": {"readme": "project/README.md", "sections": []},
            "lastChange": {"by": "Claude", "at": now, "via": "Claude Code",
                           "note": f"{len(screens)} screens, {len(tokens)} colour tokens"},
        }
        (project / "design-system.json").write_text(json.dumps(index, indent=2) + "\n")
    if args.screenshots:
        shown = sorted(n for n in screens if f"{n}-light.png" in blobs and f"{n}-dark.png" in blobs)
        print(f"screenshots on the pages: {', '.join(shown) if shown else 'none'}")
        print(f"screenshots captured but not uploaded: {', '.join(sorted(shots - set(shown))) or 'none'}")
        print(f"screens without a screenshot: {', '.join(uncovered) if uncovered else 'none'}")
    print(f"wrote {len(screens)} screens, {len(tokens)} colour tokens, {len(fonts)} text styles to {project}")


if __name__ == "__main__":
    main()
