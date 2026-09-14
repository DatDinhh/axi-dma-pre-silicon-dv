#!/usr/bin/env python3
"""Audit native concurrent-assertion activation from a finished local campaign.

This is a separate evidence check; it neither reruns simulation nor changes its
frozen inputs. The output directory must be new. Recorded run paths are rebased
to the supplied summary directory, so an intact relocated result is supported.
"""
import argparse
from collections import Counter
import datetime as dt
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import sys

FULL_CASES = frozenset(("csr", "lengths", "boundaries", "invalid_zero",
    "invalid_src_align", "invalid_dst_align", "invalid_len_align", "invalid_src_range",
    "invalid_dst_range", "invalid_overflow", "irq", "busy", "reset_ar", "reset_r",
    "reset_aw", "reset_w", "reset_b", "random", "read_errors", "write_errors"))
CHANNELS = {"aw": "AXI.AW", "w": "AXI.W", "b": "AXI.B", "ar": "AXI.AR", "r": "AXI.R",
            "law": "AXIL.AW", "lw": "AXIL.W", "lb": "AXIL.B", "lar": "AXIL.AR", "lr": "AXIL.R"}
CHANNEL_PROPERTIES = ("c_handshake", "c_stall", "c_stall_release")
DIRECT_PROPERTIES = ("c_axi_aw_valid", "c_axi_w_valid", "c_axi_b_valid", "c_axi_ar_valid",
                     "c_axi_r_valid", "c_axil_b_valid", "c_axil_r_valid")
PREFIX = "TOP.dma_local_test.checks."
CHECKER_FILE = "tb/local/dma_local_checks.sv"
EXPECTED = frozenset([PREFIX + channel + "." + prop for channel in CHANNELS
                      for prop in CHANNEL_PROPERTIES] + [PREFIX + prop for prop in DIRECT_PROPERTIES])
SELF_TESTS = {"checker_control": ("assertion_self_test", "PASS", "LOCAL_CHECKER_CONTROL_PASS"),
              "checker_negative": ("assertion_self_test", "PASS_EXPECTED_DETECTION", "LOCAL_SVA_HOLD"),
              "oracle_negative": ("oracle_self_test", "PASS_EXPECTED_DETECTION", "ORACLE_MEMORY")}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def validate_campaign(report):
    """Pure validation of completion, exact declared matrix and self-test outcomes."""
    require(report.get("Mode") == "local-verilator-dut", "Unexpected campaign mode")
    require(report.get("Status") == "PASS" and report.get("CompletedUtc") and
            not report.get("SetupError"), "Campaign is not a finished PASS")
    require(report.get("ConcurrentSvaEnabled") is True, "Concurrent SVA was not enabled")
    tests, seeds = report.get("Tests", []), report.get("Seeds", [])
    require(tests and len(tests) == len(set(tests)) and set(tests) <= FULL_CASES,
            "Invalid or duplicate declared cases")
    require(seeds and len(seeds) == len(set(seeds)) and
            all(type(seed) is int and 1 <= seed <= 2147483647 for seed in seeds),
            "Invalid or duplicate declared seeds")
    expected = {(case, seed) for case in tests for seed in seeds}
    results = report.get("Results", [])
    actual = [(row.get("Test"), row.get("Seed")) for row in results]
    require(len(actual) == len(expected) and set(actual) == expected,
            "DUT results do not exactly match declared Tests x Seeds")
    for row in results:
        require(row.get("Kind") == "DUT" and row.get("Result") == "PASS" and
                row.get("ExitCode") == 0 and row.get("TimedOut") is False,
                "A declared DUT run did not pass cleanly")
    self_tests = report.get("CheckerSelfTests", [])
    require(len(self_tests) == len(SELF_TESTS) and
            {row.get("Test") for row in self_tests} == set(SELF_TESTS),
            "Missing, duplicate or unexpected self-test")
    for row in self_tests:
        kind, outcome, _ = SELF_TESTS[row["Test"]]
        exits = (0,) if outcome == "PASS" else (-6, 134)
        require(row.get("Kind") == kind and row.get("Result") == outcome and
                row.get("ExitCode") in exits and row.get("TimedOut") is False,
                "Invalid self-test outcome: " + row["Test"])
    builds = report.get("Builds", [])
    require(len(builds) == 2 and {row.get("Top") for row in builds} ==
            {"dma_local_test", "dma_local_checker_negative"}, "Unexpected build inventory")
    for row in builds:
        command = row.get("Command", [])
        require(row.get("ExitCode") == 0 and row.get("TimedOut") is False and
                all(flag in command for flag in ("--assert", "--coverage-user")),
                "Missing successful assertion/coverage build")
        if "NativeCompile" in row:
            require(row["NativeCompile"].get("ExitCode") == 0 and
                    row["NativeCompile"].get("TimedOut") is False, "Native compilation failed")
    return {"Partial": set(tests) != FULL_CASES,
            "DefaultSixtyRunMatrix": set(tests) == FULL_CASES and set(seeds) == {1, 7, 42},
            "DeclaredDutRuns": len(expected), "Tests": tests, "Seeds": seeds}


