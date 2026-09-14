"""Read native Verilator counters; keep code, toggle and assertion activation separate."""
import json
import re
from collections import defaultdict
from pathlib import Path


def read_native(path):
    points = []
    seen = set()
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"C '(.*)' ([0-9]+)", line)
        if not match:
            raise ValueError("Malformed native coverage record")
        encoded, count = match.groups()
        if encoded in seen:
            raise ValueError("Duplicate native coverage point")
        seen.add(encoded)
        fields = {}
        for field in encoded.split("\x01"):
            if not field:
                continue
            key, value = field.split("\x02", 1)
            if key in fields:
                raise ValueError("Duplicate native coverage metadata")
            fields[key] = value
        if not all(key in fields for key in ("f", "l", "page")):
            raise ValueError("Native coverage metadata is incomplete")
        points.append({"File": fields["f"], "Line": int(fields["l"]),
                       "Column": fields.get("n", ""), "Page": fields["page"],
                       "Label": fields.get("o", ""), "Hierarchy": fields.get("h", ""),
                       "Hits": int(count)})
    if not points:
        raise ValueError("Empty native coverage data")
    return points


def measured(points):
    hit = sum(point["Hits"] > 0 for point in points)
    return {"Hit": hit, "Total": len(points),
            "Percent": round(100 * hit / len(points), 2) if points else None}


def summarize(native_path, snapshot):
    snapshot = Path(snapshot).resolve()
    points = read_native(native_path)
    groups = defaultdict(lambda: defaultdict(list))
    user = []
    for point in points:
        try:
            relative = Path(point["File"]).resolve().relative_to(snapshot).as_posix()
        except ValueError:
            raise ValueError("Coverage references a file outside its frozen snapshot: " + point["File"])
        point["File"] = relative
        if point["Page"].startswith("v_user/"):
            user.append(point)
        if relative.startswith("rtl/"):
            for prefix, name in (("v_line/", "LineBlockPoints"),
                                 ("v_branch/", "BranchOutcomePoints"),
                                 ("v_toggle/", "TogglePoints")):
                if point["Page"].startswith(prefix):
                    groups[relative][name].append(point)
    if not groups:
        raise ValueError("No DUT RTL coverage points were exported")
    kinds = ("LineBlockPoints", "BranchOutcomePoints", "TogglePoints")
    totals = {kind: measured([p for file in groups.values() for p in file[kind]]) for kind in kinds}
    return {"SchemaVersion": 1, "Metric": "verilator_instrumented_code_points",
            "Scope": "Only rtl/ files in the simulated top_soc_dut elaboration",
            "Totals": totals,
            "Files": [{"File": name, **{kind: measured(groups[name][kind]) for kind in kinds}}
                      for name in sorted(groups)],
            "UnhitCodePoints": [p for name in sorted(groups) for kind in kinds
                                for p in groups[name][kind] if p["Hits"] == 0],
            "AssertionActivationPoints": user,
            "Limitations": [
                "Percentages count Verilator-instrumented points, not every textual HDL line.",
                "Line/block, branch outcomes, toggles and cover-property activation have different denominators.",
                "Testbench/interface/responder counters are excluded from RTL totals.",
                "Verilator is a predominantly two-state simulator; this lane does not verify X/Z behavior.",
                "Cover-property hits show exercised scenarios, not formal proof or native covergroup closure.",
                "The optional LCOV export merges coverage types by source line and is a lossy projection."]}


def write_summary(report, directory):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "code_coverage.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    rows = ["# Local native Verilator coverage", "", report["Scope"], "",
            "Each column uses its own instrumented-point denominator; no exclusions are subtracted.", "",
            "| RTL file | Line/block points | Branch outcomes | Toggle points |",
            "| --- | ---: | ---: | ---: |"]
    def cell(value):
        return ("%d/%d (%.2f%%)" % (value["Hit"], value["Total"], value["Percent"])) if value["Total"] else "not instrumented"
    for file in report["Files"] + [{"File": "TOTAL", **report["Totals"]}]:
        rows.append("| " + file["File"] + " | " + " | ".join(cell(file[k]) for k in
                    ("LineBlockPoints", "BranchOutcomePoints", "TogglePoints")) + " |")
    rows += ["", "## Concurrent assertion activation", "",
             "Native cover properties below are collected during passing DUT runs only.", "",
             "| Property instance | Hits |", "| --- | ---: |"]
    for point in report["AssertionActivationPoints"]:
        rows.append("| " + (point["Hierarchy"] or point["Label"]).replace("|", "\\|") + " | " + str(point["Hits"]) + " |")
    rows += ["", "## Limits", ""] + ["- " + line for line in report["Limitations"]]
    (directory / "code_coverage.md").write_text("\n".join(rows) + "\n", encoding="utf-8")
