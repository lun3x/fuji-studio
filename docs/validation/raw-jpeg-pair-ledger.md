# RAW+JPEG pair execution ledger

Base: `a6ec565a`. User selected creation of a pair followed by removal of the old
RAW-only asset after verification; prior inline execution authorization persists.

Pre-flight: Task 1's save/lookup/cleanup/alias APIs feed Task 2's writer and export
recovery. Task 2's alias adoption feeds Task 3's selection/picker UI. All consume
the same verified replacement identity; passive lookup remains read-only.

Jujutsu replaces skill scripts that assume Git. Tests and completion evidence are
recorded here rather than invoking scripts that would mutate Git state.
