```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Diagnostics

These examples exercise hardware, mapper, or toolchain behavior rather than
acting as renderer demonstrations or games.

- `6507_fingerprint/` probes deliberately unstable unofficial-opcode silicon
  behavior and displays the resulting fingerprint.
- `field_diagnostic/` is one 32K F4SC cartridge for NTSC, PAL, and SECAM. It
  reports console switches and controller input, draws a deterministic TIA
  object/playfield/color panel, checks collision latches, and alternates short
  tones between both TIA audio channels. Controller family is selected
  explicitly; the cartridge does not claim passive controller autodetection.
- `bankswitching/` contains the mapper diagnostic family, including F8/F6/F4
  and Superchip variants, FA/RAM Plus, 4KSC, CV, JANE, 0840, UA/UASW, 0FA0,
  E0, 3F/3E/3EX, FE, WD, DPC, FA2, FC, F0, and maximum-size stress cartridges.
