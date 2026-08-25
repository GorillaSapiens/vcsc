```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# SECAM50 all-five interactive example

This is the maintained native 228-line `all_five` profile running directly
across the SECAM50 visible field. It instantiates `all_five (lines:=228)`, uses
a 60-byte/15-packed-row playfield, and exposes all 114 two-scanline object Y
positions (`0..113`). There is no 192-line centered component and no synthetic
17/19-line visible padding.

After `game_draw()` completes its 228th visible scanline, the SECAM frame
helper's `vcs_secam_component_to_overscan_handoff()` normalizes the cycle phase
expected by the calibrated overscan timer without consuming another visible
scanline. The complete frame remains `3 + 45 + 228 + 36 = 312` displayed
scanlines.

The source specifies its colors directly with `__builtin_secam_rgb(r,g,b)`;
the compiler maps the same NTSC all-five RGB intents to the nearest of the eight
distinct SECAM display colors.

Stella cannot reliably infer SECAM from 50 Hz timing. `make play` therefore
launches the ROM with `-format SECAM`; use that option for direct launches too.
`-tv` controls the emulated Color/B&W console switch and is not a video-format
option.

Controls are the same as the NTSC example: Game Select cycles P0/P1/M0/M1/Ball,
the left joystick moves the selected object, and console Reset restarts.
