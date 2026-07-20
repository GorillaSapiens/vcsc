```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Six-digit score

`03_six_digit_score` displays a centered white six-digit score on a medium-blue
Atari VCS background. It starts at `123456` and increments once every 20 NTSC
frames.

The persistent score is an ordinary VCSC packed-decimal value:

```vcsc
bcd24_t score := 123456;
```

`score++` therefore uses the 6507's decimal-mode `ADC` chain and wraps after
`999999`. VCSC owns the score and frame cadence; the visible display is an
adaptation of the retained batari Basic standard score mini-kernel because its
TIA writes must remain cycle-counted assembly. The adapted kernel and default
font derive from the retained batari Basic material provided under CC0.

The kernel uses both players in three-close-copy mode to draw six characters.
It temporarily repurposes the hardware stack pointer as one graphics register,
but saves it first, performs no call or push while it is borrowed, and restores
it before returning to compiled code. The two `LAX` instructions require the
assembler's supported unofficial-opcode table, enabled by `-Wa,--illegals`.

The font is deliberately separate:

- `score_font.s` exports `score_font` and selects the active include.
- `fonts/default.inc` contains ten consecutive eight-byte glyphs.

To add another font, create another include with the same 80-byte layout and
change the `.include` line in `score_font.s`. The setup builds six complete
16-bit glyph pointers, so alternate fonts do not require page alignment.

Build after building the toolchain:

```sh
make
```

The result is `six_digit_score.bin`, an exact 4096-byte unbanked cartridge.
