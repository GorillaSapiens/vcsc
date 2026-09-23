```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Video-standard comparison examples

Examples are grouped by demonstration first, with video-standard peers inside each demonstration. This keeps the two 50 Hz implementations adjacent
for direct source, timing, and color comparison. PAL sources use
`__builtin_pal_rgb(r,g,b)` and SECAM sources use
`__builtin_secam_rgb(r,g,b)`.

The maintained demonstrations are `blank`, `player_color`, `all_five`,
`multisprite`, and `enhanced_multisprite_asymmetric`. Every demonstration has
adjacent `ntsc/`, `pal/`, and `secam/` cells, forming the complete 15-cell
standards matrix.

Both standards share the measured 312-line 50 Hz frame machinery, but their
color contracts remain deliberately separate. PAL RGB matching selects from the
PAL TIA palette; SECAM RGB matching selects from its eight distinct display
colors.

Stella cannot reliably distinguish SECAM50 from PAL50 from frame timing alone.
Use each example's `make play` target, which explicitly selects `-format PAL`
or `-format SECAM`. For a direct SECAM launch use `stella -format SECAM ROM.bin`.
Stella's `-tv` option is the emulated console Color/B&W switch; it does not
select PAL or SECAM.

## Native 228-line renderer matrix

Both PAL and SECAM cells maintain native 228-line examples for the
parameterized full-height renderer families: `all_five`, `player_color`,
and `multisprite`. These examples use the full active
field directly; none wraps a 192-line renderer in visible padding.

Fixed-height composition profiles are not mislabeled as 228-line renderers. The combined `all_five` `missiles:=1, player_colors:=1` specialization remains a
hard-scheduled 192-line component until that schedule is genuinely generalized.
