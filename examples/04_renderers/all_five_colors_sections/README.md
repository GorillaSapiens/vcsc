```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# All-five row colours and sections — experimental preview

[`no_score`](no_score/) is a runnable NTSC preview combining independent
eight-row player colours with continuous playfield/background sections.

**This is not the finished general renderer.** Its eight bands default to heights
of 16, 16, 16, 16, 32, 32, 32 and 32 scanlines, spread across the display.
Heights are configurable in 16-line increments.

Runnable combined-colour score previews are now available:

- [`score_above`](score_above/): independent eleven-line score before gameplay.
- [`score_below`](score_below/): independent eleven-line score after gameplay
  through the ordinary component handoff.

Both have left-joystick movement, Select cycling through all five objects,
Reset, four-frame upright artwork, independent player row colours, and
right-joystick BCD editing. They use **122/128 bytes of stock RAM**, ordinary F8
ROM, and one drawing bank, with no mirrored sprite tables.

The score previews support exactly **2,2,2,2,2,2,2,162** colourable-line heights
(176 lines plus the gameplay setup/tail). Other geometry is explicitly rejected.
All eight PF/background palettes are independently configurable in `.c26`.
Edit the instantiation parameters and visual playfield rows in
`examples/_common/all_five_colors_sections_score_interactive.c26`.
These are experimental examples, **not a general extracted renderer ABI**;
arbitrary mixed-row geometry remains unfinished. No generators are required.
