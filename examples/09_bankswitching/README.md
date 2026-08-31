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
and reinitialization after console reset without adding more cartridges. The `01_f864`
diagnostic executes both its complete ordered direct-JMP matrix and complete
ordered C-call matrix internally.

Generated JSR/RTS paths need a stronger test than merely touching every bank.
`test/vcs_bankswitching_call_matrix.pl` builds one ROM per source bank and makes
that source call every destination bank, checking metadata, return value,
hardware-stack balance, and simulator execution. This covers every ordered JSR
pair for F8/F8SC, F6/F6SC, F4/F4SC, FA, both FA2 profiles, JANE, 0840,
UA/UASW, 0FA0, and DPC. F8/F6/F4(+SC) and FA now use the fixed generic
inline-target block; the remaining families intentionally keep their existing
mapper-specific/legacy paths until migrated.

The public VCSC cartridge profiles also stamp the final physical bank with a
four-byte mapper signature at logical addresses `$xFF8-$xFFB` (eight bytes before that bank ends). Short mapper names are
ASCII-NUL padded: `F8\0\0`, `F6\0\0`, `F4\0\0`, `FA\0\0`, and
`CV\0\0`; the complete four-byte names are `4KSC`, `F8SC`, `F6SC`, `F4SC`,
`OMNI`, `JANE`, `0840`, `UA\0\0`, `UASW`, `0FA0`, `E0\0\0`, `FE\0\0`, `WD\0\0`, `DPC\0`, `3F\0\0`, and `3E\0\0`. Only the final CPU-mapped bank in file order contains the signature; later DPC data-only chunks are excluded. Selector-hotspot addresses are valid storage
for these bytes because hardware switching is caused by accessing the address,
not by the byte stored there. Where the final file bank also owns the vector
page, the final two signature bytes replace only the unused 6507 NMI vector and
leave RESET and IRQ/BRK intact. FE is the exception: its signature is in final
file bank 1 at `$DFF8-$DFFB`, while RESET and IRQ/BRK remain in startup bank 0
at `$FFFC-$FFFF`.

`03_fa_ram_plus/` is the dedicated CBS FA/RAM Plus diagnostic. It displays
`pass`/`FAIL`, uses the generic inline-target call ABI for all six ordered
source/destination call pairs, uses all 256 bytes of cartridge RAM, and verifies
startup from physical bank 2. The shared ordered-call regression independently
repeats the exhaustive FA matrix with hardware-stack checks.

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
bank and crosses all four selectors through a representative nested call/return
chain; the shared regression separately covers every ordered JSR pair. It
displays `JANE` below `pass`/`FAIL`. The image also carries Stella's
`LDA $FFF1; RTS` autodetection byte pattern as inert data.

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

`11_e0/` is the Parker Brothers E0 diagnostic. It verifies the 4/5/6/7 power-on
mapping, all three independently selectable 1K windows, fixed physical bank 7,
and actual execution from all eight physical chunks. Its deliberately tiny
fixed-bank display uses green for PASS and red for FAIL; `make play` forces
Stella's `E0` mapper.

## Banked standard renderer

`02_standard_renderer/` is the consolidated F8 integration of the maintained
standard all-five renderer with generic C26 topology.  Its only bank switch is a
VBLANK-only overscan-hook round trip; F6, F4, F8SC, and unbanked-reference builds
remain private regression variants of the same source.

`12_3f/` is the classic 3F diagnostic. It exercises multiple lower 2K ROM banks
plus the fixed final 2K, forces Stella's 3F mapper, and renders large PASS/FAIL
with small `3F`. The profile transparently uses the `$40-$7F` TIA mirror so
ordinary display writes do not become 3F bank-select writes.

`13_3e/` is the classic 3E diagnostic. It exercises lower-ROM switching, two
1K RAM banks, read/write aliases, RAM persistence, ROM restoration, and the
fixed final 2K, then renders large PASS/FAIL with small `3E`.

`14_fe/` is the released two-bank FE/SCABS diagnostic. Physical/file bank 0 is
the `$F000-$FFFF` startup view and physical/file bank 1 is the `$D000-$DFFF`
alternate view. FE has no ordinary selector hotspot: an access to mirrored
`$01FE` arms a one-cycle-delayed latch, and the following bus value chooses the
bank. The diagnostic sets `SP=$FF` and exercises the released-cartridge direct
`JSR`/`RTS` switching idiom, verifies that the return restores both bank and
stack state, and renders large PASS/FAIL with small `FE`. Its display deliberately
uses BSS-only/simple startup so generic initialization cannot touch `$01FE` via
temporary stack traffic. `make play` forces Stella's `FE` mapper.

`15_wd/` is the Wickstead Design diagnostic for the corrected 8K image layout.
It verifies power-on arrangement 0, multiple `$30-$3F` read-selected four-segment
arrangements, delayed selector visibility, write-without-switch behavior, and both
ends of the 64-byte `$1000/$1040` split RAM device. Ordinary TIA I/O uses the
`$40-$7F` mirror so collision/input reads cannot accidentally select an
arrangement. The cartridge executes from several physical 1K chunks, renders
large PASS/FAIL with small `WD`, and `make play` forces Stella's `WD` mapper.


`16_dpc/` is the DPC diagnostic. It emits the conventional 10,495-byte image
as two F8-style program banks plus a 2K display-data bank and 255-byte Poly8
tail, both declared `$data_only`. The self-test executes both ordered calls
between the two F8-style program banks, reads and checksums every display byte
through DPC fetcher 0 including an 11-bit counter wrap check, then resets and
verifies the complete 255-state DPC RNG sequence. It renders large PASS/FAIL
with small `DPC`; `make play` forces Stella's `DPC` mapper.

- `17_fa2` — FA2 28K seven-bank + 256-byte cartridge-RAM PASS/FAIL diagnostic.
  The visible cartridge uses a representative seven-bank nested chain; the shared
  ordered-call regression exhaustively covers every source/destination pair for
  both the six-bank and seven-bank FA2 profiles.
