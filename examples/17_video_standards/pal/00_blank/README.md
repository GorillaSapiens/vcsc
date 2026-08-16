```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# PAL50 blank frame

Minimal PAL 50 Hz cartridge using the public `frame_pal.c26` front end and
`__builtin_pal_rgb(r,g,b)` compile-time color matcher. It leaves all 228 visible lines black and is
the smallest public example of the standard frame contract. The background
RGB value is converted to the nearest PAL TIA color at compile time.

