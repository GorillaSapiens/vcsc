```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Combined colours: score below

```sh
make play
```

Controls, configuration and the supported fixed layout are the same as
[`score_above`](../score_above/). RAM **122/128**, including eleven stack bytes;
ordinary 8K F8 ROM and one drawing bank, with no mirrored graphics.

Gameplay returns after its final WSYNC. The application then performs the normal
component handoff, draws the independent eleven-line score, and starts overscan:

```vcsc
game_draw();
vcs_ntsc_component_handoff();
score_draw();
vcs_ntsc_begin_overscan();
```

There is no gameplay-owned score callback or overscan start. Omitting the handoff
is rejected by an exact-RGB mutation test. The older coupled-terminal fixture
remains regression-tested but is no longer used by this runnable example.

This remains a bounded NTSC preview, not a general combined renderer. Heights
are even/nonnegative, total176, first section nonempty and eighth at least162.
Middle slots may be empty, e.g. `4,0,2,0,4,0,0,166`. Boundaries after line14 are
rejected. The original `2,2,2,2,2,2,2,162` layout remains the default.
