```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Faithful legacy multisprite renderer

This directory is the source-integration baseline for the retained legacy BASIC
multisprite renderer.  It intentionally preserves the selected upstream timing,
RAM layout, five-way P1 multiplexing, integrated six-digit score, stack-pointer
tricks, and stable/common-NMOS unofficial opcode use before any attempt is made
to turn the renderer into a more composable VCSC interface.

The selected profile is deliberately narrow:

- NTSC;
- unbanked 4K;
- no Superchip RAM;
- default 88-line gameplay region;
- integrated six-digit score;
- no `screenheight`, `debugscore`, `overscan_time`, `vblank_bB_code`,
  `vblank_time`, `minirenderer`, `noscore`, `pfscore`, or `qtcontroller`
  variants.

`normalize.pl` reproducibly selects that profile from
`../../legacy-basic-renderers/multisprite/multisprite_renderer.asm` and the
retained common score table.  It rewrites the historical `$80-$F9` symbols as
offsets from the linker-owned `vcs_multisprite_state` object and emits
`faithful_legacy_multisprite_renderer.s26`.  `normalize.pl --check` must report
that the generated source is current.

## Exact RAM and stack contract

The faithful state object is **122 bytes** and occupies exactly `$80-$F9`.
Within it, the historical `A..Z` application window is the 26 bytes `$D7-$F0`.
The renderer also needs all six physical hardware-stack bytes `$FA-$FF`: one
ordinary caller return plus two nested renderer call levels.  Therefore the
fixed faithful diagnostic owns **all 128 RIOT RAM bytes**.

The custom startup clears RIOT RAM and TIA directly and then `JMP`s to `main`.
It deliberately does not use the stock runtime startup, which would require
both its own RAM scratch and an additional physical `JSR main` return pair.
The normalized renderer declares `.callstackextra 2`.  The linker models four
source-call bytes (`main -> drawscreen` plus its root slot); the extra two bytes
reconcile that model with the actual six-byte hardware-stack maximum of this
tail-entry profile.

The score field is `uint8_t score[3]`, not `bcd24_t`.  The retained renderer
stores three packed-BCD bytes in **display order**.  A later VCSC game-logic
boundary must adapt that representation explicitly instead of pretending it is
a little-endian VCSC integer.

The generated renderer contains the retained `LAX` path, so cartridges using
this faithful profile must be assembled with `-Wa,--illegals`.

## Fixed diagnostic baseline

`examples/10_faithful_legacy_multisprite/01_diagnostic/` is intentionally a
fixed reference cartridge rather than the final application API.  Its C
`main` has zero activation RAM; a small assembly fixture installs known test
state once, then `main` repeatedly calls the faithful `drawscreen` entry.

The locked baseline is:

- P0 plus five distinct logical sprites multiplexed through P1;
- sprite rows stored bottom-to-top as consumed by the retained renderer;
- a ninth zero P0 row which clears `GRP0` before later P1 reposition `HMOVE`s;
- asymmetric playfield data so left/right or row timing corruption is visible;
- integrated six-digit score displaying `123456`;
- 88-line gameplay profile;
- **264 raw scanlines per stable frame** (faithful legacy behavior);
- **1472/4090 ROM bytes** for the fixed diagnostic;
- **122 object bytes + 6 hardware-stack bytes = 128/128 RIOT RAM**.

`test/vcs_faithful_legacy_multisprite.pl` is the default deterministic oracle.
It pins normalization, exact RAM ownership, hidden stack depth, ROM cost, frame
length, complete visible TIA-write stream, all six player rasters, colors, and
P1 reposition timing.  The independent Stella 7.0 reference raster can be
checked with:

```sh
make stella-faithful-multisprite-test STELLA=/path/to/stella
```

This baseline is not the end of roadmap item 28.  The next substep is to define
and prove one **stack-safe VCSC game-logic boundary** using the retained 26-byte
application window.  Do that before adding bankswitching, Superchip, optional
features, or additional multisprite variants.
