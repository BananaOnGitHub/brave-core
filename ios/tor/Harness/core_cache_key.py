#!/usr/bin/env python3
"""Key prebuilt BraveCore by backend sources, toolchain and CI build recipe."""
import hashlib
import subprocess
from pathlib import Path


def calculate_key(tree, toolchain, recipe):
    digest = hashlib.sha256(toolchain + b"\0" + recipe)
    for entry in tree.split(b"\0"):
        if not entry:
            continue
        _, path = entry.split(b"\t", 1)
        if path.startswith((b"ios/brave-ios/", b"ios/tor/", b"docs/", b".github/")):
            continue
        digest.update(entry + b"\0")
    return "brave-ios-core-v1-" + digest.hexdigest()


if __name__ == "__main__":
    tree = subprocess.check_output(["git", "ls-tree", "-rz", "HEAD"])
    toolchain = subprocess.check_output(["xcodebuild", "-version"])
    toolchain += subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-build-version"])
    recipe = Path(".github/workflows/ios-tor-brave.yml").read_bytes()
    print("key=" + calculate_key(tree, toolchain, recipe))
