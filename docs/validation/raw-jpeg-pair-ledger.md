# RAW+JPEG pair execution ledger

Base: `a6ec565a`. User selected creation of a pair followed by removal of the old
RAW-only asset after verification; prior inline execution authorization persists.

Pre-flight: Task 1's save/lookup/cleanup/alias APIs feed Task 2's writer and export
recovery. Task 2's alias adoption feeds Task 3's selection/picker UI. All consume
the same verified replacement identity; passive lookup remains read-only.

Jujutsu replaces skill scripts that assume Git. Tests and completion evidence are
recorded here rather than invoking scripts that would mutate Git state.

Task 1: complete. Observed the missing service behavior fail; then observed
metadata-loss and limited-access recovery regressions fail before fixing them.
`Scripts/test-ios.sh FujiStudioTests/PhotoLibraryPairerTests` passed all 8 tests
(including five corruption/change variants). This includes real byte read-back,
metadata preservation, durable reopen, read-only recovery, and submitted-operation
cancellation. Log: `/tmp/fuji-pair-service-final.log`.

Task 2: complete. Writer routing, catalog alias ordering, selection replacement,
and explicit cleanup recovery were observed failing before implementation.
The app-level mixed-batch test then reproduced the lost selection and premature
pause with replacement notifications before fixing their handling. The 26
focused tests passed, followed by `Scripts/test-ios.sh --fast`: 583 Swift Testing
tests and 20 XCTest cases passed. Logs: `/tmp/fuji-pair-app-green.log` and
`/tmp/fuji-pair-fast.log`. The fixture replacement implementation moved into this
task so the actual notification timing could be tested before the UI step.

Task 3 in progress: the full RAW-only export UI flow reaches both exports and
retains the same checked pair. Its first run failed only the expected Paired JPEG
label assertion (`/tmp/fuji-pair-ui-red.log`).

Final review: two P2 findings were reproduced and fixed in one pass. An original
reordered within an album is now rejected, accounting for our own inserted pair.
A limited-to-full permission transition cannot certify an inaccessible original
as removed, in passive lookup or explicit cleanup. Both regressions were observed
RED in `/tmp/fuji-pair-review-red.log`, then GREEN in the full fast unit run:
585 Swift Testing tests and 20 XCTest cases passed (`/tmp/fuji-pair-review-green.log`).
Affected UI checks after these fixes: 11 passed, 1 existing native Home-boundary
skip (`.build/TestResults/20261030-162526-8348.xcresult`).

The reviewer did not run tests; their runtime-result question is resolved by the
main agent's observed outputs above. Actual native PhotoKit classification,
metadata retention and album ordering remain untested on a real photo library.
The installed API/SDK and native implementation were inspected, and every actual
export must pass resource and metadata read-back guards before removal. Automated
validation does not create or remove user photos on the phone.
