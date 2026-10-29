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
- [x] Run the complete suite with the cleanup fix, record result, remove the new simulator, and publish final evidence. The selected two-worker full control passed; final default argument checks match its flags.
- Fresh-simulator parallel run with the broad existence shortcuts failed numeric-picker geometry and initial AX5 Select hit-testing, before affected rotation cleanup ran. Reverted every existence/predicate shortcut, removed ElementWaits.swift, and restored the original XCTest polling throughout. Original seven affected cases then all passed (258.11 seconds). Conservation check now verifies all 64 bodies against baseline after only normalizing the three safe deferred cleanup additions.
- Final validation will erase/reboot the task simulator before running the default full suite, so success cannot depend on warmed UI state. The accepted performance changes are bounded parallelism, feature-class scheduling, verbose-diagnostic opt-in, and the measured rotation-cleanup fix.

## Follow-up: editor keyboard obstruction
- Full erased-simulator run with original native waits and rotation cleanup completed in 768.17 seconds: 546 passed, 3 skipped, 2 editor failures. Failure snapshots show alphabetic keyboard clipping numeric/temperature menu options. No timing shortcut remained.
- Made keyboard visibility explicit before the numeric-menu test. With original whole-window reveal helper, the focused regression failed in 102.53 seconds. Replaced whole-window scrolling with recipe.editor.form scrolling and used the native Return button to dismiss the alphabetic keyboard when present.
- Independent review found no assertion/coverage regression, confirmed all reveal callers belong to this editor and Return does not Save. Number-pad dismissal is outside this helper's current requirements.
- Five-case editor group: four passed, including the explicit numeric regression and invalid-temperature case; the original grain-picker case failed at a Save transition. Total 220.98 seconds. Do not describe this as a passing suite or a grain-flake fix.
- Command-stub runner checks and Bash syntax passed again. Mechanical source comparison confirms all 64 original UI methods, normalizing only the three rotation cleanup additions and the explicit keyboard setup. No original assertion removed.
- Full default validation started after the focused Xcode process exited, with the task simulator erased and rebooted. Final report now clearly distinguishes the rejected fast-wait timings from accepted-source results.

- Cold four-worker keyboard/helper run completed in 794.86 seconds: 545 passed, 3 skipped, 3 failed (grain, camera-ready predicate timeout, temperature). Host startup showed load averages over 500 and about 7 GB used swap; two runners started substantially later. Do not retain four merely because its early best run was fastest.
- Temperature trace: initial keyboard check false, keyboard then appears before Colour temperature selection; Return later occurs with a menu potentially open, making it ambiguous. Added explicit Name focus and keyboard-visible expectation before reveal(balance), mirroring the passing numeric regression. Review confirms no validation/persistence assertion bypass. This does not claim the helper handles every possible late keyboard.
- Fresh erased-simulator three-worker full run started with original native waits and the strengthened temperature setup. Compare lower worker counts before finalizing the default.

- Three-worker cold run complete: 740.38 seconds, 547 passed, 3 skipped, 1 failure. All five editor cases passed; unchanged AX5 Select.isHittable assertion failed just after launch. Review recommends an asserted native property readiness wait only in this specific case if transience is demonstrated; keep original assertions. No synchronization change made yet.
- Two-worker cold run started with unchanged source after three-worker Xcode process exit. Its result will inform the final reliable worker default.

## Final candidate decision rule
- Preserve the unchanged two-worker cold control as the fallback if it completes cleanly. All editor and AX5 layout cases have passed in that run so far; no synchronization change is in its source.
- If two is materially slower than three (>5%), one bounded experiment remains: an asserted native Select.isHittable readiness wait in the specific AX5 layout test, before geometry measurements, retaining all existing assertions. Record whether the initial false state becomes true without interaction. This is an experiment, not a claimed root-cause fix. Reject it if the gate remains false or the full three-worker result is not clean/faster. Do not add retries, interactions, or extend existing timeouts to conceal failure.

- Two-worker cold control PASSED: 843.80 seconds, 548 passed, 3 existing skips, 0 failed. Source8b3d4016, all original immediate assertions unchanged. This is the clean fallback, approximately37% less wall time than the original cold serial baseline.
- Since three was >5% faster, the single bounded AX5 readiness candidate is now running in an erased-simulator full3test. It records initial and post-wait readiness and retains every original assertion. A full clean faster result is required to retain it; false→true evidence is required before claiming the prior failure was transient.

## Final decision and verification
- The final three-worker readiness candidate failed the unchanged numeric-picker Save-disappearance assertion before the AX5 candidate executed. Its predefined clean/faster gate was impossible, so it was interrupted; actual process exit was474.21seconds. Cancellation-generated zero-duration failures are not product regressions or completed timings. No retries were used.
- Reverted the entire AX5 readiness/diagnostic block. Selected the clean two-worker full control:843.80seconds,548passed/3existing-skips/0failed. This is~37% less measured wall time than original1334.88seconds, subject to cold-build and simulator-startup differences. Three/four cold workers had failures; six stalled. Do not claim the rejected475.71second fast-wait result for final source.
- Runner default-two command-stub check first failed against default-four, then passed after changing the default and README/help. Bash syntax passed. Final UI test source is identical to passing control8b3d4016, and production app/project.yml remain identical to baseline.
- Final task base and all task-owned native worker clones removed after actual Xcode exit. Unrelated iPhone18Pro remains booted. Evidence in `.build/Benchmarks/final-cleanup-verified.json`; workspace and raw artifacts retained for review. Final checkpoints publish on `codex/ui-test-speed`.
