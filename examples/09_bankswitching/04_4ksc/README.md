```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# 4KSC Superchip diagnostic

Build with `make`. The cartridge is exactly 4096 bytes and uses the Atari 4KSC
layout: ordinary ROM is visible at `$F100-$FFFF`, while the first `$100` bytes
of the 4K cartridge window are the standard 128-byte Superchip write/read ports
(`$F000-$F07F` write, `$F080-$F0FF` read).

The final four image bytes at `$0FF8-$0FFB` before the reset/IRQ vectors carry
the VCSC mapper signature `4KSC`. Its trailing `SC` also satisfies Stella's
4KSC autodetection convention, so ordinary `make play` needs no forced mapper.

The diagnostic allocates all 128 Superchip bytes, verifies DATA initialization
and BSS clearing, then writes and reads sentinels at both ends and the middle of
the device. On success it displays lowercase `pass` on a green background with
`4KSC` centered below it. Any failure displays uppercase `FAIL` on dark red.

The automated regression also starts split RAM with a hostile nonzero fill and
performs a console-style reset before accepting PASS, proving that normal VCSC
startup reinitializes Superchip DATA/BSS on every reset.
