```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# OmniCart OMNI diagnostic

`omni_diagnostic.c26` is the public PASS/FAIL cartridge for the planned
OmniCart PHM `OMNI` direct-addressing profile. It displays lowercase `pass` on
a green background when all checks succeed and uppercase `FAIL` on a dark-red
background otherwise, with `OMNI` centered below the result.

OMNI is not conventional bank switching. The generated 32K image contains eight
4K file chunks mapped directly to logical `$1000`, `$3000`, `$5000`, `$7000`,
`$9000`, `$B000`, `$D000`, and `$F000`. `$1000-$1FFF` is the common `cartram`
region; the other seven islands hold code and constants. There are no selector
hotspots, wrong-bank startup states, vector bridges, or call trampolines.

The diagnostic consumes all 4096 bytes of `cartram`, verifies normal DATA/BSS
startup initialization, writes persistent sentinels, and executes a nested direct
call chain through every RO island before returning normally. Each probe also
reads constants across island boundaries, so both control transfers and data
references exercise ordinary 16-bit logical addressing.

No released Atari cartridge or emulator currently implements OmniCart PHM's
recovered upper address bits, so there is intentionally no `make play` target.
`make` builds the 32K diagnostic for toolchain inspection and future OmniCart
hardware. VCSC's automated regression suite executes the same self-test through
`vcsc-sim` using `vcs_omni_32k.cfg`, which models the direct logical layout but
no mapper state because OMNI has none.
