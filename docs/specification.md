# AXI DMA specification - baseline v1

I use this specification as the contract for the implemented DMA and its
testbenches. It covers the fixed configuration below. Burst support is a possible
extension, not part of the current implementation.

## Configuration and transactions

- One clock, synchronous active-low reset. The DUT, CSR master, and memory responder
  share reset; reset cancels outstanding protocol transactions. Memory contents
  already written are retained. DMA completion is not atomic or rollback-capable.
- 32-bit byte addresses, 32-bit data, little-endian memory, ID zero, 64 KiB memory.
- A copy uses serialized single-beat AXI INCR transfers (AxLEN=0, AxSIZE=2).
  A descriptor can span a 4 KiB boundary; each individual aligned beat stays within
  one page. MAX_BURST_BEATS is reserved and does not enable bursts.
- Source, destination, and byte length must be multiples of four. Length must be
  nonzero and both half-open address intervals must fit in [0,65536).
- Only disjoint source/destination buffers are supported. Overlap is outside the
  contract and is not guaranteed to be detected. This is not memmove.
- START while busy is ignored without aborting the current copy. CSR configuration
  can be rewritten while busy; the active descriptor was latched at accepted START.
- AXI address/data VALID must not depend on READY. Each VALID and its payload must
  remain asserted/stable until handshake, except during reset.
- No DUT timeout is implemented. Testbench watchdogs bound tests whose responder
  is configured to make progress; they are not AXI protocol latency requirements.

## Register map

All registers are 32-bit, word-aligned. All reset to zero. Full strobes (WSTRB=0xf)
are required for writes: partial/zero strobes return SLVERR without side effects.
Unknown or unaligned addresses return SLVERR; invalid reads return zero.
Writes to known read-only registers return OKAY and are ignored.

| Offset | Name | Access | Definition |
| --- | --- | --- | --- |
| 0x00 | CTRL | mixed | bit0 START pulse; bit1 IRQ_EN; bit2 CLR_DONE pulse; bit3 CLR_ERR pulse |
| 0x04 | SRC_ADDR | RW | Source byte address |
| 0x08 | DST_ADDR | RW | Destination byte address |
| 0x0c | LEN | RW | Length in bytes |
| 0x10 | STATUS | RO | bit0 BUSY, bit1 sticky DONE, bit2 sticky ERR |
| 0x14 | IRQ_STATUS | RW1C | bit0 DONE, bit1 ERR; shares the STATUS sticky bits |
| 0x18 | ERR_CODE | RO | Low byte contains the last error code |
| 0x1c | BYTES_REMAIN | RO | Remaining bytes; decremented on successful B response |

CTRL reads return only IRQ_EN; command bits read zero. Every CTRL write sets
IRQ_EN to the supplied bit, so software must preserve it when issuing commands.

## Events and errors

1. Accepted valid START clears sticky DONE, ERR, and ERR_CODE. Invalid START sets
   ERR without clearing an earlier DONE. Thus DONE+ERR is legal for accumulated
   events across descriptors; it does not mean one descriptor both succeeded and
   failed.
2. Validation priority: zero length (1), address/length alignment (2), range (3).
   Rejected descriptors issue no memory transactions.
3. Non-OKAY read response reports 5; non-OKAY write response reports 6; malformed
   single-beat RLAST reports 8 (framing error takes precedence over RRESP). Codes 4 (busy) and 7 (timeout) are reserved.
4. Error terminates the copy without new transfers or new DONE. Earlier writes
   remain. The erroring write may have modified memory; BRESP is not rollback.
   BYTES_REMAIN is cleared during error cleanup and is not a progress guarantee
   on failure. Response IDs must match the single supported ID.
5. IRQ = IRQ_EN && (DONE || ERR). Masking affects the output, not sticky status.
6. IRQ_STATUS writes clear selected sticky bits and preserve ERR_CODE. CTRL
   CLR_ERR clears both sticky ERR and ERR_CODE. New event-set wins over a clear
   applied in the same cycle. Command/clear pulses take effect in the following
   cycle; a read already accepted observes its captured value.

## Verification boundaries

The memory responder may delay AW/W/AR acceptance and R/B responses but must
eventually respond in bounded regression configurations. Error response injection
uses legal SLVERR transactions; malformed LAST injection is a separate protocol
fault, not ordinary backpressure. Checks use observed handshakes and a source
snapshot taken before data movement, independently of the DUT validation helper.

## Deferred extensions

Multi-beat INCR bursts and source/destination 4 KiB splitting, UVM RAL, solver-based
constrained random stimulus on a verified simulator, and measured covergroup/code
coverage closure. Multiple outstanding IDs, scatter-gather, unaligned transfers,
cache coherency, and CDC are outside baseline v1.
