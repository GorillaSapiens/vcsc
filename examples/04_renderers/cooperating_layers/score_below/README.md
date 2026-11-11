```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Cooperating layers, score below

```sh
make
make play
make clean
```

176 gameplay lines (64+64+48), a12-line two-plus-two score, then four blank tail
lines. Objects slowly traverse both scenery seams; both runtime scores increase.
Uses128/128 RAM bytes, including stack, and one4K bank. Score pointers occupy
only mask bytes88..95, outside the active gameplay stream. Edit `main.c26`;
no other example leaf is required. See the [family guide](../README.md).
