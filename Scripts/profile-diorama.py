#!/usr/bin/env python3
"""Capture one foreground demo. Power/display settings are never modified.

Native captures export layer FPS and signposts; simulator counters are diagnostics only.
Keep builds, UI automation and other captures stopped during measured phases.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def counters(log):
    phases = {}
    for line in log.splitlines():
        found = re.search(r"\bphase=(\w+)", line)
        if not found:
            continue
        phase = phases.setdefault(found[1], {"phase": found[1]})
        for key, value in re.findall(r"\b(\w+)=(true|false|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b", line):
            if key == "phase":
                continue
            phase[key] = (value == "true") if value in ("true", "false") else (float(value) if any(c in value for c in ".eE") else int(value))
        bins = re.search(r"distinctGroundBins=([\d,]+)", line)
        if bins:
            phase["distinctGroundBins"] = list(map(int, bins[1].split(",")))
    return [p for p in phases.values() if p.get("completed") is True and "ticks" in p]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--preset", default="performance")
    parser.add_argument("--workload", default="polygons")
    parser.add_argument("--shape", choices=["circle", "hexagon", "square"])
    parser.add_argument("--simulator", help="Device UDID; omit for native macOS layer capture")
    parser.add_argument("--seconds", type=int, default=75)
    parser.add_argument("--time-profiler", action="store_true", help="Add CPU sampling; use separate runs for final FPS acceptance")
    args = parser.parse_args()
    prefix = args.output.resolve()
    prefix.parent.mkdir(parents=True, exist_ok=True)
    if Path(str(prefix) + ".json").exists() or Path(str(prefix) + ".trace").exists():
        parser.error("Choose a new output prefix; existing captures are preserved")
    app = args.app.resolve()
    env = {"MAQUETTE_PROFILE": "1", "MAQUETTE_PRESET": args.preset,
           "MAQUETTE_WORKLOAD": args.workload, "MAQUETTE_PROFILE_DRIVER": "scene",
           "MAQUETTE_PROFILE_TRAJECTORY": "linear"}
    if args.shape:
        env["MAQUETTE_PROFILE_SHAPE"] = args.shape
    before = run(["pmset", "-g", "custom"], capture_output=True).stdout
    battery = run(["pmset", "-g", "batt"], capture_output=True).stdout
    if args.simulator:
        run(["xcrun", "simctl", "install", args.simulator, str(app)])
        child_env = os.environ.copy()
        child_env.update({"SIMCTL_CHILD_" + k: v for k, v in env.items()})
        launch = run(["xcrun", "simctl", "launch", args.simulator, "com.maquette.MaquetteProfile"],
                     env=child_env, capture_output=True).stdout
        pid = int(re.search(r":\s*(\d+)", launch)[1])
    else:
        executable = str(app / "Contents/MacOS/MaquetteDemo")
        existing = subprocess.run(["pgrep", "-f", "^" + re.escape(executable) + "$"], capture_output=True, text=True)
        if existing.returncode == 0:
            parser.error("The exact profiling app is already running; close its window/app before a new capture")
        command = ["open", "-n", "-a", str(app)]
        for key, value in env.items():
            command += ["--env", key + "=" + value]
        run(command)
        pid = int(run(["pgrep", "-f", "^" + re.escape(executable) + "$"], capture_output=True).stdout.strip())
    Path(str(prefix) + ".pid").write_text(str(pid) + "\n")
    print(f"Capturing {args.preset}/{args.shape or 'preset shape'} PID {pid}", flush=True)
    try:
        if args.simulator:
            time.sleep(args.seconds)
        else:
            with Path(str(prefix) + "-record.txt").open("w") as log:
                instruments = ["--instrument", "Metal Performance Overview", "--instrument", "Points of Interest"]
                if args.time_profiler:
                    instruments += ["--instrument", "Time Profiler"]
                run(["xcrun", "xctrace", "record", *instruments, "--attach", str(pid), "--time-limit",
                     str(args.seconds) + "s", "--output", str(prefix) + ".trace"],
                    stdout=log, stderr=subprocess.STDOUT)
        command = ["/usr/bin/log", "show", "--last", "5m", "--style", "compact", "--predicate",
                   f'category == "ProfileTour" AND processIdentifier == {pid}']
        if args.simulator:
            command = ["xcrun", "simctl", "spawn", args.simulator, "log"] + command[1:]
        phase_log = run(command, capture_output=True).stdout
        Path(str(prefix) + "-phases.txt").write_text(phase_log)
        result = {"pid": pid, "preset": args.preset, "shape": args.shape, "workload": args.workload,
                  "simulator": args.simulator, "cpuSampling": args.time_profiler, "phases": counters(phase_log), "powerBefore": before,
                  "powerAfter": run(["pmset", "-g", "custom"], capture_output=True).stdout,
                  "batteryBefore": battery, "batteryAfter": run(["pmset", "-g", "batt"], capture_output=True).stdout,
                  "agentChangedPowerSettings": False, "trace": None if args.simulator else str(prefix) + ".trace"}
        diagnostic_command = ["/usr/bin/log", "show", "--last", "5m", "--style", "compact", "--predicate",
            f'processIdentifier == {pid} AND (eventMessage CONTAINS "Cut wall coverage" OR eventMessage CONTAINS "Pan tile upload failed" OR eventMessage CONTAINS "the cut wall")']
        if args.simulator:
            diagnostic_command = ["xcrun", "simctl", "spawn", args.simulator, "log"] + diagnostic_command[1:]
        diagnostics = run(diagnostic_command, capture_output=True).stdout
        Path(str(prefix) + "-wall-diagnostics.txt").write_text(diagnostics)
        result["wallCoverageFailures"] = sum("Cut wall coverage failed" in line for line in diagnostics.splitlines())
        result["meshUploadFailures"] = sum("Pan tile upload failed" in line or "Could not" in line for line in diagnostics.splitlines())
        executable_path = app / ("MaquetteDemo" if args.simulator else "Contents/MacOS/MaquetteDemo")
        result["executableSHA256"] = hashlib.sha256(executable_path.read_bytes()).hexdigest()
        result["powerProfilesUnchanged"] = result["powerBefore"] == result["powerAfter"]
        Path(str(prefix) + ".json").write_text(json.dumps(result, indent=2) + "\n")
        if not args.simulator:
            for schema, suffix in [("metal-perf-overview-layer-count-metric", "fps"),
                                   ("os-signpost", "signposts")]:
                run(["xcrun", "xctrace", "export", "--input", str(prefix) + ".trace", "--xpath",
                     '/trace-toc/run[@number="1"]/data/table[@schema="' + schema + '"]',
                     "--output", str(prefix) + "-" + suffix + ".xml"], capture_output=True)
        print(json.dumps({"output": str(prefix) + ".json", "completedPhases": len(result["phases"])}), flush=True)
    finally:
        if args.simulator:
            run(["xcrun", "simctl", "terminate", args.simulator, "com.maquette.MaquetteProfile"])
        else:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass


if __name__ == "__main__":
    main()
