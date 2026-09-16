"""Exercise the production Xcode build gate in separate CLI processes."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

APP = Path(__file__).resolve().parents[1]


class FoodArtGateTests(unittest.TestCase):
    def invoke(self, root, expected, diagnostic, bundle=None):
        result = subprocess.run(
            ["xcrun", "swift", str(APP / "Scripts/validate-food-art.swift"), str(root)]
            + ([str(bundle)] if bundle else []),
            capture_output=True, text=True, timeout=60,
        )
        print(f"{diagnostic}: raw_exit={result.returncode}\n{result.stdout}{result.stderr}", flush=True)
        self.assertEqual(result.returncode, expected)
        if expected:
            self.assertIn(diagnostic, result.stderr)

    def test_complete_library_and_missing_or_unreadable_assets_in_either_theme(self):
        with tempfile.TemporaryDirectory(prefix="morsel266-gate-") as scratch:
            root = Path(scratch) / "FoodArt"
            shutil.copytree(APP / "Resources/FoodArt", root)
            self.invoke(root, 0, "complete")
            catalog = json.loads((root / "catalog.json").read_text())
            # Last identity catches accidentally validating only the legacy 18.
            identity = catalog["assets"][-1]["id"]
            for theme in ("paper", "night"):
                path = root / f"{identity}-{theme}-64.png"
                original = path.read_bytes()
                for corruption in ("missing", "unreadable", "truncated-pixels"):
                    with self.subTest(theme=theme, corruption=corruption):
                        path.unlink()
                        if corruption == "unreadable":
                            path.write_bytes(b"not an image")
                        elif corruption == "truncated-pixels":
                            path.write_bytes(original[:64])
                        self.invoke(root, 1, path.name)
                        path.write_bytes(original)
            self.invoke(root, 0, "restored")
            # A complete source tree cannot mask an incomplete built product.
            bundle = Path(scratch) / "Morsel.app"
            shutil.copytree(root, bundle)
            self.invoke(root, 0, "bundled", bundle)
            for theme in ("paper", "night"):
                path = bundle / f"{identity}-{theme}-64.png"
                original = path.read_bytes()
                for corruption in ("missing", "unreadable", "truncated-pixels", "wrong-art"):
                    with self.subTest(bundle=True, theme=theme, corruption=corruption):
                        path.unlink()
                        if corruption == "unreadable":
                            path.write_bytes(b"not an image")
                        elif corruption == "truncated-pixels":
                            path.write_bytes(original[:64])
                        elif corruption == "wrong-art":
                            path.write_bytes((root / f"coffee-{theme}-64.png").read_bytes())
                        self.invoke(root, 1, path.name, bundle)
                        path.write_bytes(original)
            self.invoke(root, 0, "bundled-restored", bundle)
            (root / "catalog.json").write_text('{"assets": []}')
            self.invoke(root, 1, "catalog.json")
            (root / "catalog.json").unlink()
            self.invoke(root, 1, "FoodArt completeness")


if __name__ == "__main__":
    unittest.main()
