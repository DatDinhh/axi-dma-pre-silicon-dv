# Running the UVM environment on Xcelium

I prepared a Linux runner for the same 39-case UVM campaign, with native coverage
and concurrent SVA enabled. I have checked its process handling and failure gates
with local fixtures. **I have not yet compiled or simulated this project on
Xcelium, or collected its native coverage and assertion results.**

## Package and run

Create a source ZIP from the project directory:

```powershell
python -B scripts/package_xcelium.py
```

The command prints the ZIP path and SHA-256. It includes RTL, testbench, scripts,
and documentation, including the coverage requirement catalog. Generated output,
installed tools, private local evidence, and Git metadata are excluded. Transfer
the archive to a Linux machine with a licensed Xcelium installation, then extract
it. Replace `<id>` with the identifier printed by the packaging command:

```bash
unzip axi_dma_xcelium_<id>.zip
cd axi_dma
python3 --version
xrun -version
python3 scripts/run_xcelium.py --probe-capabilities
python3 scripts/run_xcelium.py
```

Python 3.8+ is required. Set up the installed Cadence environment before running
these commands. The runner accepts `--xrun /path/to/xrun` when the executable is
not on PATH; it does not change license variables or guess module names.

The preflight checks UVM, constraint enforcement, covergroup sampling/query, and
an intentionally violated concurrent assertion. All four need to pass before the
campaign. The default matrix contains 39 combinations: eleven normal tests plus
read-error and write-error tests, each with seeds 1, 7, and 42. It uses independent
AW/W timing and bounded stalls. Error injection starts at read address 0x100 and
write address 0x8000, matching the Windows portfolio suite.

```bash
python3 scripts/run_xcelium.py --tests copy_test --seeds 1 --waves
python3 scripts/run_xcelium.py --timeout 1200
python3 scripts/run_xcelium.py --xrun /path/to/xrun
python3 scripts/run_xcelium.py --dry-run
```

`--dry-run` works without Xcelium and records NOT_RUN. It produces commands, not
simulation evidence. The 600-second default timeout applies to each combined
compile/run. A timeout terminates the simulator process group and remains a failure.

## Reports and pass criteria

Every run creates `output/xcelium_<id>/` with a source snapshot, SHA-256 manifest,
exact argument arrays and replay commands, simulator version, per-case logs,
JSON/JUnit reports, observed-requirement TSVs, and native databases. New runs use
new directories. HDL is compiled from the snapshot. Cadence bundled UVM is selected
with `-uvmhome CDNS-1.2`; logs retain the tool version and UVM banner. Vendor sources
are not redistributed.

A normal case requires exit zero, its exact `<test> PASSED` marker, zero UVM
errors/fatals, no simulator/assertion error, a complete catalog TSV, and a nonempty
native `.ucd` database. The runner does not retry or waive failures. Exit codes are
0 for all selected cases passing or a completed dry-run, 1 for a setup failure,
and 3 for a run failure.

The runner enables `ENABLE_SV_COV`, `ENABLE_SVA`, and `-coverage all`, using native
Cadence UVM/DPI. Optional SHM files open with `simvision waves.shm` in the case's
output directory.

## Coverage review

I treat a passing campaign and coverage closure as separate results. Native
covergroup crosses need reachability review, and assertions need evidence of
activation as well as the absence of failures. After running the campaign, I
would inspect the native bins, branches, and assertion results in IMC, add missing
reachable scenarios, and document any valid exclusions.

The portable requirement-bin merger operates separately from native databases.
Replace `RUN_DIRECTORY` with the directory printed by the runner:

```bash
python3 scripts/merge_coverage.py --reports output/RUN_DIRECTORY/summary.json --output output/RUN_DIRECTORY/coverage
```

The merger checks passing results, source/catalog hashes, the complete declared
matrix, and each TSV. It reports the finite observed requirement-bin metric; it
does not merge native coverage databases.

The report records `.ucd` paths. The installed IMC help (`help merge` and
`help report_metrics`) describes release-specific merging and reporting. Model
mismatch warnings need review before combining databases. Xcelium and ModelSim
results remain separate simulator measurements.

## Moving evidence between machines

Keep the complete run directory, including `source/`, manifests, case directories,
`summary.json`, `junit.xml`, and native databases. An aggregate percentage or a
screenshot cannot supply the source and per-case provenance used by the merger.

If a run is copied to another machine, supply an explicit relocation mapping.
Replace `/original/output/run` with the report's original `OutputDirectory`, and
`./output/copied-run` with the copied directory:

```powershell
python -B scripts/merge_coverage.py --reports ./output/copied-run/summary.json --output ./output/copied-run/coverage_verified --relocate /original/output/run ./output/copied-run
```

Relocation changes where artifacts are read. It does not change hashes or the
recorded tool provenance, and the report lists each mapping. Missing source files,
missing matrix members, unfinished runs, and dry-runs cannot close coverage.

## Command references

I used these official Cadence examples when preparing the runner. The installed
Xcelium release still needs runtime validation:

- [UVM selection and automatic compilation](https://community.cadence.com/cadence_technology_forums/f/functional-verification/57172/why-my-xrun-does-not-compile-uvm-library-package-automatically): `-uvm`, `-uvmhome`.
- [Coverage invocation](https://community.cadence.com/cadence_technology_forums/f/functional-verification/17448/merging-issues-in-functional-coverage): `-coverage all`, `-covtest`, `-covworkdir`.
- [Coverage directory layout](https://community.cadence.com/cadence_technology_forums/f/functional-verification/55578/merge-command-error/1387841): `.ucd` paths for IMC.
- [Seed semantics](https://community.cadence.com/cadence_technology_forums/f/functional-verification/42123/a-test-runs-differently-if-i-use-the--svseed-command-line-switch-or-i-set-the-seed-via-tcl-and-then-give-run/1362129): `-svseed` at startup.
- [SHM waveform commands](https://community.cadence.com/cadence_technology_forums/f/functional-verification/27090/sv-help-how-can-dump-the-wave-from-class/1326552): `-input`, database/probe, `run`, `exit`.

The local runner fixtures validate control flow and failure handling. They do not
validate Cadence compilation or HDL behavior.
