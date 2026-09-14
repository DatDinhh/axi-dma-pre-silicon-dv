#!/usr/bin/env python3
"""Run isolated AXI DMA simulations with a Linux Xcelium installation.

Only Python's standard library is used. --dry-run never executes a simulator.
Real Xcelium execution must be validated on the licensed host; fixture tests
exercise this runner's process/failure handling, not HDL simulation.
"""
import argparse
import csv
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
NORMAL_TESTS = (
    "smoke_test", "copy_test", "len_zero_test", "unaligned_addr_test",
    "out_of_range_test", "csr_access_test", "descriptor_corner_test", "irq_test",
    "busy_start_test", "reset_mid_transfer_test", "seeded_copy_test",
)
ERROR_TESTS = {"read_error_test": "+AXI_RERR_ADDR=100",
               "write_error_test": "+AXI_BERR_ADDR=8000"}
PROBES = ("uvm_probe", "constrained_random_probe", "covergroup_probe", "assertion_probe")
SNAPSHOT_ROOTS = ("filelist.f", "run_regression.ps1", "rtl", "tb", "scripts")


def utcnow():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def source_files(root):
    """Whitelist repository inputs; never include output, git, or private files."""
    files = []
    for name in SNAPSHOT_ROOTS:
        item = root / name
        if not item.exists():
            raise ValueError("Missing project input: " + name)
        candidates = item.rglob("*") if item.is_dir() else (item,)
        for candidate in candidates:
            if candidate.is_symlink():
                raise ValueError("Source symlinks are not accepted: " + str(candidate))
            if candidate.is_file() and "__pycache__" not in candidate.parts and candidate.suffix != ".pyc":
                candidate.resolve().relative_to(root.resolve())
                files.append(candidate)
    return sorted(files, key=lambda path: path.relative_to(root).as_posix())


def snapshot_sources(root, output):
    snapshot = output / "source"
    entries = []
    for original in source_files(root):
        relative = original.relative_to(root)
        frozen = snapshot / relative
        frozen.parent.mkdir(parents=True, exist_ok=True)
        # Hash the exact bytes copied, including uncommitted edits.
        frozen.write_bytes(original.read_bytes())
        entries.append({"Path": relative.as_posix(), "Sha256": sha256(frozen)})
    return snapshot, entries


def resolved_hdl(snapshot):
    paths = []
    for line in (snapshot / "filelist.f").read_text(encoding="utf-8-sig").splitlines():
        name = line.strip()
        if not name or name.startswith(("#", "//")):
            continue
        if name.startswith(("-", "+")) or Path(name).is_absolute():
            raise ValueError("filelist.f must contain project-relative HDL files only: " + name)
        path = (snapshot / name).resolve()
        path.relative_to(snapshot.resolve())
        if not path.is_file():
            raise ValueError("Missing HDL input: " + name)
        if any(char in str(path) for char in ('"', "\n", "\r")):
            raise ValueError("Unsupported quote/newline in HDL path")
        paths.append(path)
    return paths


def run_process(command, directory, log_path, timeout):
    start = time.monotonic()
    timed_out = False
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(command, cwd=directory, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=(os.name == "posix"))
        try:
            exit_code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            if os.name == "posix":
                # Kill the whole compilation/simulation process group, not just xrun.
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
            exit_code = process.wait()
    return {"ExitCode": exit_code, "TimedOut": timed_out,
            "RuntimeSeconds": round(time.monotonic() - start, 3)}


def failure_reason(text, process, marker, require_uvm=True):
    if process["TimedOut"]:
        return "Wall-clock timeout; simulator process group was terminated."
    if process["ExitCode"] != 0:
        return "Simulator returned nonzero exit code %s." % process["ExitCode"]
    if re.search(r"(?im)(?:\*\s*[EF],|^\s*(?:FATAL|ERROR)\s*:|segmentation fault|SIGSEGV|"
                 r"internal (?:error|fatal)|assertion[^\n]*(?:\bfailed\b|\bviolation\b)|assertion\s+failure\b|"
                 r"PROBE_FEATURE_INACTIVE)", text):
        return "Simulator reported an error, assertion violation, crash, or inactive feature."
    if re.search(r"(?im)^\s*UVM_(?:ERROR|FATAL)\s+(?!:\s*0\s*$)\S", text):
        return "UVM reported an error or fatal."
    if re.search(r"UVM_(?:ERROR|FATAL)\s*:\s*[1-9]", text):
        return "UVM summary contains errors or fatals."
    if require_uvm and any(not re.search(r"UVM_%s\s*:\s*0\b" % severity, text)
                           for severity in ("ERROR", "FATAL")):
        return "Clean UVM report summary is missing."
    if not re.search(r"\b" + re.escape(marker) + r"(?:\.|\s|$)", text):
        return "Required completion marker '%s' is missing." % marker
    return ""


