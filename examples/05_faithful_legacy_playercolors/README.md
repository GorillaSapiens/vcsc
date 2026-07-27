```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Faithful Legacy Playercolors

This example uses the retained faithful legacy player-color kernel. It draws P0, P1, Ball, and the integrated six-digit score below the
gameplay field using the retained Atari 2600 BASIC 1.9 monolithic kernel.

The source preserves the stock RAM aliases, unofficial instructions, frame
schedule, and timing-critical branch contracts. The kernel template is compared
with a retained-source audit using an identical fixture scene. This public
example intentionally uses different playfield data, so its own test checks
stable 264-line frames and exact P0/P1 graphics and row colors; it does not
pretend to be the pristine scene ROM.

Build with `make`, then run `faithful_legacy_playercolors.bin` in Stella.
