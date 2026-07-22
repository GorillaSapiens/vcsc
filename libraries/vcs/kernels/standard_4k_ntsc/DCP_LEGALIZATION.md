```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Standard-kernel DCP legalization

The normalized two-line kernel currently retains eleven zero-page `DCP` sites.
`DCP zp` performs a five-cycle memory decrement followed by the flag result of
`CMP A,zp`.  The direct legal spelling:

```asm
    dec object_y
    cmp object_y
```

is eight cycles.  Replacing all five steady-state object updates naively adds
15 CPU cycles to every two displayed scanlines and makes the playfield write
phase drift.  It is therefore not a safe textual opcode substitution.

## Locked steady-state schedule

`vcs_standard_kernel_dcp_schedule.test` executes the complete static-kernel
cartridge and records the actual instruction-start phase in frame 3.  In the
steady two-line body the five object updates are:

| Scanline half | Object | DCP start cycle |
| --- | --- | ---: |
| odd | ball | 45 normally; 43 on the playfield-row transition |
| odd | player 1 | 60 |
| even | missile 1 | 5 |
| even | player 0 | 48 |
| even | missile 0 | 69 |

The row-transition ball site occurs every 16 scanlines at lines congruent to 5
modulo 16 in the harness's frame-relative numbering.  The regression also
identifies sites by their final zero-page operand rather than by linked code
address, so ordinary code movement does not invalidate the baseline.

## Small legalization slices

1. Preserve this dynamic baseline while designing legal player update paths.
   Player paths must remain cycle-balanced for both visible and skipped rows.
2. Legalize the two player counters and verify graphics/collision output plus
   every playfield-store phase.
3. Legalize ball and missile counters, again preserving both enabled and
   disabled paths.
4. Legalize the alternate/final-row duplicates, remove the DCP inventory row,
   and only then mark task 20q complete.

A deliberate page-crossing branch is not an acceptable one-cycle filler.  The
linker now works to remove such crossings, and kernel timing must not depend on
reintroducing one.  Any added legal work must come from explicit padding,
removed redundant work, or a documented kernel scheduling change.
