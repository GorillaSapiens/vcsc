```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Wide score above gameplay

The interactive cartridge uses the same Game Select, left-joystick object
motion, right-joystick score editing, reset behavior, playfield, player glyphs,
and per-row colors as the other official `player_color_181` examples. Only the
score geometry changes: six 8-pixel glyphs at X=36,52,68,84,100,116.

| No. | Example | Draw order | Purpose |
|---:|---|---|---|
| 01 | [`interactive`](01_interactive/) | score, handoff, gameplay | Standard P0/P1/Ball selection and score controls with the exact 88-pixel score raster |
