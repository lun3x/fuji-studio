# Recipe editor availability

The user's explicit revision replaces the earlier grey, disabled inventory with a focused editor. Hide settings unavailable for the selected camera or current dependencies. Show only available values in each menu and the Kelvin list. Retain every stored value.

An available setting whose retained selection is invalid stays visible and tappable. Display its selected value in red, identify it as unavailable for accessibility, and keep Save disabled until a valid choice is made. Do not add that invalid selection to the menu. Apply the same treatment to a typed invalid Kelvin value. Switching back to a camera, film, or dependency that accepts a retained value restores it.

## Approach

Use the draft's existing capability/dependency rules to filter the editor. The user has specified this presentation directly; no additional design choice is needed. The standard catalog and persistence continue representing the full domain. Building another UI capability matrix would duplicate those rules.

The work is limited to editor presentation and regression coverage. No new camera mappings or conversion behavior are needed. Use an isolated `/tmp/` Jujutsu workspace and a task-specific simulator; update the existing `codex/standard-recipes` bookmark and PR #45.
