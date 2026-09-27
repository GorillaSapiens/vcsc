```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Two-stripe 192-line renderer example

This is the current runnable stripe prototype for the consolidated gameplay
renderer.  It uses `stripes:=2` to draw two equal 96-line bands with independent
playfield bytes and independent `COLUPF`/`COLUBK` colors while P0, P1, M0, M1,
and Ball remain active.

Run `make` to build the 4K ROM and `make play` to launch it in Stella.

The public stripe ABI is still being completed.  At this checkpoint two equal
stripes are the supported demonstration; arbitrary even heights and `N > 2`
remain roadmap work.  The renderer's future public name is `gameplay`; the
existing `all_five` path remains until that API migration is ready.
