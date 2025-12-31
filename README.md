
---

## Current Status

This repo is built using a **walking-skeleton → incremental functionality** approach.

Typical progression:
1. **Walking skeleton**: compiles/runs; AXI-Lite programming + basic control/irq plumbing
2. **Minimal end-to-end**: single-beat copy verified with scoreboard
3. **Full baseline spec**: bursts + backpressure + error injection + assertions + coverage

You can track completion via the test plan milestones in `docs/testplan.md`.

---

## Test Suite (Planned / Implemented as Development Proceeds)

Mapped to the test plan:

**Bring-up**
- `smoke_test` — minimal valid transfer, checks DONE/irq and memory copy

**Registers & Reset**
- `reset_defaults_test`
- `axil_alignment_strobe_test`
- `rw_ro_rw1c_semantics_test`
- `start_while_busy_test`

**Start-time errors (no AXI traffic expected)**
- `len_zero_error_test`
- `align_error_test`
- `range_error_test`

**Functional copy**
- `burst_test`
- `multi_burst_test`
- `boundary_4kb_test` (optional feature)

**Stress / robustness**
- `backpressure_test`
- `axi_rresp_error_test`
- `axi_bresp_error_test`
- `random_test` (multi-seed constrained-random regression)

---

## Assertions (Design Intent)

Assertions are layered so they add value early:
- **AXI4-Lite protocol**: stability-under-stall, R/B causality checks
- **AXI4 protocol**: stability-under-stall, burst beat counting, WLAST/RLAST checks
- **DMA semantics**: start/busy/done/err invariants, “no AXI on invalid start”
- **IRQ equation**: `irq = IRQ_EN && (DONE || ERR)`
- **No-X checks**: critical pins must not go X after reset

See: `docs/assertions_arch.md`.

---

## Coverage Strategy (Design Intent)

Coverage is used to show breadth of verification, not just “tests ran”:
- **Functional coverage**: LEN buckets, burst usage, completion types, error codes, backpressure levels
- **Protocol coverage**: stall lengths, response latencies, response types, LAST correctness
- Cross coverage examples:
  - LEN bucket × backpressure profile
  - completion type × irq_en
  - burst length × boundary condition

See: `docs/testplan.md` and `docs/tb_arch.md`.

---

## How to Run (Simulation)

> This section is finalized as the Makefile + filelist are completed. The intent is a one-command flow.

Expected usage (examples):
```bash
# Run a single test with a fixed seed
make sim TEST=smoke_test SEED=1

# Enable waves (if supported by simulator wrapper)
make sim TEST=backpressure_test SEED=42 WAVES=1

# Run a regression (multiple tests / multiple seeds)
make regress

# Clean generated artifacts
make clean
