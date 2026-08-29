```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Parameterized multisprite examples

These examples exercise the modern composable derivative of the faithful legacy
multisprite raster. The renderer uses the required `lines` instantiation
parameter and retains one stable/common NMOS `LAX`, so these cartridges build
with `-Wa,--illegals`.

- `01_192` demonstrates the full 192-line profile interactively.
- `02_181_score_above` composes an independent 11-line score above the 181-line
  gameplay profile.
- `03_181_score_below` composes the same score below gameplay.

Select cycles P0 and the five logical P1 sprites. The left joystick moves the
selected sprite horizontally across X=0..159 and vertically through the
profile-specific legal Y range. Up moves upward and Down moves downward; Y=0 is
the fully clipped bottom position. In both 181-line score compositions, the
right joystick edits the six-digit score: Left/Right select a decimal digit and
Up/Down decrement/increment it, with full-neutral re-arm between actions. The
automated MOS6502/TIA regression sweeps
every legal independent X/Y position and requires a stable 262-line NTSC frame.
For every profile it also forces two logical P1 sprites into the same vertical
band for consecutive frames and verifies the faithful flicker arbitration: the
conflicting sprites alternate instead of permanently hiding the lower-numbered
sprite.
An optional Stella 7.0 pixel regression (`make stella-multisprite-test`) checks
actual rendered horizontal placement across all five multiplex ranks, both edges,
the P1 top edge, and the 181 P0 sort-order/no-stripe regressions. The two 181-line
compositions also lock the exact bottom/top score as `123456`.
