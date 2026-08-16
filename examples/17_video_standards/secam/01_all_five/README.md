```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# SECAM50 all-five interactive example

This is the maintained 192-line `all_five` gameplay component running inside
the native SECAM50 312-line scheduler. The gameplay kernel itself is unchanged:
17 measured pre-component helper lines precede it and an 18-line visible tail follows it.
The renderer owns its terminal WSYNC boundary, so this emulator-calibrated wrapper reaches
the 228-line visible boundary; it is intentionally not a naive 18 + 192 + 18 split. The source specifies its colors directly with `__builtin_secam_rgb(r,g,b)`;
the compiler maps the same NTSC all-five RGB intents to the nearest of the eight
distinct SECAM display colors.

Stella cannot reliably infer SECAM from 50 Hz timing. `make play` therefore
launches the ROM with `-format SECAM`; use that option for direct launches too.
`-tv` controls the emulated Color/B&W console switch and is not a video-format option.

Controls are the same as the NTSC example: Game Select cycles P0/P1/M0/M1/Ball,
the left joystick moves the selected object, and console Reset restarts.

