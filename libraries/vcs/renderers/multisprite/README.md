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
| 192 | 92 | full-height, scoreless | 81 bytes |
| 181 | 87 | one independent 11-line score above or below | 81 bytes |

The legacy logical Y counter is not a physical scanline count. The measured
192 profile runs the retained core from logical Y=92, which consumes 191
physical lines, then closes the field with one terminal line. The 181 profile
runs from logical Y=87 and uses one visible entry/handoff line to restore P0
after an adjacent score component has owned the players. Adjacent visible
components use `vcs_ntsc_component_handoff()`.

Both profiles preserve the faithful five-P1 multiplexing algorithm, six
playfield rows, P0 trailing clear, TXS/PHP enable pipeline, and beam-critical
reposition schedule. Graphics-pointer adjustment is fully 16-bit for both P0
and P1, so pointer arithmetic itself is correct across page boundaries. The
actual `(ptr),Y` glyph loads are still cycle-sensitive to a 6502 page crossing,
so the public graphics layout below deliberately prevents those crossings.

## Interface

Applications provide one page-aligned graphics block plus the playfield rows:

```vcsc
align(256) const uint8_t game_graphics[129] := {
   // bytes 0..79 are reserved padding
   // bytes 80..88: P0, including its leading clear sentinel
   // bytes 89..96: logical P1
   // bytes 97..104: logical P2
   // bytes 105..112: logical P3
   // bytes 113..120: logical P4
   // bytes 121..128: logical P5
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
Starting the 129-byte block on a 256-byte boundary and putting glyph data at
offsets 80..128 guarantees that every maintained sprite fetch stays within the
same ROM page. This makes the visible reposition schedule independent of where
the linker places surrounding ROM objects.

Public aliases expose X/Y/height for P0 and the five logical P1 sprites, P0/P1
NUSIZ and colors, plus the retained M0/M1/Ball coordinates.

The maintained minimal profiles deliberately keep M0, M1, and Ball outside the
active gameplay field. Making those three objects active changes the retained
multiplexing timing and is not part of this component contract. Likewise, the
five logical P1 Y positions are a **timing schedule**, not unrestricted game
state: changing their vertical spacing can change the physical scanline count.
The public interactive examples therefore keep the cycle-proven Y schedules
fixed and move P0/P1 sprites horizontally.

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
selected sprite horizontally; Reset restores the scene.
