```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Stella 7.0 static raster reference

`reference_stella_7.0.png` is the checked visual oracle for
`static_kernel_test.c26`. It was captured from the cartridge built by this tree
with Stella 7.0 using software video, the raw TIA image (`ss1x`), no TV filter,
no interpolation, no bezel, and player debug colors disabled.

Reference file:

```text
size:   320 x 228 pixels
sha256: 6ae39084ebe6a91a0e4b0f16546b45c953ede3903f23a86bd9183a4525c25776
```

The coordinates below are inclusive raw-PNG bounding boxes. They are not vague
"looks about right" descriptions:

| Feature | Source state | Expected bounding box |
|---|---|---|
| top playfield bar | playfield row 0 | `x=32..287, y=11..25` |
| bottom playfield bar | playfield row 10 | `x=32..287, y=171..185` |
| P0 paddle | `X=76, Y=78, height=7, NUSIZ0=$25` | `x=152..183, y=157..164` |
| M0 | `X=64, Y=30, height=5, NUSIZ0=$25` | `x=124..131, y=60..71` |
| ball | `X=84, Y=45, height=3, CTRLPF=$21` | `x=164..171, y=95..102` |
| M1 | `X=132, Y=60, height=7, NUSIZ1=$20` | `x=260..267, y=115..130` |
| P1 alien, overall | `X=108, Y=42, height=7` | `x=214..229, y=79..92` |
| score | `123456` | `x=122..213, y=191..198` |

The application reapplies `COLUP0`, `COLUP1`, `COLUPF`, `CTRLPF`, `NUSIZ0`,
and `NUSIZ1` before every draw because the retained kernel legitimately borrows
or clears several of those TIA registers. A first-frame-only picture is not a
stable reference.

The automated CPU/TIA-write tests remain the fast regression layer. This PNG
and table are the independent human-visible review layer; neither substitutes
for the other.
