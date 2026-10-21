#!/usr/bin/env python3
"""Verify removed pre-1.0 API spellings fail against the production public module."""
import argparse
import pathlib
import platform
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--modules", type=pathlib.Path, required=True)
args = parser.parse_args()
expected = {
    "LegacyFeatureStyle.swift": "cannot find 'AnnotationStyle' in scope",
    "LegacyCameraAngles.swift": "extra arguments at positions #1, #2 in call",
    "LegacyCameraBinding.swift": "extra argument 'position' in call",
}
fixtures = pathlib.Path(__file__).parent / "Fixtures/Rejected"
for name, diagnostic in expected.items():
    result = subprocess.run([
        "xcrun", "swiftc", "-typecheck", "-swift-version", "6", "-target",
        f"{platform.machine()}-apple-macos15.0", "-I", str(args.modules), str(fixtures / name)
    ], capture_output=True, text=True, check=False)
    if result.returncode == 0 or diagnostic not in result.stderr:
        raise SystemExit(f"Unexpected result for {name}:\n{result.stdout}\n{result.stderr}")
    print(f"PASS: {name} rejected for its intended migration diagnostic")
