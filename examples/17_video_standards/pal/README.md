```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# PAL50 examples

- `00_blank`: minimal 312-line PAL50 frame.
- `01_all_five`: interactive stock 192-line all-five renderer centered in the
  PAL 228-line visible window.

The examples use `__builtin_pal_rgb(r,g,b)` directly. The builtin is evaluated at
compile time against the PAL reference palette and emits the nearest TIA color.
