# Tigervision 3EX

This profile targets the 3EX implementation in Stella 7.0: up to 256 physical
2K ROM banks (512K ROM) and 256 independently selected 1K RAM banks (256K RAM).
ROM switching and compiler-managed `$swapram` use the same `$3F`/`$3E` windows
as classic 3E.

Stella 7.0 stores `(RAM bank count - 1)` in ROM byte `size-6`.  That byte
overlaps the third byte of VCSC's ordinary tail-signature location, so the
physical tail is a 3EX-specific exception: the linker writes the RAM-count
metadata there instead of the topology signature's third byte.  Stella's
detector requires two `3EX` byte strings anywhere in the image; the maintained
bankcall template carries two inert copies after its terminal indirect jump.

The compiler-visible swapram region is 256K with a 1K bank size.  Accesses are
lowered through `swapram_read1`/`swapram_write1` helpers that execute from the
permanently visible final ROM bank.
