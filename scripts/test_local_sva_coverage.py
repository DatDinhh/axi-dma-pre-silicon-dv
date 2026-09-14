#!/usr/bin/env python3
"""Fast failure-gate fixtures for the independent SVA activation audit."""
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from check_local_sva_coverage import (CHECKER_FILE, EXPECTED, FULL_CASES, PREFIX,
                                     SELF_TESTS, audit, validate_activation, validate_campaign)


def fixture_points():
    return [{"File": CHECKER_FILE, "Line": 20, "Column": "16", "Page": "v_user/fixture",
             "Label": name.rsplit(".", 1)[-1], "Hierarchy": name, "Hits": 1}
            for name in sorted(EXPECTED)]


def fixture_report(full=True):
    tests = sorted(FULL_CASES) if full else ["csr"]
    seeds = [1, 7, 42] if full else [1]
    return {"Mode": "local-verilator-dut", "Status": "PASS", "CompletedUtc": "2026-09-14T00:00:00Z",
            "ConcurrentSvaEnabled": True, "RunId": "synthetic-fixture", "Tests": tests, "Seeds": seeds,
            "Results": [{"Test": case, "Seed": seed, "Kind": "DUT", "Result": "PASS",
                         "ExitCode": 0, "TimedOut": False} for case in tests for seed in seeds],
            "CheckerSelfTests": [{"Test": name, "Kind": spec[0], "Result": spec[1], "TimedOut": False,
                                  "ExitCode": 0 if spec[1] == "PASS" else -6}
                                 for name, spec in SELF_TESTS.items()],
            "Builds": [{"Top": name, "ExitCode": 0, "TimedOut": False,
                        "Command": ["verilator", "--assert", "--coverage-user"]}
                       for name in ("dma_local_test", "dma_local_checker_negative")]}


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def native_text(points, snapshot):
    lines = ["# SystemC::Coverage-3"]
    for point in points:
        fields = {"f": str(snapshot / point["File"]), "l": str(point["Line"]),
                  "n": point["Column"], "page": point["Page"], "o": point["Label"], "h": point["Hierarchy"]}
        encoded = "".join("\x01" + key + "\x02" + value for key, value in fields.items())
        lines.append("C '" + encoded + "' " + str(point["Hits"]))
    return "\n".join(lines) + "\n"


def artifact_fixture(root):
    report = fixture_report(full=False)
    snapshot = root / "source"
    checker = snapshot / CHECKER_FILE
    checker.parent.mkdir(parents=True)
    checker.write_text("// synthetic fixture source; no simulation result is claimed\n", encoding="utf-8")
    manifest = root / "source_manifest.json"
    save(manifest, {"SnapshotDirectory": str(snapshot), "Sources": [{"Path": CHECKER_FILE, "Sha256": sha(checker)}]})
    report.update({"OutputDirectory": str(root), "SourceManifestPath": str(manifest),
                   "SourceManifestSha256": sha(manifest)})
    points = fixture_points()
    run_dir = root / "csr_seed_1"
    run_dir.mkdir()
    (run_dir / "simulation.log").write_text("LOCAL_TEST_PASS csr\n", encoding="utf-8")
    (run_dir / "coverage.dat").write_text(native_text(points, snapshot), encoding="utf-8")
    report["Results"][0].update({"LogPath": str(run_dir / "simulation.log"),
                                 "CoveragePath": str(run_dir / "coverage.dat"),
                                 "CoverageSha256": sha(run_dir / "coverage.dat")})
    for row in report["CheckerSelfTests"]:
        directory = root / row["Test"]
        directory.mkdir()
        marker = SELF_TESTS[row["Test"]][2]
        log = marker + ("\n" if row["Result"] == "PASS" else "\n%Error: Verilog $stop\nAborting...\n")
        (directory / "simulation.log").write_text(log, encoding="utf-8")
        row["LogPath"] = str(directory / "simulation.log")
    coverage_dir = root / "coverage"
    coverage_dir.mkdir()
    (coverage_dir / "merged.dat").write_text(native_text(points, snapshot), encoding="utf-8")
    coverage = {"SourceManifestSha256": sha(manifest), "PassingDutRuns": 1,
                "MergedNativeSha256": sha(coverage_dir / "merged.dat"), "AssertionActivationPoints": points}
    save(coverage_dir / "code_coverage.json", coverage)
    report["Coverage"] = {"ReportPath": str(coverage_dir / "code_coverage.json")}
    save(root / "summary.json", report)
    return root / "summary.json"


