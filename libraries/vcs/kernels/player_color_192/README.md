```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Player-color 192-line gameplay component

`player_color_192.c26` is the official-opcode, scoreless full-height P0/P1/Ball
profile with independent per-row P0 and P1 color tables. Instantiate it after
`vcs.c26` and drive its four lifecycle functions from `frame_ntsc.c26`.

The application supplies page-contained `INSTANCE_playfield[48]`,
`INSTANCE_player0_colors[8]`, and `INSTANCE_player1_colors[8]` objects plus
page-contained player graphics. The component owns exactly 192 visible lines;
it cannot be combined with the independent 11-line score inside a standard
192-line visible field.

RAM contract: 13 public bytes, 53 private bytes, 66 bytes total. Missiles are
not available. The component owns no score/font, VSYNC, VBLANK, or RIOT timer
state and uses only official NMOS 6502 opcodes.

## Adversarial handoff status

The installed `poison_debug_score` component is the hostile-state probe for
this profile. It deliberately overwrites TIA geometry, graphics, colors,
position, motion, and delay state while obeying its own scanline/frame-ownership
contract. The player-color family remains under the 22i4b stop-ship pixel and
handoff audit until its raster is proved identical after that predecessor.
Existing friendly-score fixtures remain historical regression coverage; they
are not by themselves proof of arbitrary-state independence.

