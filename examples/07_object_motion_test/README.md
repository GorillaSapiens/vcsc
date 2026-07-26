```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Moving all-five component, score below

This example composes the official `all_five_181` gameplay component above the
independent eleven-line score. P0, P1, M0, M1, and Ball move asynchronously
through the full public X=`0..159` range at different speeds. The score remains
below gameplay, and `main()` owns all frame scheduling and lifecycle order.

Build with `make` and run `object_motion_test.bin` in Stella.

The playfield uses `VCS_PLAYFIELD_ROW()` so each 32-bit visual-binary literal
reads left-to-right on screen; all bit reversal and byte extraction is folded at
compile time.
