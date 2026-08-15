```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Two keypad controllers

This example reads one Atari CX50-style 12-key keypad in each controller port.
The left keypad controls the white P0 glyph centered in the left half of the
screen; the right keypad controls P1 in the right half. The background uses the
project's blue and both glyphs are white.

Each displayed character comes from a custom 13-glyph 8x10 subset trimmed from
our 8x16 Big font: `1` through `9`, `*`, `0`, `#`, plus an empty rectangle
used when no key is held. The source Big glyphs all had two blank rows above and four below,
so the example stores only the ten potentially visible rows per glyph; the
surrounding blank scanlines keep the characters in the same vertical position.
If more than one key is held, the display shows the first key in
row-major order while `keypad_controller.c26` still reports every held key in its 12-bit
`keys` mask.

The hardware is a 4x3 switch matrix. Pins 1 through 4 are active-low row
outputs; the three columns return through INPT0/INPT1/INPT4 on the left port or
INPT2/INPT3/INPT5 on the right. Software treats all three as ordinary boolean
matrix inputs: after the selected row has settled, a pressed key reads LOW on
its column. There is no paddle-position measurement loop here. Atari's
programming documentation requires about 400 microseconds between changing the
row outputs and reading the TIA input ports, so this example selects the same
row on both keypads during overscan, waits seven NTSC scanlines (about 445
microseconds), and then samples both sides. One row is scanned per frame, so a
complete stable snapshot and the `pressed`/`released` edge masks are committed
every four frames.

`libraries/vcs/keypad_controller.c26` is parameterized with `port:=0` or
`port:=1`. It only changes the selected port's SWCHA/SWACNT nibble; the other
port is preserved. The public example keeps all keypad work in overscan so
input-dependent branches cannot disturb the VBLANK-to-visible deadline.

Current Stella auto-detects controller types by recognizing ROM access idioms.
The component therefore uses recognizable BIT/branch reads for the keypad INPT
registers while preserving SWCHA through an indexed read that does not falsely
advertise joystick-direction input. This makes the public ROM classify as
Keyboard on both ports instead of Joy2BPlus.
