#!/usr/bin/env python3
"""Compile TorTabState against Brave's real tab protocols without Chromium.

Only the unrelated Chromium factory is omitted. Profile/string modules are
minimal test doubles. This does not substitute for a full Brave application build.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[2] / "brave-ios/Sources/Web"
destination = Path(__file__).resolve().parent / "TabContracts/Generated"
destination.mkdir(parents=True, exist_ok=True)
source = (root / "TabState.swift").read_text()
start = source.index("public class TabStateFactory {")
end = source.index("/// An error that may occur while restoring tab data", start)
(destination / "TabState.swift").write_text(source[:start] + source[end:])
