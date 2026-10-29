# UI test performance investigation

Date: 2026-10-29. Baseline: `34649780`. Development bookmark: `codex/ui-test-speed`.

## Result

The runner defaults to **four native simulator workers**, with all **64 original UI methods** distributed over **14 feature classes** instead of six. The original serial full-suite baseline took **1334.88 seconds (22m 15s)**, including a cold build and one existing grain-editor failure. Final accepted-source validation is recorded below when complete.

The fastest experimental passing run was **475.71 seconds (7m 56s)**. That configuration included immediate existence/predicate shortcuts which were subsequently rejected for reliability. **That timing is not a claim about the final source.**

## Retained changes

- `FUJI_STUDIO_TEST_WORKERS` defaults to four; use one for serial execution. Worker options apply only to simulator runs containing UI tests. Unit-only selectors, `--fast`, and physical-device signing retain their behavior.
- Smaller feature classes remove the whole-class scheduling bottleneck. Originally, AppFlowTests alone took 687.3 seconds and WorkspaceLayoutTests 295.3 seconds. Shared base classes contain no test methods. [Apple describes class-based parallel distribution](https://developer.apple.com/videos/play/wwdc2020/10221/).
- Verbose simulator diagnostics are opt-in with `FUJI_STUDIO_TEST_DIAGNOSTICS=on-failure`. Normal `.xcresult` results and attachments remain. A sampled failed run spent over seven minutes in `collectSimulatorDiagnostics`, waiting for `simctl diagnose --timeout=600`. With the new default `never`, a temporary deliberate failure returned the expected exit 65 in 12.21 seconds and recorded exactly one failure. The probe was removed.
- Three completed-app rotation cleanups terminate the app before resetting portrait. The measured post-assertion reset dropped from a 60.52-second AUT idle wait to a 0.026-second SpringBoard wait. All live foreground rotations, screenshots, and assertions remain, including explicit portrait-return selection checks. Five affected cases passed.
- Editor control revelation scrolls `recipe.editor.form` rather than the entire app. When the alphabetic keyboard exposes Return, it dismisses it through that public UI action and waits for disappearance. A regression setup explicitly opens the name keyboard before checking the complete numeric menu. The old helper failed; the new helper passed. Number-pad dismissal is not added.

No production app code, test methods, assertions, native animations, or existing device gates were removed. All immediate existence/predicate shortcuts were reverted, including ElementWaits.swift. The original scheme, debugger, and recording format remain.

## Measurement conditions

- Mac: 10 logical CPUs, 16 GiB RAM. Xcode 27.1 (27A9275), iPhone 15 Pro / iOS 27.0 (24A434).
- Isolated task-owned simulators; Xcode creates and removes its native worker clones. Unrelated simulators were left untouched.
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

Six-worker interruption failures are not product regressions or completed timing data. Higher counts were not attempted after the host exceeded useful capacity. The direct-shard probe's preparation/unit readiness took 270.68 seconds, and UI execution alone took 498.45 seconds; it was slower even before setup. Its four extra simulators were removed, and no Python runtime dependency was added.

## Reliability and evidence limits

The original grain-editor test is intermittent. Its baseline failure was an immediate disabled-size assertion followed by a missed Strong choice. Three original isolated repeats passed at about 44.4 seconds each. State-wait and coordinate experiments did not provide a reliable speed improvement and were discarded. The subsequent keyboard-focused editor group reproduced this baseline flake at a Save transition. This investigation does not claim to fix grain selection.

Fresh parallel runs exposed numeric-menu geometry and accessibility hit-testing failures with the fast-wait candidate. Every shortcut was removed. Seven focused cases then passed with original native waits in 258.11 seconds. The next erased-simulator full run still showed keyboard-clipped editor menus, motivating the explicit keyboard regression and form-scrolling correction.

The keyboard-focused five-case editor run took 220.98 seconds: four passed and the grain case failed. This is not a passing suite. A later four-worker erased-simulator run took 794.86 seconds (545 passed, 3 skipped, 3 failed). It reproduced grain selection, a camera-status predicate timeout with a nine-second AX lookup, and a keyboard appearing after the temperature helper's initial check. The temperature case now also explicitly focuses Name and waits for the keyboard before revealing the white-balance control; the independent reviewer confirmed that this deterministic precondition preserves its validation and persistence coverage. Lower-worker comparisons use that strengthened setup. Return is not a general solution for keyboards appearing after a presence check.

The remaining foreground rotation waits occur inside XCTest, not explicit test sleeps. One trace contained a 61.64-second Landscape Left idle wait. Preserving native foreground rotation coverage means that long tail can still recur.

One early diagnostic was mistakenly started while its preceding failed Xcode process was collecting diagnostics. That overlapping experiment is invalid and excluded. Subsequent measurements wait for actual process exit.

Four workers were the fastest early experiment, but the later cold runs exposed startup saturation and failures. The final worker count must account for those results rather than select only the best time. Six stalled, alternate scheme/capture settings did not improve the early result, and prepared manual sharding was slower. This is not proof of a universal minimum. Hardware, runtime, and native worker startup affect the result; a 5% material-improvement threshold was used when considering extra settings.

## Reproduce and inspect

```sh
FUJI_STUDIO_DESTINATION='platform=iOS Simulator,id=TASK_SIMULATOR_UDID' Scripts/test-ios.sh
FUJI_STUDIO_TEST_WORKERS=1 Scripts/test-ios.sh
FUJI_STUDIO_TEST_WORKERS=3 Scripts/test-ios.sh
FUJI_STUDIO_TEST_DIAGNOSTICS=on-failure Scripts/test-ios.sh FujiStudioUITests/PhoneRecipeEditorTests
```

Runner command-stub checks cover defaults, overrides, serial execution, focused selectors, invalid values, ignored worker settings for unit-only/phone runs, signing preservation, and diagnostic modes. `bash -n` passes. A separate `--fast` run passed all 487 unit cases.

Independent review verified all 64 original method bodies after normalizing the then-proposed wait names, and subsequently reviewed rotation cleanup and the keyboard/form correction. No substantive issues were found. One minor worker-validation concern was fixed and verified. Source conservation after restoring native waits permits only the three cleanup additions and the explicit keyboard regression setup.

Raw logs, result bundles, process samples, command-stub checks, and discarded probes remain under `/tmp/fuji-ui-test-speed/.build/`. The reviewable Jujutsu workspace is `/tmp/fuji-ui-test-speed`; checkpoints are pushed to `codex/ui-test-speed`.
