```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# All-five 181-line unofficial-opcode component

`all_five_181_unofficial.c26` is the separately named experimental twin of
`../all_five_181/all_five_181.c26`. It has the same lifecycle API, 23-byte
public state, 51-byte private state, 74-byte total RAM contract, 44-byte
playfield contract, solid player colors, five-object behavior, and score-above
or score-below composition rules. Assemble cartridges that instantiate it with
`-Wa,--illegals`.

Only one reviewed stable/common NMOS form remains: a zero-page unofficial NOP
(`$04`) replaces a same-size, same-cycle dead-flag padding instruction during
VBLANK positioning. The visible renderer otherwise follows the official source
and schedule exactly. No silicon-sensitive or unstable opcode is used.

The maintained smoke links measure:

```text
official linked ROM bytes:   2092
unofficial linked ROM bytes: 2092
signed saving:                  0
```

The zero-byte result is intentional. Removing compensating instructions would
save bytes only by changing visible-write or lifecycle timing and would no
longer be an equivalent renderer. Pairwise emulator tests require identical
visible TIA traces, object behavior, score composition, RAM addresses, and
stable 262-line frames, including horizontal-blank P1 and missile handoffs,
for the official and unofficial cartridges.
