# AXI DMA Pre-Silicon DV — Coverage Plan

## 1. Purpose
This document defines the **coverage strategy** for the AXI DMA pre-silicon DV project.
The goal is to ensure we have measurable verification progress beyond “tests passed”, by tracking:
- **Functional coverage** (did we verify the intended behaviors?)
- **Assertion coverage** (did safety/contract checks ever trigger or get exercised?)
- **Code coverage** (did simulation execute relevant RTL code paths?)

This project currently targets a “walking skeleton” DMA, but the coverage plan is written so it can scale to a fuller DMA (bursts, backpressure, concurrency, etc.) later.

---

## 2. DUT Summary
DUT is a simple DMA block controlled via **AXI-Lite registers**, issuing **AXI memory reads/writes**, and generating **interrupt(s)** on DONE/ERR.

Key functions:
- Program SRC/DST/LEN, then START
- DMA moves LEN bytes from SRC to DST (copy_test validates data moved)
- Error detection:
  - LEN=0 → ERR_LEN_ZERO
  - Unaligned SRC/DST (word alignment requirement) → ERR_ALIGN
  - Out-of-range address access → ERR_RANGE
- Interrupt behavior:
  - DONE and ERR reflected in IRQ_STATUS and optionally drive IRQ output
  - IRQ status bits cleared by RW1C

---

## 3. Coverage Types and What “Done” Means

### 3.1 Functional Coverage (Primary)
Tracks that we exercised all key features, boundaries, and combinations.

**Completion criteria (walking skeleton target):**
- 100% of required functional coverpoints hit at least once
- All error-code bins hit (LEN0 / ALIGN / RANGE)
- All “status + irq” combinations covered (DONE vs ERR)
- At least one test per coverpoint is traceable

### 3.2 Assertion Coverage (Secondary)
Assertions are used to enforce invariants and protocol intent.
Coverage here means:
- Assertions are enabled
- We can show key properties were **evaluated** across runs
- Negative tests intentionally trigger error behaviors without violating protocol assumptions

**Completion criteria:**
- Assertions compile cleanly
- No unexpected assertion failures during regression
- (Optional) Coverage reports show assertion instances were active

### 3.3 Code Coverage (Tertiary, Tool-Dependent)
If tool supports it, collect RTL:
- Statement / branch / condition coverage
- Toggle coverage on key state and outputs

**Completion criteria (walking skeleton target):**
- ≥ 80% statement coverage on dma engine/reg block
- Toggles observed on:
  - busy/done/err flags
  - start acceptance pulse
  - irq output path
- Exclusions documented (dead code, unreachable due to skeleton design)

> Note: Intel FPGA ModelSim has limitations vs Questa. Even if full functional coverage reporting is limited, this plan still documents what should be covered. Where a feature is tool-limited, we keep the model and enable it under a compile define for Questa later.

---

## 4. Test Inventory (Current)
Current tests in regression:
- **smoke_test**: basic programming + completion + IRQ DONE
- **copy_test**: memory init + DMA copy + data compare
- **len_zero_test**: negative; expect ERR_LEN_ZERO
- **unaligned_addr_test**: negative; expect ERR_ALIGN
- **out_of_range_test**: negative; expect ERR_RANGE

Planned additions (recommended next):
- **start_while_busy_test**: negative; expect ERR_BUSY (requires RTL support)
- **reset_mid_transfer_test**: robustness check (optional)
- **irq_mask_test**: DONE/ERR occurs but masked IRQ output (still sets status)

---

## 5. Functional Coverage Model

### 5.1 Register Programming Coverage (AXI-Lite)
**Goal:** Confirm all relevant registers and control flows are exercised.

Coverpoints:
- Writes to:
  - SRC_ADDR
  - DST_ADDR
  - LEN_BYTES
  - CTRL/START
  - IRQ_ENABLE
  - IRQ_STATUS (RW1C)
- Reads from:
  - STATUS
  - ERR_CODE
  - IRQ_STATUS
- Start sequencing:
  - “normal”: program regs then start
  - “reprogram while idle”
  - “reprogram while busy” (future / optional)
- CTRL bits combinations (if applicable):
  - irq enable for DONE
  - irq enable for ERR

Recommended bins:
- SRC/DST address alignment bins: aligned vs misaligned
- LEN bins: {0}, {1..3}, {4}, {8}, {16}, {64}, {128}, {256+}
- IRQ enable bins: disabled / enabled

### 5.2 DMA Transfer Coverage
**Goal:** Validate the DMA moved data correctly and exercised boundaries.

Coverpoints:
- Transfer length bins (as above)
- Address region bins:
  - low region (0x0000_0000..)
  - mid region
  - upper boundary near MEM_SIZE-1
- Source vs destination overlap:
  - non-overlapping (required)
  - overlapping (optional, document expected behavior: undefined or error)

Cross coverage:
- LEN bins x alignment bins
- LEN bins x range bins
- LEN bins x IRQ enable bins

