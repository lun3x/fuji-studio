# UI test speed implementation plan

**Goal:** Reduce reliable full-suite wall time without dropping assertions, test cases, or native interaction coverage.
**Architecture:** Measure a fresh isolated simulator baseline, fix demonstrated stalls, then distribute balanced XCTest suites over a measured worker count. Preserve focused and unit-only test entry points.
**Tech stack:** XCTest/XCUIAutomation, XcodeGen, Bash, Jujutsu.
**Authorization:** User requested autonomous investigation and continued optimization on 2026-10-29.

## Constraints and review focus
- Use a temporary Jujutsu workspace, task-specific simulator, and active development bookmark; push checkpoints.
- Keep every test case and assertion. Preserve existing opt-in hardware gates.
- Benchmark one variable at a time with warmed build products; include result summaries and failure counts.
- Avoid private XCTest APIs, blanket animation disabling, or relaxing assertions to obtain speed.
- Stop after repeat measurements show no meaningful gain from additional workers or identified safe optimizations. This establishes a measured local plateau, not a universal minimum.

## Tasks
- [ ] Record full baseline and per-test timings, including orientation/animation waits.
- [ ] Reproduce the slowest behavior in focused tests. Apply only evidence-backed fixes and remeasure.
- [ ] Balance suites while preserving test method names and assertions, if class scheduling limits throughput.
- [ ] Benchmark bounded worker counts, select the fastest reliable setting, and expose a configurable script override with argument validation.
- [ ] Validate script behavior, run unit tests and affected UI tests during implementation, then the full wrapper suite.
- [ ] Review the complete diff, document measurements and limitations, push final checkpoint, and remove task simulators.

## Experiment ledger
- Baseline: original main@origin 34649780, default scheme and runner, iPhone 15 Pro / iOS 27.0. Logs under ignored `.build/Benchmarks/`.
- Ruling: use inline implementation and a final independent review, because the measurements and modifications are sequential and share one simulator.
