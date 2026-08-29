```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# VCSC field diagnostic

Build with `make`; run with `make play` or load `vcsc_diagnostic.bin` as an F4SC
cartridge. The same ROM supports NTSC, PAL, and SECAM.

## Controls

* **SELECT** cycles `JOYSTICK -> PADDLE -> KEYPAD -> DRIVING -> JOYSTICK`.
* Hold **RESET** while pressing **SELECT** to cycle `NTSC -> PAL -> SECAM -> NTSC`.
* The displayed `SELECT`, `RESET`, `COLR/B&W`, and left/right difficulty values
  are live console-switch states.

Controller-mode changes take effect on a frame boundary. Holding SELECT does
not repeatedly advance the mode; release it before the next selection.

## Logo, host, and CPU fingerprint

The top mark is rendered directly from the canonical
`libraries/vcs/fonts/logo_font.c26` six-slice VCSC logo.  It is not a locally
redrawn approximation.

The TV-standard row also identifies the host as `2600` or `7800` (for example,
`2600 NTSC`). Detection is done by the cartridge's reset shim **before ordinary
RIOT RAM is cleared**. A 7800 compatibility-mode boot leaves a loader image in
RIOT RAM containing the four-byte signature `6C FC FF EA`; the shim scans for
that sequence, remembers the result in F4SC RAM, and then establishes the
cartridge's normal clean RAM state. `6C FC FF` is `JMP ($FFFC)`, an indirect
jump through the cartridge reset vector. The following `EA` is a NOP and is
unreachable after that unconditional jump, so it is not required for the jump
itself; it is included because it is part of the observed 7800 loader image and
makes the signature substantially less likely to occur accidentally.

The six-hex-digit CPU silicon fingerprint is rendered with the canonical larger
`big_ascii.c26` glyphs rather than the compact two-character status font.  The
checked-in `diagnostic_fingerprint_font.c26` is a generated `0-9A-F` subset;
`make fonts` regenerates it.  The fingerprint uses the same four unofficial
`ARR` probes and CRC-24/OPENPGP reduction as the standalone VCSC fingerprint
example. On a 2600 this fingerprints the 6507; on a 7800 it fingerprints the
compatibility-mode 6502-family CPU instead. These values are intended for
comparing real machines, not as a CPU revision database built into the
cartridge.

## Controller hookups

* **JOYSTICK:** one CX10-compatible joystick per controller port. Direction and
  fire are displayed for both ports.
* **PADDLE:** a normal pair of paddles on each controller port; all four analog
  positions and buttons are displayed.
* **KEYPAD:** one CX50/Video Touch Pad compatible keypad per controller port.
  One matrix row is sampled per frame, so a complete key snapshot updates every
  four frames.
* **DRIVING:** one Indy 500 driving controller per controller port. Position is
  accumulated from the two-bit Gray-code sequence and each button is displayed.

Do not depend on automatic controller identification in an emulator. Configure
Stella's left/right controller properties for the controller family being
exercised. Keypad mode actively drives the controller-port row lines as required
by the matrix and therefore is intentionally an explicit mode rather than a
background probe.

## TIA collision test

The bottom of the display is a live, human-readable test of **all 15 pairwise
TIA collision latches** among `M0`, `M1`, `P0`, `P1`, Ball (`BL`), and
playfield (`PF`). The fifteen tests are labeled `A` through `O` in TIA
register-bit order. A six-pixel underline beneath a letter means that pair's
most recent isolated hardware test passed. The lower-right sixteenth slot is a
check mark meaning **all fifteen A-O tests currently pass**.

| Label | Collision | Label | Collision |
| --- | --- | --- | --- |
| `A` | M0-P1 | `I` | M0-PF |
| `B` | M0-P0 | `J` | M0-BL |
| `C` | M1-P0 | `K` | M1-PF |
| `D` | M1-P1 | `L` | M1-BL |
| `E` | P0-PF | `M` | BL-PF |
| `F` | P0-BL | `N` | P0-P1 |
| `G` | P1-PF | `O` | M0-M1 |
| `H` | P1-BL | check | all A-O pass |

On screen the top row is `A B C D E F G H`; the bottom row is
`I J K L M N O` followed by the check slot.  The cartridge exercises **one and
only one pair at a time**.  All five movable TIA objects are placed at the same
horizontal position; each phase enables only the two objects named by that
letter, except playfield phases, which enable the named movable object plus a
full playfield.  The complete 15-bit collision register bitmap is then captured.
A phase passes only when that entire bitmap contains exactly its one expected
latch and no unexpected collision bits.

Normal operation holds each A-O phase for sixteen frames so the currently
exercised pair is visible, followed by one sixteen-frame idle phase, then repeats.
A successful phase sets its letter's underline; a later failure of the same phase
removes it.  The check mark is computed from all fifteen remembered results, so
it cannot appear until every collision pair has actually passed.  The Stella
certification build merely accelerates this same physical sequence to one phase
per frame; it does not synthesize pass bits.

The screen itself uses P0/P1 and therefore dirties collision latches. `CXCLR` is
strobed immediately before the controlled collision lane. The collision
registers are read only after that isolated lane has run, so UI drawing cannot
make a test pass.

The collision labels use the canonical `libraries/vcs/fonts/half_ascii.c26`
letters. `make_collision_font.pl` centers `A` through `O` in the six-pixel
collision cells and generates both inactive and underlined-pass states in the
checked-in `diagnostic_collision_font.c26`. Run `make fonts` in this directory,
or at repository top level, after changing the Half ASCII or Big ASCII font.
Ordinary example builds consume the checked-in generated files and do not
require Perl.

Audio channel 0 and channel 1 also emit short distinct alternating beeps.

The cartridge is intended as a field aid, not as a substitute for an oscilloscope
or a known-good controller when diagnosing intermittent analog hardware.
