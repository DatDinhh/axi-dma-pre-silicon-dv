# Local simulation and synthesis results

I use two simulation lanes to check the DMA: a four-state UVM environment in
ModelSim and a separate Verilator testbench around `top_soc_dut`. I added the
Verilator lane to execute concurrent assertions and measure native code coverage,
then checked the same RTL with Quartus Analysis & Synthesis. These additions did
not change the RTL behavior.

## Measured results

| Lane | Result | Scope |
| --- | --- | --- |
| ModelSim UVM 1.2 campaign | 39/39 PASS; 70/70 selected requirement bins | Existing four-state UVM environment; previously recorded baseline |
| Verilator 5.020 full-DUT campaign | 60/60 PASS | 20 cases, seeds 1/7/42; concurrent SVA and native code/toggle coverage |
| Local checker controls | Clean control PASS; both deliberate defects detected | Stalled AW payload mutation and independent memory-oracle guard corruption |
| Quartus 20.1.1 Analysis & Synthesis | PASS, zero errors | Exact four-file RTL snapshot; map only on Cyclone V 5CSEMA5F31C6 |
| ModelSim after interface guards | Smoke PASS | Default UVM interface behavior retained |

The [local campaign](results/local_verilator_suite.json) exercises 579 transfers:
564 completed results and 15 reset cancellations. The random cases contain
128 descriptors per seed (384 total). The independent oracle checked 37,945,344
memory bytes across all completions and reset aborts. This is repeated checking
of the 64 KiB memory, not that much distinct storage or copied data.

The testbench checks accepted CSR responses, source/destination addresses, read
and write payloads, exact transfer/error progress, and the whole memory image.
Tests include all non-full CSR strobe masks, address/order/response delays,
length/alignment/range/overflow cases, page/end-of-memory boundaries, IRQ events,
busy START, five reset phases, seeded copies, and first/middle/last response errors.

## Native code coverage

I report counts of native Verilator instrumented points. Each metric has its
own denominator; testbench, interface and responder code is excluded from RTL
totals. No unhit points have been removed as waivers.

| Metric | Hit / total | Measured percentage |
| --- | ---: | ---: |
| Line/block points | 40 / 44 | 90.91% |
| Branch outcomes | 65 / 70 | 92.86% |
| Toggle points | 1098 / 1474 | 74.49% |

See the [per-file report](results/local_native_coverage.md) and
[raw-point summary](results/local_native_coverage.json). The package contains
constants/helpers without separate surviving counters in this elaboration; the
top-level wiring has toggle instrumentation, not executable block counters.
The optional LCOV export is lossy: Verilator projects multiple coverage types
onto source lines. It is not used as the denominator for the table above.

I reviewed the unhit line/block and branch points as follows:

| Location | Reason it is unhit in this campaign |
| --- | --- |
| Engine malformed-RLAST error path | This full-DUT campaign uses a protocol-valid responder. Malformed RLAST is checked separately by the existing engine unit test; its coverage is not mixed into this campaign. |
| Engine state-machine default | Defensive recovery from an illegal state; no internal state corruption was injected. |
| Engine/register `ALIGN_LSB == 0` branches | The selected 32-bit word configuration has alignment bits; the byte-wide alternative is outside this elaboration. |
| Engine range helper's zero-length fast path | Descriptor validation rejects zero length before reaching that helper path. |
| Register decode/read default branches | Prior range/alignment validation restricts accepted offsets to the eight defined word registers. |
| Disabled BYTES_REMAIN branch | This elaboration fixes `ENABLE_BYTES_REMAIN=1`. |

This review explains the selected configuration and stimulus; I did not perform
a formal reachability proof. Unhit toggle points include fixed AXI attributes,
upper address bits constrained by the 64 KiB range, alignment bits, and other
bits not toggled by this stimulus. Toggle closure has not been claimed.

## Concurrent assertion evidence

