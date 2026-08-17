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

The public VCSC cartridge profiles also stamp the final physical 4K bank with a
four-byte mapper signature at image offsets `$xFF8-$xFFB`. Short mapper names are
ASCII-NUL padded: `F8\0\0`, `F6\0\0`, `F4\0\0`, and `FA\0\0`; the complete
four-byte names are `4KSC`, `F8SC`, `F6SC`, `F4SC`, and `OMNI`. Only the final bank in
file order contains the signature. Selector-hotspot addresses are valid storage
for these bytes because hardware switching is caused by accessing the address,
not by the byte stored there. The final two bytes overlap the unused 6507 NMI
vector while leaving RESET and IRQ/BRK intact.

`03_fa_ram_plus/` is the dedicated CBS FA/RAM Plus diagnostic. It displays
`pass`/`FAIL`, exercises all three selectors through nested cross-bank calls,
uses all 256 bytes of cartridge RAM, and verifies startup from physical bank 2.

`04_4ksc/` is the direct 4K Superchip diagnostic. It allocates all 128 bytes of
Superchip RAM, verifies DATA/BSS reset initialization and read/write aliases,
and displays `4KSC` below the green `pass` or red `FAIL` result.

`05_omni/` is the OmniCart PHM direct-addressing diagnostic. It uses all
4K of same-address `cartram`, calls through all seven RO islands with ordinary
16-bit JSR/RTS and data references, and displays `OMNI` below `pass`/`FAIL`.
There is no Stella target because released Atari hardware/emulators do not expose
PHM's recovered upper address bits; the regression suite executes the cartridge
with `vcsc-sim`'s selector-free OMNI logical layout.

## Banked standard renderer

`02_standard_renderer/` is the consolidated F8 integration of the maintained
standard all-five renderer with generic C26 topology.  Its only bank switch is a
VBLANK-only overscan-hook round trip; F6, F4, F8SC, and unbanked-reference builds
remain private regression variants of the same source.
