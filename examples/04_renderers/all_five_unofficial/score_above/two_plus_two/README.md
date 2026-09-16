```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# all_five_181_unofficial independently positioned left/right two-plus-two score above

This cartridge composes the 11-line independently positioned left/right two-plus-two score before the 181-line
`all_five_181_unofficial` gameplay renderer, with `vcs_ntsc_component_handoff()` at the
boundary. The visible field is exactly 192 lines.

It starts with left field `12` at x=16 and right field `34` at x=104 and the established certification positions for
P0, P1, M0, M1, and Ball.

## Controls

- Game Select cycles the selected gameplay object. The left joystick moves the selected object in X/Y; Game Reset restarts through `$FFFC`.
- The bright field is selected. Right fire toggles left/right; right-joystick left/right moves the selected field (the right field reaches X=144, ending at the screen edge) and up/down changes its packed-BCD value. Each joystick direction acts immediately once per press; holding does not repeat, and the stick must return fully to neutral before another direction press can act.

Build with `make`. The result is `all_five_181_unofficial_two_plus_two_score_above_interactive.bin`.
