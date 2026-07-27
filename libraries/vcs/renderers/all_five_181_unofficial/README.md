```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

All-five 181-line unofficial-opcode component
=============================================

`all_five_181_unofficial.c26` is the separately named experimental twin of
`../all_five_181/all_five_181.c26`. It has the same lifecycle API, public and
private RAM layout, 181-line gameplay contract, object behavior, and score
composition rules. Build cartridges that instantiate it with
`-Wa,--illegals`.

Only reviewed stable/common NMOS 6502/6507 forms are used:

* `AXS #252` replaces each `TXA` / optional `CLC` / `ADC #4` / `TAX` row-index
  idiom. One-byte NOP padding retains the official sequence's exact byte count
  and cycle count. A is dead and the following `CPX` or load replaces flags.
* one zero-page unofficial `NOP` (`$04`) remains where it replaces `BIT CXM0P`
  with dead flags outside the corrected draw path. The draw routine now matches
  the official component's horizontal-blank PF1 restoration exactly.

These substitutions deliberately preserve every cycle boundary. They produce
**zero linked-byte savings** in the maintained smoke cartridge: both official
and unofficial links use 1421 ROM bytes. This is a valid result; removing the
compensating NOPs would save bytes only by shifting visible writes or lifecycle
boundaries and therefore would not be an equivalent renderer.
