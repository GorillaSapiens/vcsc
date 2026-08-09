```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Unofficial-opcode 181-line player-color renderer

`player_color_181_unofficial.c26` is the measured experimental twin of the
normal official-opcode `player_color_181` lifecycle component. It has the same
P0/P1/Ball API, packed full-range player handoff, per-row color contract,
181-line gameplay field, 13/11/24-byte public/private/total RAM contract, scanline schedule,
score-composition behavior, and terminal-line cleanup.

Assemble cartridges using this explicitly experimental profile with
`-Wa,--illegals`. After the object-mask builder was removed, none of the former
reviewed unofficial substitutions remains profitable: the current generated
renderer uses only official instructions and is byte-for-byte the same size as
the official twin. Keeping the separate profile makes opcode policy explicit
and leaves room for future measured experiments without silently changing the
official renderer.

Tests compare five official/unofficial cartridge pairs, including both score
orders and asynchronous full-range motion. The maintained smoke cartridges now
measure 1422 linked ROM bytes for both implementations, including the shared
160-entry packed position table, for a measured size delta of zero bytes. The
motion oracle also pins the corrected delayed-Ball transfer across a row
boundary.

This profile is explicit rather than selected by an alias so opcode policy is
obvious from the component filename.

The ten-cartridge public score/poison matrix lives under
`examples/07_player_color_181_unofficial/`. They are direct twins of the
official examples and keep `-Wa,--illegals` visible in each Makefile.
