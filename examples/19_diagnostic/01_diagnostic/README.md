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

## TIA self-test panel

The final text row reports `TIA PASS` only when the cartridge observes the
expected player/missile and ball/playfield collision latches. Beneath it, the
hardware panel draws P0, P1, both missiles, the ball, and a reflected playfield
using colors selected for the active television standard. Audio channel 0 and
channel 1 emit short distinct alternating beeps.

The cartridge is intended as a field aid, not as a substitute for an oscilloscope
or a known-good controller when diagnosing intermittent analog hardware.
