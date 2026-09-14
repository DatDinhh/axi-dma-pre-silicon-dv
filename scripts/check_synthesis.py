#!/usr/bin/env python3
"""Bounded Quartus Analysis & Synthesis on an exact snapshot of baseline RTL.

This is a structural/synthesis sanity check, not fitting, timing signoff, a
resource estimate for another target, or a formal correctness proof.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
import uuid


RTL = ["rtl/dma_pkg.sv", "rtl/dma_regs_axil.sv", "rtl/dma_engine_axi.sv", "rtl/top_soc_dut.sv"]


def discover_quartus_map() -> str | None:
    """Resolve the installed tool from PATH or the standard Quartus environment."""
    executable = shutil.which("quartus_map")
    if executable:
        return executable
    for variable in ("QUARTUS_ROOTDIR", "QUARTUS_ROOTDIR_OVERRIDE"):
        install_root = os.environ.get(variable)
        if not install_root:
            continue
        for directory in ("bin64", "bin"):
            for name in ("quartus_map.exe", "quartus_map"):
                candidate = Path(install_root) / directory / name
                if candidate.is_file():
                    return str(candidate)
    return None


def run(command: list[str], cwd: Path, log: Path, timeout: int) -> dict:
    started = datetime.now(timezone.utc)
    with log.open("w", encoding="utf-8") as stream:
        process = subprocess.Popen(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT,
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        timed_out = False
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                               capture_output=True, creationflags=subprocess.CREATE_NO_WINDOW)
            else:
                process.kill()
            process.wait()
    return {"command": command, "exit_code": process.returncode, "timed_out": timed_out,
            "seconds": (datetime.now(timezone.utc) - started).total_seconds(), "log": log.name}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quartus-map", default=discover_quartus_map(),
                        help="Executable path (default: PATH, QUARTUS_ROOTDIR or QUARTUS_ROOTDIR_OVERRIDE)")
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--part", default="5CSEMA5F31C6")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.timeout < 1 or not 1 <= args.jobs <= 2:
        parser.error("timeout must be positive and jobs must be 1 or 2")
    root = Path(__file__).resolve().parents[1]
    started_utc = datetime.now(timezone.utc).isoformat()
    output = (args.output or root / "out" / f"synthesis_{uuid.uuid4().hex[:12]}").resolve()
    output.mkdir(parents=True, exist_ok=False)
    summary = {"schema_version": 1, "result": "FAIL", "started_utc": started_utc,
               "tool": "Quartus Prime Analysis & Synthesis", "part": args.part,
               "scope": "exact-source synthesis sanity; no fitting, timing signoff or formal proof",
               "sources": [], "runs": []}
    try:
        source = output / "source"
        for name in RTL + ["scripts/check_synthesis.py"]:
            original = root / name
            target = source / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original, target)
            summary["sources"].append({"path": name, "sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
        if not args.quartus_map:
            raise FileNotFoundError("Quartus map was not found. Add it to PATH, set QUARTUS_ROOTDIR, or supply --quartus-map.")
        executable = shutil.which(args.quartus_map) or str(Path(args.quartus_map).resolve())
        if not Path(executable).is_file():
            raise FileNotFoundError(f"Quartus map executable not found: {executable}")
        version = run([executable, "--version"], output, output / "version.log", 30)
        summary["runs"].append(version)
        summary["version"] = (output / "version.log").read_text(encoding="utf-8", errors="replace").strip()
        if version["exit_code"] != 0 or version["timed_out"]:
            raise RuntimeError("Tool version check failed")
        (output / "synthesis_check.qpf").write_text('PROJECT_REVISION = "synthesis_check"\n', encoding="ascii")
        qsf = ['set_global_assignment -name FAMILY "Cyclone V"',
               f'set_global_assignment -name DEVICE {args.part}',
               'set_global_assignment -name TOP_LEVEL_ENTITY top_soc_dut',
               f'set_global_assignment -name NUM_PARALLEL_PROCESSORS {args.jobs}',
               'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY reports']
        for name in RTL:
            qsf.append(f'set_global_assignment -name SYSTEMVERILOG_FILE "source/{name}"')
        (output / "synthesis_check.qsf").write_text("\n".join(qsf) + "\n", encoding="ascii")
        mapped = run([executable, "synthesis_check", "--write_settings_files=off",
                      f"--parallel={args.jobs}"], output, output / "quartus_map.log", args.timeout)
        summary["runs"].append(mapped)
        log = (output / "quartus_map.log").read_text(encoding="utf-8", errors="replace")
        summary["warnings"] = [line.strip() for line in log.splitlines() if re.match(r"\s*(?:Critical )?Warning(?: \(|:)", line)]
        summary["errors"] = [line.strip() for line in log.splitlines() if re.match(r"\s*Error(?: \(|:)", line)]
        warning_counts = Counter(re.search(r"Warning \((\d+)\)", line).group(1)
                                 for line in summary["warnings"] if re.search(r"Warning \((\d+)\)", line))
        summary["warning_counts"] = dict(sorted(warning_counts.items()))
        summary["warning_interpretations"] = {
            "10762": "Wide CSR address case completeness cannot be checked by this compiler; review defaults in source.",
            "13024": "Constant output summary; examine child 13410 messages against supported protocol subset.",
            "13410": "Constant output bits; expected for fixed single-beat, ID-zero AXI sidebands and OKAY/SLVERR responses.",
            "21074": "Unused input summary; examine child 15610 messages against specification.",
            "15610": "Input has no influence on output; baseline ignores AXI-Lite protection and incoming AXI response IDs."
        }
        summary["unclassified_warning_codes"] = sorted(set(warning_counts) - set(summary["warning_interpretations"]))
        report = output / "reports" / "synthesis_check.map.rpt"
        summary["report"] = str(report.relative_to(output)) if report.exists() else None
        report_text = report.read_text(encoding="utf-8", errors="replace") if report.exists() else ""
        summary["resource_summary_lines"] = [line.strip() for line in report_text.splitlines()
                                             if re.match(r";\s*(?:Total (?:registers|logic|combinational|memory|block|DSP)|ALUTs|Estimate of Logic utilization|Combinational ALUT usage|Dedicated logic registers|Logic utilization|Family|Device)\s", line)]
        summary["resources"] = {}
        resource_names = {
            "estimated_alms": "Estimate of Logic utilization (ALMs needed)",
            "combinational_aluts": "Combinational ALUT usage for logic",
            "registers": "Dedicated logic registers",
            "block_memory_bits": "Total block memory bits",
            "dsp_blocks": "Total DSP Blocks"
        }
        for key, label in resource_names.items():
            match = re.search(r";\s*" + re.escape(label) + r"\s*;\s*(\d+)\s*;", report_text)
            if match:
                summary["resources"][key] = int(match.group(1))
        structural = []
        for line in (log + "\n" + report_text).splitlines():
            if re.search(r"(?:inferred.*latch|combinational loop|multiple (?:constant )?drivers|no driver|undriven)", line, re.I):
                if not re.search(r"(?:0 |no )(?:latches|combinational loops|multiple drivers)", line, re.I):
                    structural.append(line.strip())
        summary["structural_findings"] = sorted(set(structural))
        success = "Quartus Prime Analysis & Synthesis was successful" in log
        summary["result"] = "PASS" if mapped["exit_code"] == 0 and not mapped["timed_out"] and success and report.exists() and not summary["errors"] and not structural else "FAIL"
    except Exception as exc:
        summary["error"] = f"{type(exc).__name__}: {exc}"
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(f"Output: {output}")
    print(f"Synthesis sanity: {summary['result']}")
    print("No fitting, timing closure, or formal correctness is claimed.")
    return 0 if summary["result"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
