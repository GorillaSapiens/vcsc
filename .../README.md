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

The compact durable project handoff. It contains current state, durable invariants, active constraints, and the immediate next action. **Treat it as a new-chat bootstrap, not a per-turn checklist:** read it once near the start of a new chat, retain that state in the conversation, and do not reread the whole file on later turns merely because another task arrived. If later verification is needed, read only the relevant section, search result, line range, or tail. Re-reading unchanged handoff text repeatedly wastes the chat context that this file exists to conserve. Keep it small by updating existing state rather than appending history.

### Chat and archive lineage

Do not develop the same VCSC source lineage concurrently in multiple chats. A returned tarball is a handoff point: finish work in one chat, use that chat's returned archive as the input to the next chat, and then continue there. The newest user-supplied archive is the sole source-tree authority for that chat; never silently combine it with, or overwrite it from, an older working copy remembered from another chat.

If parallel chats were used accidentally, stop normal development and reconcile the divergent archives explicitly before doing more work. Compare the trees, identify changes unique to each lineage, and deliberately merge or choose between them. Do **not** assume that the archive with the newest timestamp contains all prior work, and do not package a stale working tree over a newer one.

### `roadmap.txt`

The detailed main-project roadmap and acceptance criteria formerly embedded in `context.txt`. The compact context selects the active workstream; this file preserves the full main checklist.

### `context-history/`

One chronological development-log file per local work date, named `YYYY-MM-DD.txt`. These files are historical archives and should be opened only when investigating an older decision, regression, or implementation detail—not read wholesale during every handoff. Entries may have multiline details, but every entry begins with an ASCII-only `YYYY-MM-DD HH:MM:SS PDT, short description` header; the description is at most 50 characters and the complete header is at most 72 characters.

### `bankswitching.txt`

The detailed internal design and ordered sub-roadmap for full-window F8/F6/F4 bankswitching, per-bank vectors and reset bridges, cross-bank trampolines, cartridge output order, and Superchip RAM. The compact `context.txt` handoff selects the active workstream; `roadmap.txt` owns the detailed main-project checklist.

### `ram_optimization.txt`

The focused RIOT-RAM optimization roadmap. It records the animated-gallery RAM baseline, explains renderer object-mask and hardware-stack ownership, and orders compiler lifetime overlay, repeated-inline scratch sharing, compact lowering, high-level example cleanup, phase overlay, direct-countdown renderer work, stack reduction, and optional two-sprite-only renderer profiles.

### `instruction.txt`

The intentionally retained default workflow for bounded roadmap work: finish only complete steps, reserve time for testing and cleanup, package a clean tree, and place the download link first. It is durable project guidance, not accidental conversational residue.

## Obsolete internal files removed during the hygiene audit

- The former top-level `NOTES.md` duplicated maintained documentation and contained stale claims, including that source-level inline functions were unsupported.
- The former `software_stack_inventory.txt` was a frozen historical snapshot. The executable regression `test/software_stack_inventory.pl` is now the authoritative check for removed software-stack emitters and runtime symbols.
