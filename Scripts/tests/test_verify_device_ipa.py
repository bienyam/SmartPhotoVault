import importlib.util
import pathlib
import plistlib
import struct
import tempfile
import unittest
import zipfile

module_path = pathlib.Path(__file__).parents[1] / "verify_device_ipa.py"
spec = importlib.util.spec_from_file_location("verify_device_ipa", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DevicePackageTests(unittest.TestCase):
    def check_package(self, platform=2, cpu=0x0100000C, description="Read photo metadata"):
        header = struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0)
        command = struct.pack("<6I", 0x32, 24, platform, 0, 0, 0)
        info = {"CFBundleExecutable": "SmartPhotoVault", "CFBundleIdentifier": "com.bienyam.SmartPhotoVault",
                "CFBundleSupportedPlatforms": ["iPhoneOS"], "MinimumOSVersion": "17.0",
                "NSPhotoLibraryUsageDescription": description}
        with tempfile.TemporaryDirectory() as directory:
            package = pathlib.Path(directory) / "app.ipa"
            with zipfile.ZipFile(package, "w") as archive:
                archive.writestr("Payload/SmartPhotoVault.app/Info.plist", plistlib.dumps(info))
                archive.writestr("Payload/SmartPhotoVault.app/SmartPhotoVault", header + command)
            return module.verify(package)

    def test_accepts_device_arm64(self):
        self.assertEqual(self.check_package()["platform"], "iPhoneOS")

    def test_rejects_arm64_simulator_even_when_plist_says_iphone(self):
        with self.assertRaisesRegex(ValueError, "physical iOS"):
            self.check_package(platform=7)

    def test_rejects_intel_binary(self):
        with self.assertRaisesRegex(ValueError, "arm64"):
            self.check_package(cpu=0x01000007)

    def test_rejects_missing_permission_explanation(self):
        with self.assertRaisesRegex(ValueError, "permission explanation"):
            self.check_package(description="")


if __name__ == "__main__":
    unittest.main()
