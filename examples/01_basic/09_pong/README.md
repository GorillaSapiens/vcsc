```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Pong-like two-paddle example

This 4K example composes `three_plus_three_score_component.c26` with a compact
181-line Pong playfield. The left paddle/score are blue, the right paddle/score
are red, and the black field uses white walls, center dashes, and Ball.

Two CX30-style paddles share controller port 0. Each knob controls its paddle;
either paddle fire button serves from the center toward the opposite player.
The console Reset switch resets both scores and returns the ball to serve.

The top and bottom walls are exactly four scanlines high. The center divider is
an eight-scanline-on/eight-scanline-off reflected playfield bit, with the same
one-scanline black gap between the divider and each wall. Gameplay uses M0 and
M1 for the two paddles so the score component may freely own P0/P1.

The Pong renderer uses the same calibrated divide-by-fifteen RESP/HMxx sequence
as the maintained all-five renderers. The blue and red paddles are placed at
mirrored physical X positions, and the Ball's software edge limits stop at the
last stable visible coordinates rather than allowing the RESP calculation to
wrap around the left or right edge.

`two_paddles.c26` measures both analog inputs in two-scanline units and permits
a measurement to span frames instead of clipping slow/high-resistance paddle
positions. The game gives the low end a small dead zone for controller tolerance,
then maps both channels onto the same odd Y=9..159 rendered-top range. M0 and M1
now change enable state in the same raster phase, so equal paddle positions are
actually level on screen. The displayed paddle slews toward the latest target by
two scanlines per frame, hiding the multi-frame update cadence of high-resistance
positions. Both endpoints keep the same wall clearance, and the bottom endpoint
disables inside the visible pair loop instead of leaking into the bottom wall.
