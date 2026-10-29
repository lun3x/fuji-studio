# UI test performance investigation

Date: 2026-10-29. Baseline: `34649780`.

## Result

The runner now defaults to **four simulator workers**. The best completed passing full-suite run took **475.71 seconds (7m 56s)** versus **1334.88 seconds (22m 15s)** for the original serial baseline. All **64 original UI test methods** remain, distributed over **14 feature suites**. No production app code, assertions, native animations, or existing device gates were removed.

A pre-cleanup-fix default-command repeat also passed all 551 tests in **651.37 seconds (10m 51s)**. Native-worker timings vary with simulator startup and occasional XCTest rotation idle waits; the best and repeat correspond to approximately **64% and 51% less wall time** than the cold serial baseline. The table preserves all outcomes rather than selecting only favorable results.

## Measurement conditions

- Mac with 10 logical CPUs and 16 GiB RAM; Xcode 27.1 (27A9275); iPhone 15 Pro / iOS 27.0 (24A434).
- Initial task-owned simulator: `5E1942C5-ACE1-4824-B263-F2F411298291`. A fresh task-owned iPhone 15 Pro was created after the initial cleanup to validate the rotation-cleanup follow-up. Xcode created and removed its worker clones for each run. Unrelated simulators were left untouched.
- The serial baseline included a fresh build. Later comparisons used warmed build products; some invoked the full wrapper and others `test-without-building`. Simulator/test-runner startup remains included.
- No retries or test exclusions. Counts are Xcode's logical test summary, including parameterized tests. All full runs include 487 unit and 64 UI tests; three existing opt-in native-device gates skip.
- XcodeGen 2.46.0 was installed as required by the README; Python tooling used the workspace's `.venv`. `pmset -g therm` reported no thermal or performance warnings during the worker sweep.

## Full-suite measurements

| Configuration | Wall time | Passed / skipped / failed | Outcome |
| --- | ---: | --- | --- |
| Original serial wrapper, cold build | 1334.88 s | 547 / 3 / 1 | Baseline grain-editor flake |
| Original six UI classes, 2 workers | 674.25 s | 547 / 3 / 1 | Same grain flake; no other failures |
| Fourteen UI classes, 4 workers | 475.71 s | 548 / 3 / 0 | Fastest completed passing configuration |
| Fourteen classes, 6 workers | Cancelled at 507.69 s | Incomplete | Only 31 UI cases completed; startup stalls and an unresponsive host |
| Debugger off, only UI target parallel, 4 workers | 592.21 s | 546 / 3 / 2 | Slower, with numeric-picker and phone-deletion failures; discarded |
| Original scheme, 3 workers | 595.03 s | 548 / 3 / 0 | Slower than four workers |
| Screenshot capture instead of recording, 4 workers | 565.64 s | 548 / 3 / 0 | No improvement; discarded |
| Default wrapper before rotation-cleanup fix, normal recording, 4 workers | 651.37 s | 548 / 3 / 0 | Passed; two 60-second rotation idle waits inflated the tail |
| Build once, preboot 4 simulators, direct balanced shards | 782.94 s | 548 / 3 / 0 | Includes setup, merged results and cleanup; slower, discarded |

The six-worker cancellation generated interruption failures; those are not product regressions or a completed suite timing. Xcode removed all six worker clones, and the host recovered. Larger worker counts were not attempted on this machine.

## Retained changes

`AppFlowTests` originally took **687.3 seconds** and `WorkspaceLayoutTests` **295.3 seconds**. XCTest's whole-class scheduling made AppFlowTests alone an approximately 11.5-minute floor regardless of worker count. Their tests are now grouped into smaller feature classes with fixture operations in shared base classes. The base classes contain no test methods.

Logs also showed approximately one second before XCTest's initial existence poll. `waitUntilExists` checks the actual current existence first and falls back to the original XCTest wait and timeout when needed. Central fixture/finite-metrics predicates likewise check their existing success condition before polling. Property and disappearance waits remain unchanged. An independent review verified every original method body after existence-helper-name normalization, no duplicates, and per-launch UUID fixture isolation. A subsequent focused review confirmed that three added deferred app terminations preserve all foreground rotation/assertion sequences. Runtime runs verified actual discovery and all 551 tests.

A second bottleneck affected failed runs. After a focused suite finished at 09:11:21, Xcode remained alive for over seven more minutes. Its process sample showed `XCTHRunDestinationAllocator.collectSimulatorDiagnostics` blocked in `XCTHProcessInvocation.simCtlDiagnose`; the child command was `simctl diagnose --timeout=600`.

