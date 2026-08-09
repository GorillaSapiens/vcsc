```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Interactive 181-line multisprite with score below

Build with `make`. The cartridge draws 181 lines of multisprite gameplay, hands
off to an 11-line six-digit score, and keeps a standard 262-line NTSC frame.
Select cycles P0/P1..P5; the left joystick moves the selected sprite
horizontally and vertically within the 181-line profile's legal range; Reset
restores the scene. The score is `123456` after the gameplay handoff.

Joystick Up moves toward larger Y, Down toward smaller Y, and Y=0 is the fully clipped bottom edge. Public P1 X positions run from the left edge at 0 through the rightmost position at 159 without a vertical-sort-dependent horizontal shift.
