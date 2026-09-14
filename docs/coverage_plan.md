# Verification plan - AXI DMA baseline v1

I use the [specification](specification.md) as the contract for this verification
plan. The table maps each requirement to stimulus and an independent check. I
track test results and coverage separately because a passing test alone does not
show that every intended behavior was exercised.

## Requirement traceability

| ID | Requirement | Tests | Independent checking / evidence |
| --- | --- | --- | --- |
| R01 | Correct aligned copy; source and unrelated bytes preserved | smoke_test, copy_test, seeded_copy_test | Pre-START source snapshot, observed address/data checking, full 64 KiB memory comparison |
| R02 | Serialized, aligned single-beat ID-zero INCR AXI | all copy tests; standalone engine tests | AXI monitor and protocol shape/lifecycle checks |
| R03 | VALID and payload stable through stalls, including release edge | csr_access_test; stalled portfolio runs | Always-active rv_stability_check on all 10 AXI/AXI-Lite channels; checker mutation self-test |
| R04 | AW and W accepted independently without READY-dependent VALID | standalone engine_aw_w_test; AXI_AW_WAIT_W portfolio mode | AW-before-W, W-before-AW, simultaneous unit cases; original deadlock reproduced then fixed |
| R05 | Length zero, alignment and range rejection with no memory traffic | len_zero_test, unaligned_addr_test, out_of_range_test, descriptor_corner_test | Independent validation priority, no unexpected bus transactions, unchanged memory |
| R06 | Source/destination end boundaries and 32-bit arithmetic overflow handled | descriptor_corner_test | Last legal word, end-of-memory crossing and large length/address rejection |
| R07 | CSR reset values, RO/RW/RW1C, invalid address and strobe policies | csr_access_test, irq_test, negative tests | Readback/response oracle, independent accepted CSR monitor |
| R08 | IRQ masked independently of sticky status; selective RW1C; errors persist until CTRL clear | irq_test, bad_descriptor helper | Explicit status/IRQ tests plus sampled IRQ_STATUS/IRQ consistency |
| R09 | Valid START clears old status; invalid START can add ERR to previous DONE | irq_test, recovery tests | Explicit accumulated-event checks; scoreboard allows both only for rejected new descriptor |
| R10 | Active descriptor is latched; busy START ignored | busy_start_test | Original data/address expectation retained despite reprogramming; next command uses new descriptor |
| R11 | Shared reset cancels pending work and enables fresh transfers | reset_mid_transfer_test | Actual AR/R/AW/W/B phase sampled at reset assertion; committed-memory integrity, queues flushed, reset CSR checks, five recovery copies |
| R12 | Read/write SLVERR terminates without false DONE; recovery possible | read_error_test, write_error_test | Observed RRESP/BRESP prediction at first/middle/last beat, partial memory side effects, codes 5/6, successful recovery |
| R13 | Missing RLAST reports protocol code 8 | standalone engine_aw_w_test | Direct malformed-response test; separate from legal SLVERR tests |
| R14 | Memory responder correctly implements error injection, strobes and held responses | standalone mem_model_test | Final-WLAST defect reproduced before fix; focused strobe/guard and R/B stability checks |
| R15 | Coverage reflects observed, accepted transactions | all baseline tests | Monitor analysis ports feed subscriber; source map uses full CSR address |
| R16 | Regression rejects a superficially passing but incorrectly checked run | scoreboard_negative_test, checker unit, runner unit checks | Inject guard corruption, require SB_MEMORY and nonzero runner result; intentional protocol violation caught separately |
| R17 | New event-set beats simultaneous RW1C/CTRL clear; reset dominates events | standalone regs_event_test | Direct event pulses, sticky status and diagnostic-code checks |

## Test organization

The default regression contains eleven scenario classes:
smoke_test, copy_test, len_zero_test, unaligned_addr_test, out_of_range_test,
csr_access_test, descriptor_corner_test, irq_test, busy_start_test,
reset_mid_transfer_test, seeded_copy_test.

The portfolio suite runs them with seeds 1, 7, 42 and a bounded memory responder
(AWREADY waits for WVALID, maximum stall parameter 7). Each seeded_copy_test runs
32 disjoint descriptors, lengths 4..512 bytes, varied patterns, and IRQ enabled
or masked. These are deterministic seeded sweeps; no constraint solver is used.

