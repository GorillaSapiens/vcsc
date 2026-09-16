```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# SECAM50 blank frame

Minimal SECAM 50 Hz cartridge using the public `frame_secam.c26` front end and
`__builtin_secam_rgb(r,g,b)` compile-time color matcher. It leaves all 228 visible
lines in the closest available match to the usual NTSC dark-blue background
(`#12139d`) and is the smallest public example of the standard frame contract.
The background
RGB value is mapped to one of the eight SECAM display colors at compile time.

Stella cannot reliably infer SECAM from 50 Hz timing. `make play` therefore
launches the ROM with `-format SECAM`; use that option for direct launches too.
`-tv` controls the emulated Color/B&W console switch and is not a video-format option.

