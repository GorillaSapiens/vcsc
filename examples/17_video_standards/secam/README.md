```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# SECAM50 examples

- `00_blank`: minimal 312-line SECAM50 frame.
- `01_all_five`: interactive stock 192-line all-five renderer centered in the
  SECAM 228-line visible window.

The examples use `__builtin_secam_rgb(r,g,b)` directly. The builtin is evaluated
at compile time and maps the requested RGB color to one of the eight distinct
SECAM display colors.