def validate_coverage(path, expected_bins):
    if not path.is_file():
        return "Observed-requirement coverage TSV is missing."
    try:
        with path.open(encoding="utf-8-sig", newline="") as stream:
            reader = csv.DictReader(stream, delimiter="\t")
            if reader.fieldnames != ["bin", "hits"]:
                return "Coverage TSV header must be bin<TAB>hits."
            seen = set()
            for row in reader:
                if set(row) != {"bin", "hits"}:
                    return "Coverage TSV row has extra or missing columns."
                name, hits = row["bin"], row["hits"]
                if name in seen or name not in expected_bins or not re.fullmatch(r"\d+", hits or ""):
                    return "Coverage TSV has a duplicate/unknown bin or invalid hit count."
                seen.add(name)
            if seen != expected_bins:
                return "Coverage TSV is missing catalog bins."
    except (OSError, UnicodeError, csv.Error, KeyError, TypeError) as error:
        return "Invalid coverage TSV: " + str(error)
    return ""


def save_report(report, directory):
    write_json(directory / "summary.json", report)
    results = report["Results"]
    suite = ET.Element("testsuite", name=report["Mode"], tests=str(len(results)),
                       failures=str(sum(row["Result"] == "FAIL" for row in results)),
                       skipped=str(sum(row["Result"] == "NOT_RUN" for row in results)))
    for row in results:
        case = ET.SubElement(suite, "testcase", name=row["Test"] + ".seed_" + str(row["Seed"]),
                             classname=report["Mode"], time=str(row.get("RuntimeSeconds", 0)))
        if row["Result"] == "FAIL":
            ET.SubElement(case, "failure", message=row["Reason"]).text = row["LogPath"]
        elif row["Result"] == "NOT_RUN":
            ET.SubElement(case, "skipped", message="Dry run: simulator was not executed.")
        ET.SubElement(case, "system-out").text = "Log: " + row["LogPath"]
    ET.ElementTree(suite).write(directory / "junit.xml", encoding="utf-8", xml_declaration=True)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xrun", default="xrun", help="Executable or absolute path to xrun")
    parser.add_argument("--uvmhome", default="CDNS-1.2", help="Cadence UVM selection (default CDNS-1.2)")
    parser.add_argument("--tests", nargs="+", choices=NORMAL_TESTS + tuple(ERROR_TESTS))
    parser.add_argument("--seeds", nargs="+", type=int, default=[1, 7, 42])
    parser.add_argument("--timeout", type=int, default=600, help="Seconds per compile-and-run (default 600)")
    parser.add_argument("--output", type=Path, help="New output directory; existing directory is rejected")
    parser.add_argument("--dry-run", action="store_true", help="Freeze inputs and write commands without running xrun")
    parser.add_argument("--probe-capabilities", action="store_true", help="Run only the four runtime feature probes")
    parser.add_argument("--waves", action="store_true", help="Record SHM signals for each test (larger outputs)")
    args = parser.parse_args(argv)
    if not 1 <= args.timeout <= 86400:
        parser.error("--timeout must be between 1 and 86400 seconds")
    if len(set(args.seeds)) != len(args.seeds) or any(seed < 1 or seed > 2147483647 for seed in args.seeds):
        parser.error("Seeds must be unique integers in [1, 2147483647]")
    if args.tests and len(set(args.tests)) != len(args.tests):
        parser.error("Tests must be unique")
    if args.probe_capabilities and args.tests:
        parser.error("--tests cannot be combined with --probe-capabilities")
    return args


