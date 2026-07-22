```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Moving standard-kernel position reference

This cartridge is deliberately easy to judge by eye. A gold border and four
fixed vertical rulers remain visible while P0, P1, M0, M1, and BL move in five
separate vertical bands. Every object advances **one source X coordinate on
every frame**. The old diagnostic intentionally skipped frames at different
rates, which made correct movement look jerky and was a poor test.

The objects use distinct ranges and starting directions, so their reversals do
not occur in lockstep:

| Object | Initial X | Range | Initial direction |
|---|---:|---:|---|
| P0 | 20 | 12..144 | right |
| P1 | 140 | 20..148 | left |
| M0 | 48 | 24..136 | right |
| M1 | 112 | 8..128 | left |
| BL | 80 | 32..120 | right |

## Horizontal contract

The retained kernel's public X values are response-strobe coordinates. With
single-copy, normal-width players (`NUSIZ` player bits zero), Stella 7.0 renders:

```text
P0/P1 left edge = source X - 1 active pixel
M0/M1/BL left edge = source X - 2 active pixels
```

A one-unit source change must therefore move the rendered object exactly one
active pixel. Raw `ss1x` PNGs are 320 pixels wide, so each active-pixel change
is two PNG columns. Calibration points after linking are:

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
20 consecutive frames it locks each object's RESP write cycle and HMxx fine-
motion nibble against the independent divide-by-15/reposition model. That is
the regression which catches 15-pixel quantization or a dead fine-motion table.

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
