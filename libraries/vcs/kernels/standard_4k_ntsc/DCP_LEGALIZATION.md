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
operands and cycles and checks all five final precomputed values. The complete
static-kernel execution test separately verifies object output, PF phases,
persistent-state restoration, and a stable 262-line frame.

Task 20q is complete. The normalized profile contains no `DCP` instruction; the
remaining unofficial forms belong to tasks 20r and 20s.
