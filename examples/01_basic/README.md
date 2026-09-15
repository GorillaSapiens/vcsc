```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Basic cartridges and components

These examples do not share one gameplay renderer. They introduce the toolchain
and the lifecycle-component model in small, independently understandable steps.

| No. | Example | Display architecture |
|---:|---|---|
| 01 | [`blank_screen`](../01_basics/blank_screen/) | Inline 262-line NTSC frame with a constant background |
| 02 | [`blank_noasm`](../01_basics/blank_noasm/) | The same basic 262-line frame expressed entirely in VCSC source |
| 03 | [`ode_to_joy`](../01_basics/ode_to_joy/) | No-assembly timer-owned frame scheduler plus TIA audio in overscan |
| 04 | [`score`](../02_components/six_digit_score/) | `frame_ntsc.c26` composed with the 11-line `six_glyph_component.c26` |
| 05 | [`fingerprint`](05_fingerprint/) | Big-wide 8x16 hexadecimal fingerprint with fixed `012345` VCSC logos at upper right and lower left |
| 06 | [`wide_score`](../02_components/wide_score/) | `frame_ntsc.c26` composed with the 88-pixel-wide `six_glyph_wide_component.c26` |
| 07 | [`big_wide_score`](../02_components/big_wide_score/) | 19-line wide score using the 8x16 Big decimal font and `six_glyph_big_wide_component.c26` |
| 08 | [`dual_score`](../02_components/three_plus_three_score/) | Fixed independent three-digit left/right score fields using `three_plus_three_score_component.c26` |
| 09 | [`paddleball`](../06_games/paddleball/) | Two-paddle Paddleball game combining `two_paddles.c26`, a 3+3 score, missiles, Ball, walls, and a dashed center line |
| 10 | [`four_player_paddleball`](../06_games/four_player_paddleball/) | Four-player team Paddleball using all four paddles across both ports, P0/M0 versus P1/M1, hardware Ball collisions, and team scoring |
| 11 | [`keypad`](../03_controllers/keypad/) | Two 12-key keypad controllers scanned in parallel; P0/P1 show a centered Big-font key glyph for the left/right ports |
| 12 | [`drive`](../03_controllers/driving/) | Two Indy 500 driving controllers; clockwise/counterclockwise motion wraps independent hexadecimal P0/P1 counters and each fire button turns its glyph red while held |
| 13 | [`tanks`](../06_games/tanks/) | Two-player joystick tank duel with a 3+3 blue/red score, slowed sixteen-way driving, fire/hit audio, hit spins, tall pseudo-random vertical barriers, and hardware collision latches |

The score, wide-score, big-wide-score, dual-score, and fingerprint examples demonstrate component composition rather than
a full gameplay renderer. They own the surrounding blank visible lines and call
each six-glyph component at its calibrated entry phase. The fingerprint example
combines centered, left-justified, and right-justified eleven-line variants and
reuses score digits as six slices of a wider logo.
