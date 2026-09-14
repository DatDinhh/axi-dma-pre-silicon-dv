# Verification evidence

I keep these reports so readers can trace the results in my project overview to individual tests, requirement bins, source snapshots, and tool diagnostics.

| Evidence | What I measured |
| --- | --- |
| [UVM campaign](v1_portfolio_sweep.json) and [requirement coverage](v1_requirement_coverage.md) | 39/39 runs passed; 70/70 selected observed requirement bins hit. This is not native UVM covergroup coverage. |
| [Unit checks](v1_unit_checks.json) and [scoreboard negative test](v1_checker_negative.json) | 14/14 expected unit outcomes; intentional memory corruption was detected. |
| [Local DUT campaign](local_verilator_suite.json) and [native coverage](local_native_coverage.md) | 60/60 Verilator runs passed with RTL instrumentation enabled. |
| [SVA activation](local_sva_activation.md) | 27/37 cover properties hit; hold antecedents exercised on 5/10 channels. |
| [Synthesis](local_synthesis.md) | Quartus Analysis & Synthesis passed with zero errors and 67 reviewed warnings. No timing closure was run. |
| [Loader study](loader_ab_study.json) and [earlier campaign](../validation_legacy_campaign.md) | Original startup failures and the measured simulator option comparison. |
| [Tool capabilities](tool_capabilities.json) and [Xcelium runner fixtures](xcelium_runner_fixture_tests.json) | Local capability probes and runner-control checks. Xcelium DUT execution remains pending. |

## How I publish these records

These are sanitized historical review copies. I replace local workspace and tool-installation paths with `{repo}`, `{simulator}`, `{quartus}`, and `{iverilog}`, and remove date stamps from run and artifact names. Those aliases describe archived artifacts; they are not links to files included in this public folder. I keep test outcomes, seeds, counters, tool versions, and factual UTC metadata.

Each JSON records its original artifact SHA-256 under `_Publication`. Existing source hashes, report hashes, manifest hashes, and provenance signatures still refer to the original bytes. They do not authenticate the rewritten JSON. Frozen source manifests identify the code used for those runs; later documentation, path, and runner cleanup means some entries differ from the current repository. The full campaigns were not rerun for that cleanup.

I preserve the original evidence bytes in a local archive excluded from Git and source bundles. Its manifest maps original paths to date-free archive entries and records hashes. I remove reproducible compiler databases and binaries from the working directory.

To validate a new run, I use the commands in the [project README](../../README.md) and pass the generated raw reports to the merger or SVA auditor. These published review copies are not replayable inputs to those strict validators. Negative tests and tool failures remain separate from positive DUT results.
