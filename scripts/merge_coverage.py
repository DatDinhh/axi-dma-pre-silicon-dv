#!/usr/bin/env python3
"""Merge finite observed-requirement bins from immutable passing regressions.

This is not a native covergroup, RTL-code, assertion, or correctness percentage.
Only Python's standard library is required. Failed or retried configurations,
tampered snapshots, and mixed source/tool/UVM provenance fail closed.
"""
import argparse
import csv
import hashlib
import json
import re
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

METRIC = "observed_requirement_bins"
CATALOG_PATH = "tb/coverage/coverage_requirements.json"
CAMPAIGN_MODES = {"regression", "portfolio-suite", "xcelium-portfolio-suite"}


class CoverageError(ValueError):
    pass


def demand(condition, message):
    if not condition:
        raise CoverageError(message)


def digest(path):
    with path.open("rb") as handle:
        result = hashlib.sha256()
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def signature(value):
    return hashlib.sha256(canonical(value).encode("utf-8")).hexdigest()


def no_duplicate_keys(pairs):
    obj = {}
    for key, value in pairs:
        demand(key not in obj, "Duplicate JSON key: " + key)
        obj[key] = value
    return obj


def file_path(value, parent):
    demand(isinstance(value, str) and bool(value.strip()), "Missing file/directory path")
    path = Path(value.replace("\\", "/"))
    return path.resolve() if path.is_absolute() else (parent / path).resolve()


def relative_name(value):
    demand(isinstance(value, str) and bool(value), "Manifest path must be a nonempty string")
    value = value.replace("\\", "/")
    name = PurePosixPath(value)
    demand(not name.is_absolute() and ":" not in value and
           all(part not in ("", ".", "..") for part in value.split("/")),
           "Manifest path must be relative without traversal: " + value)
    return str(name)


def require_pass(entry, context):
    demand(isinstance(entry, dict), context + ": result must be an object")
    demand(entry.get("Result") == "PASS", context + ": every result must be PASS")
    demand(type(entry.get("ExitCode")) is int and entry["ExitCode"] == 0,
           context + ": explicit ExitCode=0 is required")
    demand(entry.get("TimedOut") is False, context + ": explicit TimedOut=false is required")


