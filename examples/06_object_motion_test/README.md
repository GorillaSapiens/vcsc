```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Moving standard-kernel object diagnostic

This cartridge gives every standard-kernel TIA object its own fixed vertical
band while P0, P1, M0, M1, and BL move horizontally at different rates and
phases. Each object bounces between X coordinates 8 and 148. The deliberately
asynchronous motion makes stale positions, shared counters, and object mix-ups
obvious instead of letting them hide in a pleasant static scene.

The vertical contract is stated in frame scanlines measured from the rising
edge of VSYNC. These are the TIA register-write rows produced by the retained
standard-kernel counter convention:

| Object | Y | Height | Expected active write scanlines |
|---|---:|---:|---|
| P0 | 18 | 7 | `56,58,60,62,64,66,68,70` |
| M0 | 34 | 5 | `95,97,99,101,103,105` |
| BL | 48 | 3 | `127,129,131,133` |
| M1 | 62 | 7 | `146,148,150,152,154,156,158,160` |
| P1 | 78 | 7 | `178,180,182,184,186,188,190,192` |

P0 and BL use the TIA's vertical-delay pipeline, so a screenshot renderer may
present the latched pixels one raster later than the corresponding CPU write.
The table is the exact kernel-side contract used by the automated regression;
it does not depend on window scaling, cropping, or somebody eyeballing a PNG.

Build after building the toolchain:

```sh
make
```

The result is `object_motion_test.bin`, an exact 4096-byte unbanked NTSC ROM.
