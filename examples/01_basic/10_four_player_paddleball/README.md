```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Four-player Paddleball

This example extends the two-player Paddleball cartridge to all four Atari
CX30-style paddles across both controller ports.

* **Left port / blue team:** paddle 0 controls **P0** (outer blue paddle), and
  paddle 1 controls **M0** (inner blue paddle).
* **Right port / red team:** paddle 2 controls **P1** (outer red paddle), and
  paddle 3 controls **M1** (inner red paddle).
* Ball remains the TIA Ball object. The playfield draws the top/bottom walls and
  dashed center divider.

P0 and P1 are time-multiplexed. `three_plus_three_score_component.c26` owns them
for the score at the top of the frame; the three black lines below the score are
then used to reposition P0/P1 as gameplay paddles. Their visible graphics use
only two center bits so the player paddles are approximately the same width as
the 2-pixel missile paddles.

Any blue-team fire button serves toward red; any red-team fire button serves
toward blue. A miss past both defenders scores one point for the other team.
Console Reset clears both scores. Paddle and wall rebounds use the same short
square-wave effects as the two-player example, with the wall beep one octave
lower.

Paddle rebounds are based entirely on TIA collision latches: P0-Ball and
M0-Ball for blue, P1-Ball and M1-Ball for red. The score's player collisions are
discarded by clearing `CXCLR` after the score and before gameplay begins.

`four_paddles.c26` measures INPT0..INPT3 with one analog sample per scanline.
The gameplay renderer samples channels 0/1 on one two-line pair and channels
2/3 on the next, so every input is observed every four scanlines while the raw
elapsed clock still advances in the same two-scanline units used by
`two_paddles.c26`. This keeps each beam-critical line below the worst-case RC
threshold-completion budget and permits slow/high-resistance measurements to
span frames rather than clipping them.

The complete game fits in an ordinary unbanked 4K cartridge. The four-paddle
component keeps `account_gap()` as one shared callable helper rather than
inlining four-channel gap bookkeeping at each call site, avoiding duplicate ROM
without changing the public two-paddle-compatible API.
