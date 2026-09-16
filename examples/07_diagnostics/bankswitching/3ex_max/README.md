```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Maximum-size 3EX diagnostic

This is the Stella-compatible maximum-size Tigervision 3EX PASS/FAIL diagnostic:

- 256 physical 2K ROM banks = 512K ROM. Banks 0 through 254 are selectable at
  `$1000-$17FF`; bank 255 is fixed/startup at `$1800-$1FFF`.
- 256 independently selected 1K RAM banks = 256K RAM. RAM reads use
  `$1000-$13FF`; writes use `$1400-$17FF`; `$3E` selects the RAM bank.
- ROM byte `size-6` contains `$FF`, Stella's `RAM bank count - 1` metadata.
- Two Stella-detectable `3EX` strings are embedded in the fixed final bank, separated so Stella's detector counts both hits.

The ROM self-test executes every ordered source/destination pair among the 255
selectable lower banks: 255 x 255 = 65,025 calls. Same-bank pairs use direct
JSR. Cross-bank pairs use VCSC's generic three-byte bankcall descriptor through
a seven-byte inline-call stub copied into RIOT RAM. Every lower bank also calls
the fixed bank once, and the fixed bank calls every lower bank once, producing
65,535 counted target calls total. Destinations verify physical ROM-bank
identity, callers verify source restoration, and the test checks hardware-stack
balance.

## 256K RAM torture

After the ROM matrix, the scheduler fills every byte of all 256 RAM banks and
then reads every byte back through ordinary compiler-managed `$swapram` lvalues.
The accessors therefore exercise `swapram_write1` and `swapram_read1`; the
diagnostic does not bypass the compiler with raw mapper RAM accesses.

The data stream is a maximal 16-bit Galois LFSR with seed `$ACE1` and tap mask
`$B400`. It is continuous across all 256K rather than restarting at RAM-bank
boundaries, and each stored byte is additionally XORed with the logical RAM
object number. `make_torture.pl` proves the LFSR period is 65,535, proves all 256
1K generated bank images are distinct, and checks that the 256K endpoint is
`$1C4E`. Mirrored, aliased, or incorrectly selected RAM therefore cannot pass by
accident.

The 256 compiler-visible 1K RAM objects are split across eight C26 accessor
translation units and eight backing-storage assembly objects so no O26 packed
BSS namespace exceeds 64K. Their linker-assigned physical swapram-bank order is
not a source-level numbering contract; the regression requires a bijection over
all physical banks 0 through 255.

## Display and build

While testing, the cartridge keeps a stable 262-scanline NTSC frame with a blue
background and a `wait` spinner. The final screen uses the standard large
`pass`/`FAIL` line with exactly `3EX max` beneath it. Work is sliced into VBLANK
and overscan; ROM batches are 10/8 operations and RAM batches are 4/3 bytes.

The committed generated torture and font files mean a normal build does not
require Perl. Because this maximal cartridge has many independent translation
units, use parallel make for a fast rebuild:

```sh
make -j8
stella -bs 3EX 3ex_max_diagnostic.bin
```

`make torture` regenerates the torture sources; `make fonts` regenerates the
committed font subsets and then the torture payloads that embed those fonts.
