```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Official 181-line player-color component

`player_color_181.c26` is the score-composable official-opcode P0/P1/Ball
profile with page-contained per-row color tables for both players.

Instantiate it after `vcs.c26`:

```c
page const uint8_t game_playfield[44] := { /* eleven four-byte rows */ };
page const uint8_t game_player0_colors[8] := { /* storage index 0..7 */ };
page const uint8_t game_player1_colors[8] := { /* storage index 0..7 */ };
template "renderers/player_color_181/player_color_181.c26" as game
```

Graphics and color arrays use the same highest-index-to-zero row order. The
component draws exactly 181 gameplay lines. A scored application composes the
independent eleven-line six-glyph component above or below it to complete the
192-line visible field.

The public object slots are P0, P1, and Ball X plus retained P0/P1 NUSIZ values.
M0/M1 are deliberately absent. The component owns no score/font state and no
VSYNC, VBLANK, or RIOT timer state. Its `vblank()` callback positions Ball,
prepares the visible raster, and performs constant-time lookups for the two
player handoff records.

Resource contract:

- public gameplay RAM: 13 bytes
- private RAM: 51 bytes
- total component RAM: 64 bytes
- private positioning ROM: 176 bytes
- application playfield ROM: 44 bytes
- application color ROM: 8 bytes per player

## Visible-component handoff

`vcs_ntsc_end_vblank()` enters the first visible component at the canonical
cycle-3 phase. A completed visible component returns at cycle zero after its
final WSYNC. Place `vcs_ntsc_component_handoff()` between adjacent visible
components so the next one receives the same cycle-3 entry phase:

```c
vcs_ntsc_end_vblank();
score_draw();
vcs_ntsc_component_handoff();
game_draw();
```

or:

```c
vcs_ntsc_end_vblank();
game_draw();
vcs_ntsc_component_handoff();
score_draw();
```

The score component owns P0/P1 while it draws. The first two gameplay setup
lines therefore re-establish P1 and P0 coarse position and fine motion. The
third setup line applies HMOVE, restores both application NUSIZ values and normal reflection, clears stale
player graphics, and enters the timed raster. During gameplay, each P1
row is staged in private workspace and committed through GRP1 during horizontal
blanking. Because vertical delay is active, that same safe commit transfers the
pending P0 and Ball graphics before the visible right edge. Ball positioning
remains a VBLANK responsibility. After the positioning HMOVE has completed,
`HMBL` is cleared individually late in VBLANK, so the later P0/P1 entry HMOVE
does not apply the Ball fine motion a second time. This deliberately avoids an
immediate `HMCLR`, which interrupts the in-progress motion transaction on real
TIA hardware. Score-profile components preserve Ball, missile, and playfield
geometry.

The handoff uses a page-contained 160-entry packed position table. Each entry
contains the HMxx high nibble and the five-cycle coarse-loop count. This keeps
VBLANK time independent of X and keeps both positioning lines inside one
scanline for every coordinate from 0 through 159.

Maintained static and 320-frame asynchronous-motion fixtures prove every
centered, left-justified, right-justified, two-plus-two, and poison score order,
all P0/P1/Ball X coordinates, clipped horizontal pixel endpoints, exact
per-row color writes, terminal gameplay lines, stable 262-line frames, and
disjoint eleven-line score plus 181-line gameplay regions. The poison debug
score supplies hostile P0/P1 position, size, reflection, delay, graphics, and
motion state; the resulting gameplay raster and object positions remain
identical. The trace oracle rejects every gameplay GRP0 or GRP1 handoff, including zero
GRP1 transfers, that lands after horizontal blanking. A dedicated alternating
checkerboard fixture places both players at X=159, covering the subtle bit-row
swap that solid glyphs can hide at the extreme right edge and the earlier tear that
late graphics writes can cause.

A centered composed link measures 64 bytes of gameplay RAM plus 18 bytes for
the mutable-color production score. The wide mutable-color score has the same
18-byte component cost. Its public score-above and score-below examples use the
same Game Select object cycling, left-joystick selected-object motion, filtered
right-joystick digit editing, score-color changes, and reset behavior as the
centered examples. Each links at 118 of 128 total RAM bytes and 3,306 ROM bytes,
leaving ten bytes free. A poison composition adds one byte for its
caller-selected background handoff. A gameplay-only link contains no score
state or font.

## Reviewed Stella reference

The maintained score-above fixture has a reviewed Stella 7.0 capture:

Source-tree reference:

```text
test/fixtures/player_color_181/reference_score_above_stella_7.0.png
```

The image is hash-locked by the regression. It confirms the centered score,
playfield, both multicolor players, and Ball coexist without the red poison
background or obvious first-row corruption.

The twelve official public compositions live under `examples/04_player_color_181/`;
the separately named unofficial-opcode matrix lives under
`examples/07_player_color_181_unofficial/`.
