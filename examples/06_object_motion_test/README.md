```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Moving standard-kernel position reference

This cartridge is deliberately easy to judge by eye. A gold border and four
fixed vertical rulers remain visible while P0, P1, M0, M1, and BL move in five
separate vertical bands. All five traverse the complete public horizontal
coordinate range, **X=0 through X=159**, while using different integer speeds,
starting phases, and initial directions. Their motion is asynchronous without
giving different object classes different artificial travel limits.

| Object | Initial X | Range | Speed | Initial direction |
|---|---:|---:|---:|---|
| P0 | 0 | 0..159 | 1 | right |
| P1 | 159 | 0..159 | 2 | left |
| M0 | 37 | 0..159 | 3 | right |
| M1 | 121 | 0..159 | 4 | left |
| BL | 80 | 0..159 | 5 | right |

When a step would cross an endpoint, the example clamps to that endpoint for a
frame and then reverses. Thus every object visibly reaches both X=0 and X=159,
even when its speed does not divide the 159-coordinate span.

## Horizontal contract

The retained kernel's public X values are response-strobe coordinates. With
single-copy, normal-width players (`NUSIZ` player bits zero), Stella 7.0 renders:

```text
P0/P1 left edge = source X - 1 active pixel
M0/M1/BL left edge = source X - 2 active pixels
```

A one-unit source change must therefore move the rendered object exactly one
active pixel. An object moving at speed N must move N active pixels per ordinary
frame, except for the deliberate endpoint-clamp frame. Raw `ss1x` PNGs are 320
pixels wide, so each active-pixel change is two PNG columns. Calibration points
after linking are:

| Source X | player left edge | missile/ball left edge |
|---:|---:|---:|
| 20 | 19 | 18 |
| 40 | 39 | 38 |
| 60 | 59 | 58 |
| 80 | 79 | 78 |
| 100 | 99 | 98 |
| 120 | 119 | 118 |
| 140 | 139 | 138 |

`vcs_standard_motion.test` does not merely inspect the RAM X variables. For
320 consecutive frames it locks each object's RESP write cycle and HMxx fine-
motion nibble against the independent divide-by-15/reposition model. It also
requires every object to reach both X=0 and X=159. That catches 15-pixel
quantization, a dead fine-motion table, or a shortened object-specific range.

The separate `vcs_standard_pairwise.test` leaves this human-readable animation
unchanged and exhausts every pair of P0/P1/M0/M1/BL coordinates: ten pairs times
160 times 160, or 256,000 direct executions of the linked kernel's horizontal-
position routine. The other three objects remain at distinct sentinel X values,
so pair interactions and shared-scratch corruption cannot hide behind the
motion sequence used by this example.

## Vertical contract

The Y values are the public counter coordinates. The exact active TIA-write
scanlines, measured from rising VSYNC, are:

| Object | Y | Height | Active write scanlines |
|---|---:|---:|---|
| P0 | 18 | 7 | `56,58,60,62,64,66,68,70` |
| M0 | 34 | 5 | `95,97,99,101,103,105` |
| BL | 48 | 3 | `127,129,131,133` |
| M1 | 62 | 7 | `146,148,150,152,154,156,158,160` |
| P1 | 78 | 7 | `178,180,182,184,186,188,190,192` |

P0 and BL use the TIA vertical-delay pipeline, so displayed pixels may be one
raster later than their CPU writes. The test separately locks the write rows;
the visible playfield makes accidental whole-field shifts obvious.

The kernel borrows player colors for the score and clears `NUSIZ0/1`, so the
example reapplies all volatile color and geometry registers before every draw.

Build after building the toolchain:

```sh
make
```

The result is `object_motion_test.bin`, an exact 4096-byte unbanked NTSC ROM.
