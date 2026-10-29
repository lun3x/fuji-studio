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
- [x] Record full baseline and per-test timings, including orientation/animation waits.
- [x] Reproduce the slowest behavior in focused tests. Apply only evidence-backed fixes and remeasure.
- [x] Balance suites while preserving test method names and assertions, if class scheduling limits throughput.
- [x] Benchmark bounded worker counts, select the fastest reliable setting, and expose a configurable script override with argument validation.
- [x] Validate script behavior, run unit tests and affected UI tests during implementation, then the full wrapper suite.
- [x] Review the complete diff, document measurements and limitations, push final checkpoint, and remove task simulators.

## Experiment ledger
- Baseline: original main@origin 34649780, default scheme and runner, iPhone 15 Pro / iOS 27.0. Logs under ignored `.build/Benchmarks/`.
- Ruling: use inline implementation and a final independent review, because the measurements and modifications are sequential and share one simulator.
- Runner override: command-stub checks first failed for missing parallel flags, then passed after adding `FUJI_STUDIO_TEST_WORKERS`; validated default 2, override 3, serial 1, focused selectors, unit-only exclusion, phone signing preservation, and invalid-input rejection. `bash -n` passed. Worker default remains provisional until measured.
- Environment: installed the README-required XcodeGen 2.46.0; created task-local `.venv`. Task simulator: 5E1942C5-ACE1-4824-B263-F2F411298291.
- Baseline ongoing: grain editor failed at the immediate disabled-size assertion, followed by missing Strong choice; later snapshot shows the correct disabled state. Investigate with focused repeated runs. First native landscape editor passed in 17 seconds; no animation-notification stall observed so far.
- Next experiment: logs consistently show ~1 second before the first `waitForExistence` poll. Compare immediate existence check with timeout fallback against the original helper behavior, without changing animation settings.
- Baseline complete: 1334.88 seconds cold wall time; 551 tests, 547 passed, 3 pre-existing skips, 1 grain UI failure. All four orientation cases passed without animation-notification stalls. AppFlowTests alone took 687.3 seconds, establishing a whole-class scheduling bottleneck.
- Grain diagnosis: original isolated repeats all passed (~44.4 seconds each), confirming intermittency. State waits alone still failed once: the failure hierarchy showed the Strong menu open with Off selected after XCTest reported a tap. Midpoint coordinate taps consistently failed to open the picker; the blank row midpoint is not its interactive value/chevron. Targeting the value/chevron and menu choice centers, with explicit menu dismissal, has passed the first four repeated runs (~58 seconds before fast state/dismissal waits). Retain logs for all rejected experiments.
- Fast waits now cover existence, disappearance, and equatable properties, using a current-state check plus the unchanged XCTest timeout fallback. Central flow/detent/finite-metrics conditions also check the actual predicate immediately before polling.
- Rejected: all picker modifications, property/disappearance fast paths. Original grain test restored. Later popup-wait results overlapped a previous Xcode diagnostic collection and are invalid; future runs wait for process exit.
- Confirmed failure-finalization bottleneck: process sample shows simulator diagnostics collection blocked on `simctl diagnose --timeout=600` over seven minutes after the test summary. Added opt-in verbose diagnostics; default `never`. Command-stub validation passes for both modes and invalid values. Temporary deliberate UI failure exited 65 in 12.21 seconds, with exactly one expected failure in its result summary. Probe removed and project regenerated.
- Two-worker full wrapper benchmark started after all previous Xcode processes exited, using the original six UI classes and conservative existence fast paths. No retries; all original cases included.
- Two-worker original-class run complete: 674.25 seconds, 551 tests (547 passed, 3 skipped, same single original grain failure). No other failures. Proceeding with smaller suites and worker sweep; preserve this failure in reports.
- Independent review confirmed all 64 method bodies unchanged after existence-helper normalization, no duplicate inheritance tests, per-launch UUID fixture isolation, and no Critical/Important findings. Addressed its minor worker-validation concern with a failing command-stub check, then scoped worker validation to simulator UI runs; checks now pass for invalid-but-irrelevant settings on unit-only/phone runs.
- Split implementation compiled and unit validation passed: 487 unit tests, 0 failures. Four-worker full wrapper now executes the 14-class candidate. All 64 original UI methods remain exactly once; independent review verified normalized bodies. No production app changes.
- Four-worker split-suite calibration passed all 551 cases: 548 passed, 3 skipped, 0 failures, 475.71 seconds. Six-worker global-override benchmark running.
- Additional hypothesis: the global parallel override also starts hosted unit-test workers, increasing simulator/test-runner startup. Candidate scheme enables only the UI bundle; script respects per-target settings. Command-stub check first rejected the global override, then passed after removing it. Compare warmed global-4 and UI-only-parallel-4 before deciding whether to retain.
- Six-worker run rejected for local capacity: UI runner startup stalled and the host became unresponsive. Cancelled at 507.69 seconds with only 31 UI cases completed. Cancellation failures are not application regressions or valid full-suite timing data. Xcode removed all six worker clones; only task/base and unrelated original simulator remain.
- Automation-scheme candidate (no debugger, UI-only target parallelism) showed no clear startup gain and introduced a numeric-picker UI failure absent from the serial/two/four controls. Candidate script/project changes discarded; normal FujiStudio scheme and global worker override restored. The original three-worker control will run after this experiment exits.
- Three-worker original-scheme control passed all 551 tests (548 passed, 3 skipped) in 595.03 seconds. Four workers remain the fastest completed passing configuration at 475.71 seconds. No thermal/performance warning reported by `pmset -g therm`.
- Set default worker count to four, preserving overrides and unit/phone exclusions. Command-stub test rejected the old default and passed after the change. Screenshot capture is the last candidate experiment; retain only if it materially improves the full result. Then run the default wrapper again as final validation and a repeatability check.
- Screenshot-format candidate passed all 551 tests in 565.64 seconds, slower than the existing format. Reverted project.yml; final source has no scheme/debugger/capture-format changes. Default wrapper repeat now runs with four workers and original recording behavior, with no worker override in the environment.

- Final default wrapper passed: 551 total, 548 passed, 3 existing skips, 0 failures, 651.37 seconds. Its 142.684-second orientation case contains 61.64- and 60.52-second XCTest idle waits. Preserved native rotation coverage; documented the remaining runtime limitation.
- Prepared-simulator direct-shard probe also passed all 551 tests, but took 782.94 seconds including setup and cleanup. UI execution alone took 498.45 seconds, longer than the best complete native run. Rejected; no production coordinator/dependency added.
- Final cleanup verified: task base and all four manual-pool simulators absent, no native worker clones remain, original unrelated iPhone 18 Pro still booted. All project changes remain on the requested development bookmark; workspace/artifacts retained for review.
- Follow-up root fix from final activity trace: the 60.52-second Portrait wait occurs solely in post-assertion cleanup. Terminate the completed app before restoring device orientation in the three active-app rotation cleanups. Live foreground rotations and all post-rotation assertions stay intact, including the explicit portrait/selection check in the landscape-selection test. New task-owned iPhone 15 Pro simulator created for focused and full validation after the original pool cleanup.

## Follow-up: rotation cleanup
- [x] Verify trace root cause and review the three deferred cleanup changes.
- [x] Run the five affected rotation cases: all passed. The prior 60.52-second cleanup idle wait now targets SpringBoard and took 0.026 seconds; full dark geometry test took 11.725 seconds.
- [ ] Run the full default suite with the cleanup fix, record result, remove the new simulator, and publish final evidence.
