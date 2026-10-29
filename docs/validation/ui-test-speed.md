# UI test performance investigation

Date: 2026-10-29. Baseline: `34649780`. Development bookmark: `codex/ui-test-speed`.

## Result

The runner now defaults to **two native simulator workers**, with the latest main branch's **72 UI methods** distributed over **16 feature classes**. The performance calibration below was completed earlier with 64 UI methods in 14 classes, before main added eight tests. The historical clean 64-UI-test full-suite run took **843.80 seconds (14m 04s)**: **548 passed, three existing skips, zero failures**. The original serial baseline took **1334.88 seconds (22m 15s)**, including a cold build and one existing grain-editor failure. This is approximately **37% less measured wall time**; measurement conditions and limitations are below.

The expanded latest-main suite also passed complete validation: **579 logical tests, 576 passed, three existing skips, zero failures**, in **901.46 seconds (15m 01s)**. This includes **507 passing unit cases** and **72 UI cases across 16 suites (69 passed, three skipped)**. It is a separate validation result, not a like-for-like comparison with the earlier 64-UI-test benchmark.

Two is the selected default because the final cold three-worker controls failed original UI checks, four had multiple failures and heavy startup load, and six stalled. This is the best clean validated configuration from this investigation, not a guarantee of the fastest or flake-free setting on every host.

The fastest experimental passing run was **475.71 seconds (7m 56s)**. That configuration included immediate existence/predicate shortcuts which were subsequently rejected for reliability. **That timing is not a claim about the final source.**

## Retained changes

