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

**This is not the finished general renderer.** The no-score preview's eight bands
default to heights of 6, 12, 28, 34, 34, 36, 40 and 2 scanlines. Heights are
configurable in two-line increments across the entire 192-line display, including
playfield-row boundaries. Its default build still repeats two playfield patterns.
The same leaf's opt-in `make repeated` build instead demonstrates twelve distinct
PF rows with a native repeated two-scanline renderer and fixed two-byte dispatch.
That build is also unfinished: edge/NUSIZ timing and score integration remain open.
See its [limitations](no_score/README.md#opt-in-repeated-pair-build-unfinished).

Runnable combined-colour score previews are now available:

- [`score_above`](score_above/): independent eleven-line score before gameplay.
- [`score_below`](score_below/): independent eleven-line score after gameplay
  through the ordinary component handoff.

Both have left-joystick movement, Select cycling through all five objects,
Reset, four-frame upright artwork, independent player row colours, and
right-joystick BCD editing. They use **128/128 bytes of stock RAM**, ordinary F8
ROM, and one drawing bank, with no mirrored sprite tables.

The score previews accept positive **even** heights totaling **176**, with
every section at least **2** lines and section eight at least **150**. Supported
boundaries are **2,4,6,8,10,12,14,16,18,20,22,24 and 26**; later positions are explicitly
rejected. Defaults are now `4,12,2,2,2,2,2,150`, including adjacent seams16..26.
The earlier `2,2,2,2,2,2,2,162` layout still works and compiles out the additional
row1 drawing path. Zero-height sections are rejected in both score and no-score previews.
Gameplay setup/tail completes the 181-line component.
The application loop lives in bank1 and calls a bank0 composition function;
both renderers still return independently. The RAM budget includes sixteen
hardware-stack bytes and has no spare space for additional application state.
All eight PF/background palettes are independently configurable in `.c26`.
Edit the instantiation parameters and visual playfield rows in
`examples/_common/all_five_colors_sections_score_interactive.c26`.
These are experimental examples, **not a general extracted renderer ABI**;
arbitrary mixed-row geometry remains unfinished. No generators are required.
