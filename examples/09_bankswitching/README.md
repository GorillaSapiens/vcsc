```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Bank-switching diagnostics

This group contains mapper-level diagnostic cartridges rather than gameplay
examples.  They deliberately exercise generated cross-bank JSR/RTS and direct
JMP bridges, reset from arbitrary initially selected banks, RIOT-RAM signatures,
and hardware-stack balance.

The source is parameterized so one editable cartridge produces six mapper
diagnostics—F8, F6, F4, F8SC, F6SC, and F4SC—plus a seventh deliberately
poisoned F8SC image which renders the known FAIL result. The SC diagnostics also
certify hostile initial RAM, mixed BSS/DATA startup, bank-switch persistence,
and reinitialization after console reset without adding more cartridges. Each
mapper diagnostic executes its complete ordered direct bank-transition matrix
internally.

`03_fa_ram_plus/` is the dedicated CBS FA/RAM Plus diagnostic. It displays
`pass`/`FAIL`, exercises all three selectors through nested cross-bank calls,
uses all 256 bytes of cartridge RAM, and verifies startup from physical bank 2.

## Banked standard renderer

`02_standard_renderer/` is the consolidated F8 integration of the maintained
standard all-five renderer with generic C26 topology.  Its only bank switch is a
VBLANK-only overscan-hook round trip; F6, F4, F8SC, and unbanked-reference builds
remain private regression variants of the same source.
