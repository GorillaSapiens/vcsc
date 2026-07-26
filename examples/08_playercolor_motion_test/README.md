```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Moving player-color component, score below

This example draws the official `player_color_181` gameplay component above the
independent score. P0, P1, and Ball retain per-row player colors while moving
asynchronously across X=`0..159`. Missiles are intentionally unavailable.

Build with `make` and run `playercolor_motion_test.bin` in Stella.

The playfield uses `VCS_PLAYFIELD_ROW()` so each 32-bit visual-binary literal
reads left-to-right on screen; all bit reversal and byte extraction is folded at
compile time.
