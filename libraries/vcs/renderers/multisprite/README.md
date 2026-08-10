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
| 192 | 95 | full-height, scoreless | 86 bytes |
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
NUSIZ and colors, plus the retained M0/M1/Ball coordinates. Public X coordinates
are conventional Atari screen positions over the complete 0..159 range: X=0
starts at the left edge and X=159 reaches the rightmost position. `vblank()`
precomputes one packed HMP1/coarse-count byte for each logical P1 sprite. The
beam-critical reposition path decodes that byte with a bounded countdown instead
of the old variable subtract-by-15 loop, so the right edge cannot run past the
scanline. The score/P0 handoff used to enter the first/topmost 181 reposition three CPU
cycles earlier than the ordinary post-WSYNC phase. The renderer now spends those
three cycles once at raster entry, so every 181 P1 rank consumes the same packed
horizontal controls. This avoids the old wrapped X+9 lookup, whose alias into the
ordinary right-edge bucket made top-ranked X=143..151 jump or wrap. Public P1
coordinates are never biased or restored, so vertical sort/flicker transitions
cannot leak an internal coordinate mutation into application state.

Both profiles preserve the faithful renderer's **frame-persistent
flicker-sort order**. When two or more logical P1 sprites occupy overlapping
vertical bands, the sorter omits the conflicting sprite for the current frame
and rotates it behind the other sprite(s) for the next frame. The conflicting
sprites therefore flicker/round-robin instead of lower-numbered sprites losing
permanently. The packed horizontal-control workspace cannot itself retain that
order because it is overwritten before `draw()`, so both profiles own a separate
five-byte sort-order array; that is the reason module RAM is 86 rather than
81 bytes. Six-frame regressions require the overlap winner to alternate in 192
and in both 181 score compositions.

The maintained legal Y ranges are exposed as `PLAYER0_MAX_Y` and
`PLAYER1_MAX_Y`: 95/92 for `lines:=192`, and 89/86 for `lines:=181`. Y increases
upward. The P1 maxima are the highest public coordinates that still reach the
first gameplay line in the calibrated raster. Y=0 is the completely clipped
bottom position; `vblank()` guards the faithful P0 predecrement so that zero
cannot underflow to 255 and turn stale P0 pixels into a full-height stripe. The
five multiplexed sprites may move vertically independently within the P1 range;
their initial spacing is not a fixed timing schedule.

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
`vblank()` precomputes packed P1 positioning controls and the 181 P0 handoff
coordinate. Public sprite coordinates remain application state throughout the
component lifecycle.

## Maintained examples

- `examples/14_multisprite/01_192/01_interactive/` — full-height interactive
  P0 + five-P1 demonstration.
- `examples/14_multisprite/02_181_score_above/01_interactive/` — 11-line score
  above 181-line gameplay.
- `examples/14_multisprite/03_181_score_below/01_interactive/` — the same score
  below gameplay.

Select cycles P0 and the five logical P1 sprites; the left joystick moves the
selected sprite horizontally and vertically within the profile's legal range;
Reset restores the scene. Joystick Up increments Y and Down decrements Y, matching
the renderer's upward-positive public coordinate system. The MOS6502/TIA timing
regression exhaustively checks 1,521 independent X/Y positions for the 192 profile
and 1,485 for each 181 score composition, with every case frame-stable. Physical
placement is certified separately by the optional Stella pixel regression
(`make stella-multisprite-test`): it locks all five P1 rank phases at left/middle/
right-edge coordinates, natural X=159 clipping/wrap, the P1 top edge, the 181
first-rank X=143..151 right-edge discontinuity (with X=148 locked explicitly),
181 P0 sort-invariant X placement, and the P0 Y=0 no-stripe case. The exact `123456`
score raster remains locked above and below gameplay. The simulator regression forces P1/P2 into the same vertical band for six
consecutive frames in every profile and requires the visible winner to alternate
every frame, locking the persistent flicker-sort behavior that the original port
accidentally lost.