The local checker enables 21 concurrent assertions and exports 37 native cover
properties. All ten channel handshake coverpoints are hit. Stall/release traffic
exercises the hold assertions on AXI AR/AW/W and AXI-Lite B/R. The other five
channel hold antecedents are unhit in the positive DUT campaign: the DMA consumes
its AXI R/B responses directly, and the serial CSR driver does not queue a new
AW/W/AR behind an outstanding CSR response.

Therefore, zero assertion failures does not mean every hold assertion was tested
non-vacuously. The [activation audit](results/local_sva_activation.md) verifies
the complete 37-point inventory, 27 hit points, all ten handshake channels and
each channel's hold status. It also checks the completed matrix, source hashes,
negative controls and that merged activation contains only the 60 positive DUT
runs. Its 20 synthetic failure-gate fixtures pass; those fixtures are not DUT evidence. The isolated
negative control deliberately changes held AW payload and aborts on the concurrent
`a_hold` property with `LOCAL_SVA_HOLD`. A separate guard-byte mutation aborts with
`ORACLE_MEMORY`. Neither negative run contributes to the DUT coverage totals.

Verilator is predominantly two-state; X/Z propagation and native UVM covergroups
remain outside this lane. These measurements supplement the four-state ModelSim
UVM results. They are not formal proof, native covergroup closure, or a combined
coverage percentage across simulators.

## Exact-source synthesis

[Quartus synthesis](results/local_synthesis.md) uses unchanged RTL on a selected
Cyclone V part. It reports 424 registers, 434 combinational ALUTs and 319 estimated
ALMs, with no RAM or DSP blocks. The 67 warnings were reviewed: fixed output bits,
unused protection/ID inputs, and wide-address case-enumeration warnings where
explicit default branches exist. The tool reports no latch, multiple-driver,
undriven-net or combinational-loop finding.

These are mapping estimates and diagnostics. No fitter, routing, timing analysis
or timing closure was run. The Yosys native SystemVerilog parser rejected the
package's `timeunit` declaration; that attempt is preserved as unsupported,
not counted as a passing synthesis or formal result.

## Reproduce with installed tools

I run these commands from PowerShell in the project directory. The Verilator
lane needs Linux or WSL with Verilator, make, and a C++ compiler. The synthesis
runner finds `quartus_map` through PATH or `QUARTUS_ROOTDIR`; an explicit
`--quartus-map /path/to/quartus_map` overrides discovery:

```powershell
wsl -d Ubuntu -- python3 -B scripts/run_local_verilator.py
python scripts/check_synthesis.py
```

The Verilator runner compiles with assertions and native line/branch/toggle/user
coverage, freezes its HDL, scripts and generated C++/coverage configuration, and
records hashes, arguments, logs, binaries and JSON/JUnit reports. It merges only
passing positive-DUT coverage; incomplete or failed executions remain failed.
The C++ build uses `-O0` to keep the large coroutine testbench compile inexpensive;
this is a testbench build choice, not an RTL modification.

`DMA_RAW_INTERFACES` removes only unused clocking blocks and clocking-based modport
declarations for the older Verilator. Raw signals and DUT/slave connections remain
the same. Without the define, the interface text is unchanged apart from guard
directives; the normal UVM path still compiles and passes its smoke test. The
[guard audit](results/local_interface_guard_audit.json) records the transformation.

After a new campaign, replace `RUN_DIRECTORY` with the printed directory name
and run the independent activation/provenance audit. Its output directory must
be new so prior evidence is preserved:

```powershell
wsl -d Ubuntu -- python3 -B scripts/check_local_sva_coverage.py --report output/RUN_DIRECTORY/summary.json --output output/RUN_DIRECTORY/sva_activation_audit
```

For a shorter run, select cases and seeds, for example:

```powershell
wsl -d Ubuntu -- python3 -B scripts/run_local_verilator.py --cases csr random --seeds 7 --count 16
```

I prepared an [Xcelium workflow](xcelium.md) for native UVM covergroups and another
simulator cross-check. I have not yet run that campaign. The measurements above
come from the completed local simulations and synthesis run.
