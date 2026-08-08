```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Fixed faithful multisprite diagnostic

This cartridge is the first roadmap-item-28 milestone.  It is a fixed
known-good baseline for the retained unbanked, non-Superchip legacy multisprite
renderer rather than the eventual VCSC game API.

The visible fixture deliberately contains:

- one independent P0 sprite;
- five distinct logical sprites multiplexed through P1;
- different P1 colors and horizontal positions, with sprite 5 aquamarine so it
  cannot disappear into the goldenrod playfield;
- upright sprite glyphs stored in the retained renderer's bottom-to-top memory
  order;
- a ninth zero P0 row which clears delayed `GRP0` after the eight visible rows;
- asymmetric playfield rows;
- the integrated six-digit score `123456`.

The C `main` performs no ordinary initialization because this faithful profile
has no unowned RIOT RAM: the renderer state occupies `$80-$F9` and the measured
hardware stack needs `$FA-$FF`.  A small assembly fixture installs the fixed
reference data once.  The legacy renderer walks sprite bytes from high address
to low address, and P0 needs one extra clearing row: omitting that row leaves
its last graphic byte latched while later P1 `HMOVE` strobes shift it sideways.
That fixture is diagnostic scaffolding, not a proposed application interface.

Build with:

```sh
make
```

The result is exactly 4096 bytes.  The locked reference costs 1472 bytes of ROM,
uses 122 state bytes plus six hardware-stack bytes, and produces stable 264-line
frames.  The default regression verifies the complete visible TIA event stream;
there is also an independent Stella 7.0 snapshot certification through the
repository's `stella-faithful-multisprite-test` target.
