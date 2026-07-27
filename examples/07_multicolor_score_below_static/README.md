```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Multicolor Score Below Static

This is the verified oracle-backed legacy player-color cartridge moved from
example 05. It draws P0, P1, Ball, and the integrated six-digit score below the
gameplay field using the retained Atari 2600 BASIC 1.9 monolithic kernel.

The source preserves the stock RAM aliases, unofficial instructions, frame
schedule, and timing-critical branch contracts. Its built ROM is compared
directly with the independently built pristine BASIC 1.9 oracle: all 1,230
visible TIA events, exact P0/P1 graphics and row colors, and stable 264-line
frames.

Build with `make`, then run `multicolor_score_below_static.bin` in Stella.
