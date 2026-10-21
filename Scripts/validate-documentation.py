#!/usr/bin/env python3
"""Check published migration examples and optionally compile the DocC catalog."""
import argparse
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--compile-docc", action="store_true")
parser.add_argument("--symbol-graphs", type=pathlib.Path,
                    help="Directory containing public Maquette symbol graphs")
args = parser.parse_args()
article = ROOT / "Sources/Maquette/Maquette.docc/migrating-to-the-swiftui-api.md"
fixture = ROOT / "Tests/MaquetteAPITests/MigrationExamplesAPITests.swift"
examples = re.findall(r"<!-- migration-example: ([\w-]+) -->\n```swift\n(.*?)\n```\n<!-- /migration-example -->",
                      article.read_text(), re.S)
compiled = re.findall(r"// migration-example: ([\w-]+)\n(.*?)\n// /migration-example",
                      fixture.read_text(), re.S)
if not examples or len(dict(examples)) != len(examples) or examples != compiled:
    raise SystemExit("Published migration examples differ from their consumer compiler fixture")
print(f"PASS: {len(examples)} published migration examples match plain-import compiler fixtures")
if args.compile_docc:
    if not args.symbol_graphs or not (args.symbol_graphs / "Maquette.symbols.json").exists():
        raise SystemExit("--compile-docc requires --symbol-graphs containing Maquette.symbols.json")
    with tempfile.TemporaryDirectory(prefix="maquette-docc-") as output:
        subprocess.run([
            "xcrun", "docc", "convert", str(article.parent),
            "--additional-symbol-graph-dir", str(args.symbol_graphs.resolve()),
            "--output-dir", output, "--fallback-display-name", "Maquette",
            "--fallback-bundle-identifier", "org.maquette.documentation",
            "--warnings-as-errors",
        ], cwd=ROOT, check=True)
    print("PASS: DocC catalog compiles without warnings")
