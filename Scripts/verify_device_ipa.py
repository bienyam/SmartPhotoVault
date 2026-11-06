"""Reject a simulator binary accidentally packaged as an iPhone IPA. No dependencies."""
import json
import plistlib
import struct
import sys
import zipfile


def verify(path):
    with zipfile.ZipFile(path) as package:
        info_paths = [name for name in package.namelist()
                      if name.startswith("Payload/") and name.count("/") == 2
                      and name.endswith(".app/Info.plist")]
        if len(info_paths) != 1:
            raise ValueError("Expected one application under Payload.")
        info_path = info_paths[0]
        info = plistlib.loads(package.read(info_path))
        executable = info.get("CFBundleExecutable")
        if not executable or "/" in executable or "\\" in executable:
            raise ValueError("Invalid application executable name.")
        binary = package.read(info_path.removesuffix("Info.plist") + executable)
        if len(binary) < 32 or struct.unpack_from("<I", binary)[0] != 0xFEEDFACF:
            raise ValueError("Expected a 64-bit little-endian Mach-O executable.")
        if struct.unpack_from("<I", binary, 4)[0] != 0x0100000C:
            raise ValueError("Expected an arm64 device executable.")
        commands, command_bytes = struct.unpack_from("<II", binary, 16)
        end = 32 + command_bytes
        if end > len(binary):
            raise ValueError("Truncated Mach-O load commands.")
        offset = 32
        platforms = []
        for _ in range(commands):
            if offset + 8 > end:
                raise ValueError("Missing Mach-O load command.")
            kind, size = struct.unpack_from("<II", binary, offset)
            if size < 8 or offset + size > end:
                raise ValueError("Invalid Mach-O load command length.")
            if kind == 0x32:  # LC_BUILD_VERSION
                if size < 24:
                    raise ValueError("Truncated build-version command.")
                platforms.append(struct.unpack_from("<I", binary, offset + 8)[0])
            offset += size
        if platforms != [2]:  # PLATFORM_IOS, distinct from PLATFORM_IOSSIMULATOR (7)
            raise ValueError("The binary must target physical iOS, not the simulator.")
        if "iPhoneOS" not in info.get("CFBundleSupportedPlatforms", []):
            raise ValueError("Info.plist must identify the iPhoneOS platform.")
        if not info.get("NSPhotoLibraryUsageDescription"):
            raise ValueError("The photo permission explanation is missing.")
        return {"bundleIdentifier": info["CFBundleIdentifier"],
                "minimumIOS": info.get("MinimumOSVersion"),
                "architecture": "arm64", "platform": "iPhoneOS",
                "signing": "Unsigned; personal signing is required before installation"}


if __name__ == "__main__":
    print(json.dumps(verify(sys.argv[1]), indent=2))
