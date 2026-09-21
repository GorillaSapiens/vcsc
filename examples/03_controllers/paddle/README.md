```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Paddle input

This example makes all four Atari paddle controllers visible directly. The
screen is black with four equally spaced white markers at X=20, 60, 100, and
140. From left to right they are paddle 0, paddle 1, paddle 2, and paddle 3.
Turning a paddle moves only its own marker up and down.

Each marker is **2 pixels wide and 8 pixels tall**. It is solid while the
paddle button is released. Holding that paddle's button makes the same marker
dotted by drawing every other scanline. Nothing else changes, so both parts of
a CX30 paddle are obvious at a glance: the potentiometer controls position and
the button controls the marker pattern.

The example uses all four independent TIA objects that fit this display cleanly:
P0, M0, M1, and P1. P0/P1 draw two adjacent player pixels; M0/M1 use the TIA's
native 2-pixel missile width. `libraries/vcs/components/four_paddles.c26` measures the four
potentiometers through `INPT0`..`INPT3` and reads the four active-low paddle
buttons from `SWCHA`.

Paddle potentiometers are not ordinary digital inputs. The VCS discharges their
capacitors with `VBLANK.7`, releases them, then measures how long each RC circuit
takes to cross its comparator threshold. The visible loop samples one paddle
channel per scanline in a fixed four-line schedule while it draws the markers,
so the display does not perturb the timing measurement.

Build with `make` and run `make play`. Configure both Stella controller ports as
**Paddles** so all four controllers are available.
