```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Cooperating layers, score above

```sh
make
make play
make clean
```

A12-line two-plus-two score, eight frame-owner-blanked positioning lines, then
172 gameplay lines (64+64+44). Objects slowly traverse both scenery seams; both
runtime scores increase. The fixed positioning entry requires all X0..119.
Uses56/128 RAM bytes, including stack, and one4K bank. Edit `main.c26`; no other
example leaf is required. See the [family guide](../README.md) for contracts.