Read and write response errors require separate explicit plusargs, so they are
not silently mixed into successful-copy tests. Each runs three 64-byte descriptors
with SLVERR on word 1, 8, or 16 (byte offsets 0, 28, 60). The injected absolute
address stays fixed while the descriptor start moves. A successful copy at a
different address follows each error. Coverage derives positions from accepted
response counts, independently of injection arguments.

scoreboard_negative_test is an expected-failure checker test, excluded from the
normal passing suite. A missing SB_MEMORY report, a clean UVM summary or runner
exit zero would mean the checker self-test failed to demonstrate detection.

## Coverage collection

The versioned [requirement-bin catalog](../tb/coverage/coverage_requirements.json)
selects **70 reachable bins**. Every run exports all bins, including zero hits, to
`requirement_coverage.tsv`; the JSON catalog defines descriptions and exclusions.
This is the **observed requirement-bin metric**, distinct from native covergroup,
RTL code, or assertion coverage. Its denominator is the explicitly selected
baseline scenarios, not all possible behaviors of an AXI DMA.

Bins cover successful selected lengths/boundaries, observed CSR responses,
AXI-Lite handshake order and response backpressure, AXI request stalls, IRQ states,
busy START, actual reset phases, error response positions, and recovery. Success
bins are sampled only after terminal STATUS and the scoreboard's memory check.
Reset phases use passive bus observation at reset assertion; AW/W order uses
accepted-handshake cycle stamps. They are never inferred from test names.

`merge_coverage.py` requires passing runs, complete valid TSVs, identical frozen
source/catalog and tool provenance, and no duplicate test configurations. It
rejects failed runs, missing/unknown bins and changed source bytes; any unhit
required bin makes the portfolio gate fail. Its report lists counts and tests
that hit each bin. A passing partial campaign is not evidence of the full matrix.

Existing counters remain for diagnostics. R/B response latency is distinct from
R/B VALID backpressure: the serialized DMA consumes each requested response,
so R/B VALID backpressure bins are explicitly excluded from the selected catalog.

Optional `ENABLE_SV_COV` enables native register/transfer/result covergroups.
Optional `ENABLE_SVA` enables concurrent stability assertions and stall-release
cover properties. Their runtime must be validated separately. Native cross bins
include combinations that need reachability review; the selected-bin result
must not be presented as native coverage closure. See [the Xcelium workflow](xcelium.md)
and [measured validation](validation.md).

## Oracle independence and limits

The scoreboard does not call the RTL's descriptor-validation functions. It uses
observed accepted writes, a pre-START memory image and an independently implemented
address/data model. It checks the complete memory image on a terminal STATUS read.

Tests must observe terminal STATUS before changing memory or issuing a new idle
descriptor. The scoreboard's active flag tracks this verification lifecycle, not
cycle-exact engine BUSY. Current tests follow the rule; autonomous back-to-back
commands without software observation need a future completion predictor.

IRQ checking currently establishes sampled consistency with IRQ_STATUS and
explicit directed behavior. It is not a cycle-accurate interrupt predictor.
Shared reset clears protocol state but keeps committed memory writes; a
DUT-only reset with a live, unreset AXI subordinate is outside this baseline.

The register map is shared as named public contract constants; data transformation
and legality checking are independent. Whole-memory snapshots favor strong
checking and simplicity over simulation throughput in this 64 KiB educational DUT.

## Remaining closure work

- Native UVM covergroup and assertion measurements on Xcelium, plus code coverage
  for the full UVM campaign; review cross-bin reachability before setting closure
  targets. The separate Verilator code measurements are recorded below.
- UVM RAL adapter/predictor, richer scenario sequences and solver-based constraints.
- Cycle-accurate completion/IRQ prediction and integrated software/hardware event timing scenarios (register event priority is covered separately by regs_event_test).
- Reset with partial AXI-Lite address/data transactions outstanding, beyond the
  selected DMA bus phases covered in this baseline.
- Optional burst RTL and corresponding beat count/LAST/4 KiB split verification.

Overlap, multiple outstanding IDs, unaligned byte transfers, CDC, coherency,
CPU instruction execution, power and timing signoff are not baseline claims.

## Additional local native measurements

The separate classless Verilator harness covers 20 scenarios across three seeds
and executes concurrent SVA on the same DUT RTL. [Local validation](local_validation.md)
records 60/60 passing runs, native line/block/branch/toggle counts, assertion
activation and the unhit-path review. Its metrics are not merged with the
70-bin UVM requirement catalog. The tool is predominantly two-state; the
four-state UVM lane continues to provide separate evidence.
