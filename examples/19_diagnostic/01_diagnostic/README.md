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

The bottom of the display is a live, human-readable TIA collision test. Three
rows show the actual hardware collision registers being exercised:

* `CXM0P` -- missile 0 against player 0; the expected latched value is `40`.
* `CXM1P` -- missile 1 against player 1; the expected latched value is `40`.
* `CXBLPF` -- Ball against playfield; the expected latched value is `80`.

Directly below those rows are three matching four-scanline collision lanes. In
the first lane M0 approaches a large P0 `0` shape, in the second M1 approaches
a narrow P1 `1` shape, and in the third the Ball approaches a centered
playfield wall. Only the two objects relevant to a lane are enabled there, so a
collision can be understood just by watching the screen rather than knowing the
TIA register map in advance. M0/P0 use the P0 color, M1/P1 use the P1 color, and
Ball/playfield use the playfield color. SECAM deliberately uses yellow, cyan,
and magenta for those three paths.

The objects move slowly toward their targets and then hold visibly in contact.
`CXCLR` is strobed only when the 64-frame animation cycle restarts. Consequently
each displayed register changes from `00` to its hardware-latched collision
value and stays there even after the instant of first contact. `OK` appears at
the end of the `CXBLPF` row only after all three expected collision bits have
latched. This intentionally demonstrates the TIA's sticky collision-latch
behavior rather than reducing several tests to an unexplained PASS/FAIL bit.

Audio channel 0 and channel 1 also emit short distinct alternating beeps.

The cartridge is intended as a field aid, not as a substitute for an oscilloscope
or a known-good controller when diagnosing intermittent analog hardware.
