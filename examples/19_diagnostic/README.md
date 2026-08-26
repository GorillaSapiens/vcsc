```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Field diagnostic cartridge

`01_diagnostic/` is a single 32K F4SC field-diagnostic cartridge for NTSC,
PAL, and SECAM consoles. It reports console switches and controller input,
draws a deterministic TIA object/playfield/color panel, checks collision
latches, and alternates short tones between both TIA audio channels.

The cartridge deliberately does **not** claim controller-type autodetection.
Joystick and driving-controller inputs overlap electrically, an idle keypad has
no unique passive signature, and keypad scanning requires the joystick-direction
pins to become outputs. Select the controller family being tested explicitly.
