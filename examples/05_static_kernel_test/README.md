```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Static all-five component, score above

This example composes the official `all_five_181` gameplay component with the
independent eleven-line six-glyph score above it:

```text
11 score lines + 181 gameplay lines = 192 visible NTSC lines
```

P0, P1, M0, M1, Ball, the asymmetric playfield, and a fixed `123456` score are
all visible. `main()` owns the frame scheduler and invokes both complete
lifecycle interfaces. Build with `make` and run `static_kernel_test.bin` in
Stella.
