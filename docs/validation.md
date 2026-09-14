# UVM validation record

I ran the baseline as a 32-bit, aligned, serialized single-beat AXI DMA with a
UVM 1.2 environment. This record covers the completed UVM campaign, checker
self-tests, and infrastructure checks. Each campaign freezes its source inputs
and records SHA-256 hashes. The checked-in [review reports](results/README.md)
retain measured results and source fingerprints, with machine-specific paths
sanitized for publication.

I also ran a separate [local verification campaign](local_validation.md): 60/60
full-DUT Verilator cases with concurrent SVA and native code coverage, plus Quartus
Analysis & Synthesis. That lane uses the same RTL behavior and a separate classless
testbench. Its results are reported independently below the UVM evidence.

## Completed UVM campaign

The [complete campaign](results/v1_portfolio_sweep.json) achieved **39/39 PASS**
in one sweep, with **zero simulator crashes, zero timeouts, and zero automatic
retries**. The source-checked merge reports **70/70 selected requirement bins hit**
and an empty missing-bin list. The [bin report](results/v1_requirement_coverage.md)
and [JSON report](results/v1_requirement_coverage.json) list individual results.

The campaign used ModelSim Intel FPGA Starter 2020.1 on Windows, bundled UVM 1.2,
`UVM_NO_DPI`, seeds 1, 7, and 42, `AXI_AW_WAIT_W=1`, and `AXI_STALL_MAX=7`.
It ran eleven normal classes plus read-error and write-error classes. Each seeded
copy case checked 32 descriptors. Each error case exercised word 1, 8, and 16 of a
64-byte descriptor, with a recovery copy after every error.

[Scoreboard totals](results/v1_campaign_totals.json): 231 descriptor starts,
216 completed results, 15 reset cancellations, three ignored busy STARTs, and
15,138,816 memory bytes checked. The byte total counts repeated comparisons of
a 64 KiB memory; it is not distinct storage capacity or transfer throughput. The
seeded tests covered 96 descriptors. Their runtimes were approximately 122, 113,
and 98 seconds, below the 180-second per-case limit.

Every case required its exact completion marker, zero UVM errors/fatals, a
successful simulator exit, no timeout, and a complete observed-bin TSV. The
coverage merger rejects failed, incomplete, repeated, or incompatible campaigns.

## Source provenance

The three campaign phases had identical manifests for 41 repository inputs and
145 bundled UVM files. I then hardened report validation and relocation handling,
added declared-matrix metadata to the Xcelium runner, and removed trailing blank
lines from two files. The [source audit](results/release_source_audit.json) records
those differences; no HDL behavior changed. A separate smoke compile/run passed
on that later source state.

The local Verilator lane subsequently added conditional guards around clocking
declarations unused by its raw-signal harness. The default UVM interface path
passed a [fresh smoke run](results/local_uvm_interface_smoke.json). The
[guard audit](results/local_interface_guard_audit.json) records that change.

These reports identify specific executed snapshots. Later documentation, report
sanitization, and tool-path or output-naming cleanup do not retroactively change
which source files were compiled in a historical campaign.

## Meaning of the coverage result

I selected 70 reachable observed requirement bins in the
[versioned catalog](../tb/coverage/coverage_requirements.json). They sample
accepted CSR and bus responses, actual AW/W handshake order and stalls,
reset-phase signals, error-response positions, and checked completion results.
Each bin is mapped to the tests that hit it.

This is an **observed requirement-bin metric**. It is separate from native UVM
covergroup, RTL code, and assertion coverage. The denominator is the explicit
baseline selection; exclusions document unsupported features and behavior checked
separately by unit tests. Native cross-bin reachability still needs review on
Xcelium. I do not claim native covergroup closure from the 70/70 result.

## Simulator startup mitigation

I ran a [fixed A/B study](results/loader_ab_study.json) with 12 independent
processes per mode. The original loader passed 11/12 and reproduced a
pre-time-zero SIGSEGV; `-nodpiexports` passed 12/12. Bundled UVM declares an unused
reporting DPI export even under `UVM_NO_DPI`. Suppressing its generated wrapper
loading avoided the exercised crash path while retaining the test and checker
activity. This is a tested mitigation, not a diagnosis of the simulator's internal
root cause or a guarantee against all future crashes.

`-DpiExportMode Auto` applies the option only to the tested Windows ModelSim Intel
FPGA Starter 2020.1 pure-SystemVerilog setup. Other configurations retain their
normal behavior. The report records the selected mode and reason. Xcelium uses
its regular UVM/DPI path. The [earlier campaign record](validation_legacy_campaign.md)
keeps the prior failures and targeted reruns separate from the completed campaign.

## Unit and checker evidence

[Fourteen standalone checks](results/v1_unit_checks.json) met their expected
outcomes, with zero JUnit failures:

- Six engine cases: three AW/W orderings, RRESP, BRESP, and malformed RLAST errors.
- Five responder cases: normal and stalled operation, injected errors, and deterministic replay.
- Two protocol-checker cases: clean traffic and an intentional held-payload violation.
- One register-event case: reset, clear/event priority, and diagnostic-code behavior.

The [scoreboard negative test](results/v1_checker_negative.json) intentionally
changed guard byte 0x7ffc after START. It produced `SB_MEMORY`, UVM_ERROR=1, and a
failing runner result despite reaching the scenario's PASSED marker. That result
demonstrates checker detection; it is excluded from ordinary passing DUT cases.

During review, I also found that the reset helper ignored its `at_negedge`
argument. I corrected it to assert reset immediately when the caller is already
at the falling edge. Passive phase bins and whole-memory checking verify the
selected reset phase and preservation of committed bytes. The corrected tests
passed.

## Infrastructure and tool checks

The ModelSim failure gate and real process exit/timeout handling passed their
PowerShell self-tests. The coverage merger passed
[33 synthetic fixtures](results/coverage_merger_fixtures.json) covering input
integrity, source mismatch, invalid bins, incomplete campaigns, and relocation.
The [Xcelium runner fixtures](results/xcelium_runner_fixture_tests.json) check
process handling and failure gates only; they are not HDL simulation evidence.

Runtime probes on the tested ModelSim installation found working UVM, unavailable
solver and native-covergroup licensing, and unsupported concurrent SVA execution.
I kept sampled protocol checks enabled. The separate Verilator capability probe
showed support for concurrent stability assertions and native coverage. The later
[full-DUT campaign](local_validation.md), rather than the probe alone, supplies
the actual RTL measurements.

## Remaining validation

I prepared the [Xcelium workflow](xcelium.md) for a native 39-case UVM/SVA/coverage
campaign. **Actual Xcelium compilation, simulation, coverage databases, and
assertion results remain pending.** A dry-run or passing process fixture does not
complete that step. I will need to review native code and covergroup coverage,
assertion activation, unhit reachable cases, and valid exclusions before claiming
native coverage closure.

Bursts, multiple outstanding IDs, RAL, solver-based stimulus, cycle-exact
completion/IRQ prediction, and formal or timing signoff are outside this baseline.
The local synthesis result covers mapping only.

## Reproduce

```powershell
.\scripts\run_unit_checks.ps1
.\scripts\run_portfolio_suite.ps1 -TimeoutSeconds 180
.\scripts\Test-RegressionTools.ps1
python -B -m unittest discover -s scripts -p test_merge_coverage.py
```

Use `-PythonPath` if Python 3 is not on PATH. New runs write full logs, waves,
frozen sources, commands, manifests, and JSON/JUnit reports to their printed
`output/` directories; unit runs use `out/`. I keep selected sanitized review
reports in `docs/results/`.
