```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Provisional retained legacy player-color baseline

This profile is a provisional retained-source baseline, not yet the external
gold standard and not a redesigned gameplay component. It selects the retained
legacy NTSC standard-kernel branches for P0, P1, Ball, per-row player colors,
and the integrated six-digit score. It preserves the selected unofficial
opcodes and instruction order, but the pristine upstream Atari 2600 BASIC 1.9
cartridge has shown that the current VCSC state layout does not yet preserve
all stock RAM aliases or the exact stable frame period.

Instantiate it after `vcs.c26`:

```vcsc
template "kernels/faithful_legacy_playercolors/faithful_legacy_playercolors.c26" as legacy
```

The application supplies page-contained `legacy_playfield[48]` and graphics and
color tables, initializes the instance state, and repeatedly calls
`legacy_drawscreen()`. Build with `-Wa,--illegals` and
`faithful_legacy_playercolors.cfg`.

`faithful_legacy_playercolors_reference.s26` is a separately linked
**retained-source audit**, not an independent gold oracle. The existing
regression still usefully proves that the template matches that audit's visible
TIA-write schedule and 20,140-cycle frame period.

The actual external oracle lives under
`test/oracles/pristine_basic_v1.9_playercolors/` and was built with pristine
upstream BASIC 1.9 plus DASM 2.20.14.1. It currently exposes two stop-ship gaps:
stock upstream BASIC has a 20,064-cycle (264 raw line) stable frame, and its
first visible mismatch is HMM0 because `player0colorstore` aliases `missile0x`
in the stock selected-profile RAM map. Values written to TIA strobe registers
remain data-insensitive, but HMM0 is not a strobe and its value is behaviorally
significant.

Do not use this template as a derivation oracle until roadmap task 22i4b0b turns
the known-gap regression into a positive comparison against the pristine ROM.
