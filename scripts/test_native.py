#!/usr/bin/env python3
"""Exercise Finder routing and action flows; file operations use the packaged Rust engine."""
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
BUILD.mkdir(exist_ok=True)
CASES = [
    ("menu", ["MenuActionStore.swift"]),
    ("layout", ["MenuActionStore.swift", "FinderMenu.swift"]),
    ("routing", ["FinderRequestRouting.swift"]),
    ("volumes", ["FinderVolumeMonitor.swift"]),
    ("actions", ["FinderActions.swift"]),
]
for name, sources in CASES:
    with tempfile.TemporaryDirectory(prefix="rustclick-native-") as directory:
        main = pathlib.Path(directory) / "main.swift"
        shutil.copyfile(ROOT / "tests" / f"{name}-main.swift", main)
        executable = BUILD / f"{name}-tests"
        subprocess.run(["swiftc", *[str(ROOT / "native" / source) for source in sources],
                        str(main), "-framework", "Cocoa", "-o", str(executable)], check=True)
        args = [str(executable)]
        if name == "actions":
            args.append(str(ROOT / "dist/RightClick.app/Contents/MacOS/RightClick"))
        subprocess.run(args, check=True)
