```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# For Developer Eyes Only

This directory is **for developer eyes only**. Its contents are project-maintenance records, not user documentation or installed toolchain data. They stay in the source tree so work can continue consistently across development sessions without presenting internal process files as part of the public interface.

## Files

### `context.txt`

The durable project handoff, design-decision record, immediate TODO list, and chronological development log. Read it before continuing queued work, and update it after meaningful implementation or design changes.

### `remove.txt`

The cumulative one-path-per-line deletion and rename ledger. It is used when reconciling or pruning older source snapshots and must remain synchronized with intentional removals and moved paths.

## Obsolete internal files removed during this audit

- The former top-level `NOTES.md` duplicated maintained documentation and contained stale claims, including that source-level inline functions were unsupported.
- The former `software_stack_inventory.txt` was a frozen historical snapshot. The executable regression `test/software_stack_inventory.pl` is now the authoritative check for removed software-stack emitters and runtime symbols.
