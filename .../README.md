```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# For Developer Eyes Only

The deliberately terse directory name is `...`. Its files are internal handoff
and planning records, not user documentation. The directory is intentionally
split into **hot state** that may be read during ordinary work and **cold history**
that should be opened only for a specific older question.

## Context discipline

The purpose of this directory is to *save* chat context, not consume it.

- `context.txt` is the only automatic new-chat bootstrap and has a hard **16 KiB**
  ceiling.
- Focused active documents have small limits enforced by
  `test/source_tree_hygiene.pl`; completed focused documents should normally be
  only a few KiB.
- Hot files contain durable invariants, current authoritative state, unfinished
  acceptance criteria, and immediate next work only.
- Completed implementation narratives, dated experiments, old test totals,
  superseded plans, and old measurements go in `context-history/`.
- Never keep an old checkpoint merely because a test looks for its prose. Tests
  should enforce structure/contracts or inspect executable artifacts instead.
- Update current state by replacement/consolidation. Do not append a new
  chronological checkpoint to a hot file.

## Files

### `context.txt`

Read once near the start of a new chat. It contains source-lineage rules, durable
workflow constraints, the small set of open workstreams, last meaningful
validation boundary, and the immediate next step. Do not reread it wholesale on
every turn.

### `roadmap.txt`

Only unfinished main-project roadmap items and their acceptance criteria.
Completed main-roadmap material is historical.

### `enhanced_asymmetric.txt`

Compact active handoff for the asymmetric-playfield enhanced multisprite WIP.
Read it when that side quest is the current task.

### `enhanced.txt`

Compact durable handoff for the symmetric enhanced-multisprite side quest.

### `bankswitching.txt`

Durable cartridge/bank identity rules plus unfinished bankswitching work. It is
the sole internal bankswitching design record; do not create a duplicate.

### `disassembler.txt`

Durable exact-round-trip disassembler contract plus unfinished mapper/analysis
work.

### `ram_optimization.txt`

Short durable closeout for the completed RIOT-RAM optimization workstream.
Authoritative current accounting lives in executable fixtures/tests, not here.

### `inline_roadmap.txt`

Short durable closeout for specialization/inlining policy. Open new optimizer
work as a new concrete roadmap item rather than reviving its old diary.

### `video_standard_roadmap.txt`

Short durable closeout for PAL/SECAM work and the few video-standard invariants
future changes must preserve.

### `instruction.txt`

Default bounded-work/handoff instructions for starting another development
session. It also retains the user's release-tag reminder at the bottom.

### `context-history/`

Cold chronological archive: one file per local work date, `YYYY-MM-DD.txt`.
Ordinary handoffs must not read this directory wholesale. Search or open only the
date needed to recover an older decision, regression, measurement, or discarded
approach.

Each entry begins with:

    YYYY-MM-DD HH:MM:SS PDT, short description

The entry description is ASCII and at most 50 characters; the complete header is
at most 72 characters. Detail lines may be arbitrary.

## Source lineage

Do not develop the same VCSC source lineage concurrently in multiple chats. The
newest user-supplied archive in the current chat is that chat's sole source-tree
authority. If lineages diverge, reconcile them explicitly before further work;
a newer timestamp alone does not prove ancestry.