class Merger:
    def __init__(self, relocations=None):
        self.relocations = []
        self.relocated_paths = {}
        old_roots = set()
        for pair in relocations or []:
            demand(isinstance(pair, (list, tuple)) and len(pair) == 2,
                   "Relocation requires OLD_ROOT NEW_ROOT")
            old, new = pair
            demand(isinstance(old, str) and bool(old.strip()), "Empty relocation OLD_ROOT")
            old = old.replace("\\", "/")
            windows = bool(re.match(r"^[A-Za-z]:/", old)) or old.startswith("//")
            demand(old.startswith("/") or bool(re.match(r"^[A-Za-z]:/", old)),
                   "Relocation OLD_ROOT must be absolute: " + old)
            demand(not any(part in (".", "..") for part in old.split("/")),
                   "Relocation OLD_ROOT cannot contain traversal: " + old)
            old = str(PurePosixPath(old)).rstrip("/") or "/"
            # Keep drive roots absolute instead of converting C:/ into C:.
            if re.fullmatch(r"[A-Za-z]:", old):
                old += "/"
            key = old.casefold() if windows else old
            demand(key not in old_roots, "Duplicate relocation OLD_ROOT: " + old)
            old_roots.add(key)
            new_path = Path(new).resolve()
            demand(new_path.is_dir(), "Relocation NEW_ROOT must be an existing directory: " + str(new_path))
            self.relocations.append({"OldRoot": old, "NewRoot": str(new_path),
                                     "CaseInsensitive": windows})
        # The most specific mapping wins; input order never changes resolution.
        self.relocations.sort(key=lambda item: len(item["OldRoot"]), reverse=True)
        self.records = {}
        self.visited_reports = set()
        self.leaves = []
        self.source_signature = None
        self.provenance_signature = None
        self.catalog = None
        self.source_files = None
        self.tool_provenance = None
        self.catalog_file = None

    def resolve_path(self, value, parent):
        demand(isinstance(value, str) and bool(value.strip()), "Missing file/directory path")
        normalized = value.replace("\\", "/")
        for mapping in self.relocations:
            old = mapping["OldRoot"]
            candidate = normalized.casefold() if mapping["CaseInsensitive"] else normalized
            prefix = old.casefold() if mapping["CaseInsensitive"] else old
            boundary_prefix = prefix if prefix.endswith("/") else prefix + "/"
            if candidate != prefix and not candidate.startswith(boundary_prefix):
                continue
            suffix = normalized[len(old):].lstrip("/")
            root = Path(mapping["NewRoot"])
            resolved = (root / suffix).resolve()
            demand(resolved == root or root in resolved.parents,
                   "Relocated path escapes NEW_ROOT: " + value)
            key = (value, str(resolved))
            self.relocated_paths[key] = {"OriginalPath": value, "ResolvedPath": str(resolved),
                                         "OldRoot": old, "NewRoot": str(root)}
            return resolved
        # No implicit search or cross-platform drive translation is performed.
        return file_path(value, parent)

    def validate_campaign(self, report, path):
        context = str(path)
        mode = report.get("Mode")
        allowed_modes = {"portfolio-suite"} if report.get("ChildRuns") is not None else {
            "regression", "xcelium-portfolio-suite"}
        demand(mode in allowed_modes, context + ": unsupported or missing campaign Mode")
        declared_completion = any(key in report for key in
                                  ("StartedUtc", "CompletedUtc", "RuntimeValidation"))
        if mode in CAMPAIGN_MODES or declared_completion:
            completed = report.get("CompletedUtc")
            demand(isinstance(completed, str) and bool(completed.strip()),
                   context + ": campaign is not complete (CompletedUtc required)")
            try:
                completion = datetime.fromisoformat(completed.replace("Z", "+00:00"))
            except ValueError as exc:
                raise CoverageError(context + ": invalid CompletedUtc") from exc
            demand(completion.tzinfo is not None, context + ": CompletedUtc needs a timezone")
        demand(report.get("DryRun") is not True, context + ": dry-run evidence is not accepted")
        if "RuntimeValidation" in report or mode == "xcelium-portfolio-suite":
            demand(report.get("RuntimeValidation") == "PASS",
                   context + ": RuntimeValidation must be PASS")
        demand(not report.get("SetupError"), context + ": setup failure is not accepted")
        if mode in {"regression", "xcelium-portfolio-suite"}:
            demand("Tests" in report and "Seeds" in report,
                   context + ": declared Tests and Seeds are required")
        if "Tests" in report:
            tests, seeds = report["Tests"], report.get("Seeds")
            demand(isinstance(tests, list) and bool(tests) and
                   all(isinstance(test, str) and bool(test.strip()) for test in tests),
                   context + ": Tests must be a nonempty string list")
            demand(len(set(tests)) == len(tests), context + ": duplicate declared Tests")
            demand(isinstance(seeds, list) and bool(seeds) and
                   all(type(seed) is int for seed in seeds),
                   context + ": Seeds must be a nonempty integer list")
            demand(len(set(seeds)) == len(seeds), context + ": duplicate declared Seeds")
            actual = Counter((row.get("Test"), row.get("Seed")) for row in report["Results"])
            expected = Counter((test, seed) for test in tests for seed in seeds)
            demand(actual == expected, context + ": Results do not exactly match declared Tests x Seeds")

    def record(self, path, kind):
        demand(path.is_file(), "Missing " + kind + ": " + str(path))
        key = str(path.resolve())
        sha = digest(path)
        if key in self.records:
            demand(self.records[key]["Sha256"] == sha, "Input changed during merge: " + key)
        else:
            self.records[key] = {"Path": key, "Sha256": sha, "Kind": kind}
        return sha

    def load(self, path, kind):
        self.record(path, kind)
        try:
            data = json.loads(path.read_text(encoding="utf-8-sig"), object_pairs_hook=no_duplicate_keys)
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise CoverageError("Invalid JSON " + str(path) + ": " + str(exc)) from exc
        demand(isinstance(data, dict), "JSON root must be an object: " + str(path))
        return data

    def expand(self, path):
        path = path.resolve()
        demand(str(path) not in self.visited_reports, "Duplicate/cyclic report input: " + str(path))
        self.visited_reports.add(str(path))
        report = self.load(path, "regression_report")
        results = report.get("Results")
        demand(isinstance(results, list) and bool(results), "Empty/missing Results: " + str(path))
        for index, entry in enumerate(results):
            require_pass(entry, str(path) + " result " + str(index))
        self.validate_campaign(report, path)
        children = report.get("ChildRuns")
        if children is not None:
            demand(isinstance(children, list) and bool(children), "Empty/invalid ChildRuns: " + str(path))
            collected = []
            for child in children:
                demand(isinstance(child, dict), "Invalid child record")
                demand(type(child.get("ExitCode")) is int and child["ExitCode"] == 0,
                       "Child regression exited unsuccessfully")
                if child.get("SummaryPath"):
                    child_path = self.resolve_path(child["SummaryPath"], path.parent)
                else:
                    child_path = self.resolve_path(child.get("OutputDirectory"), path.parent) / "summary.json"
                child_results = self.expand(child_path)
                if "Count" in child:
                    demand(type(child["Count"]) is int and child["Count"] == len(child_results),
                           "Child result count does not match expanded report")
                collected.extend(child_results)
            demand(Counter(canonical(r) for r in results) ==
                   Counter(canonical(r) for r in collected),
                   "Portfolio Results do not exactly match all child results")
            return collected
        if report.get("Compile") is not None:
            require_pass(report["Compile"], str(path) + " compile")
        self.leaves.append((path, report))
        return results

    def source_entries(self, entries, directory, context):
        demand(isinstance(entries, list) and bool(entries), context + ": empty/missing source list")
        normalized = {}
        for entry in entries:
            demand(isinstance(entry, dict), context + ": malformed source entry")
            name = relative_name(entry.get("Path"))
            sha = entry.get("Sha256")
            demand(isinstance(sha, str) and re.fullmatch(r"[0-9a-fA-F]{64}", sha),
                   context + ": invalid SHA-256 for " + name)
            demand(name not in normalized, context + ": duplicate normalized source path " + name)
            path = (directory / name).resolve()
            demand(directory.resolve() in path.parents, context + ": source escapes snapshot")
            demand(path.is_file(), context + ": missing source " + str(path))
            actual = digest(path)
            demand(actual == sha.lower(), context + ": source hash mismatch: " + name)
            normalized[name] = sha.lower()
        return [{"Path": name, "Sha256": normalized[name]} for name in sorted(normalized)]

    def provenance(self, path, report):
        manifest_path = self.resolve_path(report.get("SourceManifestPath"), path.parent)
        manifest = self.load(manifest_path, "source_manifest")
        if "SourceManifestSha256" in report:
            demand(str(report["SourceManifestSha256"]).lower() == digest(manifest_path),
                   "SourceManifestSha256 does not match source manifest")
        snapshot = self.resolve_path(manifest.get("SnapshotDirectory"), manifest_path.parent)
        demand(snapshot.is_dir(), "Missing frozen snapshot: " + str(snapshot))
        sources = self.source_entries(manifest.get("Sources"), snapshot, "Frozen sources")
        listed = {entry["Path"] for entry in sources}
        present = {item.relative_to(snapshot).as_posix() for item in snapshot.rglob("*") if item.is_file()}
        demand(present == listed, "Frozen snapshot contains unlisted or missing files")
        demand(CATALOG_PATH in listed, "Coverage catalog is not part of frozen source manifest")
        version = report.get("ToolVersion")
        demand(isinstance(version, str) and bool(version.strip()), "Missing simulator ToolVersion")
        simulator = report.get("VsimPath") or report.get("XrunPath") or report.get("Simulator")
        demand(isinstance(simulator, str) and bool(simulator.strip()), "Missing simulator identity")
        tool = {
            "ToolVersion": version.strip(),
            "Simulator": simulator.replace("\\", "/"),
            "CoverageEnabled": report.get("CoverageEnabled"),
            "SvaEnabled": report.get("SvaEnabled"),
            "UvmNoDpiEnabled": report.get("UvmNoDpiEnabled"),
            "DpiExportModeResolved": report.get("DpiExportModeResolved"),
        }
        if manifest.get("UvmSources"):
            uvm_dir = self.resolve_path(manifest.get("UvmSourceDirectory"), manifest_path.parent)
            tool["UvmSources"] = self.source_entries(manifest["UvmSources"], uvm_dir, "UVM sources")
        else:
            uvm = report.get("UvmProvenance", manifest.get("UvmProvenance"))
            demand(isinstance(uvm, (str, dict)) and bool(uvm),
                   "UVM source hashes or explicit built-in UvmProvenance are required")
            tool["UvmProvenance"] = uvm
        src_sig = signature(sources)
        prov_sig = signature(tool)
        if self.source_signature is None:
            self.source_signature = src_sig
            self.provenance_signature = prov_sig
            self.source_files = sources
            self.tool_provenance = tool
            self.catalog_file = snapshot / CATALOG_PATH
            self.catalog = self.load(self.catalog_file, "coverage_catalog")
            self.validate_catalog()
        else:
            demand(src_sig == self.source_signature,
                   "Cannot merge differing full frozen source/catalog signatures")
            demand(prov_sig == self.provenance_signature,
                   "Cannot merge differing simulator/UVM/compile-option provenance")
            self.record(snapshot / CATALOG_PATH, "coverage_catalog")
        return src_sig, prov_sig

    def validate_catalog(self):
        demand(self.catalog.get("schema_version") == 1, "Unsupported catalog schema_version")
        demand(self.catalog.get("metric") == METRIC, "Catalog is not observed_requirement_bins")
        bins = self.catalog.get("bins")
        demand(isinstance(bins, list) and bool(bins), "Coverage catalog has no bins")
        ids = set()
        required = 0
        for entry in bins:
            demand(isinstance(entry, dict), "Invalid catalog bin")
            name = entry.get("id")
            demand(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_.-]+", name),
                   "Invalid catalog bin ID")
            demand(name not in ids, "Duplicate catalog bin ID: " + name)
            ids.add(name)
            demand(type(entry.get("required")) is bool, "Every bin needs explicit required boolean")
            demand(isinstance(entry.get("requirement_id"), str) and bool(entry["requirement_id"]),
                   "Every bin needs requirement_id")
            demand(isinstance(entry.get("description"), str) and bool(entry["description"]),
                   "Every bin needs description")
            required += entry["required"]
        demand(required > 0, "Catalog has no required bins")
        demand(isinstance(self.catalog.get("exclusions"), list), "Catalog must state explicit exclusions")
        for exclusion in self.catalog["exclusions"]:
            demand(isinstance(exclusion, dict) and isinstance(exclusion.get("id"), str) and
                   isinstance(exclusion.get("reason"), str), "Malformed catalog exclusion")

    def read_hits(self, path):
        self.record(path, "coverage_tsv")
        expected = {entry["id"] for entry in self.catalog["bins"]}
        rows = {}
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            reader = csv.reader(handle, delimiter="\t")
            demand(next(reader, None) == ["bin", "hits"], "Invalid TSV header: " + str(path))
            for row in reader:
                demand(len(row) == 2, "Malformed TSV row: " + str(path))
                name, raw = row
                demand(name in expected, "Unknown coverage bin: " + name)
                demand(name not in rows, "Duplicate coverage bin: " + name)
                demand(re.fullmatch(r"[0-9]+", raw) is not None,
                       "Coverage hits must be nonnegative integers: " + name)
                rows[name] = int(raw)
        demand(set(rows) == expected, "Missing coverage bins or incorrect row count: " + str(path))
        return rows

    def merge(self, report_paths):
        for path in report_paths:
            self.expand(path)
        demand(bool(self.leaves), "No leaf regression reports found")
        seen_configurations = set()
        totals = None
        hit_by = {}
        evidence = []
        for path, report in self.leaves:
            source_sig, provenance_sig = self.provenance(path, report)
            if totals is None:
                totals = {entry["id"]: 0 for entry in self.catalog["bins"]}
                hit_by = {entry["id"]: [] for entry in self.catalog["bins"]}
            seen_test_seed = set()
            for entry in report["Results"]:
                test, seed = entry.get("Test"), entry.get("Seed")
                demand(isinstance(test, str) and bool(test), "Missing test name")
                demand(type(seed) is int, "Seed must be an integer")
                phase = entry.get("Phase", "default")
                demand(isinstance(phase, str) and bool(phase), "Invalid result Phase")
                demand((phase, test, seed) not in seen_test_seed,
                       "Duplicate test+seed within campaign: " + phase + "/" + test + "/" + str(seed))
                seen_test_seed.add((phase, test, seed))
                args = entry.get("PlusArgs", report.get("PlusArgs", []))
                demand(isinstance(args, list) and all(isinstance(arg, str) for arg in args),
                       "PlusArgs must be an array of strings")
                # Artifact destination and banner suppression do not make a new stimulus.
                semantic = sorted(arg for arg in args if not arg.startswith("+COVERAGE_FILE=")
                                  and arg != "+UVM_NO_RELNOTES")
                config = {"Test": test, "Seed": seed, "PlusArgs": semantic}
                config_id = signature(config)
                demand(config_id not in seen_configurations,
                       "Duplicate/retried test+seed+configuration across reports: " + test + "/" + str(seed))
                seen_configurations.add(config_id)
                coverage_path = self.resolve_path(entry.get("CoveragePath"), path.parent)
                hits = self.read_hits(coverage_path)
                evidence_id = "run-" + str(len(evidence) + 1)
                record = {
                    "Id": evidence_id, "Test": test, "Seed": seed, "Phase": phase, "PlusArgs": args,
                    "ConfigurationSignature": config_id, "ReportPath": str(path),
                    "CoveragePath": str(coverage_path), "CoverageSha256": digest(coverage_path),
                    "SourceSignature": source_sig, "ProvenanceSignature": provenance_sig,
                }
                evidence.append(record)
                for name, count in hits.items():
                    totals[name] += count
                    if count:
                        hit_by[name].append(evidence_id)
        required = [b["id"] for b in self.catalog["bins"] if b["required"]]
        missing = [name for name in required if totals[name] == 0]
        output_bins = [dict(entry, Hits=totals[entry["id"]], HitBy=hit_by[entry["id"]])
                       for entry in self.catalog["bins"]]
        # Detect input changes between validation and artifact emission.
        for record in self.records.values():
            demand(digest(Path(record["Path"])) == record["Sha256"],
                   "Input changed during merge: " + record["Path"])
        return {
            "SchemaVersion": 1, "Metric": METRIC,
            "AnalysisTool": {"Path": str(Path(__file__).resolve()), "Sha256": digest(Path(__file__).resolve())},
            "Relocations": self.relocations,
            "RelocatedPaths": list(self.relocated_paths.values()),
            "Status": "CLOSED" if not missing else "OPEN",
            "GeneratedUtc": datetime.now(timezone.utc).isoformat(),
            "RequiredBins": len(required), "HitRequiredBins": len(required) - len(missing),
            "ObservedRequirementBinPercent": round(100 * (len(required) - len(missing)) / len(required), 2),
            "MissingBins": missing, "Bins": output_bins, "Results": evidence,
            "SourceSignatures": [self.source_signature],
            "ProvenanceSignatures": [self.provenance_signature],
            "SourceFiles": self.source_files, "ToolProvenance": self.tool_provenance,
            "CatalogPath": str(self.catalog_file), "Exclusions": self.catalog["exclusions"],
            "InputRecords": list(self.records.values()),
            "Limitations": "Finite observed requirement-bin coverage only; not native covergroup, RTL code, assertion coverage, or proof of universal correctness.",
        }


