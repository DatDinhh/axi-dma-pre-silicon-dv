# Earlier campaign and simulator loader failures

I keep this record to explain why I changed the ModelSim launch configuration.
These earlier runs contain failures and targeted reruns; they are separate from
the later [39/39 passing UVM campaign](validation.md).

## Before the mitigation

The [first portfolio attempt](results/initial_portfolio_attempt.json) passed 33/39
combinations. Three cases crashed during generated DPI DLL loading before UVM
started. The three seeded-copy cases reached the selected 60-second wall-clock
limit. A focused 32-descriptor run passed with a 180-second limit; subsequent
stressed seeded runs took roughly 100–117 seconds.

The next [complete sweep](results/final_portfolio_sweep.json) passed 37/39 cases,
with two startup failures and no timeouts. Its runner exit remained 3. I recorded
[two bounded targeted reruns](results/final_targeted_reruns.json) separately: one
passed and the other reproduced a startup crash. That produced passing executions
for 38/39 distinct combinations, **not a clean full-regression PASS**.

The unresolved combination was `out_of_range_test`, seed 1. Both attempts failed
while loading `export_tramp.dll`, before UVM activity. The same scenario passed
with seeds 7 and 42. I did not substitute an older passing seed-1 run for the
failed campaign. The [campaign summary](results/campaign_summary.json) retains
those distinctions and the [source manifest](results/verified_source_manifest.json)
identifies that campaign's inputs.

## Diagnostic result

Shortening TEMP/TMP did not eliminate the intermittent crash. I then ran a fixed
A/B study of normal loading and `-nodpiexports`: 12 independent launches per mode,
with every result retained. The normal mode passed 11/12 and reproduced a loader
SIGSEGV; the no-export mode passed 12/12.

Bundled UVM declares an unused reporting DPI export even under `UVM_NO_DPI`.
Disabling generated export wrappers avoided the exercised DLL-loading path while
retaining the UVM and checker activity. I treat this as a version-specific
mitigation, not proof that the simulator's internal fault is repaired. Details
are in the [loader diagnostic](../scripts/diagnostics/README.md).

The runner's `Auto` mode now selects this option only for the tested Windows
ModelSim Intel FPGA Starter 2020.1 pure-SystemVerilog setup. I ran the later full
39-case campaign independently with that configuration; it completed without
crashes, timeouts, or automatic retries.

## Tool limitations

The [runtime probes](results/simulator_capabilities.json) found working UVM on
this installation, unavailable constraint-solver and covergroup licensing, and
unsupported concurrent SVA execution. Compiling optional syntax did not establish
that those features worked. I kept sampled protocol checks active, used explicit
seeded stimulus, and added the separate [Verilator lane](local_validation.md) for
executed concurrent SVA and native code measurements.
