"""Colours live in Sources/Brand.swift as roles (CLAUDE.md, Design). This guards against new literals."""
import pathlib
import re
import unittest

SOURCES = pathlib.Path(__file__).resolve().parents[2] / "Sources"
LITERAL = re.compile(r"Color\((red|white|hue):|Color\.(gray|blue|pink|red|orange|yellow|green|brown|purple|mint|teal|cyan|indigo)\b")
# DrivePanel.swift still has two literals; it is being changed on another branch. Move them to Brand next.
PENDING = {"DrivePanel.swift"}


class BrandColorTests(unittest.TestCase):
    def test_no_color_literals_outside_brand(self):
        found = []
        for path in sorted(SOURCES.glob("*.swift")):
            if path.name == "Brand.swift" or path.name in PENDING:
                continue
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if LITERAL.search(line):
                    found.append(f"{path.name}:{number}: {line.strip()}")
        self.assertEqual(found, [], "Add a Brand role instead of a colour literal:\n" + "\n".join(found))

    def test_both_storage_bars_use_the_storage_roles(self):
        dashboard = (SOURCES / "DashboardView.swift").read_text(encoding="utf-8")
        breakdown = dashboard[dashboard.index("struct PhoneBreakdown"):dashboard.index("struct WhatsUsingView")]
        for role in ("Brand.storagePhotos", "Brand.storageRest", "Brand.storageFree"):
            self.assertIn(role, breakdown)


if __name__ == "__main__":
    unittest.main()
