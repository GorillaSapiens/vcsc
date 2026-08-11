```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Official 181-line all-five renderer with player color tables

`all_five_player_color_181.c26` is the score-composable official-opcode sibling
of `all_five_player_color_192`. It retains P0, P1, M0, M1, and Ball while P0
and P1 use independent immutable eight-entry color tables:

```vcsc
instantiate "renderers/all_five_player_color_181/all_five_player_color_181.c26" as game
```

The component consumes **181 visible scanlines** and returns on the measured
component boundary, so one independent eleven-line score can be placed either
above or below gameplay:

```text
181 gameplay + 11 score = 192 visible lines
```

Each instance supplies page-contained immutable `game_playfield[44]`,
`game_player0_colors[8]`, and `game_player1_colors[8]` objects. P0/P1 retain
independent graphics pointers, X/Y/height state, and NUSIZ values. M0, M1, and
Ball retain independent X/Y/height state.

The 181-line schedule uses a 44-byte packed BL/M1/M0 mask plus a 16-byte row
cache. Fourteen cache bytes are the alternating seven-byte raster banks. The
last two bytes hold the packed P0/P1 visible-entry positioning controls; once
that handoff is complete, one is reused to save the caller's hardware stack
pointer while `S` temporarily carries the four-byte row base through the compact
visible loop. The raster performs no stack accesses while `S` is borrowed and
restores it before returning. The exact component contract remains **81
RIOT-RAM bytes**: 21 public bytes plus 60 private bytes.

P0/P1 are deliberately repositioned at visible entry rather than relying on
VBLANK positioning, because a score above gameplay owns and changes the player
registers. Non-player objects are positioned during VBLANK and their HMOVE
controls are cleared before the player-only visible handoff. A compact 15-byte
fine-motion table plus a VBLANK divide-by-15 helper replaces the 160-byte
expanded player-position table; the blanking-time cost is preferable to the ROM
cost in a 4K score-composed cartridge.

The terminal path explicitly transfers a zero through the delayed Ball latch
before the final blank line. Without that `GRP1` transfer, `VDELBL` can retain
the previous Ball enable for one extra line even after `ENABL` is cleared.

Public examples are under
`examples/16_all_five_player_color_181/`: one fixed six-digit score above and
one below. After collapsing the duplicated middle-pair raster bodies, both
cartridges link at **3739/4090 ROM bytes** and **107/128 RAM bytes**, leaving 351
ROM bytes and 21 RAM bytes free. They remain static raster diagnostics; the ROM
optimization makes a small interactive layer plausible, but a full control UI
still needs to be measured rather than assumed to fit.

Regression coverage pins both public examples to exact 262-line frames, checks
the 81-byte component RAM contract, and runs the existing all-five object raster
oracle on a score-above certification fixture. The maintained Stella target
compares complete score-above and score-below rasters against the established
`all_five (lines:=181)` profile with solid player colors; both match
pixel-for-pixel.