def markdown(report):
    if report["Status"] == "INVALID":
        return "# Observed requirement coverage: INVALID\n\nNo coverage percentage was accepted.\n\n" + "\n".join(
            "- " + error.replace("\n", " ") for error in report["Errors"]) + "\n"
    lines = [
        "# Observed requirement coverage: " + report["Status"], "",
        str(report["HitRequiredBins"]) + "/" + str(report["RequiredBins"]) +
        " required bins hit (" + str(report["ObservedRequirementBinPercent"]) + "%).", "",
        report["Limitations"], "",
        "Accepted runs: " + str(len(report["Results"])) +
        ". All listed runs passed; no failed run or retry was discarded.", "",
        "Frozen source SHA-256 signature: `" + report["SourceSignatures"][0] + "`", "",
        "Missing required bins: " + (", ".join(report["MissingBins"]) or "none") + ".", "",
        "| Bin | Requirement | Hits | Evidence |",
        "| --- | --- | ---: | --- |",
    ]
    for entry in report["Bins"]:
        lines.append("| " + entry["id"] + " | " + entry["requirement_id"] + " | " +
                     str(entry["Hits"]) + " | " + (", ".join(entry["HitBy"]) or "unhit") + " |")
    lines += ["", "## Evidence index", "", "| Evidence | Test | Seed | Configuration |",
              "| --- | --- | ---: | --- |"]
    for entry in report["Results"]:
        lines.append("| " + entry["Id"] + " | " + entry["Test"].replace("|", "\\|") +
                     " | " + str(entry["Seed"]) + " | `" +
                     entry["ConfigurationSignature"][:12] + "` |")
    lines += ["", "Full arguments, paths, hashes, bin descriptions, and source identities are in coverage_summary.json.",
              "", "## Explicit exclusions", ""]
    for entry in report["Exclusions"]:
        lines.append("- **" + entry["id"] + "**: " + entry["reason"])
    return "\n".join(lines) + "\n"


