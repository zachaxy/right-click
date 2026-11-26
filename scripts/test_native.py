#!/usr/bin/env python3
"""Exercise Finder routing and action flows; file operations use the packaged Rust engine."""
import pathlib
import json
import os
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
BUILD.mkdir(exist_ok=True)
CASES = [
    ("network-speed-image", ["ToolboxIcon.swift", "NetworkSpeedStatusImage.swift"]),
    ("network-speed", ["NetworkSpeedMonitor.swift"]),
    ("panel-activation", ["ToolPanel.swift", "ClipboardStore.swift", "ClipboardPanel.swift", "ClipboardStack.swift", "ClipboardCoordinator.swift", "TranslationPanel.swift", "TranslationCoordinator.swift"]),
    ("translation", ["ToolPanel.swift", "TranslationPanel.swift"]),
    ("input-source", ["InputSourceSettings.swift", "InputSourceCoordinator.swift"]),
    ("english-punctuation", ["EnglishPunctuation.swift"]),
    ("clipboard", ["ClipboardStore.swift"]),
    ("clipboard-panel", ["ToolPanel.swift", "ClipboardStore.swift", "ClipboardPanel.swift"]),
    ("clipboard-mcp", ["ClipboardStore.swift", "ClipboardMCP.swift"]),
    ("clipboard-stack", ["ClipboardStack.swift"]),
    ("menu", ["MenuActionStore.swift"]),
    ("layout", ["ToolboxIcon.swift", "MenuActionStore.swift", "FinderMenu.swift"]),
    ("routing", ["FinderRequestRouting.swift"]),
    ("volumes", ["FinderVolumeMonitor.swift"]),
    ("actions", ["FinderActions.swift"]),
]
for name, sources in CASES:
    with tempfile.TemporaryDirectory(prefix="rustclick-native-") as directory:
        main = pathlib.Path(directory) / "main.swift"
        shutil.copyfile(ROOT / "tests" / f"{name}-main.swift", main)
        executable = BUILD / f"{name}-tests"
        frameworks = {
            "clipboard-panel": ["Cocoa", "Quartz", "WebKit"],
            "translation": ["Cocoa", "SwiftUI", "Translation", "NaturalLanguage"],
            "panel-activation": ["Cocoa", "Quartz", "WebKit", "SwiftUI", "Translation", "NaturalLanguage"],
        }.get(name, ["Cocoa"])
        subprocess.run(["swiftc", *[str(ROOT / "native" / source) for source in sources],
                        str(main), *[argument for framework in frameworks for argument in ("-framework", framework)],
                        "-o", str(executable)], check=True)
        args = [str(executable)]
        if name == "actions":
            args.append(str(ROOT / "dist/趁手.app/Contents/MacOS/RightClick"))
        subprocess.run(args, check=True)

# Exercise the actual Rust -> Swift exported entry point in the signed app bundle.
with tempfile.TemporaryDirectory(prefix="rightclick-mcp-cli-") as directory:
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "isolated-build-check", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
            "name": "clipboard_search", "arguments": {"query": "build-check"}}},
    ]
    result = subprocess.run(
        [str(ROOT / "dist/趁手.app/Contents/MacOS/RightClick"), "--clipboard-mcp"],
        input="".join(json.dumps(request) + "\n" for request in requests), text=True,
        capture_output=True, check=True, timeout=15,
        env={**os.environ, "RUSTCLICK_DATA_DIR": directory})
    responses = [json.loads(line) for line in result.stdout.splitlines()]
    assert [response["id"] for response in responses] == [1, 2, 3]
    assert responses[0]["result"]["protocolVersion"] == "2025-06-18"
    assert len(responses[1]["result"]["tools"]) == 3
    assert responses[2]["result"]["isError"] is True
    assert not list(pathlib.Path(directory).iterdir()), "Disabled MCP must not create or capture data"
    print("PASS: packaged MCP entry point, protocol, disabled scope and no data writes")
