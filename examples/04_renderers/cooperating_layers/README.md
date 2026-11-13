```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Cooperating all-five layers — experimental

Three independently buildable examples use the actual cooperating components,
not the older fixed-eight-section renderer:

| Example | Visible composition | ROM used | RAM, including stack |
| --- | --- | --- | --- |
| [No score](no_score/) | Three64-line sections |2041 bytes |46/128 bytes |
| [Score above](score_above/) |12 score +8 blanked positioning +172 gameplay |2617 bytes |56/128 bytes |
| [Score below](score_below/) |176 gameplay +12 score +4 blank tail |2601 bytes |56/128 bytes |

From the repository root:

```sh
make -C examples/04_renderers/cooperating_layers/no_score play
make -C examples/04_renderers/cooperating_layers/score_above play
make -C examples/04_renderers/cooperating_layers/score_below play
```

All five objects move together at about30 pixels/second, traversing both scenery
seams before reversing at the display ends. The bodies stay upright; only the
exhaust changes at7.5 fps. Scores increase at3.75 Hz. These examples are automatic
previews, not joystick-controlled games. Each leaf has `make`, `make play` and
`make clean`; none depends on another leaf or on test fixtures.

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
`0x20`), not RAM variables. The score leaves leave72 RAM bytes free; adding
variables or nested calls still needs
a fresh lifetime/stack analysis. Existing examples and renderer defaults are
unchanged. See [the layer contracts](../../../libraries/vcs/layers/README.md).
