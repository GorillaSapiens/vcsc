```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Unofficial-opcode 181-line player-color renderer

`player_color_181_unofficial.c26` is the measured experimental twin of the
normal official-opcode `player_color_181` lifecycle component. It has the same
P0/P1/Ball API, packed full-range player handoff, per-row color contract,
181-line gameplay field, 13/51/64-byte RAM layout, scanline schedule,
score-composition behavior, and terminal-line cleanup.

Assemble cartridges using this component with `-Wa,--illegals`. The component
uses only reviewed stable/common NMOS forms: two `AXS #252` operations and one
zero-page unofficial NOP. Ordinary official NOPs remain where required to
preserve the official component's exact cycle boundaries.

Tests compare five official/unofficial cartridge pairs, including both score
orders and asynchronous full-range motion. The maintained smoke cartridges now
measure 1783 linked ROM bytes for the official implementation and 1781 bytes
for this variant, including the shared 160-entry packed position table, for a
measured saving of two bytes.

This profile is explicit rather than selected by an alias so opcode policy is
obvious from the template filename.
