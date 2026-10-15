```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Colour sections, score above

Run `make`, then `make play` (Stella). This builds an **8K F8** cartridge.

- **Left joystick:** move the selected object, clamped to X=0..159, Y=0..87.
- **Game Select:** cycle P0 → P1 → M0 → M1 → ball, once per press.
- **Right joystick left/right:** select the score digit; selection cycles the
  score colour. Digit zero is the units digit.
- **Right joystick up/down:** add/subtract the selected digit's decimal weight,
  once per deflection; release to re-arm. Decimal carry/borrow and six-digit
  wrap match the existing interactive examples.
- **Game Reset:** restore positions, P0 selection and score `123456`.

Edit the eight sections directly in the `.c26` instantiation. Their even heights
total **176 gameplay scanlines**; fixed setup/tail complete the 181-line gameplay
component, and the score occupies 11 lines. Both players use the same four-frame,
eight-row sprites and `(X ^ Y) & 3` frame selection as
`examples/_common/all_five_181_interactive_common.c26`. There is no automatic motion.

The score and raster stay in bank0; controls and VBLANK preparation use bank1.
The first playfield row is mirrored for preparation in the shared example body.
If editing that row, update both copies. All 128 RAM bytes are allocated.