### 5.3 Error Detection Coverage (Negative Behavior)
**Goal:** Each defined error condition triggers the correct behavior.

Coverpoints:
- ERR_CODE values:
  - ERR_NONE
  - ERR_LEN_ZERO
  - ERR_ALIGN
  - ERR_RANGE
  - (future) ERR_BUSY
- Error behavior requirements:
  - STATUS shows ERR set
  - DONE is not set (unless your spec allows DONE+ERR together; normally not)
  - IRQ_STATUS has ERR bit set
  - IRQ output asserted only if IRQ_ERR enabled
  - Engine does not issue memory writes when error is detected early (if that’s the intended spec)

### 5.4 IRQ Coverage
**Goal:** Ensure IRQ behavior is correct and status is RW1C clearable.

Coverpoints:
- IRQ cause:
  - DONE
  - ERR
- RW1C clearing:
  - clear DONE
  - clear ERR
- IRQ enable effects (if implemented):
  - status set but IRQ output masked
  - status set and IRQ output asserted

Cross coverage:
- (DONE/ERR) x IRQ enable bit
- RW1C clear x subsequent operation (can run another transfer afterward)

---

## 6. Protocol/Interface Coverage

### 6.1 AXI-Lite Protocol Coverage (Lightweight)
Even in a small project, show you understand the bus protocol.

Coverpoints:
- AW/W handshake ordering:
  - AW before W
  - W before AW (if TB supports it)
  - AW and W same cycle
- Backpressure behavior:
  - ready always-high (baseline)
  - ready toggled low for a few cycles (optional enhancement)
- Response types (BRESP/RRESP):
  - OKAY (required)
  - SLVERR/DECERR (optional, if you extend)

### 6.2 AXI Master Protocol Coverage (Lightweight)
Coverpoints:
- Read address burst properties (if bursts exist):
  - ARSIZE bin (word size)
  - ARLEN bin (single vs multi-beat)
- Write data behavior:
  - WLAST correctness if bursts exist
- Backpressure:
  - RVALID stalls (optional)
  - WREADY stalls (optional)

> For walking skeleton, it’s okay if AXI backpressure is not implemented. In that case, document it as “not supported” and exclude from closure criteria.

---

## 7. Requirements-to-Coverage Traceability (Walking Skeleton)
Map the key requirements (R) to coverpoints (C) and tests (T).

R1: Program regs and start DMA
- C: reg writes + start accepted, busy->done
- T: smoke_test, copy_test

R2: Correct data moved SRC->DST
- C: data compare pass, LEN bins exercised
- T: copy_test

R3: LEN=0 must error
- C: ERR_LEN_ZERO hit, status/irq correct
- T: len_zero_test

R4: Misaligned addr must error
- C: ERR_ALIGN hit
- T: unaligned_addr_test

R5: Out-of-range addr must error
- C: ERR_RANGE hit
- T: out_of_range_test

R6: IRQ status RW1C clearing works
- C: DONE/ERR set then cleared by RW1C
- T: smoke_test (DONE clear), negative tests (ERR clear if implemented)

---

## 8. Implementation Notes (How to Collect Coverage)

### 8.1 Where to Put Functional Coverage Code
Recommended structure:
- `tb/coverage/dma_cov.sv` (covergroups + sampling functions)
- instantiate in `tb_top.sv` or create a simple UVM component that samples:
  - on register writes/reads
  - on dma completion
  - on irq events

### 8.2 Tool Compatibility Strategy (ModelSim Intel vs Questa)
Intel FPGA ModelSim prints warnings about some SystemVerilog testbench features.
To keep portability:
- Guard coverage code with a define:
  - Compile with `+define+ENABLE_SV_COV` when your simulator supports covergroups well
  - Otherwise, compile stubs that do nothing (tests still pass)

Example approach:
- Default: coverage stubs (safe in ModelSim Intel)
- Questa run: enable `ENABLE_SV_COV` and generate coverage reports

### 8.3 Reporting
Minimum reporting (always):
- Regression summary PASS/FAIL
- Per-test logs in `logs/`

If simulator supports it:
- Code coverage report (statement/branch/toggle)
- Functional coverage report (covergroup bin hit counts)
- Assertion report (active properties / failures)

---

## 9. Coverage Closure Checklist (Walking Skeleton)
Before calling coverage “done”:
- [ ] All 5 current tests pass in regression
- [ ] Positive tests cover at least 3 different LEN bins (e.g., 4, 16, 128)
- [ ] All error codes (LEN0/ALIGN/RANGE) observed at least once
- [ ] DONE and ERR IRQ paths observed at least once
- [ ] RW1C clear observed at least once
- [ ] (If supported) code coverage ≥ 80% statement on RTL core blocks
- [ ] Any exclusions documented (not implemented features)

---

## 10. Next Recommended Step
Implement lightweight **functional coverage hooks** (even if stubbed in ModelSim Intel),
then plan a “Questa coverage run” later to produce a real coverage report.
