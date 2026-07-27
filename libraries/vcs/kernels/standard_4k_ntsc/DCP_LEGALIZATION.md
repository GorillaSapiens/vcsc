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

is eight cycles. Replacing all five steady-state object updates naively would
add 15 CPU cycles to every two displayed scanlines and visibly move the
playfield writes. Task 20q therefore legalized one timing family at a time.

## Player paths

The two steady player counters use legal `LDY`/`DEY`/`STY`/`CPY` branch
diamonds. Each path decrements the row, compares it with a precomputed exclusive
height, and selects either the indexed glyph or a permanent zero byte. The draw
and skip arms remain cycle-balanced.

Player 1's extra cycle was recovered by replacing the old ball `ROL` pair with
the already-retained `height+2` subtraction. Player 0 uses an absolute TIA store
and consumes the next iteration's former two-cycle pad. First entry and row
transitions are retimed separately, so PF1/PF2 writes remain at cycles 24, 31,
38, and 45.

## Steady ball and missile paths

During VBLANK, `vcs_standard_prepare_object_masks` computes one packed bit per
live BL, M1, and M0 update. The visible kernel consumes the bits with legal
zero-page-indexed `LSR` instructions. Loading constant 1 preserves carry, and
`ADC #0` maps the shifted carry directly into TIA enable bit 1.

The legal schedule is locked across 46 central scanlines:

| Scanline half | Object | Legal `LSR` start cycle |
| --- | --- | ---: |
| first | ball | 45 normally; 39 on a playfield-row transition |
| second | missile 1 | 2 |
| second | missile 0 | 68 |

The packed masks raise mandatory module RAM to 80 bytes and require a ROM
playfield in this profile. A mutable 48-byte playfield no longer fits alongside
the mask workspace and reserved hardware stack.

## Final-row paths

The five final-row duplicates are also legal. The VBLANK helper precomputes the
exact bytes that the old final `DCP` sequences would have produced:

* BL, M1, and M0 retain the old compare/carry-to-TIA value, including otherwise
  ignored high bits;
* P0 and P1 retain the exact final glyph-or-zero selection at row `Y - 89`;
* the final-row visible code loads those bytes and uses explicit legal `BIT` and
  `NOP` delays to preserve every TIA store cycle.

The formerly temporary schedule regression is now
`vcs_standard_kernel_legal_schedule.test`. It locks the three steady mask
operands and cycles and checks all five final precomputed values.

## Post-legalization raster repair

The original task-20q tests were not sufficient: they proved selected
instruction phases and merely counted that each object appeared, but did not
lock the complete raster. Three rendering regressions consequently survived:

* the mask-clear loop used `TXA` to advance its record offset and then reused A
  as the value to store, filling later mask records with offsets instead of
  zero;
* M0's application Y value was saved in pointer workspace before the horizontal
  positioning loop reused that byte, so later frames restored a corrupted Y;
* a 37-cycle pre-kernel setup call crossed a scanline, and its replacement delay
  preserved that unintended whole-frame vertical shift.

The repaired helper keeps zero in Y while X advances, reconstructs and saves M0
Y in the existing twelve-cycle post-positioning slot, and removes the extra
pre-kernel delay. `test/fixtures/vcs_examples/06_object_motion/golden.c26` gives all five TIA objects
separate documented vertical bands and independently phased horizontal motion.
The first version of `vcs_standard_motion.test` still checked only RAM X values
and vertical TIA writes. That missed a separate linker failure: each
`@repostable-$100` operand was relocated by its altered packed value, which
happened to lie in an earlier code layout. RESP coarse positioning worked while
all five HMxx reads came from unrelated bytes, quantizing movement into roughly
15-pixel jumps.

Version-2 o26 local relocations now preserve the exact defining layout. The
motion regression checks every RESP cycle and HMxx nibble for 320 frames,
and the example moves every object at a distinct integer speed across the full
X=0..159 range against a visible ruler playfield. The static example also reapplies volatile TIA geometry every
frame and carries a reviewed Stella 7.0 raster with exact bounding boxes.

Task 20q is complete. The normalized profile contains no `DCP` instruction; the
task 20r removed the remaining unofficial forms; task 20s removes redundant opt-in plumbing and adds a linked-byte gate.
