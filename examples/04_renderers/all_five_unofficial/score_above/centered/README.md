```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Interactive all-five score-above diagnostic

This cartridge instantiates the unofficial-opcode renderer twin; its Makefile passes `-Wa,--illegals`.

SELECT cycles through P0, P1, M0, M1, and Ball. The left joystick moves the selected object one pixel or logical scanline per frame. The right joystick edits the six-digit score immediately once per direction press; holding it does not repeat, and it must return fully to neutral before another direction press can act. Horizontal digit changes advance the score color by `$10`. RESET restores the initial scene.
