#!/usr/bin/env python3
"""Create a source-only ZIP for a Linux Xcelium host."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import sys
import uuid
import zipfile
from run_xcelium import ROOT, source_files


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="New ZIP path (default output/axi_dma_xcelium_<unique id>.zip)")
    args = parser.parse_args(argv)
    bundle_id = uuid.uuid4().hex[:12]
    output = (args.output or ROOT / "output" / ("axi_dma_xcelium_" + bundle_id + ".zip")).resolve()
    if output.exists():
        parser.error("Refusing to overwrite an existing handoff bundle: " + str(output))
    files = source_files(ROOT) + [ROOT / "README.md", ROOT / ".gitignore", ROOT / ".gitattributes"]
    files += [path for path in (ROOT / "docs").rglob("*") if path.is_file() and path.suffix in (".md", ".json", ".svg", ".png", ".vcd")]
    entries = []
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for source in sorted(set(files)):
            if source.is_symlink():
                raise ValueError("Symlinks cannot be packaged: " + str(source))
            relative = source.relative_to(ROOT).as_posix()
            data = source.read_bytes()
            entries.append({"Path": relative, "Sha256": hashlib.sha256(data).hexdigest().upper(), "Bytes": len(data)})
            archive.writestr("axi_dma/" + relative, data)
        manifest = {"SchemaVersion": 1, "CreatedUtc": dt.datetime.now(dt.timezone.utc).isoformat(),
                    "Purpose": "Xcelium source/scripts/docs bundle; runtime validation pending", "Files": entries}
        archive.writestr("axi_dma/HANDOFF_MANIFEST.json", json.dumps(manifest, indent=2) + "\n")
    with zipfile.ZipFile(output) as archive:
        if archive.testzip() is not None:
            raise ValueError("ZIP integrity verification failed")
        for entry in entries:
            if hashlib.sha256(archive.read("axi_dma/" + entry["Path"])).hexdigest().upper() != entry["Sha256"]:
                raise ValueError("ZIP content hash mismatch: " + entry["Path"])
    print("Bundle: " + str(output))
    print("SHA-256: " + hashlib.sha256(output.read_bytes()).hexdigest().upper())
    print("Packaged %d source/script/document files; no git, generated outputs, logs, or tool installations." % len(entries))
    return 0


if __name__ == "__main__":
    sys.exit(main())
