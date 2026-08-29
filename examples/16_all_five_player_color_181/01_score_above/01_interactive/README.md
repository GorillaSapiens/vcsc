```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Interactive score-above diagnostic

The editable six-digit score is above the 181-line combined gameplay field. P0 and P1 retain independent eight-row color tables while P0, P1, M0,
M1, and Ball remain independently movable.

Use **Game Select** to cycle P0 -> P1 -> M0 -> M1 -> Ball. The **left
joystick** moves the selected object in both axes. On the **right joystick**,
Left/Right select one of the six decimal digits, Up/Down decrement/increment the
selected digit, and horizontal selection advances the score hue. A new score
action requires returning the right joystick fully neutral first. **Reset**
restores the initial scene and `123456`. The cartridge remains unbanked 4K at
**4051/4090 ROM bytes** (39 free) and **124/128 RAM bytes** (4 free).

Build with `make`.
