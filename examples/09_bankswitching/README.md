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

The public VCSC cartridge profiles also stamp the final physical bank with a
four-byte mapper signature at logical addresses `$xFF8-$xFFB` (eight bytes before that bank ends). Short mapper names are
ASCII-NUL padded: `F8\0\0`, `F6\0\0`, `F4\0\0`, `FA\0\0`, and
`CV\0\0`; the complete four-byte names are `4KSC`, `F8SC`, `F6SC`, `F4SC`,
`OMNI`, `JANE`, `0840`, `UA\0\0`, `UASW`, and `0FA0`. Only the final bank in file order contains the signature. Selector-hotspot addresses are valid storage
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

`06_cv/` is the fixed CommaVid CV diagnostic. It uses all 1024 bytes of
`cartram`, verifies DATA/BSS initialization and the `$F000/$F400` split aliases,
and displays `CV` below `pass`/`FAIL`. The generated image includes the
`STA $F400,Y` byte pattern used by Stella for CV autodetection.

`07_jane/` is the 16K JANE diagnostic. It preserves physical file-bank order
0/1/2/3 for selectors `$1FF0/$1FF1/$1FF8/$1FF9`, while hardware startup is
physical bank 1. The self-test begins correctly from every possible selected
bank, crosses all four selectors through nested calls/returns, and displays
`JANE` below `pass`/`FAIL`. The image also carries Stella's `LDA $FFF1; RTS`
autodetection byte pattern as inert data.

`08_0840/` is the 8K 0840/EconoBanking diagnostic. Physical bank 0 powers up;
reads or writes in the decoded `$0800` family select bank 0 and the `$0840`
family selects bank 1. Generated bank bridges use an NMOS absolute NOP read so
selection does not write mirrored console devices. The diagnostic exercises
nested calls/returns and displays `0840` below `pass`/`FAIL`; its repeated
`NOP $0800; JMP` reset bridges also provide the standard emulator detector
pattern.

`09_ua/` contains paired 8K UA and UASW diagnostics. UA decodes selector aliases
with `(A & $1260)==$0220` for physical bank 0 and `==$0240` for bank 1; aliases
such as `$02A0/$02C0` therefore select the same banks. UASW uses the identical
decoder with the bank association reversed. Both power up in physical bank 0,
use read-only NMOS absolute-NOP selector accesses in generated bridges, and
preserve the underlying TIA/RIOT-side transaction when a low-address selector
is read or written. The paired cartridges display `UA` or `UASW` below the
common `pass`/`FAIL` result.

`10_0fa0/` is the Brazilian Fotomania 0FA0 diagnostic. Physical/file bank 1 is
the startup bank. The mapper uses the explicit mask `(A & $16E0)`: `$06A0`
selects physical bank 0 and `$06C0` selects physical bank 1, with A11, A8, and
A4-A0 acting as aliases. VCSC uses `$0FA0/$0FC0` as canonical selector accesses,
and the focused regression also proves noncanonical read/write aliases. The
cartridge displays `0FA0` below the large `pass`/`FAIL` result.

## Banked standard renderer

`02_standard_renderer/` is the consolidated F8 integration of the maintained
standard all-five renderer with generic C26 topology.  Its only bank switch is a
VBLANK-only overscan-hook round trip; F6, F4, F8SC, and unbanked-reference builds
remain private regression variants of the same source.
