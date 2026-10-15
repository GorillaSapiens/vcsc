```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# All-five colour-section examples

This directory groups three independent runnable examples. Build and run from
the desired leaf directory with `make` and `make play`:

- [`no_score/`](no_score/): 192-line gameplay, 4K ROM.
- [`score_above/`](score_above/): 181-line gameplay with an 11-line score above,
  8K F8 ROM.
- [`score_below/`](score_below/): the same score composition below gameplay,
  8K F8 ROM.

Each leaf contains its own source, Makefile and instructions. No runnable example
contains another runnable example.

All three use the standard all-five interactive P0/P1 sprites: four eight-row
frames, selected from each player's X/Y position as in
`examples/_common/all_five_181_interactive_common.c26`.
