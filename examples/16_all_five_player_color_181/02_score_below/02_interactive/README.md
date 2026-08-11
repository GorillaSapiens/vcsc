```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Interactive score-below diagnostic

The fixed six-digit score is below the 181-line combined gameplay field. P0 and P1 retain independent eight-row color tables while P0, P1, M0,
M1, and Ball remain independently movable.

Use **Game Select** to cycle P0 -> P1 -> M0 -> M1 -> Ball. The **left
joystick** moves the selected object in both axes. The score remains fixed at
`123456` so the cartridge can fit the combined renderer, score, and useful
five-object interaction in an unbanked 4K ROM. It links at **4043/4090 ROM bytes**
(47 free) and **116/128 RAM bytes** (12 free).

Build with `make`.
