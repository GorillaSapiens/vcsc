```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# PAL and SECAM examples

The 50 Hz examples are split by video standard. Each standard has its own local
numbering and uses the matching compile-time RGB builtin directly so the source
can be written in RGB while the compiler selects the appropriate TIA color.

- [`pal/`](pal/): PAL50 examples using `__builtin_pal_rgb(r,g,b)`.
- [`secam/`](secam/): SECAM50 examples using `__builtin_secam_rgb(r,g,b)`.

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

Both PAL and SECAM directories maintain native 228-line examples for the
parameterized full-height renderer families: `all_five`, `player_color`,
`all_five_unofficial`, and `multisprite`. These examples use the full active
field directly; none wraps a 192-line renderer in visible padding.

Fixed-height composition profiles are not mislabeled as 228-line renderers. In
particular, `all_five_player_color_192` remains a separate hard-scheduled
192-line component until that renderer is genuinely parameterized. Retained
legacy/compatibility renderers remain NTSC-only by contract.
