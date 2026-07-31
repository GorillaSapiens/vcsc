```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# All-five 181-line unofficial-opcode component

`all_five_181_unofficial.c26` is the separately named experimental counterpart to
`../all_five_181/all_five_181.c26`. It has the same lifecycle API, 23-byte
public state, 51-byte private state, 74-byte total RAM contract, 44-byte
playfield contract, solid player colors, five-object behavior, and score-above
or score-below composition rules. Assemble cartridges that instantiate it with
`-Wa,--illegals`.

Only one reviewed stable/common NMOS form remains: a zero-page unofficial NOP
(`$04`) replaces a same-size, same-cycle dead-flag padding instruction during
VBLANK positioning. No silicon-sensitive or unstable opcode is used. The
unofficial renderer remains on its older visible schedule; the corrected
physical modulo-76 schedule is currently confined to the official renderer.

The maintained smoke links measure:

```text
official linked ROM bytes:   2090
unofficial linked ROM bytes: 2092
signed byte difference:          2
```

The two components retain identical lifecycle and RAM contracts, but they are
not currently raster-identical. Tests validate each renderer independently and
continue to require the same application-visible object behavior, score
composition, RAM addresses, reviewed opcode set, and stable 262-line frames.

Public score-above and score-below five-object examples live under
`examples/08_all_five_181_unofficial/`. They are application-level counterparts to the official
examples and keep `-Wa,--illegals` visible in each Makefile.
