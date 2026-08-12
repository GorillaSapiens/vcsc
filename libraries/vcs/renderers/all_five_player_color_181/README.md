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

The 181-line schedule uses a 44-byte packed BL/M1/M0 mask plus a 21-byte row
cache. Fourteen cache bytes are the alternating seven-byte raster banks. The
remaining seven hold P0/P1 fine-motion bytes, coarse counts, one-cycle RESP
phase flags, and the caller's hardware stack pointer while `S` temporarily
carries the four-byte row base through the compact visible loop. The raster
performs no stack accesses while `S` is borrowed and restores it before
returning. The exact component contract is **86 RIOT-RAM bytes**: 21 public
bytes plus 65 private bytes.

P0/P1 are deliberately repositioned at visible entry rather than relying on
VBLANK positioning, because a score above gameplay owns and changes the player
registers. VBLANK precomputes each player's coarse count, fine-motion byte, and
an early-RESP flag. Normal residues retain the historical RESP phase; residues
13, 14, and 0 strobe RESP one CPU cycle earlier, filling the three physical X
positions the older handoff skipped every 15 pixels. HMP is written after RESP
and the player-only HMOVE remains at its measured setup phase. The existing
16-byte non-player reposition table is reused, so no second player-motion table
is needed. Non-player objects remain positioned during VBLANK and their HMOVE
controls are cleared before the player-only visible handoff.

The terminal path explicitly transfers a zero through the delayed Ball latch
before the final blank line. Without that `GRP1` transfer, `VDELBL` can retain
the previous Ball enable for one extra line even after `ENABL` is cleared.

Public examples are under `examples/16_all_five_player_color_181/`. Each score
order has a static raster diagnostic and an interactive cartridge. The static
score-above and score-below examples link at **3754/4090 ROM bytes** and
**114/128 RAM bytes**. The interactive examples link at **4058/4090 ROM bytes**
and **123/128 RAM bytes**; Game Select cycles P0/P1/M0/M1/Ball and the left
joystick moves the selected object in both axes.

Regression coverage pins both score orders to exact 262-line frames, checks the
88-byte component RAM contract, sweeps P0/P1 through the supported X range
0..159, and runs the all-five object raster oracle using the renderer's
post-RESP player-motion transaction. The maintained Stella target keeps Ball at
X=20 to exercise the terminal delayed-latch flush and probes P0/P1 at X=13..16;
those four positions must remain physically distinct. The examples use the same full-width eleven-row playfield pattern as the
canonical `all_five_181` interactive example; source regression coverage keeps
all 32 visual playfield bits exercised. Complete score-above and
score-below rasters still match the established `all_five (lines:=181)` profile
pixel-for-pixel with solid player colors.
