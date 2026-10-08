"""Source regressions for supplement fixes; behavioral Swift tests run in CI."""
import unittest
from pathlib import Path

S = Path("ios/NutritionCore/Sources")
class ProductKindRegressionTests(unittest.TestCase):
    def test_ui_imports_kind(self):
        for root in (S / "NutritionUI", Path("ios/HealthNutrition")):
            for path in root.rglob("*.swift"):
                source = path.read_text()
                if "ProductKind" in source or ".supplement" in source:
                    self.assertIn("import NutritionDomain", source, str(path))
    def test_library_row_is_extracted(self):
        self.assertIn("private func libraryRow", (S / "NutritionUI/LibraryView.swift").read_text())
    def test_manual_kind_snapshot(self):
        self.assertIn('catalogOrigin: "manual"', (S / "NutritionUI/AddIntakeViewModel.swift").read_text())
    def test_embedded_supplement_heading(self):
        source = Path("ios/NutritionCore/Tests/NutritionProvidersTests/NutritionFactsParserTests.swift").read_text()
        self.assertFalse('"supplementary blend panel"' in source)
        self.assertIn('"Example Supplement Facts blend panel"', source)
    def test_lookup_identity_includes_kind(self):
        self.assertIn('signature += "|kind=" + kind.rawValue', (S / "NutritionUI/BarcodeLookup.swift").read_text())
    def test_library_accessibility_includes_kind(self):
        self.assertIn("public var accessibilityLabel: String", (S / "NutritionUI/LibraryViewModel.swift").read_text())
        self.assertIn(".accessibilityLabel(item.accessibilityLabel)", (S / "NutritionUI/LibraryView.swift").read_text())
    def test_v2_requires_kind(self):
        self.assertIn("container.decode(ProductKind.self, forKey: .kind)", (S / "NutritionJournal/JournalExport.swift").read_text())
        self.assertIn("decoder.userInfo", (S / "NutritionJournal/JournalExport.swift").read_text())
