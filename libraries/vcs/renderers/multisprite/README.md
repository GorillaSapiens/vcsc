```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Parameterized multisprite renderer

`multisprite.c26` is the modern composable derivative of the retained
`faithful_legacy_multisprite` raster. It draws one independent P0 plus five
logical sprites multiplexed through P1 and a six-row asymmetric playfield. The
required `lines` instantiation parameter selects one of the two maintained,
cycle-proven visible profiles:

```vcsc
instantiate "renderers/multisprite/multisprite.c26" as game (lines:=192)
instantiate "renderers/multisprite/multisprite.c26" as game (lines:=181)
```

`lines` is compile-time only. Unsupported values are rejected at compile time.
The renderer retains the stable/common NMOS `LAX` used by the faithful beam
path, so cartridges using it must be assembled with `-Wa,--illegals`.

## Profiles

| `lines` | Logical core height | Typical composition | Module RAM |
| ---: | ---: | --- | ---: |
| 192 | 95 | full-height, scoreless | 81 bytes |
| 181 | 89 | one independent 11-line score above or below | 81 bytes |

The legacy logical Y counter is not a physical scanline count. After restoring
the faithful two-scanline cadence, the measured 192 profile enters the retained
core at logical Y=95 and closes the field with its terminal line. The 181
profile enters at logical Y=89. When it follows or precedes a score component,
its draw path spends two owned lines in the faithful divide-by-15 P0
repositioner before entering the hot multiplexing loop, so P0 remains legal over
the complete X=0..159 range. Adjacent visible components use
`vcs_ntsc_component_handoff()`.

Both profiles preserve the faithful five-P1 multiplexing algorithm, six
playfield rows, P0 trailing clear, TXS/PHP enable pipeline, and beam-critical
reposition schedule. Graphics-pointer adjustment is fully 16-bit for both P0
and P1, so pointer arithmetic itself is correct across page boundaries. The
actual `(ptr),Y` glyph loads are still cycle-sensitive to a 6502 page crossing,
so the public graphics layout below deliberately prevents those crossings.

## Interface

Applications provide one page-aligned graphics block plus the playfield rows:

```vcsc
align(256) const uint8_t game_graphics[145] := {
   // bytes 0..95 are reserved padding
   // bytes 96..104: P0, including its leading clear sentinel
   // bytes 105..112: logical P1
   // bytes 113..120: logical P2
   // bytes 121..128: logical P3
   // bytes 129..136: logical P4
   // bytes 137..144: logical P5
};
const uint8_t game_pf1[6] := { ... };
const uint8_t game_pf2[6] := { ... };
```

For an instance named `game`, the required offsets are available as
`game_PLAYER0_GRAPHICS_OFFSET` through `game_PLAYER5_GRAPHICS_OFFSET`.
`game_PLAYER0_GLYPH(...)` and `game_SPRITE_GLYPH(...)` store human top-to-bottom
rows in the bottom-to-top order consumed by the retained raster.

The **alignment and offsets are part of the timing contract**, not cosmetic
padding. The retained raster performs cycle-critical `(ptr),Y` graphics loads.
Starting the 145-byte block on a 256-byte boundary and putting glyph data at
offsets 96..144 guarantees that every legal maintained P0/P1 glyph fetch stays
within the same ROM page. This matters at the top of the legal Y range as well
as in the default scene: a page-crossing `(ptr),Y` load costs an extra 6502
cycle and would otherwise make frame length depend on sprite Y.

Public aliases expose X/Y/height for P0 and the five logical P1 sprites, P0/P1
NUSIZ and colors, plus the retained M0/M1/Ball coordinates. X is legal over the
complete 0..159 range. The maintained legal Y ranges are exposed as
`PLAYER0_MAX_Y` and `PLAYER1_MAX_Y`: 95/91 for `lines:=192`, and 89/85 for
`lines:=181`. The five multiplexed sprites may move vertically independently
within that P1 range; their initial spacing is not a fixed timing schedule.

The maintained minimal profiles deliberately keep M0, M1, and Ball outside the
active gameplay field. Making those three objects active changes the retained
multiplexing timing and is not part of this component contract.

Beam timing is deliberately structural. The faithful three-cycle mask reads,
short K1 branches, branch-page constraints, and the local cycle-balanced
reposition decision must not be simplified as ordinary code. Every conditional
branch executed by `draw()` has a hard page-timing annotation. The maintained
raster requires the three-cycle taken-branch case for all of them, so they are
`.same`; no draw-path branch requires the four-cycle `.cross` case. The VBLANK
divide-by-15 positioning loop is likewise `.same` because one extra taken cycle
would change horizontal placement. Non-beam-critical setup/sort/overscan branches
remain unannotated and therefore use the normal `.flex` default. The regression
sweeps every legal independent X/Y position and rejects any frame-length drift.

The scheduler owns VSYNC, VBLANK, RIOT timers, and visible-component order.
`init()`, `vblank()`, `draw()`, and `overscan()` are the component lifecycle.

## Maintained examples

- `examples/14_multisprite/01_192/01_interactive/` — full-height interactive
  P0 + five-P1 demonstration.
- `examples/14_multisprite/02_181_score_above/01_interactive/` — 11-line score
  above 181-line gameplay.
- `examples/14_multisprite/03_181_score_below/01_interactive/` — the same score
  below gameplay.

Select cycles P0 and the five logical P1 sprites; the left joystick moves the
selected sprite horizontally and vertically within the profile's legal range;
Reset restores the scene. The regression exhaustively checks 1,516 independent
X/Y positions for the 192 profile and 1,480 for each 181 score composition, in
addition to locking the exact `123456` score raster above and below gameplay.
