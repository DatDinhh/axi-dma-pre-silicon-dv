# Design walkthrough

I built a small DMA so I could verify its behavior from the software-visible
registers through the memory bus, including what happens when a transfer fails
or reset interrupts it. This walkthrough explains my main design and verification
choices. The [specification](specification.md) defines the exact contract.

## Scope

The engine copies data between disjoint buffers in a 64 KiB byte-addressed memory.
It uses 32-bit, word-aligned, serialized single-beat AXI INCR accesses and AXI-Lite
control registers. A descriptor may span a 4 KiB boundary because each AXI
transaction contains only one aligned word. I did not implement bursts, multiple
outstanding IDs, scatter-gather, unaligned byte transfers, or CDC.

I kept that scope small enough to check error handling, reset, and memory side
effects thoroughly. An invalid descriptor must leave memory unchanged; an error
or reset during a valid descriptor may leave already committed writes behind.
The reference model needs to distinguish those cases.

## Testbench structure

My main environment is in [dma_uvm_pkg.sv](../tb/uvm/dma_uvm_pkg.sv). Sequences
choose transaction intent, the AXI-Lite driver controls signal timing, and passive
monitors report accepted transactions through UVM analysis ports. The
[README diagram](../README.md#verification-architecture) shows their connections.

I derive the scoreboard's descriptor from observed CSR writes and snapshot memory
before START takes effect. Its address, legality, and data predictions do not call
the RTL's validation helpers. At an observed terminal STATUS read, it compares the
entire memory image: source bytes, destination bytes, guards, and unrelated bytes.
This catches an extra write even when the requested destination data looks right.
Reset checks include the writes that committed before cancellation.

I share named register-map constants because they define the public interface.
I keep the expected behavior independently implemented because duplicating the
RTL's decision logic would risk reproducing the same defect in the checker.

The scoreboard has a deliberate lifecycle limit: software must read terminal
STATUS before issuing the next idle descriptor. IRQ checking is sampled, not a
cycle-exact completion predictor. Shared reset cancels both sides of the memory
protocol. I document these limits so that the evidence can be interpreted against
the behavior actually checked.

## AXI write-channel deadlock

The original engine waited for AWREADY before asserting WVALID. A legal slave
that waits for WVALID before AWREADY therefore deadlocked it. I reproduced that
behavior, then changed the engine to assert AWVALID and WVALID independently and
track the two handshakes separately.

An always-ready responder hid this defect. I added standalone AW-before-W,
W-before-AW, and simultaneous-handshake cases, and run the integrated suite with
`AXI_AW_WAIT_W=1`. The [bug report](bugs/axi_write_deadlock.md) records the failure
and fix. I also found a final-WLAST error-handling defect in the responder, which
is why I test the verification components independently of the full DMA testbench.

## Reproducing a case and testing the checker

This short case uses bounded memory stalls and the AWREADY policy that exposed
the deadlock:

```powershell
.\run_regression.ps1 -Tests smoke_test -Seeds 7 `
  -PlusArgs '+AXI_AW_WAIT_W=1','+AXI_STALL_MAX=7'
```

The runner prints a fresh result directory containing `summary.json`, a frozen
`source_manifest.json`, per-case `simulation.log`, and `requirement_coverage.tsv`.
I retain the seed, commands, and source hashes so I can reproduce a failing case.
The seeded stimulus uses an explicit PRNG, not a constraint solver.

I also test whether the checks fail when they should:

```powershell
# Intentional checker self-test: expected SB_MEMORY and a nonzero runner exit.
.\run_regression.ps1 -Tests scoreboard_negative_test -Seeds 7
```

This test changes a guard byte after START. The scoreboard must report `SB_MEMORY`
and the runner must fail, even if the scenario prints its PASSED marker. A clean
result would mean the self-test did not demonstrate detection. I keep this case
outside the normal passing regression.

The local Verilator lane has two independent negative controls: one changes an
AW payload while stalled and triggers the concurrent hold assertion; the other
corrupts a memory guard and triggers the oracle. Neither contributes coverage
to the positive DUT campaign.

## What the measurements establish

The [UVM campaign](validation.md) passed 39/39 cases and hit all 70 selected
observed requirement bins. That denominator is a finite catalog of behaviors,
not every AXI behavior or a native covergroup percentage.

The separate [Verilator campaign](local_validation.md) passed 60/60 cases and
measured native line/block, branch, toggle, and assertion activation points on
the DUT. I reviewed the unhit points and reported which hold-assertion antecedents
were exercised. Zero assertion failures alone would not establish that every
assertion was meaningfully tested. Verilator is predominantly two-state, so I
keep those measurements separate from the four-state UVM results.

Quartus Analysis & Synthesis completed without errors, but I did not run fitting,
routing, or timing closure. I have prepared the Xcelium workflow for native UVM
covergroups and another simulator check; actual Xcelium execution remains pending.

## Next engineering steps

I would first collect and review native UVM coverage and assertion activation on
Xcelium. The next testbench improvements are a cycle-accurate completion/IRQ
predictor, partial AXI-Lite reset scenarios, and a UVM RAL model. Burst support
would be a separate RTL extension with new beat-count, LAST, and 4 KiB split
requirements, rather than a change implied by the current results.
