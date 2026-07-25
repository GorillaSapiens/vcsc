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
