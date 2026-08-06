```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# For Developer Eyes Only

The deliberately terse directory name is `...`. This directory is **for developer eyes only**. Its contents are project-maintenance records, not user documentation or installed toolchain data. They stay in the source tree so work can continue consistently across development sessions without presenting internal process files as part of the public interface.

## Files

### `context.txt`

The compact durable project handoff. It contains current state, durable invariants, active constraints, and the immediate next action. Read it before continuing queued work and keep it small by updating existing state rather than appending history.

### `roadmap.txt`

The detailed main-project roadmap and acceptance criteria formerly embedded in `context.txt`. The compact context selects the active workstream; this file preserves the full main checklist.

### `context-history/`

One chronological development-log file per local work date, named `YYYY-MM-DD.txt`. These files are historical archives and should be opened only when investigating an older decision, regression, or implementation detail—not read wholesale during every handoff.

### `bankswitching.txt`

The detailed internal design and ordered sub-roadmap for full-window F8/F6/F4 bankswitching, per-bank vectors and reset bridges, cross-bank trampolines, cartridge output order, and Superchip RAM. The compact `context.txt` handoff selects the active workstream; `roadmap.txt` owns the detailed main-project checklist.

### `instruction.txt`

The intentionally retained default workflow for bounded roadmap work: finish only complete steps, reserve time for testing and cleanup, package a clean tree, and place the download link first. It is durable project guidance, not accidental conversational residue.

### `remove.txt`

The cumulative one-path-per-line deletion and rename ledger. It is used when reconciling or pruning older source snapshots and must remain synchronized with intentional removals and moved paths.

## Obsolete internal files removed during the hygiene audit

- The former top-level `NOTES.md` duplicated maintained documentation and contained stale claims, including that source-level inline functions were unsupported.
- The former `software_stack_inventory.txt` was a frozen historical snapshot. The executable regression `test/software_stack_inventory.pl` is now the authoritative check for removed software-stack emitters and runtime symbols.
