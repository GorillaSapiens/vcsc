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

### `bankswitching.txt`

Durable cartridge/bank identity rules plus mapper-wide unfinished bankswitching
work. Mapper-specific focused records may be split out while active.

### `3ex.txt`

Compact active handoff for 3EX's current Stella compatibility state: detector
marker contract, confirmed >64K banked-RAM write alias, evidence, and upstream
acceptance criterion.

### `disassembler.txt`

Durable exact-round-trip disassembler contract plus unfinished mapper/analysis
work.

### `instruction.txt`

Default bounded-work/handoff instructions for starting another development
session.

### `release.txt`

Short human-only release/tag reminder. Keep it in the developer-record directory;
it is intentional project state, not generated residue.

### `context-history/`

Cold archive. Daily work history lives in local-date files named `YYYY-MM-DD.txt`;
completed focused records may be moved here under their former basename once they
have no unfinished work. Ordinary handoffs must not read this directory wholesale.
Search or open only the specific date or archived focused record needed to recover
an older decision, regression, measurement, or discarded approach.

Each entry begins with:

    YYYY-MM-DD HH:MM:SS PDT, short description

The entry description is ASCII and at most 50 characters; the complete header is
at most 72 characters. Detail lines may be arbitrary.

## Source lineage

Do not develop the same VCSC source lineage concurrently in multiple chats. The
newest user-supplied archive in the current chat is that chat's sole source-tree
authority. If lineages diverge, reconcile them explicitly before further work;
a newer timestamp alone does not prove ancestry.
