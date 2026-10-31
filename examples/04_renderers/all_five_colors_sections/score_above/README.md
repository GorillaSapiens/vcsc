```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Combined colours: score above

```sh
make play
```

Left joystick moves the selected object. Select cycles P0/P1/M0/M1/Ball;
Reset restores the initial scene. Right joystick left/right selects a decimal
place; up/down adds/subtracts its BCD weight. Release the right stick between
edits. Horizontal selection also changes the score colour.

Independent eight-row player colours and four-frame artwork move continuously
through the section seams. Heights must be nonnegative and even, total176, with
section one nonempty and section eight at least158 lines. Supported seams are
2/4/6/8/10/12/14/16/18, not later positions. Defaults are now
`2,2,2,2,2,6,2,158`, including adjacent16/18 boundaries. Earlier layouts, including
`4,0,2,0,4,0,0,166`, remain supported. Configure the eight
palettes and eleven visual playfield rows in
`examples/_common/all_five_colors_sections_score_interactive.c26`.

NTSC only. Ordinary 8K F8 ROM; preparation/controls in bank1, all drawing and
artwork in bank0. RAM **122/128**, including eleven stack bytes. The eleven-line
score composes above the 181-line gameplay preview through the usual handoff.
This is not the general combined renderer.
