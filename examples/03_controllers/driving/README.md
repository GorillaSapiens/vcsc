```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Two Indy 500 driving controllers

This example reads one Atari Indy 500 driving controller in each controller
port. The left controller drives P0 in the left half of the screen; the right
controller drives P1 in the right half. Each player is the accumulated rotation
shown as a hexadecimal digit, while its matching missile is a 4x4 dot orbiting
that digit through 16 positions.

Each side starts at `0` with its dot at the top of the orbit. Turning clockwise
increments the digit through `0`..`9`,`A`..`F` and advances the dot clockwise;
turning counterclockwise decrements the digit and moves the dot counterclockwise.
Both wrap naturally between `0` and `F`. This makes the driving controller's
important property visible: it reports endless relative rotation rather than an
absolute knob position.

M0 belongs to the left/P0 display and M1 belongs to the right/P1 display. The
missiles use the TIA's native four-pixel missile width and are enabled for four
scanlines, making each orbit marker 4x4. The 16-position orbit is wider in
scanlines than in color clocks so it appears approximately circular with VCS
pixel aspect. The digit and its orbit dot are white while the controller button
is released and red for exactly as long as the button is held; missiles inherit
their matching player's color automatically.

`libraries/vcs/components/driving_controller.c26` decodes the two-bit Gray code on pins 1
and 2: left SWCHA D4/D5 and right SWCHA D0/D1. Written as pin1:pin2,
the clockwise sequence is `11 -> 10 -> 00 -> 01 -> 11`; counterclockwise is the
reverse. Each call to `sample()` reports a signed `step` and adds that movement
to the signed `delta` for the current application frame. `begin_frame()` resets
that accumulation. An opposite-state jump means one intermediate Gray state was
missed; the component preserves a known direction and counts that case as two
steps. Before a direction has been established it refuses to guess.

The example samples both controllers three times during VBLANK and three more
times during overscan. All input-dependent work stays in timer-owned blanking
periods. The visible display is a fixed 48-line scene centered inside the
192-line NTSC region, with the 16-line hexadecimal glyphs in its middle and the
4x4 orbit markers moving around them. The hexadecimal glyphs come directly from
`fonts/big_hex.c26`.

The fire button is pin 6: INPT4 on the left and INPT5 on the right. Current
Stella does not auto-detect Indy 500 driving controllers from a ROM. Before
running this example in Stella, go to **Options -> Game Properties ->
Controllers** and select **Driving** for both the **Left port** and **Right
port**.
