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
- Runner override: command-stub checks first failed for missing parallel flags, then passed after adding `FUJI_STUDIO_TEST_WORKERS`; validated default 2, override 3, serial 1, focused selectors, unit-only exclusion, phone signing preservation, and invalid-input rejection. `bash -n` passed. Worker default remains provisional until measured.
- Environment: installed the README-required XcodeGen 2.46.0; created task-local `.venv`. Task simulator: 5E1942C5-ACE1-4824-B263-F2F411298291.
- Baseline ongoing: grain editor failed at the immediate disabled-size assertion, followed by missing Strong choice; later snapshot shows the correct disabled state. Investigate with focused repeated runs. First native landscape editor passed in 17 seconds; no animation-notification stall observed so far.
- Next experiment: logs consistently show ~1 second before the first `waitForExistence` poll. Compare immediate existence check with timeout fallback against the original helper behavior, without changing animation settings.