The runner now defaults to `-collect-test-diagnostics never`, while retaining normal `.xcresult` results and attachments. Set `FUJI_STUDIO_TEST_DIAGNOSTICS=on-failure` to restore verbose simulator diagnostics. A temporary deliberate `XCTFail` returned the expected exit 65 in **12.21 seconds**, and its result summary recorded exactly that one failure. The probe was removed before subsequent full runs.

## Rejected changes and evidence limits

The unchanged baseline grain-editor test failed at an immediate disabled-size assertion, followed by a missed Strong selection. Three original isolated repeats passed at about **44.4 seconds** each, confirming intermittency. State waits alone still failed once; the failure hierarchy showed Strong open with Off still selected after XCTest reported tapping it. Coordinate/transition-wait experiments passed five repeats but took **57.6–58.3 seconds**. Aggressive property/disappearance fast paths later failed one of three repeats. All picker modifications and those fast paths were discarded. The original grain test is preserved, and this investigation does not claim to fix its flake.

One subsequent diagnostic was mistakenly started while the preceding failed Xcode process was still collecting diagnostics. That overlapping experiment is invalid and excluded from comparisons. Subsequent benchmarks waited for process exit.

All four orientation tests passed in the baseline. The complete historical 1,222-second stall did not reproduce, but the final repeat exposed its mechanism: `testTrayAndControlsStayAtPhysicalDeviceEdgesInBothLandscapeDirections` took **142.684 seconds**, including **61.64 seconds** waiting for app idleness after Landscape Left and **60.52 seconds** after Portrait. These waits are inside XCTest, not explicit test sleeps. The fixture has no loading animation. The Portrait wait was post-assertion cleanup, so it can safely run after terminating the completed app. The three active-app rotation cleanup blocks now terminate first, then reset portrait. All live foreground rotations and assertions remain, including the explicit portrait-return selection checks. Five affected rotation cases passed; the cleanup activity now targets SpringBoard and took **0.026 seconds**, and the dark geometry case took **11.725 seconds**. Foreground XCTest idle waits remain a runtime limitation; only unnecessary cleanup waiting is removed.

A direct-sharding probe built test products once, cloned/prebooted four isolated simulators, balanced all fourteen UI classes by measured durations, and merged unit plus four UI result bundles. All 551 tests passed. Preparation/unit readiness took **270.68 seconds**, the UI phase **498.45 seconds**, and total time including cleanup was **782.94 seconds**. The UI phase alone exceeded the best entire native-worker run, so the extra runner was not retained. No Python driver or additional runtime dependency was added to the project.

The debugger/per-target parallelization experiment and screenshot-format change were also reverted; the normal scheme, debugger, and recording behavior remain.

The practical stopping point is four native workers: three were slower, six exceeded useful local capacity, the alternate scheme/capture settings did not improve the result, and manual prepared-simulator sharding was slower even before accounting for setup. A repeat of the final defaults passed. A 5% material-improvement threshold was used for retaining extra settings. This is a measured local choice, not a universal optimum for other hardware or Xcode versions.

## Reproduce and inspect

```sh
FUJI_STUDIO_DESTINATION='platform=iOS Simulator,id=TASK_SIMULATOR_UDID' Scripts/test-ios.sh
FUJI_STUDIO_TEST_WORKERS=1 Scripts/test-ios.sh
FUJI_STUDIO_TEST_WORKERS=3 Scripts/test-ios.sh
FUJI_STUDIO_TEST_DIAGNOSTICS=on-failure Scripts/test-ios.sh FujiStudioUITests/PhoneRecipeEditorTests
```

`--fast` and focused selectors retain their existing usage. Worker settings apply only to simulator runs that include the UI target; unit-only and physical-device runs ignore them. The final runner validation exercised defaults, overrides, serial execution, focused selectors, invalid values, phone signing preservation, and diagnostic modes with command stubs. A separate `--fast` validation passed all **487 unit tests**. Independent review found no substantive issues; its minor worker-validation concern was fixed and verified before the final full run.

Raw logs, result bundles, source-conservation checks, the process sample, and command-stub checks remain under `/tmp/fuji-ui-test-speed/.build/`. The reviewable workspace is `/tmp/fuji-ui-test-speed`; checkpoints are pushed to `codex/ui-test-speed`.
