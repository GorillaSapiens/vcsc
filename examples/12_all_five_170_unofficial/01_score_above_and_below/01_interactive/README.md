```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# all_five unofficial 170-line score-above-and-below interactive example

This interactive cartridge instantiates the single unofficial `all_five_unofficial` renderer
with `lines:=170`, then composes one eleven-line six-digit score above it and a
second eleven-line score below it. The resulting visible field is exactly 192
scanlines.

Game Select cycles P0, P1, M0, M1, and Ball. The left joystick moves the selected
object. The right joystick uses the same immediate one-action-per-press digit
selection and packed-BCD editing convention as the other all-five score
examples; it must return fully to neutral before another press can act. The top
score is editable while the lower score remains a contrasting static reference. Reset restores the initial scene.

Build with `make`; the Makefile passes `-Wa,--illegals` explicitly.
