```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Combined-colour interactive preview

```sh
make
make play
```

Joystick 0 moves the selected object, Select cycles P0/P1/M0/M1/ball, and Reset
restarts. The five objects start at different heights across the display.
Players use the same four eight-row animation frames as the other section demos;
each player's eight row colours are independently editable in the `.c26` source.
The eight section palettes are also editable in the source's `instantiate`
arguments, along with `section1_lines` through `section8_lines`.

This **experimental even-line preview** defaults to seams at visible scanlines
6, 18, 46, 80, 114, 150 and 190. The eight heights are
**6, 12, 28, 34, 34, 36, 40, 2**, totaling 192 scanlines.
Every height must be positive and even (at least two scanlines), totaling 192.
Zero-height sections are rejected. Boundaries can cross playfield rows and may
be two scanlines apart, including at the bottom of the display.
Movement extends to Y=103, allowing objects to cross the last boundary and clip
below the display rather than stopping above it.
The two visual playfield row
aliases repeat down the display; edit those aliases rather than individual copies.
It uses ordinary 8K F8 ROM and 106 of the stock 128 RAM bytes, not cartridge RAM. Drawing and
sprite tables stay in bank0; preparation, initialization and controls use bank1.
No sprite mirroring or external source generator is required.

The example-local renderer is not installed as a general public component.
The sibling score previews retain their bounded geometry; they do not yet use
this display-wide scheduler. The default build still requires alternating PF rows.

## Opt-in repeated-pair build (unfinished)

```sh
make repeated
make play-repeated
```

This builds the **same interactive example**, with twelve distinct visual PF
rows selected by `ALL_FIVE_REPEATED_PREVIEW` in its `.c26` source. It retains the
seven default seams, all five movable objects, independent player row colours,
and four animation frames. Edit the twelve `VCS_PLAYFIELD_ROW` entries and the
shared section arguments directly; no external generator is involved.

The alternative renderer repeats a two-scanline body for each PF row and routes
fine colour events through native compile-time scheduling. Its dispatch uses
**two reusable RAM bytes**, not a growing return vector. Drawing and sprite ROM
stay in bank0; startup and application work use bank1, with stock F8 bank sizes
and stock RIOT RAM. The hardware stack is not repurposed during drawing.
The supplied build uses **3724/3840** bank0 bytes and **94/128** RAM bytes,
including its hardware-stack reservation.

For row-aligned layouts (all eight heights multiples of16), the first PF row
now repeats six ordinary pairs and uses a separate final-pair/boundary handoff.
The layout `16,16,16,16,32,32,32,32` passes the isolated first-boundary runtime
height/pointer/NUSIZ exact probe with twelve distinct PF rows. This uses the
temporarily dead dispatch low byte for staging, not additional RAM or the stack.
It is only a first-row fix; fine-event layouts retain their existing path.

**Not completion or a general renderer ABI:** the distinct-row/default-position
exact-pixel checks pass, but edge-position/runtime-NUSIZ probes still expose P0
row-ending colour timing differences outside that bounded first-row path.
P1 handoffs in later rows and fine-event layouts still need certification.
Uniform PF inputs now retain the scheduled loads: equal adjacent PF constants
pass timing and exact pixels at default positions on both the row-aligned and
supplied fine-seam layouts. This does not fix their edge-control limitations.
Other geometries are not certified, and
neither score composition uses this renderer yet. Keep the default build when
you need its existing edge-control behaviour.
