```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Standard-kernel DCP legalization

The normalized two-line kernel originally retained eleven zero-page `DCP`
sites. `DCP zp` performs a five-cycle memory decrement followed by the flag
result of `CMP A,zp`. The direct legal spelling:

```asm
    dec object_y
    cmp object_y
```

is eight cycles. Replacing all five steady-state object updates naively adds
15 CPU cycles to every two displayed scanlines and makes the playfield write
phase drift. Legalization therefore proceeds one timing family at a time.

## Completed player paths

The two steady player counters are now legal. Each path:

1. loads the current row into Y;
2. decrements Y and stores it back;
3. compares against a precomputed exclusive height; and
4. selects either the indexed glyph byte or a permanent zero through a
   cycle-balanced branch diamond.

The exclusive heights and zero byte occupy three private scratch bytes prepared
outside the visible hot loop. Player 1's legal path costs one cycle more than the
old DCP path; the main ball calculation now uses the already-retained
`height+2` SBC encoding instead of two ROL instructions, recovering that cycle.
Player 0's path costs two cycles more and uses an absolute TIA store; the next
iteration's former two-cycle pad is removed. The one-time first-entry save and
the row-transition delay are separately retimed so all PF writes remain at
cycles 24, 31, 38, and 45.

The final-row player duplicates still use DCP and are deliberately left for
20q4.

## Remaining dynamic DCP schedule

`vcs_standard_kernel_dcp_schedule.test` executes the complete example-05
cartridge and records the remaining ball and missile sites in frame 3. Across
46 central scanlines:

| Scanline half | Object | DCP start cycle |
| --- | --- | ---: |
| first | ball | 45 normally; 42 on the playfield-row transition |
| second | missile 1 | 5 |
| second | missile 0 | 71 |

The regression identifies sites by their final zero-page operands rather than
linked code addresses, so ordinary code movement does not invalidate the
baseline. The complete static-kernel test separately verifies stable player
output, skipped-row zero output, all five TIA objects, and every PF write phase.

## Remaining slices

1. **20q3:** legalize the steady ball and missile counters while preserving the
   enabled/disabled TIA values and the schedule above.
2. **20q4:** legalize alternate and final-row duplicates, remove the DCP
   inventory form, and replace this transitional DCP regression with wholly
   legal-opcode timing coverage.

A deliberate page-crossing branch is not an acceptable one-cycle filler. The
linker now works to remove such crossings, and kernel timing must not depend on
reintroducing one. Added work must come from explicit padding, removed
redundancy, or a documented scheduling change.
