```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Official all-five 192-line scoreless component

`all_five_192.c26` is the full-height official-opcode P0/P1/M0/M1/BL
lifecycle component. It uses the predecessor's full-height twelfth-row path and holds its final
state through the eleven lines otherwise reserved for a score, for exactly 192
visible scanlines and owns no score state, font, VSYNC, VBLANK, or RIOT timer.

Instantiate it after defining a page-contained 48-byte `INSTANCE_playfield`:

```c
template "kernels/all_five_192/all_five_192.c26" as game
```

The profile is intentionally distinct from `all_five_181`: it cannot share the
standard 192-line visible field with the eleven-line score. `draw()` clears TIA
gameplay state at the final boundary; `overscan()` restores application-visible
Y coordinates after the application has asserted VBLANK.

RAM contract: 19 public bytes plus 51 private bytes, 70 bytes total. The
application supplies the 48-byte playfield and player graphics in ROM.
