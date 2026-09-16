```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# E0 diagnostic

This 8K cartridge certifies VCSC's constrained automatic-call ABI for Parker
Brothers E0.  Compiled code uses only three relocation-safe mapper states:

```text
state 0  [0,1,6,7]
state 1  [2,3,6,7]
state 2  [4,5,6,7]   hardware reset state
```

Banks 0/2/4 have canonical origin `$1000`, banks 1/3/5 `$1400`, bank 6 remains
at `$1800`, and fixed bank 7 remains at `$1C00`. Cross-state calls switch the
first two windows together and restore the caller state. Banks 6 and 7 are
resident in every state; one internal state byte lets nested calls made from
resident code restore the lower pair correctly.

The self-test executes the complete 8x8 ordered physical-bank call matrix. It
also makes bank6 perform a nested state0 -> state1 call and bank7 perform a
nested state1 -> state2 call, verifies that both restore their caller state,
checks a cross-state 16-bit `A:X` return, and requires the final mapper state to
be state 2. The focused regression separately proves that a direct bank4 ->
bank5 ROM reference is legal because both are always visible in state 2, while
a bank0 -> bank2 ROM data reference is rejected.

After certification, the cartridge displays the standard large `pass`/`FAIL`
result with `E0` underneath. Display code/data are placed in the hardware reset
state: draw code in bank4, glyphs in bank5, lifecycle helpers in resident bank6,
and `main` in fixed bank7. The independent timing oracle requires 262-line NTSC
frames.

VCSC stamps `E0\0\0` at `$FFF8-$FFFB` in physical bank 7. `make play` forces
Stella's E0 mapper.