def validate_activation(points, partial=False):
    """Pure inventory/activity check. A partial matrix may legitimately have zeros."""
    by_name = {}
    for point in points:
        name = point.get("Hierarchy", "")
        require(name not in by_name, "Duplicate assertion activation hierarchy: " + name)
        require(point.get("File") == CHECKER_FILE and
                point.get("Page", "").startswith("v_user/"), "Unexpected activation source")
        require(point.get("Label") == name.rsplit(".", 1)[-1], "Activation label/hierarchy mismatch")
        require(type(point.get("Hits")) is int and point["Hits"] >= 0, "Invalid activation count")
        by_name[name] = point
    require(set(by_name) == EXPECTED,
            "Expected 37-point inventory mismatch; missing=" + str(sorted(EXPECTED - set(by_name))) +
            "; unexpected=" + str(sorted(set(by_name) - EXPECTED)))
    channels = []
    for instance, channel in CHANNELS.items():
        hits = {prop: by_name[PREFIX + instance + "." + prop]["Hits"] for prop in CHANNEL_PROPERTIES}
        require(hits["c_stall_release"] <= min(hits["c_stall"], hits["c_handshake"]),
                "Impossible stall-release count: " + channel)
        if not partial:
            require(hits["c_handshake"] > 0, "Full campaign has no handshake activation: " + channel)
        channels.append({"Channel": channel, "Assertion": PREFIX + instance + ".a_hold",
                         "Handshakes": hits["c_handshake"], "StallAntecedents": hits["c_stall"],
                         "StallReleases": hits["c_stall_release"],
                         "HoldStatus": "EXERCISED" if hits["c_stall"] else "NOT_EXERCISED"})
    if not partial:
        require(all(by_name[PREFIX + prop]["Hits"] > 0 for prop in DIRECT_PROPERTIES),
                "Full campaign has an unhit shape/response antecedent")
    return {"ExpectedNativePoints": len(EXPECTED), "ObservedNativePoints": len(by_name),
            "HitNativePoints": sum(point["Hits"] > 0 for point in points),
            "ChannelsWithHandshakes": sum(row["Handshakes"] > 0 for row in channels),
            "HoldAssertionsExercised": sum(row["HoldStatus"] == "EXERCISED" for row in channels),
            "Channels": channels,
            "ShapeAndResponseAntecedents": [{"Property": prop, "Hits": by_name[PREFIX + prop]["Hits"]}
                                           for prop in DIRECT_PROPERTIES]}


def rebase(value, declared_root, actual_root):
    recorded = PurePosixPath(str(value).replace("\\", "/"))
    relative = recorded.relative_to(PurePosixPath(str(declared_root).replace("\\", "/")))
    require(".." not in relative.parts, "Artifact path escapes recorded run directory")
    path = Path(actual_root).joinpath(*relative.parts).resolve()
    require(path.is_relative_to(Path(actual_root).resolve()), "Artifact path escapes actual run directory")
    return path


def native_activation(path, declared_snapshot):
    """Read only v_user records, preserving metadata for comparison with JSON."""
    points = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"C '(.*)' ([0-9]+)", line)
        require(match is not None, "Malformed native coverage record")
        fields = {}
        for encoded in match[1].split("\x01"):
            if not encoded:
                continue
            key, value = encoded.split("\x02", 1)
            require(key not in fields, "Duplicate native metadata field")
            fields[key] = value
        if not fields.get("page", "").startswith("v_user/"):
            continue
        relative = PurePosixPath(fields["f"]).relative_to(PurePosixPath(declared_snapshot)).as_posix()
        points.append({"File": relative, "Line": int(fields["l"]), "Column": fields.get("n", ""),
                       "Page": fields["page"], "Label": fields.get("o", ""),
                       "Hierarchy": fields.get("h", ""), "Hits": int(match[2])})
    return points


