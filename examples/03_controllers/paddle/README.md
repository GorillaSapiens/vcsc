```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Paddle input

This example is a raw input monitor for the first paddle on the left controller
port. It demonstrates the two parts that make Atari paddles different from a
joystick: the potentiometer is measured by **RC charge time**, while the paddle
button is an ordinary active-low digital switch.

`libraries/vcs/two_paddles.c26` handles the measurement lifecycle. Setting
`VBLANK.7` discharges the paddle capacitors. Releasing that bit lets them charge
through the paddle potentiometers. The TIA's `INPT0.7` input changes state when
paddle 0 crosses the comparator threshold, so the component counts elapsed
sampling slots until that happens. Its public `position0` value is the raw time
in approximately two-NTSC-scanline units; it is intentionally not calibrated to
a game coordinate. High-resistance readings may continue across frame
boundaries rather than being clipped.

The screen shows the last completed raw `position0` byte in binary. The top
eight bands are bits 7 through 0; a green band means that bit is 1 and dark blue
means 0. The ninth, bottom band is the button and turns red while pressed. The
first left-port paddle button is `SWCHA` bit 7 and is active-low.

While one completed value is displayed, the next RC measurement is sampled
throughout VBLANK, all 192 visible scanlines, and overscan. The source computes
all display colors during VBLANK so visible input sampling keeps a fixed phase;
that avoids making the measured value depend on which bits happen to be shown.

Build with `make` and run `make play`. If Stella does not choose paddles for the
left controller automatically, select **Paddles** for the left port in the game
controller properties.
