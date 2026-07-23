```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

Standard 4K NTSC timing inventory
=================================

This is the task-20e baseline taken before page-placement or opcode-legalization
work.  `standard_4k_ntsc_timing_inventory.tsv` is generated reproducibly by
`inventory.pl` from the normalized macro and kernel sources.  Later tasks must
regenerate the TSV and explain intentional row changes rather than silently
altering a cycle-sensitive path.

Current linked layout
---------------------

The `examples/05_static_kernel_test` baseline map places `KERNEL_CODE` at
`$F300..$F5FF` (size `$0300`), `KERNEL_RODATA` at `$F600..$F657` (size `$0058`),
and the immutable 48-byte playfield at `$F100..$F12F`.  The source presently has
page anchors before the main visible loop, last-line kernel, score loop, and
score table.  These addresses are observations, not new ABI guarantees.

Inventory summary
-----------------

The current source contains 28 relative branches, 35 indexed reads, 11 indexed indirect pointer reads, 34 explicit padding sites, four alignment directives,
and no source-level unofficial-opcode sites.

Task 20o originally classified the retained forms and locked their bytes and
cycles. The generated `standard_4k_ntsc_unofficial_opcodes.tsv` is now empty
apart from its header.

* task 20p removed all 5 `LAX` sites;
* task 20q removed all 11 `DCP` sites; and
* task 20r replaced the final `SBX`, `ASR`, and `NOP.z` sites. The legal row
  advance consumes two cycles from each transition pad, the score-nibble helper
  adds two blanking cycles per call under the fixed VBLANK timer, and odd
  `SLEEP` durations use three-cycle `BIT VSYNC` with dead flags.

Page-sensitive classes
----------------------

A taken relative branch gains a cycle when source and destination are on
opposite pages.  Absolute indexed reads and `(zp),Y` reads can gain a cycle when
the effective address crosses a page.  The latter additionally depend on a
valid zero-page pointer pair.  `SLEEP`, explicit `NOP`, and page anchors are
recorded because later legal-opcode and zero-based-index work may exchange those
padding cycles, but must not accidentally alter unrelated paths.

Regeneration
------------

From this directory:

```
./inventory.pl > standard_4k_ntsc_timing_inventory.tsv
```

The regression reruns that command and requires byte-for-byte equality with the
committed TSV.  The inventory is intentionally lexical: it records every
candidate operation, including paths excluded only by runtime state.  Exact
linked branch addresses and indexed ranges become separate metadata in tasks
20k and 20m.
