#!/usr/bin/env python3
"""Run actual DMA RTL with local Verilator SVA/code coverage; no UVM license needed.

Invoke from Windows using: wsl -d Ubuntu -- python3 -B scripts/run_local_verilator.py
Native covergroups and the ModelSim UVM regression are separate evidence lanes.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET
from local_coverage import summarize, write_summary

ROOT = Path(__file__).resolve().parent.parent
CASES = ("csr", "lengths", "boundaries", "invalid_zero", "invalid_src_align",
         "invalid_dst_align", "invalid_len_align", "invalid_src_range", "invalid_dst_range",
         "invalid_overflow", "irq", "busy", "reset_ar", "reset_r", "reset_aw", "reset_w",
         "reset_b", "random", "read_errors", "write_errors")
COMMON = ("rtl/dma_pkg.sv", "rtl/dma_regs_axil.sv", "rtl/dma_engine_axi.sv", "rtl/top_soc_dut.sv",
          "tb/interfaces/axi_if.sv", "tb/interfaces/axil_if.sv", "tb/mem/mem_bkdr_if.sv",
          "tb/mem/axi_mem_model.sv", "tb/local/dma_local_checks.sv")
TOPS = {"dma_local_test": COMMON + ("tb/local/dma_local_test.sv",),
        "dma_local_checker_negative": ("tb/interfaces/axi_if.sv", "tb/interfaces/axil_if.sv",
             "tb/local/dma_local_checks.sv", "tb/local/dma_local_checker_negative.sv")}


def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def execute(command, cwd, logfile, timeout):
    started = time.monotonic()
    with Path(logfile).open("w", encoding="utf-8") as log:
        process = subprocess.Popen(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        timed_out = False
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(process.pid, signal.SIGKILL)
            code = process.wait()
    return {"Command": command, "ExitCode": code, "TimedOut": timed_out,
            "RuntimeSeconds": round(time.monotonic() - started, 3), "LogPath": str(logfile)}


def write_reports(report, output):
    save(output / "summary.json", report)
    rows = report["Results"] + report["CheckerSelfTests"]
    suite = ET.Element("testsuite", name="local-verilator", tests=str(len(rows)),
                       failures=str(sum(r["Result"] == "FAIL" for r in rows)))
    for row in rows:
        case = ET.SubElement(suite, "testcase", name=row["Test"] + ".seed_" + str(row.get("Seed", 0)),
                             classname=row.get("Kind", "DUT"), time=str(row["RuntimeSeconds"]))
        if row["Result"] == "FAIL":
            ET.SubElement(case, "failure", message=row["Reason"]).text = row["LogPath"]
    if report.get("SetupError"):
        case = ET.SubElement(suite, "testcase", name="infrastructure")
        ET.SubElement(case, "failure", message=report["SetupError"])
        suite.set("tests", str(len(rows) + 1))
        suite.set("failures", str(int(suite.get("failures")) + 1))
    ET.ElementTree(suite).write(output / "junit.xml", encoding="utf-8", xml_declaration=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", nargs="+", choices=CASES, default=list(CASES))
    parser.add_argument("--seeds", nargs="+", type=int, default=[1, 7, 42])
    parser.add_argument("--count", type=int, default=128, help="Descriptors in each random case")
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--build-timeout", type=int, default=300)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args(argv)
    if os.name != "posix":
        parser.error("Run this lane in Linux/WSL using the installed Verilator.")
    if len(set(args.cases)) != len(args.cases) or len(set(args.seeds)) != len(args.seeds):
        parser.error("Duplicate case/seed selections are not accepted.")
    if not args.seeds or any(seed < 1 or seed > 2147483647 for seed in args.seeds):
        parser.error("Seeds must be in 1..2147483647.")
    if not (1 <= args.count <= 10000 and 1 <= args.timeout <= 3600 and
            1 <= args.build_timeout <= 1800 and 1 <= args.jobs <= 8):
        parser.error("Invalid descriptor count, timeout or build job count.")
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    run_id = "local-verilator-" + uuid.uuid4().hex[:12]
    output = ROOT / "output" / run_id
    output.mkdir(parents=True)
    report = {"SchemaVersion": 1, "Mode": "local-verilator-dut", "RunId": run_id,
              "StartedUtc": utc(), "CompletedUtc": None, "Status": "RUNNING", "Tests": args.cases,
              "Seeds": args.seeds, "RandomDescriptorsPerCase": args.count, "OutputDirectory": str(output),
              "ConcurrentSvaEnabled": True, "NativeCodeCoverageEnabled": True,
              "NativeCovergroupsEnabled": False, "UvmExecution": False,
              "Builds": [], "Results": [], "CheckerSelfTests": [], "Coverage": None}
    print("Output: " + str(output), flush=True)
    try:
        version = subprocess.run(["verilator", "--version"], capture_output=True, text=True, check=True)
        report["ToolVersion"] = version.stdout.strip()
        print(report["ToolVersion"], flush=True)
        if not shutil.which("verilator_coverage"):
            raise ValueError("verilator_coverage is missing")
        snapshot = output / "source"
        inputs = set(path for group in TOPS.values() for path in group)
        inputs.update(("scripts/run_local_verilator.py", "scripts/local_coverage.py"))
        sources = []
        for name in sorted(inputs):
            original = ROOT / name
            if not original.is_file() or original.is_symlink():
                raise ValueError("Missing/unsupported source input: " + name)
            target = snapshot / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(original.read_bytes())
            sources.append({"Path": name, "Sha256": sha(target)})
        mains = {}
        for top in TOPS:
            target = snapshot / "generated" / (top + "_main.cpp")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('''#include "V%s.h"
#include "verilated.h"
#include "verilated_cov.h"
#include <memory>
int main(int argc, char** argv) {
    const auto context = std::make_unique<VerilatedContext>();
    context->commandArgs(argc, argv);
    const auto top = std::make_unique<V%s>(context.get());
    while (!context->gotFinish()) {
        top->eval();
        if (!top->eventsPending()) break;
        context->time(top->nextTimeSlot());
    }
    top->final();
    context->coveragep()->write("coverage.dat");
    return context->gotFinish() ? 0 : 1;
}
''' % (top, top), encoding="utf-8")
            mains[top] = target
            sources.append({"Path": target.relative_to(snapshot).as_posix(), "Sha256": sha(target)})
        coverage_config = snapshot / "generated" / "coverage_scope.vlt"
        coverage_config.write_text('`verilator_config\n' + ''.join(
            'coverage_off -file "' + str(snapshot / pattern) + '"\n' for pattern in
            ('tb/interfaces/*', 'tb/mem/*', 'tb/local/dma_local_test.sv', 'tb/local/dma_local_checker_negative.sv')),
            encoding="utf-8")
        sources.append({"Path": coverage_config.relative_to(snapshot).as_posix(), "Sha256": sha(coverage_config)})
        manifest = output / "source_manifest.json"
        save(manifest, {"SnapshotDirectory": str(snapshot), "Sources": sources})
        report["SourceManifestPath"] = str(manifest)
        report["SourceManifestSha256"] = sha(manifest)
        binaries = {}
        for top, hdl in TOPS.items():
            build = output / ("build_" + top)
            command = ["verilator", "--cc", "--exe", "--timing", "--assert",
                       "--coverage-line", "--coverage-toggle", "--coverage-user", "+define+DMA_RAW_INTERFACES", "-Wall", "-Wno-fatal",
                       "--top-module", top, "--Mdir", str(build), "-j", str(args.jobs)]
            command += [str(coverage_config)] + [str(snapshot / name) for name in hdl] + [str(mains[top])]
            result = execute(command, output, output / (top + "_build.log"), args.build_timeout)
            result["Top"] = top
            build_text = Path(result["LogPath"]).read_text(errors="replace")
            result["WarningCategories"] = sorted(set(re.findall(r"%Warning-([A-Z0-9_]+):", build_text)))
            report["Builds"].append(result)
            write_reports(report, output)
            if result["ExitCode"] != 0 or result["TimedOut"]:
                raise ValueError("Build failed: " + result["LogPath"])
            if re.search(r"%Warning-(?:LATCH|MULTIDRIVEN|UNOPTFLAT):[^\n]*/rtl/", build_text):
                raise ValueError("Structural RTL warning needs review: " + result["LogPath"])
            native = execute(["make", "-C", str(build), "-f", "V" + top + ".mk", "-j", str(args.jobs),
                              "OPT_FAST=-O0", "OPT_SLOW=-O0"], output,
                             output / (top + "_native_build.log"), args.build_timeout)
            result["NativeCompile"] = native
            if native["ExitCode"] != 0 or native["TimedOut"]:
                raise ValueError("C++ build failed: " + native["LogPath"])
            binaries[top] = build / ("V" + top)
            result["BinarySha256"] = sha(binaries[top])
            print("BUILD PASS: " + top, flush=True)
        for negative in (0, 1):
            directory = output / ("checker_negative" if negative else "checker_control")
            directory.mkdir()
            row = execute([str(binaries["dma_local_checker_negative"]), "+NEGATIVE=" + str(negative)],
                          directory, directory / "simulation.log", args.timeout)
            text = Path(row["LogPath"]).read_text(errors="replace")
            detected = (not row["TimedOut"] and row["ExitCode"] in (-signal.SIGABRT, 134) and "LOCAL_SVA_HOLD" in text)
            clean = (not row["TimedOut"] and row["ExitCode"] == 0 and "LOCAL_CHECKER_CONTROL_PASS" in text
                     and "%Error" not in text)
            okay = detected if negative else clean
            row.update({"Test": directory.name, "Kind": "assertion_self_test", "Seed": 0,
                        "Result": ("PASS_EXPECTED_DETECTION" if negative else "PASS") if okay else "FAIL",
                        "Reason": "" if okay else "Assertion checker did not meet its expected outcome."})
            report["CheckerSelfTests"].append(row)
            print(row["Test"] + ": " + row["Result"], flush=True)
        directory = output / "oracle_negative"
        directory.mkdir()
        row = execute([str(binaries["dma_local_test"]), "+LOCAL_CASE=csr", "+LOCAL_ORACLE_NEGATIVE=1"],
                      directory, directory / "simulation.log", args.timeout)
        text = Path(row["LogPath"]).read_text(errors="replace")
        detected = not row["TimedOut"] and row["ExitCode"] in (-signal.SIGABRT, 134) and "ORACLE_MEMORY" in text
        row.update({"Test": "oracle_negative", "Kind": "oracle_self_test", "Seed": 0,
                    "Result": "PASS_EXPECTED_DETECTION" if detected else "FAIL",
                    "Reason": "" if detected else "Independent memory oracle did not detect injected guard corruption."})
        report["CheckerSelfTests"].append(row)
        print(row["Test"] + ": " + row["Result"], flush=True)
        for case in args.cases:
            for seed in args.seeds:
                directory = output / (case + "_seed_" + str(seed))
                directory.mkdir()
                plusargs = ["+LOCAL_CASE=" + case, "+TEST_SEED=" + str(seed), "+AXI_STALL_SEED=" + str(seed),
                            "+AXI_AW_WAIT_W=1", "+AXI_STALL_MAX=7", "+TRANSFER_COUNT=" + str(args.count)]
                if case == "read_errors":
                    plusargs.append("+AXI_RERR_ADDR=100")
                if case == "write_errors":
                    plusargs.append("+AXI_BERR_ADDR=8000")
                row = execute([str(binaries["dma_local_test"])] + plusargs, directory,
                              directory / "simulation.log", args.timeout)
                text = Path(row["LogPath"]).read_text(errors="replace")
                cov = directory / "coverage.dat"
                okay = (not row["TimedOut"] and row["ExitCode"] == 0 and
                        ("LOCAL_TEST_PASS " + case) in text and "%Error" not in text and
                        cov.is_file() and cov.stat().st_size > 0)
                row.update({"Test": case, "Kind": "DUT", "Seed": seed, "PlusArgs": plusargs,
                            "CoveragePath": str(cov), "Result": "PASS" if okay else "FAIL",
                            "Reason": "" if okay else "Simulation, completion marker or coverage export failed."})
                if cov.is_file():
                    row["CoverageSha256"] = sha(cov)
                report["Results"].append(row)
                save(directory / "result.json", row)
                write_reports(report, output)
                print(case + " seed=" + str(seed) + ": " + row["Result"], flush=True)
        if any(row["Result"] == "FAIL" for row in report["Results"] + report["CheckerSelfTests"]):
            raise ValueError("Failed cases are preserved; coverage is not merged from a failing campaign.")
        for entry in sources:
            if sha(snapshot / entry["Path"]) != entry["Sha256"]:
                raise ValueError("Frozen source changed during execution")
        for row in report["Results"]:
            if sha(row["CoveragePath"]) != row["CoverageSha256"]:
                raise ValueError("Coverage input changed during execution")
        coverage = output / "coverage"
        coverage.mkdir()
        inputs = [row["CoveragePath"] for row in report["Results"]]
        merged = coverage / "merged.dat"
        for tag, command in (("merge", ["verilator_coverage", "--write", str(merged)] + inputs),
                             ("lcov", ["verilator_coverage", "--write-info", str(coverage / "coverage.info"), str(merged)]),
                             ("annotate", ["verilator_coverage", "--annotate", str(coverage / "annotated"), "--annotate-min", "1", str(merged)])):
            result = execute(command, output, coverage / (tag + ".log"), 60)
            if result["ExitCode"] != 0 or result["TimedOut"]:
                raise ValueError("Native coverage postprocessing failed: " + result["LogPath"])
        measured = summarize(merged, snapshot)
        if not measured["AssertionActivationPoints"]:
            raise ValueError("No native concurrent cover-property activation was exported")
        measured["SourceManifestSha256"] = report["SourceManifestSha256"]
        measured["MergedNativeSha256"] = sha(merged)
        measured["PassingDutRuns"] = len(report["Results"])
        measured["AnalysisScriptSha256"] = sha(snapshot / "scripts/local_coverage.py")
        write_summary(measured, coverage)
        report["Coverage"] = {"ReportPath": str(coverage / "code_coverage.json"), "Totals": measured["Totals"]}
        report["Status"] = "PASS"
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        report["SetupError"] = str(error)
        report["Status"] = "FAIL"
        print("FAIL: " + str(error), file=sys.stderr, flush=True)
    report["CompletedUtc"] = utc()
    write_reports(report, output)
    print("Local Verilator: " + report["Status"] + " -> " + str(output), flush=True)
    return 0 if report["Status"] == "PASS" else 3


if __name__ == "__main__":
    sys.exit(main())
