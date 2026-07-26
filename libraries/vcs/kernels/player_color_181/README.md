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
template "kernels/player_color_181/player_color_181.c26" as game
```

Graphics and color arrays use the same highest-index-to-zero row order. The
component draws exactly 181 gameplay lines. A scored `main()` composes the
independent eleven-line six-glyph component above or below it to complete the
192-line visible field.

The profile supports P0, P1, and Ball. M0/M1 are deliberately absent, although
the inherited exact horizontal-position schedule retains two private zeroed
strobe slots. The component owns no score/font state and no VSYNC, VBLANK, or
RIOT timer state. Its `vblank()` callback uses bounded WSYNC stalls under the
scheduler-owned deadline.

Resource contract:

- public gameplay RAM: 13 bytes
- private RAM: 52 bytes
- total component RAM: 65 bytes
- application playfield ROM: 44 bytes
- application color ROM: 8 bytes per player


## Score composition

A scored application draws exactly one complete visible field in either order:

```c
score_draw();
configure_game_frame();
game_draw();
```

or:

```c
configure_game_frame();
game_draw();
score_draw();
```

The score-first order must restore gameplay-owned TIA geometry before
`game_draw()`, because the six-glyph component owns P0/P1 display state while it
runs. Maintained static and 320-frame asynchronous-motion fixtures prove both
orders, exact per-row colors, P0/P1/Ball full-range motion, stable 262-line
frames, and disjoint 11-line score plus 181-line gameplay regions.

A composed link measures 65 bytes of gameplay RAM plus 17 bytes for the
independent score. A gameplay-only link contains no score state or font.

## Adversarial handoff status

The installed `poison_debug_score` component is the hostile-state probe for
this profile. It deliberately overwrites TIA geometry, graphics, colors,
position, motion, and delay state while obeying its own scanline/frame-ownership
contract. The player-color family remains under the 22i4b stop-ship pixel and
handoff audit until its raster is proved identical after that predecessor.
Existing friendly-score fixtures remain historical regression coverage; they
are not by themselves proof of arbitrary-state independence.