class PureActivationChecks(unittest.TestCase):
    def test_full_inventory_and_handshakes(self):
        result = validate_activation(fixture_points())
        self.assertEqual(result["ObservedNativePoints"], 37)
        self.assertEqual(result["ChannelsWithHandshakes"], 10)

    def test_missing_point_fails_even_partial(self):
        with self.assertRaisesRegex(ValueError, "inventory mismatch"):
            validate_activation(fixture_points()[:-1], partial=True)

    def test_duplicate_point_fails(self):
        points = fixture_points()
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            validate_activation(points + [deepcopy(points[0])])

    def test_all_zero_full_campaign_fails(self):
        points = fixture_points()
        for point in points:
            point["Hits"] = 0
        with self.assertRaisesRegex(ValueError, "no handshake"):
            validate_activation(points)

    def test_all_zero_partial_is_explicitly_unexercised(self):
        points = fixture_points()
        for point in points:
            point["Hits"] = 0
        result = validate_activation(points, partial=True)
        self.assertEqual(result["HoldAssertionsExercised"], 0)
        self.assertTrue(all(row["HoldStatus"] == "NOT_EXERCISED" for row in result["Channels"]))

    def test_one_missing_handshake_fails_full(self):
        points = fixture_points()
        for point in points:
            if point["Hierarchy"] in (PREFIX + "r.c_handshake", PREFIX + "r.c_stall_release"):
                point["Hits"] = 0
        with self.assertRaisesRegex(ValueError, "AXI.R"):
            validate_activation(points)

    def test_unhit_hold_does_not_disappear(self):
        points = fixture_points()
        for point in points:
            if point["Hierarchy"] in (PREFIX + "r.c_stall", PREFIX + "r.c_stall_release"):
                point["Hits"] = 0
        result = validate_activation(points)
        self.assertEqual(result["HoldAssertionsExercised"], 9)
        self.assertEqual(next(row for row in result["Channels"] if row["Channel"] == "AXI.R")["HoldStatus"],
                         "NOT_EXERCISED")

    def test_unknown_source_fails(self):
        points = fixture_points()
        points[0]["File"] = "tb/unrelated.sv"
        with self.assertRaisesRegex(ValueError, "source"):
            validate_activation(points)


class CampaignChecks(unittest.TestCase):
    def test_exact_full_matrix(self):
        result = validate_campaign(fixture_report())
        self.assertEqual(result["DeclaredDutRuns"], 60)
        self.assertTrue(result["DefaultSixtyRunMatrix"])
        self.assertFalse(result["Partial"])

    def test_missing_case_seed_fails(self):
        report = fixture_report()
        report["Results"].pop()
        with self.assertRaisesRegex(ValueError, "Tests x Seeds"):
            validate_campaign(report)

    def test_duplicate_result_fails(self):
        report = fixture_report()
        report["Results"][-1] = deepcopy(report["Results"][0])
        with self.assertRaisesRegex(ValueError, "Tests x Seeds"):
            validate_campaign(report)

    def test_running_report_fails(self):
        report = fixture_report()
        report["Status"] = "RUNNING"
        with self.assertRaisesRegex(ValueError, "finished PASS"):
            validate_campaign(report)

    def test_negative_that_exits_zero_fails(self):
        report = fixture_report()
        report["CheckerSelfTests"][1]["ExitCode"] = 0
        with self.assertRaisesRegex(ValueError, "self-test outcome"):
            validate_campaign(report)

    def test_assertions_disabled_fails(self):
        report = fixture_report()
        report["Builds"][0]["Command"].remove("--assert")
        with self.assertRaisesRegex(ValueError, "assertion/coverage build"):
            validate_campaign(report)


class ArtifactChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.report = artifact_fixture(self.root)

    def test_intact_synthetic_evidence(self):
        result = audit(self.report)
        self.assertEqual(result["Status"], "PASS")
        self.assertTrue(result["Partial"])

    def test_source_mutation_fails(self):
        (self.root / "source" / CHECKER_FILE).write_text("changed", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Frozen source hash"):
            audit(self.report)

    def test_merged_mutation_fails(self):
        with (self.root / "coverage/merged.dat").open("a", encoding="utf-8") as stream:
            stream.write("# changed\n")
        with self.assertRaisesRegex(ValueError, "Merged native coverage hash"):
            audit(self.report)

    def test_json_native_disagreement_fails(self):
        path = self.root / "coverage/code_coverage.json"
        value = json.loads(path.read_text())
        value["AssertionActivationPoints"][0]["Hits"] += 1
        save(path, value)
        with self.assertRaisesRegex(ValueError, "differs from code_coverage"):
            audit(self.report)

    def test_extra_merged_hits_cannot_come_from_self_tests(self):
        path = self.root / "coverage/code_coverage.json"
        value = json.loads(path.read_text())
        for point in value["AssertionActivationPoints"]:
            point["Hits"] *= 2
        merged = self.root / "coverage/merged.dat"
        merged.write_text(native_text(value["AssertionActivationPoints"], self.root / "source"), encoding="utf-8")
        value["MergedNativeSha256"] = sha(merged)
        save(path, value)
        with self.assertRaisesRegex(ValueError, "not the sum"):
            audit(self.report)

    def test_missing_positive_marker_fails(self):
        (self.root / "csr_seed_1/simulation.log").write_text("no completion", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "log does not confirm PASS"):
            audit(self.report)


if __name__ == "__main__":
    unittest.main(verbosity=2)
