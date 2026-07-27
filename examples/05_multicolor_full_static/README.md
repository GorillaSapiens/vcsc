```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Multicolor Full Static

This is the certified static example for the official scoreless 192-line
multicolor P0+P1+Ball kernel.

The frame is intentionally diagnostic rather than decorative:

- a twelve-row asymmetric playfield with a genuine bottom border;
- a clear object lane so the players are not hidden by playfield pixels;
- eight independently colored rows for each player;
- fixed P0, P1, and Ball positions; and
- no score, missiles, or motion code.

The source uses readable binary glyphs and named NTSC colors. Regression
coverage compares the cartridge against an independent raw-byte golden source,
checks the complete TIA display trace—including all twelve playfield rows—and
locks a reviewed Stella 7.0 reference image under
`test/fixtures/vcs_examples/05_multicolor_full_static/`.

Build with `make`, then run `multicolor_full_static.bin` in Stella.
