# AXI DMA UVM Verification (`axi-dma-uvm-dv`)

Pre-silicon **SystemVerilog UVM** verification environment for an **AXI4-based DMA** memory-copy subsystem with **AXI4-Lite** register programming. This repo is structured to look and feel like an industry DV codebase (agents, monitors, scoreboards, assertions, coverage, regressions).

---

## Overview

The DUT is a single-channel DMA engine that copies `LEN` bytes from `SRC_ADDR` to `DST_ADDR`. The DMA is programmed via an **AXI4-Lite slave** register interface and performs data movement via an **AXI4 master** interface to memory. Completion or error is reported through **sticky status/event bits** and a **level interrupt** `irq`.

This project intentionally focuses on the verification skills Qualcomm DV teams value:
- clean UVM architecture (agents/env/vseq),
- scoreboard + reference model,
- protocol assertions,
- coverage-driven verification mindset,
- reproducibility (seeds, regressions).

---

## Key Features

### DUT (RTL) Features (Spec v0.1)
- AXI4-Lite slave register interface (32-bit regs)
  - word-aligned accesses only
  - full-word writes required (WSTRB = 4’hF), else `SLVERR`
  - `IRQ_STATUS` is RW1C (write-1-to-clear)
- AXI4 master data interface (DMA reads/writes)
  - INCR bursts only
  - fixed beat size = `DATA_BYTES`
  - burst length limited by `MAX_BURST_BEATS` (default 16)
  - single outstanding burst policy (baseline)
- DMA behavior
  - aligned-only transfers
  - start-time parameter validation (LEN=0, alignment, range)
  - response error detection (`RRESP`/`BRESP` != OKAY)
- Interrupt behavior
  - `irq = IRQ_EN && (DONE || ERR)` (level)
  - deasserts only when event bits cleared (RW1C)

### Verification (UVM) Features
- AXI-Lite **master agent** to program DMA registers
- AXI **slave memory agent/model** to respond to DUT AXI master traffic
  - controllable latency/backpressure
  - error injection (SLVERR/DECERR responses)
- Scoreboard + reference model for end-to-end data correctness
- Assertion plan for:
  - AXI stability-under-stall, burst legality, WLAST/RLAST behavior
  - DMA/IRQ semantic invariants
- Functional + protocol coverage plan aligned to the test plan
- Regression-ready structure (test list + seed control)

---

## Out of Scope (By Design)

To keep the project realistic but buildable:
- scatter-gather descriptors / ring buffers
- strided / 2D DMA
- cache coherency (ACE), snooping
- multi-channel DMA
- multiple outstanding AXI transactions, out-of-order completion
- CDC / multi-clock domains
- memmove overlap correctness (SRC/DST overlap is undefined)

---

## Documentation (Design Anchors)

These documents define the contract and verification intent. The repo is meant to be driven by them:

- `docs/spec.md` — DMA + register + AXI subset specification (v0.1)
- `docs/testplan.md` — requirements → tests → coverage closure plan (TP v0.1)
- `docs/tb_arch.md` — UVM architecture and dataflow (TB-ARCH v0.1)
- `docs/rtl_arch.md` — module boundaries + FSM architecture (RTL-ARCH v0.1)
- `docs/assertions_arch.md` — layered assertion strategy (ASSERT-ARCH v0.1)

> If you’re reviewing this repo: start with `docs/spec.md`, then `docs/testplan.md`.

---

## Repository Structure

axi-dma-uvm-dv/
├── README.md
├── Makefile # standardized sim/regression entrypoints (planned/iterating)
├── filelist.f # deterministic compile order (planned/iterating)
├── .gitignore
├── rtl/
│ ├── dma_pkg.sv # shared params/constants/offsets/error codes
│ ├── dma_regs_axil.sv # AXI-Lite reg block (slave)
│ ├── dma_engine_axi.sv # DMA engine + AXI master datapath
│ └── top_soc_dut.sv # integration wrapper
├── tb/
│ ├── tb_top.sv # clock/reset, DUT hookup, run_test()
│ ├── tb_pkg.sv
│ ├── interfaces/
│ │ ├── clk_rst_if.sv
│ │ ├── axil_if.sv
│ │ ├── axi_if.sv
│ │ └── irq_if.sv
│ ├── agents/
│ │ ├── axil_mst/ # AXI-Lite master agent
│ │ └── axi_mem_slv/ # AXI slave memory agent + memory model
│ ├── env/ # env, virtual sequencer, scoreboard, ref model, coverage
│ ├── sequences/ # directed + constrained-random sequences
│ └── tests/ # base_test + test suite
├── assertions/
│ ├── axil_sva.sv
│ ├── axi_sva.sv
│ ├── dma_ctrl_sva.sv
│ ├── regs_sem_sva.sv
│ ├── xcheck_sva.sv
│ └── bind_*.sv
├── scripts/
│ ├── run_sim.sh
│ ├── run_regress.py
│ └── gen_cov_report.tcl
└── docs/
├── spec.md
├── testplan.md
├── tb_arch.md
├── rtl_arch.md
└── assertions_arch.md
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
