```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Static player-color component, score above

This example composes the official `player_color_181` P0/P1/Ball component with
the independent score above gameplay. Both players use eight distinct logical-
row colors; missiles are intentionally unavailable. The visible field is
exactly eleven score lines plus 181 gameplay lines.

Build with `make` and run `playercolor_static_test.bin` in Stella.

The playfield uses `VCS_PLAYFIELD_ROW()` so each 32-bit visual-binary literal
reads left-to-right on screen; all bit reversal and byte extraction is folded at
compile time.
