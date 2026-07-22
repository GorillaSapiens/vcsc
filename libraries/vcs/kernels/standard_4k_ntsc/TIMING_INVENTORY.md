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
and the immutable 48-byte playfield at `$F754..$F783`.  The source presently has
page anchors before the main visible loop, last-line kernel, score loop, and
score table.  These addresses are observations, not new ABI guarantees.

Inventory summary
-----------------

The baseline contains 13 relative branches, 30 indexed reads, 11 indexed indirect pointer reads, 28 explicit padding sites, four alignment directives,
and 19 source-level unofficial-opcode sites.  The unofficial sites are:

* 11 `DCP`: decrement an object vertical counter and compare it with height in
  one five-cycle read-modify-write instruction;
* 5 `LAX`: three score-byte pointer-setup loads and two visible score-glyph
  loads into A and X;
* 1 `SBX`: add four to the inherited biased playfield index and obtain loop
  termination from the sign flag;
* 1 `ASR`: mask/shift a score nibble during pointer setup;
* 1 `NOP.z`: the three-cycle zero-page delay selected by odd `SLEEP` durations.

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
