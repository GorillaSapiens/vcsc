```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# All-five 181-line unofficial-opcode component

`all_five_181_unofficial.c26` is the separately named experimental counterpart to
the official `../all_five/all_five.c26` renderer instantiated with `lines:=181`. It has the same lifecycle API, 23-byte
public state, 44-byte private state, 67-byte total RAM contract, 44-byte
playfield contract, solid player colors, five-object behavior, and score-above
or score-below composition rules. Assemble cartridges that instantiate it with
`-Wa,--illegals`.

Only one reviewed stable/common NMOS form remains: a zero-page unofficial NOP
(`$04`) replaces a same-size, same-cycle dead-flag padding instruction during
VBLANK positioning. No silicon-sensitive or unstable opcode is used. Every
other instruction and every physical modulo-76 write phase now matches the
corrected official renderer.

The maintained smoke links measure:

```text
official linked ROM bytes:   1794
unofficial linked ROM bytes: 1794
signed byte difference:          0
```

Tests compare all five official/unofficial cartridge pairs byte-for-byte at the
visible TIA-event level, including score above, score below, static state, and
asynchronous motion. They also require identical RAM addresses, the single
reviewed unofficial opcode, stable 262-line frames, and the corrected playfield schedule in both variants. The official edge oracle also
pins the delayed-Ball transfer across the first packed-row boundary; the
unofficial source retains the same transition logic.

The ten-cartridge public score/poison matrix lives under
`examples/08_all_five_181_unofficial/`. They are application-level counterparts to the official
examples and keep `-Wa,--illegals` visible in each Makefile.
