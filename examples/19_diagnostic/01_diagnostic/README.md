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

## Host and CPU fingerprint

The first display row identifies the host as `2600` or `7800`. Detection is done
by the cartridge's reset shim **before ordinary RIOT RAM is cleared**. A 7800
compatibility-mode boot leaves a loader image in RIOT RAM containing the
four-byte signature `6C FC FF EA`; the shim scans for that sequence, remembers
the result in F4SC RAM, and then establishes the cartridge's normal clean RAM
state. `6C FC FF` is `JMP ($FFFC)`, an indirect jump through the cartridge reset
vector. The following `EA` is a NOP and is unreachable after that unconditional
jump, so it is not required for the jump itself; it is included because it is
part of the observed 7800 loader image and makes the signature substantially
less likely to occur accidentally.

The second row is a six-hex-digit CPU silicon fingerprint. It uses the same four
unofficial `ARR` probes and CRC-24/OPENPGP reduction as the standalone VCSC
fingerprint example. On a 2600 this fingerprints the 6507; on a 7800 it
fingerprints the compatibility-mode 6502-family CPU instead. These values are
intended for comparing real machines, not as a CPU revision database built into
the cartridge.

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

## TIA collision animation

The bottom of the display is a live, human-readable view of **all 15 pairwise
TIA collision latches** among `M0`, `M1`, `P0`, `P1`, Ball (`BL`), and
playfield (`PF`). There are no register names or hexadecimal values on screen.
Instead, the panel uses two rows of eight compact six-pixel icons. Each icon is
formed by concatenating the two three-pixel object microglyphs for that
collision pair. The otherwise blank middle scanline becomes a solid six-pixel
bar when that collision latch is set, visually joining the two objects.

The icons follow the TIA register-bit order:

```text
top:    M0-P1 M0-P0 M1-P0 M1-P1 P0-PF P0-BL P1-PF P1-BL
bottom: M0-PF M0-BL M1-PF M1-BL BL-PF P0-P1 M0-M1 CHECK
```

The lower-right sixteenth slot is a check mark. It appears only when the full
15-bit collision bitmap is exactly the three collisions intentionally driven by
the animation, so an unexpected extra collision prevents the check even if all
three intended collisions occurred.

Directly below the bitmap are three matching four-scanline collision lanes. In
the first lane M0 approaches a large P0 `0` shape, in the second M1 approaches
a narrow P1 `1` shape, and in the third the Ball approaches a centered
playfield wall. Only the two objects relevant to a lane are enabled there. The
animation therefore intends to light only `M0-P0`, `M1-P1`, and `BL-PF`; the
other twelve pair icons should remain unconnected. M0/P0 use the P0 color,
M1/P1 use the P1 color, and Ball/playfield use the playfield color. SECAM
deliberately uses yellow, cyan, and magenta for those three paths.

The objects move slowly toward their targets and then hold visibly in contact.
The screen itself is rendered with P0/P1, which would create unrelated collision
bits. To keep the 15-bit bitmap honest, `CXCLR` is therefore strobed every frame
after the text/icon raster and immediately before the three controlled lanes.
The collision registers are captured only after those lane objects have been
disabled; a lit connection bar is consequently a direct report of a hardware
TIA collision latch from the controlled test, not a collision caused by drawing
the user interface. Once an approaching pair reaches contact it remains there,
so its connection stays visibly lit.

The six object microglyphs are deliberately easy to edit. Their canonical
source is `diagnostic_collision_objects.font`; each bitmap row contains the six
three-pixel glyphs as `M0_M1_P0_P1_BL_PF`. `make_collision_font.pl` converts
that source into the checked-in `diagnostic_collision_font.c26`. Running the
diagnostic Makefile regenerates the C26 file when the editable font changes.

Audio channel 0 and channel 1 also emit short distinct alternating beeps.

The cartridge is intended as a field aid, not as a substitute for an oscilloscope
or a known-good controller when diagnosing intermittent analog hardware.