def run(report_paths, output, relocations=None):
    merger = None
    try:
        merger = Merger(relocations)
        report = merger.merge([Path(path).resolve() for path in report_paths])
        code = 0 if report["Status"] == "CLOSED" else 3
    except (CoverageError, OSError, ValueError, TypeError, KeyError) as exc:
        report = {"SchemaVersion": 1, "Metric": METRIC, "Status": "INVALID",
                  "Errors": [str(exc)], "InputRecords": list(merger.records.values()) if merger else []}
        code = 2
    report.setdefault("AnalysisTool", {"Path": str(Path(__file__).resolve()),
                                      "Sha256": digest(Path(__file__).resolve())})
    report.setdefault("Relocations", merger.relocations if merger else [])
    report.setdefault("RelocatedPaths", list(merger.relocated_paths.values()) if merger else [])
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    (output / "coverage_summary.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    (output / "coverage.md").write_text(markdown(report), encoding="utf-8")
    print("Observed requirement coverage: " + report["Status"] + " -> " + str(output))
    if code == 2:
        print(report["Errors"][0], file=sys.stderr)
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reports", nargs="+", required=True, help="Leaf or portfolio summary.json files")
    parser.add_argument("--output", required=True, help="Output directory for JSON and Markdown")
    parser.add_argument("--relocate", nargs=2, action="append", default=[],
                        metavar=("OLD_ROOT", "NEW_ROOT"),
                        help="Explicit artifact-root relocation (repeatable); hashes remain required")
    args = parser.parse_args()
    return run(args.reports, args.output, args.relocate)


if __name__ == "__main__":
    sys.exit(main())
