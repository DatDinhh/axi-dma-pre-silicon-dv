#!/usr/bin/env python3
"""Runner-control tests. Fake xrun is not a simulator and generates no DUT evidence."""
import contextlib
import io
import json
import os
from pathlib import Path
import unittest
import uuid
from run_xcelium import ROOT, failure_reason, main

FAKE_XRUN = r'''#!/usr/bin/env python3
import json, os, pathlib, sys, time
args = sys.argv[1:]
if "-version" in args:
    print("FAKE_XRUN_RUNNER_CONTROL_FIXTURE - NOT A SIMULATOR")
    sys.exit(0)
mode = os.environ.get("AXI_DMA_FIXTURE_MODE", "pass")
if mode == "timeout": time.sleep(10)
name = next(x.split("=", 1)[1] for x in args if x.startswith("+UVM_TESTNAME="))
if mode != "missing_marker": print(name + " PASSED")
if mode != "missing_summary":
    print("UVM_ERROR : 0")
    print("UVM_FATAL : 0")
if mode == "uvm_error": print("UVM_ERROR @ 10: fixture [NEGATIVE] intentional checker failure")
if mode == "tool_error": print("xmsim: *E,FIXTURE: intentional simulator error")
if mode == "assertion": print("Assertion hold failed at time 10")
coverage = pathlib.Path(next(x.split("=", 1)[1] for x in args if x.startswith("+COVERAGE_FILE=")))
if mode != "missing_tsv":
    catalog = json.loads((coverage.parent.parent / "source/tb/coverage/coverage_requirements.json").read_text(encoding="utf-8-sig"))
    text = "bin\thits\n" + "".join(row["id"] + "\t0\n" for row in catalog["bins"])
    if mode == "malformed_tsv": text += "unknown\t0\n"
    coverage.write_text(text)
if mode != "missing_native":
    native = pathlib.Path(args[args.index("-covworkdir") + 1]) / "scope" / "fixture"
    native.mkdir(parents=True)
    (native / "FIXTURE_NOT_REAL_COVERAGE.ucd").write_text("FAKE RUNNER CONTROL DATA - NOT NATIVE COVERAGE")
sys.exit(7 if mode == "nonzero" else 0)
'''

class RunnerControlTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        run_id = uuid.uuid4().hex[:12]
        cls.output = ROOT / "output" / ("xcelium_runner_selftests_" + run_id)
        cls.output.mkdir(parents=True)
        cls.fake = cls.output / "fake_xrun"
        cls.fake.write_text(FAKE_XRUN)
        cls.fake.chmod(0o755)
        cls.records = []

    @classmethod
    def tearDownClass(cls):
        report = {"Mode": "RUNNER_CONTROL_FIXTURES_ONLY", "DutSimulation": False,
                  "ActualXceliumExecuted": False, "Results": cls.records}
        (cls.output / "fixture_summary.json").write_text(json.dumps(report, indent=2) + "\n")
        print("Fixture evidence: " + str(cls.output))

    def invoke(self, mode):
        output = self.output / mode
        previous = os.environ.get("AXI_DMA_FIXTURE_MODE")
        os.environ["AXI_DMA_FIXTURE_MODE"] = mode
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                status = main(["--xrun", str(self.fake), "--tests", "copy_test", "--seeds", "1",
                               "--timeout", "1" if mode == "timeout" else "10", "--output", str(output)])
        finally:
            if previous is None: os.environ.pop("AXI_DMA_FIXTURE_MODE", None)
            else: os.environ["AXI_DMA_FIXTURE_MODE"] = previous
        report = json.loads((output / "summary.json").read_text())
        self.records.append({"Fixture": mode, "ExitCode": status, "ObservedResult": report["Results"][0]["Result"],
                             "Reason": report["Results"][0]["Reason"]})
        return status, report

    def test_pass_and_frozen_provenance(self):
        status, report = self.invoke("pass")
        self.assertEqual(status, 0)
        self.assertEqual(report["Results"][0]["Result"], "PASS")
        self.assertTrue(report["SourceManifestSha256"])
        manifest = json.loads(Path(report["SourceManifestPath"]).read_text())
        self.assertIn("tb/coverage/coverage_requirements.json", {row["Path"] for row in manifest["Sources"]})
        self.assertIn("FAKE_XRUN", report["ToolVersion"])

    def test_failure_gate_and_output_requirements(self):
        for mode in ("uvm_error", "tool_error", "assertion", "nonzero", "missing_marker", "missing_summary",
                     "missing_tsv", "malformed_tsv", "missing_native", "timeout"):
            with self.subTest(mode=mode):
                status, report = self.invoke(mode)
                self.assertEqual(status, 3)
                self.assertEqual(report["Results"][0]["Result"], "FAIL")
                if mode == "timeout": self.assertTrue(report["Results"][0]["TimedOut"])

    def test_dry_run_has_full_matrix_and_never_passes(self):
        output = self.output / "dry_run"
        with contextlib.redirect_stdout(io.StringIO()):
            status = main(["--dry-run", "--output", str(output)])
        report = json.loads((output / "summary.json").read_text())
        self.assertEqual(status, 0)
        self.assertEqual(len(report["Results"]), 39)
        self.assertTrue(all(row["Result"] == "NOT_RUN" for row in report["Results"]))
        self.assertFalse((output / "version.log").exists())
        self.records.append({"Fixture": "dry_run_39_matrix", "ExpectedResult": "NOT_RUN", "Count": 39})

    def test_zero_assertion_failure_count_is_not_a_violation(self):
        text = "copy_test PASSED\nUVM_ERROR : 0\nUVM_FATAL : 0\nAssertion failures: 0\n"
        self.assertEqual(failure_reason(text, {"TimedOut": False, "ExitCode": 0}, "copy_test PASSED"), "")

if __name__ == "__main__":
    unittest.main(verbosity=2)