- `FUJI_STUDIO_TEST_WORKERS` defaults to two; use one for serial execution. Worker options apply only to simulator runs containing UI tests. Unit-only selectors, `--fast`, and physical-device signing retain their behavior.
- Smaller feature classes remove the whole-class scheduling bottleneck. Originally, AppFlowTests alone took 687.3 seconds and WorkspaceLayoutTests 295.3 seconds. Shared base classes contain no test methods. [Apple describes class-based parallel distribution](https://developer.apple.com/videos/play/wwdc2020/10221/).
- Verbose simulator diagnostics are opt-in with `FUJI_STUDIO_TEST_DIAGNOSTICS=on-failure`. Normal `.xcresult` results and attachments remain. A sampled failed run spent over seven minutes in `collectSimulatorDiagnostics`, waiting for `simctl diagnose --timeout=600`. With the new default `never`, a temporary deliberate failure returned the expected exit 65 in 12.21 seconds and recorded exactly one failure. The probe was removed.
- Three completed-app rotation cleanups terminate the app before resetting portrait. The measured post-assertion reset dropped from a 60.52-second AUT idle wait to a 0.026-second SpringBoard wait. All live foreground rotations, screenshots, and assertions remain, including explicit portrait-return selection checks. Five affected cases passed.
- Editor control revelation scrolls `recipe.editor.form` rather than the entire app. When the editor alphabetic keyboard exposes Return, it sends a public Return typing event to the focused field and waits for disappearance. This avoids depending on the software Return key having a hittable screen coordinate. Regression setups explicitly open the name keyboard before the numeric menu, temperature-validation flow, and film-selection flow. The old helper failed; the new helper passed. Number-pad dismissal is not added.

No production app code, test methods, assertions, native animations, or existing device gates were removed. All immediate existence/predicate shortcuts were reverted, including ElementWaits.swift. The original scheme, debugger, and recording format remain.

## Measurement conditions

- Mac: 10 logical CPUs, 16 GiB RAM. Xcode 27.1 (27A9275), iPhone 15 Pro / iOS 27.0 (24A434).
- Isolated task-owned simulators; Xcode creates and removes its native worker clones. One unrelated iPhone 18 Pro simulator remained booted throughout and was left untouched.
- Baseline includes a cold build. Later runs use warmed build products; some experiments use `test-without-building`. Xcode worker/test-runner startup is included; task-base creation/erase/preboot is outside wrapper timings. The manual probe includes its own preparation and cleanup. Therefore these are operational measurements, not a controlled estimate of parallelism alone.
- No retries or test exclusions. Full runs have 551 logical cases: 487 unit and 64 UI. Three existing opt-in native-device gates skip. Parameterized execution counts differ from logical summary counts.
- XcodeGen 2.46.0 installed as required by README; Python probes use the workspace's `.venv`. No thermal/performance warnings were reported during the worker sweep.

## Experiment ledger

Rows through direct sharding used the subsequently rejected existence/predicate shortcuts, except the original baseline. They support the bounded worker choice but do not establish final-source speed or reliability.

| Configuration | Wall time | Passed / skipped / failed | Decision |
| --- | ---: | --- | --- |
| Original serial, cold build | 1334.88 s | 547 / 3 / 1 | Baseline grain-editor flake |
| Original six classes, 2 workers | 674.25 s | 547 / 3 / 1 | Same grain flake |
| Fourteen classes, 4 workers | 475.71 s | 548 / 3 / 0 | Fastest experiment; shortcuts later rejected |
| Fourteen classes, 6 workers | Cancelled at 507.69 s | Incomplete | Only 31 UI cases completed; runner startup stalled and host became unresponsive |
| Debugger off, UI-only target parallel, 4 workers | 592.21 s | 546 / 3 / 2 | Slower; discarded |
| Original scheme, 3 workers | 595.03 s | 548 / 3 / 0 | Slower than four |
| Screenshot capture instead of recording, 4 workers | 565.64 s | 548 / 3 / 0 | No improvement; discarded |
| Default repeat, before cleanup fix | 651.37 s | 548 / 3 / 0 | Passed; two 60-second native rotation waits inflated tail |
| Build once, preboot 4 simulators, balanced direct shards | 782.94 s | 548 / 3 / 0 | Slower; no custom coordinator retained |
| Cleanup fix, still using shortcuts | 611.43 s | 546 / 3 / 2 | Numeric geometry and AX5 hit-testing failures; shortcuts removed |
| Original waits plus cleanup, erased simulator | 768.17 s | 546 / 3 / 2 | Two editor menus obstructed by keyboard |
| Keyboard/form helper and explicit numeric keyboard setup, 4 workers, erased simulator | 794.86 s | 545 / 3 / 3 | Grain, camera-status timeout, temperature keyboard race |
| Explicit keyboard setup for numeric and temperature cases, 3 workers, erased simulator | 740.38 s | 547 / 3 / 1 | All editor cases passed; original immediate AX5 Select hit-testing assertion failed |
| Same source, 2 workers, erased simulator | 843.80 s | 548 / 3 / 0 | Selected; all original assertions unchanged |
| 3 workers plus scoped AX5 readiness candidate | Interrupted; process exited at 474.21 s | Incomplete | Numeric Save transition failed before the AX5 candidate ran; candidate rejected and fully reverted |

Interruption failures in the six-worker and final three-worker probes are not product regressions or completed timing data. Higher counts were not attempted after the host exceeded useful capacity. The direct-shard probe's preparation/unit readiness took 270.68 seconds, and UI execution alone took 498.45 seconds; it was slower even before setup. Its four extra simulators were removed, and no Python runtime dependency was added.

## Reliability and evidence limits

The original grain-editor test is intermittent. Its baseline failure was an immediate disabled-size assertion followed by a missed Strong choice. Three original isolated repeats passed at about 44.4 seconds each. State-wait and coordinate experiments did not provide a reliable speed improvement and were discarded. The subsequent keyboard-focused editor group reproduced this baseline flake at a Save transition. This investigation does not claim to fix grain selection.

Fresh parallel runs exposed numeric-menu geometry and accessibility hit-testing failures with the fast-wait candidate. Every shortcut was removed. Seven focused cases then passed with original native waits in 258.11 seconds. The next erased-simulator full run still showed keyboard-clipped editor menus, motivating the explicit keyboard regression and form-scrolling correction.

The keyboard-focused five-case editor run took 220.98 seconds: four passed and the grain case failed. This is not a passing suite. A later four-worker erased-simulator run took 794.86 seconds (545 passed, 3 skipped, 3 failed). It reproduced grain selection, a camera-status predicate timeout with a nine-second AX lookup, and a keyboard appearing after the temperature helper's initial check. The temperature case now also explicitly focuses Name and waits for the keyboard before revealing the white-balance control; the independent reviewer confirmed that this deterministic precondition preserves its validation and persistence coverage. Lower-worker comparisons use that strengthened setup. Return is not a general solution for keyboards appearing after a presence check.

The remaining foreground rotation waits occur inside XCTest, not explicit test sleeps. One trace contained a 61.64-second Landscape Left idle wait. Preserving native foreground rotation coverage means that long tail can still recur.

One early diagnostic was mistakenly started while its preceding failed Xcode process was collecting diagnostics. That overlapping experiment is invalid and excluded. Subsequent measurements wait for actual process exit.

The final bounded experiment added a five-second native Select.isHittable readiness wait only in the AX5 layout test, before its geometry measurements, retaining every original assertion. Review found it would still reject a persistent failure. However, an unrelated numeric-picker Save-disappearance assertion failed before that candidate ran. The predefined clean-and-faster gate was no longer achievable, so the run was interrupted rather than repeated until green. The wait and its diagnostic attachment were completely reverted. No transient-hit-testing root-cause claim is made.

The final decision uses the clean two-worker control, rather than the fastest favorable experimental time. Three workers were faster but failed in two cold attempts; four cold workers also failed, and six stalled. During startup the host showed roughly 7 GB used swap, 15 GB physical memory used, and substantial compression and simulator background activity. Those observations support resource saturation as a concern, but do not establish the cause of every individual UI failure. Alternative scheme/capture settings did not improve the early control, and prepared manual sharding was slower than the strongest native control. No further verified safe material gain was found. A 5% improvement threshold was used when considering extra settings; this is a measured local stopping point, not proof of a universal minimum.

The selected historical passing run used the UI test source at checkpoint `8b3d4016` and explicit worker count two. The later PR rebase preserves eight additional main-branch UI tests and its two editor-test corrections; its validation is recorded separately below. The final runner default emits the same Xcode flags; command-stub checks first rejected the prior default four and then passed with two. One clean full run does not prove the existing grain flake is solved, and XCTest startup/foreground-rotation variation remains.

## Reproduce and inspect

```sh
FUJI_STUDIO_DESTINATION='platform=iOS Simulator,id=TASK_SIMULATOR_UDID' Scripts/test-ios.sh
FUJI_STUDIO_TEST_WORKERS=1 Scripts/test-ios.sh
FUJI_STUDIO_TEST_WORKERS=3 Scripts/test-ios.sh
FUJI_STUDIO_TEST_DIAGNOSTICS=on-failure Scripts/test-ios.sh FujiStudioUITests/PhoneRecipeEditorTests
```

Runner command-stub checks cover defaults, overrides, serial execution, focused selectors, invalid values, ignored worker settings for unit-only/phone runs, signing preservation, and diagnostic modes. `bash -n` passes. A separate `--fast` run passed all 487 unit cases.

Independent review verified all 64 original method bodies after normalizing the then-proposed wait names, and subsequently reviewed rotation cleanup and the keyboard/form correction. No substantive issues were found. One minor worker-validation concern was fixed and verified. Comparison of all 72 latest-main test-method bodies after rebasing permits only the three cleanup additions and the three explicit keyboard regression setups (including film-menu revelation before film selection). The rejected AX5 readiness block is absent.

Raw logs, result bundles, process samples, command-stub checks, and discarded probes remain under `/tmp/fuji-ui-test-speed/.build/`. The reviewable Jujutsu workspace is `/tmp/fuji-ui-test-speed`; checkpoints are pushed to `codex/ui-test-speed`.

## Cleanup and publication

The initial task base and manual pool were removed, and the follow-up base `58ACFD93-AFC0-4BF0-A8DC-4B92280E90C1` was deleted after the final experiment exited. No task-owned native worker clones remain. The unrelated iPhone 18 Pro remains booted. Final cleanup evidence is `.build/Benchmarks/final-cleanup-verified.json`.

The historical 64-UI-test passing result is `.build/TestResults/20261029-123700-34645.xcresult`; the exact bundle path is recorded in `.build/Benchmarks/native-2-cold.log`, and its parsed summary is `.build/Benchmarks/native-2-cold.summary.json`.

## PR integration with latest main

Rebased onto `3083d717` (PR #32). Preserved all 72 latest-main UI methods, including eight new tests and the updated persisted-Small expectations and film-before-name editor sequence. Added CameraFilterTests and RecipePhotoCompatibilityTests, and placed the new X-T5 editor case in PhoneRecipeEditorTests. Shared reveal retains application scrolling for the new recipe-menu caller outside the editor; it uses the form when an editor exists.

A mechanical comparison and independent review confirm every latest-main test body is retained, normalizing only three cleanup additions, three keyboard preconditions, and the film-menu reveal call. No production app, unit-test, package, or project changes relative to latest main. Full rebased validation passed as recorded below; the historical 843.80-second timing is not a measurement of the expanded suite.

The first rebased run was interrupted after the known missed-Strong grain interaction and a film-menu failure: a visible keyboard clipped PROVIA out of the menu before name editing had begun. The film test now explicitly focuses Name, waits for the keyboard, and reveals Film through the existing Return-dismissal helper before selecting the film. This preserves main's film-selection-before-name-replacement sequence and every assertion. Both affected editor cases then passed in a focused run (2 tests, 0 failures, 128.07 seconds including build/startup). The original parallel failures remain recorded; this focused pass is not reported as a passing full run. A subsequent parallel attempt exposed the offscreen-key issue described below.

A second parallel integration attempt exposed an additional automation issue: in the numeric, temperature, and film flows, Return existed in the accessibility tree at y=1065 on the 852-point screen, and tapping it failed scroll-to-visible. That attempt was interrupted and retained as failure evidence. The editor-only dismissal helper now sends Return with `app.typeText("\n")` to the already focused Name field, retaining the keyboard-disappearance assertion and timeout. The new outside-editor recipe-menu caller is excluded from this typing path. Independent review accepted the public-event approach. The subsequent complete run passed all non-gated tests, including all six editor cases and both new recipe/photo compatibility cases.

## Final PR verification

[PR #33](https://github.com/lun3x/fuji-studio/pull/33) integrates these changes with main `3083d717`. The passing full run tested UI/script source at `8197400d`, using the default two workers and no test selectors or automatic retries. The final documentation update does not change that tested code.

- Complete command: `FUJI_STUDIO_DESTINATION='platform=iOS Simulator,id=TASK_SIMULATOR_UDID' Scripts/test-ios.sh`.
- Result: 579 logical tests; 576 passed, three existing native-device gates skipped, zero failed; wall time 901.46 seconds.
- Result bundle: `.build/TestResults/20261029-142445-75433.xcresult`.
- Parsed evidence: `.build/Benchmarks/pr-return-event-full.summary.json` and `.build/Benchmarks/pr-return-event-full.tests.json`. The test tree confirms 72 UI cases and 16 UI suites, including all eight incoming cases.
- Independent review and mechanical comparison preserve every latest-main test/assertion. Runner argument checks and Bash syntax pass. Production, unit-test, package, and project files remain identical to latest main.
- Earlier interrupted failures and the focused two-case pass remain in the report; no claim is made that one clean run eliminates the historical grain flake.

The PR task simulator `3EB11191-15DE-4A38-9505-546B1F669D74` and its worker clones were deleted after Xcode exited. Cleanup evidence is `.build/Benchmarks/pr-cleanup-verified.json`; the unrelated iPhone 18 Pro remains booted and untouched.