def main(argv=None):
    args = parse_args(argv)
    run_id = "xcelium_" + uuid.uuid4().hex[:12]
    output = (args.output or ROOT / "output" / run_id).resolve()
    report = None
    try:
        if output.exists():
            raise ValueError("Output already exists; choose a new directory to preserve evidence: " + str(output))
        if os.name != "posix" and not args.dry_run:
            raise ValueError("Execute real Xcelium runs in Linux on a licensed host.")
        executable = shutil.which(args.xrun) if not args.dry_run else args.xrun
        if not executable:
            raise ValueError("xrun was not found. Load the Cadence environment in this terminal or supply --xrun.")
        output.mkdir(parents=True)
        snapshot, hashes = snapshot_sources(ROOT, output)
        manifest_path = output / "source_manifest.json"
        manifest = {"GitRevision": "unavailable", "GitDirty": None, "SnapshotDirectory": str(snapshot),
                    "Sources": hashes, "UvmSourceDirectory": args.uvmhome, "UvmSources": [],
                    "UvmProvenance": "Cadence bundled UVM selected by -uvmhome; exact release recorded by xrun log. Vendor sources are not redistributed."}
        write_json(manifest_path, manifest)
        catalog = json.loads((snapshot / "tb/coverage/coverage_requirements.json").read_text(encoding="utf-8-sig"))
        expected_bins = {row["id"] for row in catalog["bins"]}
        source_list = output / "sources.f"
        source_list.write_text("".join('"' + str(path) + '"\n' for path in resolved_hdl(snapshot)), encoding="utf-8")
        report = {"SchemaVersion": 1, "Mode": "xcelium-capability-probes" if args.probe_capabilities else "xcelium-portfolio-suite",
                  "RunId": run_id, "StartedUtc": utcnow(), "CompletedUtc": None, "GitRevision": "unavailable", "GitDirty": None,
                  "ToolVersion": "NOT_RUN" if args.dry_run else "unavailable", "XrunPath": str(executable), "UvmPath": args.uvmhome,
                  "CoverageEnabled": True, "SvaEnabled": True, "UvmNoDpiEnabled": False, "DryRun": args.dry_run,
                  "RuntimeValidation": "NOT_RUN" if args.dry_run else "ATTEMPTED", "OutputDirectory": str(output),
                  "SourceManifestPath": str(manifest_path), "SourceManifestSha256": sha256(manifest_path),
                  "UvmProvenance": manifest["UvmProvenance"],
                  "Seeds": [1] if args.probe_capabilities else args.seeds, "TimeoutSeconds": args.timeout, "Results": []}
        print("Output: " + str(output), flush=True)
        if not args.dry_run:
            version_log = output / "version.log"
            version_result = run_process([str(executable), "-version"], output, version_log, 30)
            if version_result["TimedOut"] or version_result["ExitCode"] != 0:
                raise ValueError("xrun -version failed; see " + str(version_log))
            report["ToolVersion"] = version_log.read_text(encoding="utf-8", errors="replace").strip()
            manifest["UvmProvenance"] = "Cadence bundled UVM selection %s; xrun version: %s. Actual UVM banner remains in each simulation log; vendor sources are not redistributed." % (args.uvmhome, report["ToolVersion"])
            report["UvmProvenance"] = manifest["UvmProvenance"]
            write_json(manifest_path, manifest)
            report["SourceManifestSha256"] = sha256(manifest_path)
        names = PROBES if args.probe_capabilities else args.tests or NORMAL_TESTS + tuple(ERROR_TESTS)
        report["Tests"] = list(names)
        for name in names:
            for seed in report["Seeds"]:
                directory = output / (name + "_seed_" + str(seed))
                directory.mkdir()
                coverage_path = directory / "coverage.tsv"
                native_directory = directory / "native_coverage"
                log_path = directory / "simulation.log"
                tcl = directory / "run.tcl"
                tcl.write_text(("database -open waves -into waves.shm -default\nprobe -create tb_top -all -depth all -database waves\n"
                                if args.waves and not args.probe_capabilities else "") + "run\nexit\n", encoding="utf-8")
                plusargs = ["+UVM_NO_RELNOTES"]
                if not args.probe_capabilities:
                    plusargs += ["+UVM_TESTNAME=" + name, "+TEST_SEED=" + str(seed), "+AXI_STALL_SEED=" + str(seed),
                                 "+AXI_AW_WAIT_W=1", "+AXI_STALL_MAX=7", "+COVERAGE_FILE=" + str(coverage_path)]
                    if name in ERROR_TESTS:
                        plusargs.append(ERROR_TESTS[name])
                command = [str(executable), "-64bit", "-sv", "-uvm", "-uvmhome", args.uvmhome,
                           "+define+ENABLE_SVA", "+define+ENABLE_SV_COV", "-coverage", "all",
                           "-covworkdir", str(native_directory), "-covtest", name + "_seed_" + str(seed),
                           "-svseed", str(seed), "-top", name if args.probe_capabilities else "tb_top",
                           "-input", str(tcl), "-l", "xrun.log"]
                if args.waves:
                    command += ["-access", "+rwc"]
                command += ([str(snapshot / "scripts/probes" / (name + ".sv"))] if args.probe_capabilities
                            else ["-f", str(source_list)])
                command += plusargs
                write_json(directory / "command.json", command)
                (directory / "command.sh").write_text("#!/bin/sh\ncd " + shlex.quote(str(directory)) + "\nexec " + " ".join(map(shlex.quote, command)) + "\n", encoding="utf-8")
                row = {"Test": name, "Seed": seed, "PlusArgs": plusargs, "Result": "NOT_RUN", "Reason": "Dry run; no simulation executed.",
                       "ExitCode": None, "TimedOut": False, "RuntimeSeconds": 0, "LogPath": str(log_path),
                       "CoveragePath": None if args.probe_capabilities else str(coverage_path),
                       "NativeCoverageDirectory": str(native_directory), "NativeCoverageFiles": [],
                       "SourceManifestPath": str(manifest_path), "SourceManifestSha256": report["SourceManifestSha256"]}
                if not args.dry_run:
                    row.update(run_process(command, directory, log_path, args.timeout))
                    text = log_path.read_text(encoding="utf-8", errors="replace")
                    # Some site wrappers redirect diagnostics exclusively to xrun.log.
                    if (directory / "xrun.log").is_file():
                        text += "\n" + (directory / "xrun.log").read_text(encoding="utf-8", errors="replace")
                    reason = failure_reason(text, row, name + " PASSED", not args.probe_capabilities or name == "uvm_probe")
                    if not reason and not args.probe_capabilities:
                        reason = validate_coverage(coverage_path, expected_bins)
                    native_files = sorted(path for path in native_directory.rglob("*.ucd") if path.is_file() and path.stat().st_size)
                    row["NativeCoverageFiles"] = [str(path) for path in native_files]
                    if not reason and not args.probe_capabilities and not native_files:
                        reason = "Native coverage was requested but no nonempty .ucd database was produced."
                    row["Reason"] = reason
                    row["Result"] = "FAIL" if reason else "PASS"
                write_json(directory / "result.json", row)
                report["Results"].append(row)
                save_report(report, output)
                print("%s seed=%s: %s %s" % (name, seed, row["Result"], row["Reason"]), flush=True)
        report["CompletedUtc"] = utcnow()
        report["RuntimeValidation"] = "NOT_RUN" if args.dry_run else ("PASS" if all(row["Result"] == "PASS" for row in report["Results"]) else "FAIL")
        save_report(report, output)
        return 3 if any(row["Result"] == "FAIL" for row in report["Results"]) else 0
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
        print("SETUP ERROR: " + str(error), file=sys.stderr)
        if report is not None:
            report["CompletedUtc"] = utcnow()
            report["SetupError"] = str(error)
            report["RuntimeValidation"] = "FAIL"
            report["Results"].append({"Test": "__setup__", "Seed": 0, "Result": "FAIL", "Reason": str(error),
                                      "ExitCode": 1, "TimedOut": False, "RuntimeSeconds": 0,
                                      "LogPath": str(output / "version.log")})
            save_report(report, output)
        return 1


if __name__ == "__main__":
    sys.exit(main())
