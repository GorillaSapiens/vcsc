```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# `all_five_player_color_181` score examples

This group demonstrates the score-composable 181-line combined renderer: all
five ordinary TIA objects remain available while P0 and P1 use independent
eight-row color tables. Either an eleven-line centered six-digit score or the
eleven-line independent three-plus-three score fills the rest of the standard
192-line visible field.

| No. | Example | Purpose |
|---:|---|---|
| 01 | [`score_above`](01_score_above/) | Static and interactive six-digit score above 181-line combined gameplay |
| 02 | [`score_below`](02_score_below/) | Static and interactive six-digit score below 181-line combined gameplay |
| 03 | [`three_plus_three_score_above`](03_three_plus_three_score_above/) | Static independent three-digit left/right scores above gameplay |
| 04 | [`three_plus_three_score_below`](04_three_plus_three_score_below/) | Static independent three-digit left/right scores below gameplay |

The centered six-digit score orders each include a static raster diagnostic and
an unbanked 4K interactive cartridge. Game Select cycles P0/P1/M0/M1/Ball in
the interactive cartridges, and the left joystick moves the selected object in
both axes while the score remains fixed. Both interactive orders link at
4058/4090 ROM and 123/128 RAM.

The three-plus-three examples are static because the combined renderer plus dual
score consumes all 128 bytes of RIOT RAM. All six cartridges use the same
full-width eleven-row playfield pattern as
`examples/common/all_five_181_interactive_common.c26`; the regression suite
compares those source rows directly so sparse test data cannot mask reflected
playfield timing bugs. The player positioning handoff is physically continuous
across the old 15-pixel boundary plateau, and the terminal Ball latch is
explicitly flushed before the blank tail.
