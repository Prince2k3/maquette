"""Check that invalid consumer contracts fail for their intended reasons (macOS host)."""
import argparse
import pathlib
import platform
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--modules", type=pathlib.Path, required=True, help="Built modules directory")
args = parser.parse_args()
fixtures = pathlib.Path(__file__).parent / "Fixtures" / "Rejected"
expected = {
    "RendererStorage.swift": "'content' is inaccessible due to 'internal' protection level",
    "MarkerFill.swift": "requires that 'DioramaMarker' conform to 'DioramaFillableContent'",
    "ConflictingGroundOwnership.swift": "extra argument 'groundPosition' in call",
    "ConflictingCameraOwnership.swift": "extra argument 'cameraPosition' in call",
    "NonisolatedAnnotation.swift": "call to main actor-isolated initializer",
}
for name, diagnostic in expected.items():
    result = subprocess.run(
        ["swiftc", "-typecheck", "-swift-version", "6", "-target",
         f"{platform.machine()}-apple-macos15.0", "-I", str(args.modules), str(fixtures / name)],
        capture_output=True, text=True, check=False,
    )
    if result.returncode == 0 or diagnostic not in result.stderr:
        raise SystemExit(f"Unexpected result for {name}:\n{result.stdout}\n{result.stderr}")
    print(f"PASS: {name} rejected for the intended reason")
