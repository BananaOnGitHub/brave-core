import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from strip_static_tor_bundle import remove_static_tor_bundle


class StaticTorBundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def make_bundle(self, name):
        bundle = self.root / name
        tor = bundle / "Frameworks/tor.framework"
        resources = tor / "Versions/A/Resources"
        resources.mkdir(parents=True)
        (resources / "Info.plist").write_bytes(plistlib.dumps({}))
        (tor / "Versions/A/tor").write_bytes(b"stub")
        (tor / "Versions/Current").symlink_to("A")
        (bundle / "Info.plist").write_bytes(
            plistlib.dumps({"CFBundleExecutable": "Harness"})
        )
        return bundle, tor

    @patch("strip_static_tor_bundle.subprocess.check_output", return_value="/usr/lib/libSystem.B.dylib")
    def test_removes_redundant_bundle_from_app_and_test_host(self, otool):
        for name in ("Harness.app", "HarnessTests.xctest"):
            with self.subTest(name=name):
                bundle, tor = self.make_bundle(name)
                self.assertIn("Versions/A/tor", remove_static_tor_bundle(bundle))
                self.assertFalse(tor.exists())
                self.assertTrue((bundle / "Info.plist").exists())
                otool.assert_called_with(
                    ["xcrun", "otool", "-L", str(bundle / "Harness")], text=True
                )

    @patch("strip_static_tor_bundle.subprocess.check_output", return_value="@rpath/tor.framework/tor")
    def test_retains_dynamically_loaded_framework(self, _otool):
        bundle, tor = self.make_bundle("Harness.app")
        with self.assertRaisesRegex(RuntimeError, "dynamically loaded"):
            remove_static_tor_bundle(bundle)
        self.assertTrue(tor.exists())

    @patch("strip_static_tor_bundle.subprocess.check_output", return_value="/usr/lib/libSystem.B.dylib")
    def test_retains_unexpected_resources(self, _otool):
        bundle, tor = self.make_bundle("Harness.app")
        resource = tor / "Versions/A/Resources/geoip"
        resource.write_text("do not discard")
        with self.assertRaisesRegex(RuntimeError, "Unexpected Tor resource"):
            remove_static_tor_bundle(bundle)
        self.assertTrue(resource.exists())

    @patch("strip_static_tor_bundle.subprocess.check_output")
    def test_already_clean_bundle_is_unchanged(self, otool):
        self.assertEqual(remove_static_tor_bundle(self.root), [])
        otool.assert_not_called()


if __name__ == "__main__":
    unittest.main()
