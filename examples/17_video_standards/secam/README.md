```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# SECAM50 examples

- `00_blank`: minimal 312-line SECAM50 frame.
- `01_all_five`: native `all_five (lines:=228)`.
- `02_player_color`: native `player_color (lines:=228)`.
- `03_all_five_unofficial`: native `all_five_unofficial (lines:=228)`.
- `04_multisprite`: native `multisprite (lines:=228)`.

All renderer examples use the complete SECAM 228-line visible window; none
centers a 192-line raster with synthetic visible padding.

The examples use `__builtin_secam_rgb(r,g,b)` directly. The builtin is evaluated
at compile time and maps the requested RGB color to one of the eight distinct
SECAM display colors.