def audit(report_path):
    report_path = Path(report_path).resolve()
    report = read_json(report_path)
    matrix = validate_campaign(report)
    root, recorded_root = report_path.parent, report["OutputDirectory"]
    locate = lambda value: rebase(value, recorded_root, root)
    manifest_path = locate(report["SourceManifestPath"])
    require(sha(manifest_path) == report["SourceManifestSha256"], "Source manifest hash mismatch")
    manifest = read_json(manifest_path)
    declared_snapshot = manifest["SnapshotDirectory"]
    snapshot = locate(declared_snapshot)
    source_names = set()
    for source in manifest["Sources"]:
        name = source["Path"]
        relative = PurePosixPath(name)
        require(not relative.is_absolute() and ".." not in relative.parts and name not in source_names,
                "Invalid or duplicate source manifest path")
        source_names.add(name)
        path = snapshot.joinpath(*relative.parts).resolve()
        require(path.is_relative_to(snapshot) and sha(path) == source["Sha256"],
                "Frozen source hash mismatch: " + name)
    require(CHECKER_FILE in source_names, "Checker missing from source manifest")
    coverage_path = locate(report["Coverage"]["ReportPath"])
    coverage = read_json(coverage_path)
    require(coverage["SourceManifestSha256"] == report["SourceManifestSha256"],
            "Coverage/report source manifest mismatch")
    require(coverage["PassingDutRuns"] == matrix["DeclaredDutRuns"], "Coverage run count mismatch")
    merged = coverage_path.parent / "merged.dat"
    require(sha(merged) == coverage["MergedNativeSha256"], "Merged native coverage hash mismatch")
    points = native_activation(merged, declared_snapshot)
    activation = validate_activation(points, matrix["Partial"])
    order = lambda rows: sorted(rows, key=lambda row: row["Hierarchy"])
    require(order(points) == order(coverage["AssertionActivationPoints"]),
            "Native activation data differs from code_coverage.json")
    summed = Counter()
    for row in report["Results"]:
        log = locate(row["LogPath"]).read_text(errors="replace")
        require(re.search(r"^LOCAL_TEST_PASS " + re.escape(row["Test"]) + r"\s*$", log, re.MULTILINE)
                and "%Error" not in log and "%Fatal" not in log, "DUT log does not confirm PASS")
        source_cov = locate(row["CoveragePath"])
        require(sha(source_cov) == row["CoverageSha256"], "Per-run native coverage hash mismatch")
        run_points = native_activation(source_cov, declared_snapshot)
        validate_activation(run_points, partial=True)
        summed.update({point["Hierarchy"]: point["Hits"] for point in run_points})
    require(dict(summed) == {point["Hierarchy"]: point["Hits"] for point in points},
            "Merged activation is not the sum of declared passing DUT runs")
    for row in report["CheckerSelfTests"]:
        log = locate(row["LogPath"]).read_text(errors="replace")
        marker = SELF_TESTS[row["Test"]][2]
        require(marker in log, "Self-test log missing detection/completion marker")
        if row["Test"] == "checker_control":
            require("%Error" not in log and "%Fatal" not in log, "Clean control contains an error")
        else:
            require("%Error" in log and "LOCAL_TEST_PASS" not in log,
                    "Negative self-test did not fail as expected")
    return {"SchemaVersion": 1, "Status": "PASS", "RunId": report["RunId"],
            "Metric": "native_concurrent_assertion_activation_audit", **matrix, **activation,
            "ReportPath": str(report_path), "ReportSha256": sha(report_path),
            "SourceManifestSha256": sha(manifest_path), "MergedNativeSha256": sha(merged),
            "CodeCoverageJsonSha256": sha(coverage_path), "AuditScriptSha256": sha(__file__),
            "Verified": ["Finished declared matrix and clean DUT outcomes", "Assertion and oracle self-tests",
                         "Frozen source hashes", "Native/JSON activation agreement",
                         "37-point inventory", "Sum of passing DUT coverage inputs only"],
            "Limitations": ["PASS means this evidence audit passed; it does not mean every hold assertion was exercised.",
                "EXERCISED means a stalled-cycle antecedent was observed in a passing simulation.",
                "A reset can cancel a pending hold obligation; stall-release counts provide additional completed-sequence evidence.",
                "NOT_EXERCISED is retained explicitly; no unhit points are excluded from reported counts.",
                "Two-state simulation does not verify X/Z behavior and is not formal proof or native covergroup closure."]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        args.output.mkdir(parents=True, exist_ok=False)
    except OSError as error:
        parser.error("Output must be a new directory: " + str(error))
    try:
        result = audit(args.report)
    except (OSError, ValueError, KeyError, TypeError) as error:
        result = {"SchemaVersion": 1, "Status": "FAIL", "Reason": str(error),
                  "ReportPath": str(args.report), "AuditScriptSha256": sha(__file__)}
    result["CompletedUtc"] = dt.datetime.now(dt.timezone.utc).isoformat()
    (args.output / "sva_activation.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    if result["Status"] == "PASS":
        rows = ["# Concurrent SVA activation audit", "", "Audit: PASS. Partial case selection: " + str(result["Partial"]),
                "", "%d/%d native points have hits; %d/10 hold antecedents were exercised." %
                (result["HitNativePoints"], result["ObservedNativePoints"], result["HoldAssertionsExercised"]),
                "", "| Channel | Handshakes | Stall antecedents | Stall releases | Hold assertion |",
                "| --- | ---: | ---: | ---: | --- |"]
        rows += ["| {Channel} | {Handshakes} | {StallAntecedents} | {StallReleases} | {HoldStatus} |".format(**row)
                 for row in result["Channels"]]
        rows += [""] + ["- " + limitation for limitation in result["Limitations"]]
        (args.output / "sva_activation.md").write_text("\n".join(rows) + "\n", encoding="utf-8")
    print("SVA activation audit: " + result["Status"] + " -> " + str(args.output))
    if result["Status"] != "PASS":
        print(result["Reason"], file=sys.stderr)
    return 0 if result["Status"] == "PASS" else 3


if __name__ == "__main__":
    sys.exit(main())
