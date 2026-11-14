```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Cooperating all-five layers — experimental

Three independently buildable layouts use the actual cooperating components,
not the older fixed-eight-section renderer. Each has an automatic preview
(`main.c26`) and a joystick-controlled variant (`interactive.c26`):

| Example | Visible composition | ROM used | RAM, including stack |
| --- | --- | --- | --- |
| [No score](no_score/) | Three64-line sections |2041 bytes |46/128 bytes |
| [Score above](score_above/) |12 score +8 blanked positioning +172 gameplay |2617 bytes |56/128 bytes |
| [Score below](score_below/) |176 gameplay +12 score +4 blank tail |2601 bytes |56/128 bytes |

The table describes the automatic previews. Interactive variants use 2298/3053/
3037 ROM bytes and 46/58/58 RAM bytes respectively, including the ordinary stack.
All six programs fit a single 4K bank without cartridge RAM.

From the repository root:

```sh
make -C examples/04_renderers/cooperating_layers/no_score play
make -C examples/04_renderers/cooperating_layers/score_above play
make -C examples/04_renderers/cooperating_layers/score_below play
```

For the interactive versions:

```sh
make -C examples/04_renderers/cooperating_layers/no_score play-interactive
make -C examples/04_renderers/cooperating_layers/score_above play-interactive
make -C examples/04_renderers/cooperating_layers/score_below play-interactive
```

`make interactive` builds without launching Stella; `make clean` removes both
variants. The existing `make` and `make play` still select the automatic preview.

## Interactive controls

- **Console SELECT:** cycle P0 → P1 → M0 → M1 → Ball → P0. Holding it does not
  repeat; release it before selecting the next object.
- **Left joystick:** move only the selected object. Opposing directions prefer
  left/up. X saturates at 0..159, except score-above uses 0..119 because its
  blanked in-frame positioning entry has that stricter contract.
- Y uses two-scanline units: 0..95 without a score, 0..85 above, 0..87 below.
  Objects clip naturally at the bottom, as in the other interactive renderers.
  Move them through the scenery seams to inspect continuity.
- **Right joystick left/right** (score layouts): select a digit in display order:
  left tens → left ones → right tens → right ones, wrapping at either end.
  Selection starts at left tens. **Right up/down:** add/subtract that digit's
  decimal weight (10 or 1), with normal BCD carry/borrow and 99 ↔ 00 wraparound.
  Each press acts once; return the stick to neutral to re-arm. Diagonals select
  before editing; opposing directions prefer left/up. Fire is unused. Score
  origins and colours remain compile-time renderer parameters.
- **Console RESET:** restart the example and restore all positions/selections.

The interactive variants use the same four-frame player artwork as the ordinary
`all_five` interactive example, not the preview's rockets. Animation depends on
each player's own X/Y, so idle objects remain still and moving one does not
animate the other. Inputs and app updates run only in overscan, after
`layers_finish()` restores the ordinary stack. Renderer state, section timing
and the three score compositions are unchanged.

## Automatic previews

All five objects move together at about30 pixels/second, traversing both scenery
seams before reversing at the display ends. The bodies stay upright; only the
exhaust changes at7.5 fps. Scores increase at3.75 Hz. The `main.c26` examples are
automatic previews, not joystick-controlled games. Neither variant depends on
another leaf or on test fixtures.

Edit the three `instantiate "layers/all_five_section.c26"` declarations directly
in each `main.c26`. Each instance has `number_of_scanlines`, `playfield_row`,
`pf_color`, and `bk_color`. Heights must be positive/even; one asymmetric row
repeats through each section. No JSON or configuration generator is involved.
The intro positions all five once; sections advance the same live object state
without horizontal repositioning or separator scanlines between them.

The two-byte motion helper is app code in `examples/_common/`, not part of the
drawing library. A folded travel phase encodes direction without another RAM
byte. Score pointers share the unused mask tail, never live gameplay bytes.
Runtime player graphics pointers, heights and independent eight-row
palettes remain available. There is one4K drawing bank and no cartridge RAM.

## Limits

These remain experimental layouts. The former right-edge player corruption is
repaired: independent runtime-X sweeps pass every X0..159 for both players in
all eight modes. Score-above's distinct fixed positioning entry still requires
all X0..119. Score
positions/colours are compile-time parameters; its two BCD values are runtime.
NUSIZ values are intro parameters (`player0_nusiz` and `player1_nusiz`, default
`0x20`), not RAM variables. Automatic score previews leave72 RAM bytes free;
interactive score variants leave70. Adding
variables or nested calls still needs
a fresh lifetime/stack analysis. Existing examples and renderer defaults are
unchanged. See [the layer contracts](../../../libraries/vcs/layers/README.md).
