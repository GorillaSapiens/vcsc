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

The score previews accept nonnegative **even** heights totaling **176**, with
section one nonempty and section eight at least **158** lines. Supported
boundaries are **2,4,6,8,10,12,14,16 and 18**; later positions are explicitly
rejected. Defaults are now `2,2,2,2,2,6,2,158`, including adjacent seams16/18.
The earlier `2,2,2,2,2,2,2,162` and `4,0,2,0,4,0,0,166` layouts still work and
compile out the additional row1 drawing path. Middle slots may be empty.
Gameplay setup/tail completes the 181-line component.
All eight PF/background palettes are independently configurable in `.c26`.
Edit the instantiation parameters and visual playfield rows in
`examples/_common/all_five_colors_sections_score_interactive.c26`.
These are experimental examples, **not a general extracted renderer ABI**;
arbitrary mixed-row geometry remains unfinished. No generators are required.
