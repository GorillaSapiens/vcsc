```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Faithful retained legacy player-color kernel

This profile is a reference baseline, not a redesigned gameplay component. It
selects the retained legacy NTSC standard kernel with P0, P1, Ball, per-row
player colors, and the integrated six-digit score. It preserves the original
unofficial opcodes, instruction order, monolithic frame ownership, score path,
and entry/exit behavior.

Instantiate it after `vcs.c26`:

```vcsc
template "kernels/faithful_legacy_playercolors/faithful_legacy_playercolors.c26" as legacy
```

The application supplies page-contained `legacy_playfield[48]` and graphics and
color tables, initializes the instance state, and repeatedly calls
`legacy_drawscreen()`. Build with `-Wa,--illegals` and
`faithful_legacy_playercolors.cfg`.

`faithful_legacy_playercolors_reference.s26` is the independently linked audit
oracle mechanically selected from the retained source. The regression compares
its complete visible TIA-write schedule and 20,140-cycle frame period against
the template port. Values written to TIA strobe registers are ignored because
the hardware ignores those data bits and page placement can change the value
left in A without changing behavior.
