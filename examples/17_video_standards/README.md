```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# PAL and SECAM examples

The 50 Hz examples are split by video standard. Each standard has its own local
numbering and uses the matching compile-time RGB builtin directly so the source
can be written in RGB while the compiler selects the appropriate TIA color.

- [`pal/`](pal/): PAL50 examples using `__builtin_pal_rgb(r,g,b)`.
- [`secam/`](secam/): SECAM50 examples using `__builtin_secam_rgb(r,g,b)`.

Both standards share the measured 312-line 50 Hz frame machinery, but their
color contracts remain deliberately separate. PAL RGB matching selects from the
PAL TIA palette; SECAM RGB matching selects from its eight distinct display
colors.
