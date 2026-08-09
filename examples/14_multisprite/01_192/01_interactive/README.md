```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Interactive 192-line multisprite diagnostic

Build with `make`. Select cycles P0 and the five logical sprites multiplexed
through P1. The left joystick moves the selected sprite left/right; Reset
restores the scene. Vertical positions remain fixed because they are part of the
retained cycle-proven multiplexing schedule.
