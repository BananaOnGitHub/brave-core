#!/usr/bin/env python3
"""Package the unsigned Release harness and reject common installation blockers."""

import argparse
import json
import os
import plistlib
import re
import shutil
import stat
import subprocess
import zipfile
from pathlib import Path


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def package(source, output):
    require(source.is_dir(), f"Missing app: {source}")
    require(not output.exists(), f"Refusing to replace output: {output}")
    output.mkdir(parents=True)
    app = output / "Payload" / source.name
    shutil.copytree(source, app, symlinks=True)
    info = plistlib.loads((app / "Info.plist").read_bytes())
    for key in ("CFBundleIdentifier", "CFBundleExecutable", "CFBundleVersion",
                "CFBundleShortVersionString", "MinimumOSVersion"):
        require(isinstance(info.get(key), str) and info[key].strip(),
                f"Missing or empty {key}")
    require(re.fullmatch(r"[0-9]+(\.[0-9]+){0,2}", info["CFBundleVersion"]),
            "Invalid build version")
    require(info.get("CFBundlePackageType") == "APPL", "Not an app bundle")
    require(info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"],
            "Not an iPhone device build")
    require(info.get("UIDeviceFamily") == [1, 2], "Unexpected device families")
    executable = app / info["CFBundleExecutable"]
    require(executable.is_file() and os.access(executable, os.X_OK),
            "Missing executable or executable permission")
    require(command("xcrun", "lipo", "-archs", str(executable)) == "arm64",
            "Expected only arm64 device code")
    headers = command("xcrun", "otool", "-hv", str(executable))
    require("EXECUTE" in headers, "Main binary is not MH_EXECUTE")
    loads = command("xcrun", "otool", "-L", str(executable))
    build = command("xcrun", "vtool", "-show-build", str(executable))
    require(re.search(r"platform\s+IOS\s", build), "Not an iOS Mach-O")
    require(not list(app.glob("*.debug.dylib")), "Debug dylib in Release app")
    require("tor.framework/" not in loads,
            "Tor must be statically linked before removing its copied bundle")

    # Xcode copies the pinned static Tor framework as a codeless versioned
    # framework and injects a stub. Its code is already linked into the app.
    # Versioned bundles are unsuitable for this iOS sideloading package.
    tor = app / "Frameworks" / "tor.framework"
    removed = []
    if tor.exists():
        removed = sorted(str(p.relative_to(tor)) for p in tor.rglob("*"))
        # Do not silently discard resources if a future dependency adds them.
        for path in tor.rglob("*"):
            if path.is_symlink() or not path.is_file():
                continue
            relative = path.relative_to(tor)
            allowed = (
                path.name in {"tor", "Info.plist"}
                or any(part in {"Headers", "PrivateHeaders", "Modules",
                                "_CodeSignature"} for part in relative.parts)
            )
            require(allowed, f"Unexpected Tor resource: {relative}")
        shutil.rmtree(tor)

    for path in app.rglob("*"):
        require(not path.is_symlink(), f"Unexpected bundle symlink: {path}")
        require(not (path.is_dir() and path.name == "Versions"),
                f"Versioned bundle remains: {path}")
        if path.is_file():
            with path.open("rb") as stream:
                require(stream.read(8) != b"!<arch>\n",
                        f"Embedded static archive: {path}")
    require(not (app / "embedded.mobileprovision").exists(),
            "Unsigned package unexpectedly contains a provisioning profile")
    # A code-signing tool must generate the final signature and profile.
    report = {
        "bundle_id": info["CFBundleIdentifier"],
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "minimum_ios": info["MinimumOSVersion"],
        "supported_platforms": info["CFBundleSupportedPlatforms"],
        "device_families": info["UIDeviceFamily"],
        "executable": info["CFBundleExecutable"],
        "architectures": "arm64",
        "mach_o_build": build,
        "dynamic_dependencies": loads,
        "removed_static_tor_bundle_entries": removed,
        "signing": "unsigned; requires a valid device provisioning profile",
        "physical_device_installation": "not verified",
    }
    ipa = output / "BraveTorPrototype-unsigned.ipa"
    with zipfile.ZipFile(ipa, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted((output / "Payload").rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(output))
    with zipfile.ZipFile(ipa) as archive:
        require(archive.testzip() is None, "Corrupt IPA ZIP")
        entry = archive.getinfo(f"Payload/{app.name}/{executable.name}")
        require(entry.external_attr >> 16 & stat.S_IXUSR,
                "IPA lost executable permission")
        require(all(name.startswith(f"Payload/{app.name}/")
                    for name in archive.namelist()), "Unexpected IPA layout")
    (output / "package-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    print(f"Packaged {ipa} ({ipa.stat().st_size} bytes)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    package(args.app, args.output)
