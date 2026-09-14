# Concurrent SVA activation audit

I retain this sanitized report as a record of the measured run. Paths are portable aliases; see the [evidence notes](README.md) for source and hash scope.

Audit: PASS. Partial case selection: False

27/37 native points have hits; 5/10 hold antecedents were exercised.

| Channel | Handshakes | Stall antecedents | Stall releases | Hold assertion |
| --- | ---: | ---: | ---: | --- |
| AXI.AW | 27044 | 89594 | 22370 | EXERCISED |
| AXI.W | 27041 | 206205 | 27041 | EXERCISED |
| AXI.B | 27038 | 0 | 0 | NOT_EXERCISED |
| AXI.AR | 27059 | 95482 | 23843 | EXERCISED |
| AXI.R | 27056 | 0 | 0 | NOT_EXERCISED |
| AXIL.AW | 3012 | 0 | 0 | NOT_EXERCISED |
| AXIL.W | 3012 | 0 | 0 | NOT_EXERCISED |
| AXIL.B | 3012 | 45 | 9 | EXERCISED |
| AXIL.AR | 228806 | 0 | 0 | NOT_EXERCISED |
| AXIL.R | 228806 | 45 | 9 | EXERCISED |

- PASS means this evidence audit passed; it does not mean every hold assertion was exercised.
- EXERCISED means a stalled-cycle antecedent was observed in a passing simulation.
- A reset can cancel a pending hold obligation; stall-release counts provide additional completed-sequence evidence.
- NOT_EXERCISED is retained explicitly; no unhit points are excluded from reported counts.
- Two-state simulation does not verify X/Z behavior and is not formal proof or native covergroup closure.
