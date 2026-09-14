"""Fixture-only merger safety tests; these are not DUT simulation evidence."""
import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

import merge_coverage as merger


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    if value.get("Mode") == "portfolio-suite" and "CompletedUtc" not in value:
        value["CompletedUtc"] = "2026-09-13T21:00:00+00:00"
    path.write_text(json.dumps(value, indent=2), encoding="utf-8")


class MergeCoverageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dma-coverage-merger-")
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def fixture(self, name, test=None, counts=(1, 1), source="module fixture; endmodule\n"):
        directory = self.root / name
        directory.mkdir()
        snapshot = directory / "source"
        (snapshot / "tb/coverage").mkdir(parents=True)
        (snapshot / "rtl").mkdir()
        catalog = {
            "schema_version": 1, "metric": merger.METRIC,
            "bins": [
                {"id": "R01.copy", "requirement_id": "R01", "description": "Fixture copy",
                 "required": True},
                {"id": "R02.stall", "requirement_id": "R02", "description": "Fixture stall",
                 "required": True},
            ],
            "exclusions": [{"id": "FIXTURE", "reason": "Synthetic merger inputs, not DUT evidence."}],
        }
        write_json(snapshot / merger.CATALOG_PATH, catalog)
        (snapshot / "rtl/fixture.sv").write_text(source, encoding="utf-8")
        uvm = directory / "uvm"
        uvm.mkdir()
        (uvm / "uvm_pkg.sv").write_text("package fake_uvm; endpackage\n", encoding="utf-8")
        manifest = {
            "SnapshotDirectory": str(snapshot),
            "Sources": [{"Path": path.relative_to(snapshot).as_posix(), "Sha256": sha(path)}
                        for path in sorted(snapshot.rglob("*")) if path.is_file()],
            "UvmSourceDirectory": str(uvm),
            "UvmSources": [{"Path": "uvm_pkg.sv", "Sha256": sha(uvm / "uvm_pkg.sv")}],
        }
        write_json(directory / "source_manifest.json", manifest)
        coverage = directory / "coverage.tsv"
        coverage.write_text("bin\thits\nR01.copy\t%d\nR02.stall\t%d\n" % counts, encoding="utf-8")
        result = {"Test": test or name, "Seed": 1, "Result": "PASS", "ExitCode": 0,
                  "TimedOut": False, "CoveragePath": str(coverage), "PlusArgs": []}
        report = {
            "Mode": "regression", "RunId": name, "ToolVersion": "Fixture simulator 1",
            "StartedUtc": "2026-09-13T20:00:00+00:00",
            "CompletedUtc": "2026-09-13T21:00:00+00:00",
            "Tests": [test or name], "Seeds": [1],
            "VsimPath": "/fixture/vsim", "CoverageEnabled": False, "SvaEnabled": False,
            "UvmNoDpiEnabled": True,
            "Compile": {"Result": "PASS", "ExitCode": 0, "TimedOut": False},
            "SourceManifestPath": str(directory / "source_manifest.json"), "Results": [result],
        }
        write_json(directory / "summary.json", report)
        return directory, report, manifest

    def save(self, directory, report=None, manifest=None):
        if report is not None:
            write_json(directory / "summary.json", report)
        if manifest is not None:
            write_json(directory / "source_manifest.json", manifest)

    def merge(self, *directories):
        return merger.Merger().merge([directory / "summary.json" for directory in directories])

    def test_success_merges_complementary_bins_and_records_evidence(self):
        first, _, _ = self.fixture("first", counts=(3, 0))
        second, _, _ = self.fixture("second", counts=(0, 4))
        result = self.merge(first, second)
        self.assertEqual(result["Status"], "CLOSED")
        self.assertEqual(result["ObservedRequirementBinPercent"], 100)
        self.assertEqual(result["MissingBins"], [])
        self.assertEqual([row["Hits"] for row in result["Bins"]], [3, 4])
        self.assertEqual(len(result["SourceSignatures"]), 1)
        self.assertEqual(len(result["InputRecords"]), 8)
        self.assertIn("first", merger.markdown(result))
        self.assertIn("not native covergroup", result["Limitations"])

    def test_missing_bin_writes_open_report_and_nonzero_exit(self):
        directory, _, _ = self.fixture("open", counts=(1, 0))
        output = self.root / "output"
        self.assertEqual(merger.run([directory / "summary.json"], output), 3)
        result = json.loads((output / "coverage_summary.json").read_text())
        self.assertEqual(result["MissingBins"], ["R02.stall"])
        self.assertEqual(result["ObservedRequirementBinPercent"], 50)

    def test_invalid_input_replaces_previous_closed_output(self):
        directory, report, _ = self.fixture("replace")
        output = self.root / "output"
        self.assertEqual(merger.run([directory / "summary.json"], output), 0)
        report["Results"][0]["Result"] = "FAIL"
        self.save(directory, report)
        self.assertEqual(merger.run([directory / "summary.json"], output), 2)
        result = json.loads((output / "coverage_summary.json").read_text())
        self.assertEqual(result["Status"], "INVALID")
        self.assertNotIn("ObservedRequirementBinPercent", result)

    def test_failed_timed_out_or_missing_exit_is_rejected(self):
        for index, mutation in enumerate(({"Result": "FAIL"}, {"TimedOut": True},
                                         {"ExitCode": 1}, {"ExitCode": None},
                                         {"TimedOut": None})):
            with self.subTest(mutation=mutation):
                directory, report, _ = self.fixture("failure" + str(index))
                report["Results"][0].update(mutation)
                self.save(directory, report)
                with self.assertRaises(merger.CoverageError):
                    self.merge(directory)

    def test_failed_compile_rejected_even_when_tests_claim_pass(self):
        directory, report, _ = self.fixture("compile")
        report["Compile"]["ExitCode"] = 2
        self.save(directory, report)
        with self.assertRaisesRegex(merger.CoverageError, "compile"):
            self.merge(directory)

    def test_malformed_tsv_variants_fail_closed(self):
        variants = [
            "bin\thits\nR01.copy\t1\n",
            "bin\thits\nR01.copy\t1\nR01.copy\t2\nR02.stall\t1\n",
            "bin\thits\nR01.copy\t1\nR02.stall\t1\nR99.unknown\t1\n",
            "bin\thits\nR01.copy\t-1\nR02.stall\t1\n",
            "bin\thits\nR01.copy\t1.5\nR02.stall\t1\n",
            "bin\thits\nR01.copy\tone\nR02.stall\t1\n",
            "bin\tcount\nR01.copy\t1\nR02.stall\t1\n",
            "bin\thits\nR01.copy\t1\textra\nR02.stall\t1\n",
        ]
        for index, content in enumerate(variants):
            with self.subTest(index=index):
                directory, _, _ = self.fixture("tsv" + str(index))
                (directory / "coverage.tsv").write_text(content, encoding="utf-8")
                with self.assertRaises(merger.CoverageError):
                    self.merge(directory)

    def test_tampered_frozen_source_rejected(self):
        directory, _, _ = self.fixture("tampered")
        (directory / "source/rtl/fixture.sv").write_text("changed", encoding="utf-8")
        with self.assertRaisesRegex(merger.CoverageError, "hash mismatch"):
            self.merge(directory)

    def test_valid_but_different_full_source_rejected(self):
        first, _, _ = self.fixture("source1")
        second, _, _ = self.fixture("source2", source="different verified bytes")
        with self.assertRaisesRegex(merger.CoverageError, "differing full frozen source"):
            self.merge(first, second)

    def test_manifest_slashes_and_hash_case_normalize(self):
        first, _, _ = self.fixture("normalize1")
        second, _, manifest = self.fixture("normalize2")
        for entry in manifest["Sources"]:
            entry["Path"] = entry["Path"].replace("/", "\\")
            entry["Sha256"] = entry["Sha256"].upper()
        self.save(second, manifest=manifest)
        self.assertEqual(self.merge(first, second)["Status"], "CLOSED")

    def test_uvm_tamper_or_version_mismatch_rejected(self):
        first, _, _ = self.fixture("uvm1")
        second, _, manifest = self.fixture("uvm2")
        uvm_file = second / "uvm/uvm_pkg.sv"
        uvm_file.write_text("modified vendor", encoding="utf-8")
        with self.assertRaisesRegex(merger.CoverageError, "UVM sources: source hash mismatch"):
            self.merge(first, second)
        manifest["UvmSources"][0]["Sha256"] = sha(uvm_file)
        self.save(second, manifest=manifest)
        with self.assertRaisesRegex(merger.CoverageError, "differing simulator/UVM"):
            self.merge(first, second)

    def test_simulator_version_mismatch_rejected(self):
        first, _, _ = self.fixture("tool1")
        second, report, _ = self.fixture("tool2")
        report["ToolVersion"] = "Fixture simulator 2"
        self.save(second, report)
        with self.assertRaisesRegex(merger.CoverageError, "differing simulator/UVM"):
            self.merge(first, second)

    def test_duplicate_within_campaign_rejected(self):
        directory, report, _ = self.fixture("duplicate")
        report["Results"].append(copy.deepcopy(report["Results"][0]))
        self.save(directory, report)
        with self.assertRaisesRegex(merger.CoverageError, "declared Tests x Seeds"):
            self.merge(directory)

    def test_retries_cannot_disguise_identity_with_different_export_paths(self):
        first, report1, _ = self.fixture("retry1", test="same_test")
        second, report2, _ = self.fixture("retry2", test="same_test")
        report1["Results"][0]["PlusArgs"] = ["+COVERAGE_FILE=/old/path"]
        report2["Results"][0]["PlusArgs"] = ["+COVERAGE_FILE=/new/path", "+UVM_NO_RELNOTES"]
        self.save(first, report1)
        self.save(second, report2)
        with self.assertRaisesRegex(merger.CoverageError, "Duplicate/retried"):
            self.merge(first, second)

    def test_phase_labels_cannot_bypass_declared_campaign_matrix(self):
        directory, report, _ = self.fixture("phases", test="read_error_test")
        first = report["Results"][0]
        first["Phase"], first["PlusArgs"] = "first", ["+AXI_RERR_ADDR=100"]
        second = copy.deepcopy(first)
        second["Phase"], second["PlusArgs"] = "middle", ["+AXI_RERR_ADDR=120"]
        report["Results"].append(second)
        self.save(directory, report)
        with self.assertRaisesRegex(merger.CoverageError, "declared Tests x Seeds"):
            self.merge(directory)

    def test_portfolio_expands_every_child_and_checks_aggregate_completeness(self):
        first, report1, _ = self.fixture("child1")
        second, report2, _ = self.fixture("child2")
        portfolio = self.root / "portfolio"
        portfolio.mkdir()
        aggregate = {
            "Mode": "portfolio-suite", "Results": report1["Results"] + report2["Results"],
            "ChildRuns": [{"OutputDirectory": str(path), "ExitCode": 0, "Count": 1}
                          for path in (first, second)],
        }
        write_json(portfolio / "summary.json", aggregate)
        self.assertEqual(len(self.merge(portfolio)["Results"]), 2)
        aggregate["Results"].pop()
        write_json(portfolio / "summary.json", aggregate)
        with self.assertRaisesRegex(merger.CoverageError, "do not exactly match"):
            self.merge(portfolio)

    def test_omitted_failed_child_cannot_be_hidden_by_aggregate_pass(self):
        first, report1, _ = self.fixture("pass_child")
        second, report2, _ = self.fixture("fail_child")
        report2["Results"][0]["Result"] = "FAIL"
        self.save(second, report2)
        portfolio = self.root / "hidden"
        portfolio.mkdir()
        write_json(portfolio / "summary.json", {
            "Mode": "portfolio-suite", "Results": report1["Results"],
            "ChildRuns": [{"OutputDirectory": str(path), "ExitCode": 0} for path in (first, second)],
        })
        with self.assertRaisesRegex(merger.CoverageError, "every result must be PASS"):
            self.merge(portfolio)

    def test_manifest_duplicate_normalized_path_rejected(self):
        directory, _, manifest = self.fixture("manifest_duplicate")
        duplicated = copy.deepcopy(manifest["Sources"][0])
        duplicated["Path"] = duplicated["Path"].replace("/", "\\")
        manifest["Sources"].append(duplicated)
        self.save(directory, manifest=manifest)
        with self.assertRaisesRegex(merger.CoverageError, "duplicate normalized"):
            self.merge(directory)

    def test_unlisted_snapshot_file_rejected(self):
        directory, _, _ = self.fixture("unlisted")
        (directory / "source/extra.sv").write_text("unlisted", encoding="utf-8")
        with self.assertRaisesRegex(merger.CoverageError, "unlisted"):
            self.merge(directory)

    def test_builtin_uvm_needs_explicit_provenance(self):
        directory, report, manifest = self.fixture("builtin")
        del report["VsimPath"]
        report["XrunPath"] = "/fixture/xrun"
        manifest["UvmSources"] = []
        self.save(directory, report, manifest)
        with self.assertRaisesRegex(merger.CoverageError, "explicit built-in"):
            self.merge(directory)
        manifest["UvmProvenance"] = {"Selection": "CDNS-1.2", "ToolVersion": report["ToolVersion"]}
        self.save(directory, manifest=manifest)
        self.assertEqual(self.merge(directory)["Status"], "CLOSED")

    def test_manifest_hash_if_recorded_must_match(self):
        directory, report, _ = self.fixture("manifest_hash")
        report["SourceManifestSha256"] = "0" * 64
        self.save(directory, report)
        with self.assertRaisesRegex(merger.CoverageError, "SourceManifestSha256"):
            self.merge(directory)

    def test_missing_tsv_and_duplicate_report_are_rejected(self):
        directory, _, _ = self.fixture("missing")
        with self.assertRaisesRegex(merger.CoverageError, "Duplicate/cyclic"):
            self.merge(directory, directory)
        (directory / "coverage.tsv").unlink()
        with self.assertRaisesRegex(merger.CoverageError, "Missing coverage_tsv"):
            self.merge(directory)


    def test_unfinished_and_invalid_completion_are_rejected(self):
        for index, completed in enumerate((None, "", "not-a-date", "2026-09-13T21:00:00")):
            with self.subTest(completed=completed):
                directory, report, _ = self.fixture("unfinished" + str(index))
                report["CompletedUtc"] = completed
                self.save(directory, report)
                with self.assertRaisesRegex(merger.CoverageError, "CompletedUtc"):
                    self.merge(directory)
        directory, report, _ = self.fixture("missing_completion")
        del report["CompletedUtc"]
        self.save(directory, report)
        with self.assertRaisesRegex(merger.CoverageError, "CompletedUtc"):
            self.merge(directory)

    def test_runtime_state_rejected_even_with_all_pass_rows(self):
        for index, status in enumerate(("ATTEMPTED", "FAIL", "NOT_RUN", None)):
            directory, report, _ = self.fixture("runtime" + str(index))
            report["RuntimeValidation"] = status
            self.save(directory, report)
            with self.assertRaisesRegex(merger.CoverageError, "RuntimeValidation"):
                self.merge(directory)
        directory, report, _ = self.fixture("dry_run")
        report["DryRun"] = True
        self.save(directory, report)
        with self.assertRaisesRegex(merger.CoverageError, "dry-run"):
            self.merge(directory)

    def test_declared_matrix_must_be_exact_and_typed(self):
        mutations = (
            {"Tests": ["matrix0", "omitted_test"]},
            {"Seeds": [1, 7]},
            {"Tests": []}, {"Seeds": []},
            {"Tests": ["matrix4", "matrix4"]}, {"Seeds": [1, 1]},
            {"Tests": [17]}, {"Seeds": [True]},
        )
        for index, mutation in enumerate(mutations):
            directory, report, _ = self.fixture("matrix" + str(index))
            report.update(mutation)
            self.save(directory, report)
            with self.assertRaises(merger.CoverageError):
                self.merge(directory)
        directory, report, _ = self.fixture("extra_result")
        extra = copy.deepcopy(report["Results"][0])
        extra["Test"] = "unexpected_test"
        report["Results"].append(extra)
        self.save(directory, report)
        with self.assertRaisesRegex(merger.CoverageError, "declared Tests x Seeds"):
            self.merge(directory)

    def test_unsupported_or_missing_mode_cannot_bypass_campaign_gates(self):
        for index, mode in enumerate(("phase-fixture", None, "missing")):
            directory, report, _ = self.fixture("bad_mode" + str(index))
            for key in ("StartedUtc", "CompletedUtc", "Tests", "Seeds"):
                del report[key]
            if mode == "missing":
                del report["Mode"]
            else:
                report["Mode"] = mode
            self.save(directory, report)
            with self.assertRaisesRegex(merger.CoverageError, "campaign Mode"):
                self.merge(directory)

    def test_xcelium_requires_declared_matrix_and_final_runtime_pass(self):
        directory, report, manifest = self.fixture("xcelium_final")
        report["Mode"] = "xcelium-portfolio-suite"
        del report["Tests"]
        report["RuntimeValidation"] = "PASS"
        self.save(directory, report)
        with self.assertRaisesRegex(merger.CoverageError, "Tests and Seeds"):
            self.merge(directory)
        report["Tests"] = ["xcelium_final"]
        self.save(directory, report)
        self.assertEqual(self.merge(directory)["Status"], "CLOSED")

    def test_completed_portfolio_rejects_unfinished_child(self):
        directory, report, _ = self.fixture("unfinished_child")
        report["CompletedUtc"] = None
        self.save(directory, report)
        parent = self.root / "parent"
        parent.mkdir()
        write_json(parent / "summary.json", {
            "Mode": "portfolio-suite", "Results": report["Results"],
            "ChildRuns": [{"OutputDirectory": str(directory), "ExitCode": 0}],
        })
        with self.assertRaisesRegex(merger.CoverageError, "CompletedUtc"):
            self.merge(parent)

    def remote_paths(self, value, local_root, remote_root):
        if isinstance(value, str):
            normalized = value.replace("\\", "/")
            local = str(local_root).replace("\\", "/")
            return remote_root + normalized[len(local):] if normalized.startswith(local + "/") else value
        if isinstance(value, list):
            return [self.remote_paths(item, local_root, remote_root) for item in value]
        if isinstance(value, dict):
            return {key: self.remote_paths(item, local_root, remote_root) for key, item in value.items()}
        return value

    def test_explicit_linux_relocation_verifies_returned_complete_directory(self):
        directory, report, manifest = self.fixture("returned_run")
        baseline = self.merge(directory)
        remote_root = "/school/user/axi_dma/output"
        report = self.remote_paths(report, self.root, remote_root)
        manifest = self.remote_paths(manifest, self.root, remote_root)
        self.save(directory, report, manifest)
        # No guessed path fallback: the relocated copy alone is insufficient.
        with self.assertRaises(merger.CoverageError):
            self.merge(directory)
        result = merger.Merger([(remote_root, str(self.root))]).merge([directory / "summary.json"])
        self.assertEqual(result["Status"], "CLOSED")
        self.assertEqual(result["SourceSignatures"], baseline["SourceSignatures"])
        self.assertEqual(result["ProvenanceSignatures"], baseline["ProvenanceSignatures"])
        self.assertEqual(len(result["RelocatedPaths"]), 4)
        self.assertEqual(result["AnalysisTool"]["Sha256"], sha(Path(merger.__file__)))
        self.assertEqual(result["Relocations"][0]["OldRoot"], remote_root)
        (directory / "source/rtl/fixture.sv").write_text("tampered after relocation")
        with self.assertRaisesRegex(merger.CoverageError, "hash mismatch"):
            merger.Merger([(remote_root, str(self.root))]).merge([directory / "summary.json"])

    def test_explicit_relocation_applies_to_child_summary_paths(self):
        first, report1, manifest1 = self.fixture("relocated_child1")
        second, report2, manifest2 = self.fixture("relocated_child2")
        parent = self.root / "relocated_parent"
        parent.mkdir()
        remote = "/school/results"
        for directory, report, manifest in ((first, report1, manifest1), (second, report2, manifest2)):
            self.save(directory, self.remote_paths(report, self.root, remote),
                      self.remote_paths(manifest, self.root, remote))
        aggregate = {
            "Mode": "portfolio-suite", "Results": report1["Results"] + report2["Results"],
            "ChildRuns": [{"SummaryPath": str(first / "summary.json"), "ExitCode": 0, "Count": 1},
                          {"OutputDirectory": str(second), "ExitCode": 0, "Count": 1}],
        }
        write_json(parent / "summary.json", self.remote_paths(aggregate, self.root, remote))
        result = merger.Merger([(remote, str(self.root))]).merge([parent / "summary.json"])
        self.assertEqual(result["Status"], "CLOSED")
        self.assertEqual(len(result["Results"]), 2)

    def test_relocation_boundaries_case_and_longest_prefix(self):
        parent = self.root
        nested = parent / "nested"
        nested.mkdir()
        resolver = merger.Merger([("/Repo/", str(parent)), ("/Repo/specific", str(nested)),
                                  ("C:\\Evidence\\", str(parent))])
        self.assertEqual(resolver.resolve_path("/Repo/file", parent), parent / "file")
        self.assertEqual(resolver.resolve_path("/Repo/specific/file", parent), nested / "file")
        self.assertEqual(resolver.resolve_path("c:/evidence/file", parent), parent / "file")
        count = len(resolver.relocated_paths)
        resolver.resolve_path("/Repo2/file", parent)
        resolver.resolve_path("/repo/file", parent)
        self.assertEqual(len(resolver.relocated_paths), count)
        with self.assertRaisesRegex(merger.CoverageError, "absolute"):
            merger.Merger([("C:relative", str(parent))])
        with self.assertRaisesRegex(merger.CoverageError, "Duplicate"):
            merger.Merger([("C:/Evidence", str(parent)), ("c:/evidence/", str(nested))])
        with self.assertRaisesRegex(merger.CoverageError, "escapes"):
            resolver.resolve_path("/Repo/../escape", parent)

    def test_invalid_relocation_emits_invalid_report_with_analysis_identity(self):
        directory, _, _ = self.fixture("invalid_mapping")
        output = self.root / "invalid_mapping_report"
        self.assertEqual(merger.run([directory / "summary.json"], output,
                                   [("relative-root", str(self.root))]), 2)
        report = json.loads((output / "coverage_summary.json").read_text())
        self.assertEqual(report["Status"], "INVALID")
        self.assertEqual(report["AnalysisTool"]["Sha256"], sha(Path(merger.__file__)))

    def test_relocation_drive_root_and_unc(self):
        resolver = merger.Merger([("D:/", str(self.root)), ("//server/share", str(self.root))])
        self.assertEqual(resolver.resolve_path("d:\\logs\\run", self.root), self.root / "logs/run")
        self.assertEqual(resolver.resolve_path("//SERVER/SHARE/logs/run", self.root), self.root / "logs/run")
        self.assertEqual(resolver.resolve_path("D:/", self.root), self.root)

    def test_relocation_rejects_symlink_escape(self):
        mapped = self.root / "mapped"
        outside = self.root / "outside"
        mapped.mkdir(); outside.mkdir()
        try:
            (mapped / "escape").symlink_to(outside, target_is_directory=True)
        except OSError as exc:
            self.skipTest("Host cannot create test symlink: " + str(exc))
        resolver = merger.Merger([("/old", str(mapped))])
        with self.assertRaisesRegex(merger.CoverageError, "escapes"):
            resolver.resolve_path("/old/escape/file", self.root)


if __name__ == "__main__":
    unittest.main()
