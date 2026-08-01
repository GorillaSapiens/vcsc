```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# all_five_181 right-justified six-digit score below

This cartridge composes the 11-line right-justified six-digit score after the 181-line
`all_five_181` gameplay renderer, with `vcs_ntsc_component_handoff()` at the
boundary. The visible field is exactly 192 lines.

It starts with score `123456` at the right edge and the established certification positions for
P0, P1, M0, M1, and Ball.

## Controls

- Game Select cycles the selected gameplay object. The left joystick moves the selected object in X/Y; Game Reset restarts through `$FFFC`.
- Use the right joystick to select and change decimal digits.

Build with `make`. The result is `all_five_181_right_justified_score_below_interactive.bin`.
