```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Multicolor Full Static

This is the static example for the official scoreless 192-line multicolor
P0+P1+Ball kernel.

It restores the already-proven full-height smoke scene that existed before the
public examples were reorganized. It was not redesigned for this example.

The cartridge contains:

- all twelve playfield rows;
- eight independently colored rows for P0 and P1;
- a visible Ball;
- no score or missiles; and
- stable 262-line NTSC frames.

The source uses readable binary playfield/sprite rows and named NTSC colors.
The regression compares its visible TIA trace against the older independent
raw-byte smoke fixture and locks a fresh Stella 7.0 snapshot of the built ROM.

Build with `make`, then run `multicolor_full_static.bin` in Stella.
