```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Interactive all-five score-above diagnostic

This cartridge instantiates the unofficial-opcode renderer twin; its Makefile passes `-Wa,--illegals`.

SELECT cycles through P0, P1, M0, M1, and Ball. The left joystick moves the selected object one pixel or logical scanline per frame. The right joystick edits the six-digit score using the same filtered controls as the player-color diagnostics: samples are twenty frames apart and an action requires two consecutive identical samples. Horizontal digit changes advance the score color by `$10`. RESET restores the initial scene.
