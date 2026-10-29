# UI test performance investigation

Date: 2026-10-29. Baseline: `34649780` (`main@origin`).

## Conditions

Mac with 10 logical CPUs and 16 GiB RAM, Xcode 27.1 (27A9275), iPhone 15 Pro / iOS 27.0 (24A434). Runs use task-owned simulator `5E1942C5-ACE1-4824-B263-F2F411298291` and its Xcode worker clones; other simulators are untouched. XcodeGen 2.46.0 was installed as required by the README. Python tooling uses the workspace's `.venv`.

The original full wrapper run included a fresh build. Worker comparisons use warmed build products and all unit/UI cases, without retries. All normal animations and gestures remain enabled. Three existing opt-in native-device gates remain unchanged.

## Baseline

The unchanged full `Scripts/test-ios.sh` took **1334.88 seconds (22m 15s)**: **551 tests, 547 passed, 3 skipped, 1 failed**. The failure was `AppFlowTests/testPhoneEditorGrainEffectAndSizeSaveIndependently`, initially at the immediate disabled-size assertion and then tapping Strong. All four orientation tests passed; the historical 1,222-second animation-notification stall did not reproduce. No speculative rotation or production app changes are included.

`AppFlowTests` took **687.3 seconds** and `WorkspaceLayoutTests` **295.3 seconds**. Whole-class scheduling makes the former an approximately 11.5-minute floor even with many workers until the class is divided.

## Rejected picker experiments

Three isolated original grain repeats passed at approximately **44.4 seconds** each, confirming intermittency. State waits alone still failed once; the hierarchy showed Strong still open with Off selected after XCTest reported tapping it. Coordinate choice/value taps with explicit transition waits passed five repeats at **57.6–58.3 seconds**, but were slower. Aggressive property/disappearance fast paths subsequently failed one of three repeats. These picker changes and property/disappearance fast paths were discarded; the original grain test is retained.

One later diagnostic was inadvertently started while the previous failed Xcode process was still collecting diagnostics. That overlapping experiment is invalid and excluded from comparisons. Subsequent benchmarks explicitly wait for process exit.

## Failure-finalization overhead

After the focused test suite finished at 09:11:21, Xcode remained alive for over seven more minutes. A process sample showed `XCTHRunDestinationAllocator.collectSimulatorDiagnostics` waiting in `XCTHProcessInvocation.simCtlDiagnose`. Its child was `simctl diagnose --timeout=600`, writing into the task's result bundle. This explains a separate source of long failure latency.

The runner now defaults to `-collect-test-diagnostics never`; set `FUJI_STUDIO_TEST_DIAGNOSTICS=on-failure` to restore verbose diagnostics. Normal `.xcresult` results and attachments are retained. A temporary UI test with an intentional `XCTFail` exited with the expected code 65 in **12.21 seconds**, and its result summary recorded exactly one deliberate failure. The probe was removed and the project regenerated before the full benchmark.

## Measurements in progress

Worker experiments and final validation are appended as they complete. Raw logs, result bundles, source conservation checks, and command-stub checks are under ignored `.build/Benchmarks/` in `/tmp/fuji-ui-test-speed`.

| Configuration | Full wall time | Passed / skipped / failed | Notes |
| --- | ---: | --- | --- |
| Original serial wrapper, cold build | 1334.88 s | 547 / 3 / 1 | Baseline grain flake |
| Original six UI classes, 2 workers | 674.25 s | 547 / 3 / 1 | Same grain flake; all 551 cases executed; verbose diagnostics off |

The two-worker result confirms substantial improvement but remains bounded by the large AppFlowTests class. Its single failure is retained in the comparison, not retried or excluded.
| Split fourteen UI classes, 4 workers | 475.71 s | 548 / 3 / 0 | Full suite passed |
| Split classes, 6 workers | Cancelled at 507.69 s | Not a complete run | Only 31 UI cases completed; startup stalls and an unresponsive host made this configuration unsuitable |
| Separate automation scheme, UI-only parallelism, debugger off, 4 workers | 592.21 s | 546 / 3 / 2 | Slower, with numeric-picker and phone-deletion failures; configuration discarded |

Six workers were cancelled deliberately; cancellation failures are not reported as product regressions. Xcode removed those worker clones, and the host recovered. Larger worker counts were not attempted on this machine.

The separate automation scheme and per-target parallelization experiment were reverted. The normal scheme/debugger behavior remains. The final comparisons use the original scheme with explicit bounded workers.
