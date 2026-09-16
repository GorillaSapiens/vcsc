```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# 3F diagnostic

This 8K cartridge certifies classic Tigervision 3F bankswitching. The lower
`$1000-$17FF` 2K window is selected by the value written in the TIA
`$00-$3F` page; the upper `$1800-$1FFF` 2K window is always the final physical
ROM bank. Power-on selects physical ROM bank 0 in the lower window.

The self-test executes probes in lower physical banks 0, 1, and 2, explicitly
switches among them, and returns to fixed-bank control after every call. The
fixed final bank owns startup, self-test control, and the visible diagnostic.
The cartridge displays a large `pass` or `FAIL` with small `3F` underneath.

Classic 3F claims low TIA addresses as mapper writes. The VCSC 3F profiles
therefore bind the normal TIA register names to their equivalent `$40-$7F`
mirror, so ordinary source can continue to use `VSYNC`, `COLUBK`, `GRP0`, and
other canonical names without accidentally losing TIA accesses under Stella's
3F implementation.

Stella should be forced to 3F:

```sh
make play
```
