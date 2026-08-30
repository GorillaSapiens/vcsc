```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# FE / SCABS diagnostic

This cartridge exercises Activision's two-bank FE/SCABS hardware using the
released-cartridge JSR switching idiom rather than pretending FE has an F8-style
address hotspot.

With `S=$FF`, the low return-address push of a top-level `JSR` lands at `$01FE`
and arms FE's delayed latch. The following JSR target-high byte selects the
physical bank (`$C0-$DF` -> bank 1, `$E0-$FF` -> bank 0). The callee's `RTS`
reads the low return byte from `$01FE`; the following caller-high byte restores
the original bank before execution resumes.

The self-test calls an explicitly bank-1 function from bank-0 `main`, verifies
its return value and side effect, verifies that `S` returns to `$FF`, and then
renders green `pass` / `FE` or red `FAIL` / `FE`. `make play` forces Stella's
FE mapper with `-bs FE`.
