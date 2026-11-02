```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Private display-wide scheduling proof

`fine_global_plan.pl` plans eight even section heights totaling 192. It allocates
four route-byte writes across both row parities, avoiding palette-write slots.
Row-boundary palettes also need two M1 refills. They normally use the preceding
opposite-parity row's dead destination lane. If that parity has no free slot,
pair six's now-dead final M1 shift plus its timing pad supplies a same-parity
refill for row+2. The forced palette-style pair writes an unchanged palette where
there is no seam. No additional RAM or scanline cycles are needed.

With a boundary, at most six other seams can occupy palette slots. Exhausting
one parity therefore leaves all six slots free in the other: four route bytes,
one cross-parity M1 refill, and the pair-six fallback fit. Without a boundary,
at most seven palette slots are occupied and only four route slots are needed.
The planner test exhausts every parity/phase union with up to six occupied slots
plus a boundary, as well as 2,000 seeded full-height geometries.

`fine_global.pl` lowers that plan using the certified pair/boundary templates:

- Four reusable route bytes, not a return vector growing with section position.
- Page-contained relocated route tables; no `main` offsets or runtime search.
- Direct BL reads/shifts in boundary HBLANK; M1 reads there when no boundary
  palette is required, otherwise lifetime-safe prefetches.
- Shared non-writing packed tails; only actual phase-14 palette events get a
  palette-specific tail. The terminal path remains independent.
- Final assembler `.same`/`.cross` assertions and page/layout contracts remain
  mandatory. The original lowering uses the private byte-layout model; the
  procedure lowering no longer needs it.
- `.scope` provides zero-byte relocated entry anchors in the *same* layout.
  `.proc` cannot do this for a zero-length anchor: it creates an independently
  placed layout in o26. It **can** own a complete renderer block.

`fine_global_procedures.pl` puts whole normal/packed/boundary blocks in procedures
and lets the linker solve their branch contracts. Exported scoped entry anchors
connect them. The terminal block jumps back to the parent's close/return code at
equal cycles, preserving the independent caller continuation. The route table is
one page-contained layout. This exposed and now regression-tests the assembler's
need to sort relocation records when source resumes an earlier packed layout.

`global_schedule.c26` is the **private language-level front end**: eight `.c26`
height parameters, existing assembler macros/equates, no RAM, data or executable
planning code. It reserves M1 refills first, then assigns own/cross-row routes.
`c26_schedule_plan.pl` is only a test bridge that decodes its constant records;
`fine_global_c26` rendering gates actually consume those records. It is not a
user input format or the finished configurable renderer. No JSON is involved.

The `vcs_all_five_colors_sections_global_*.test` gates cover dense first/middle/
late/terminal rows, mixed seams, row-boundary palettes, line190, nonempty edge
poses, runtime object controls, uniform PF, and a rejected palette mutation.
Their references are independently drawn ordinary-renderer cartridges. RAM and
drawing-bank budgets are checked in each linked map. A 32-geometry compile matrix
checks both lowering paths. The `.c26` allocator is independently checked for
35 geometries, zero RAM and zero planning instructions, then certified with
moving RGB/control cases. Palette/refill mutations must fail exact RGB.

## Not yet a public renderer

Renderer lowering is still a private test transformation. The scheduling front
end now lives in `.c26`, but a static `.c26` renderer has not yet replaced that
test transformation. It still folds two alternating playfield patterns. Score
composition, full interactive state/stack budgets and arbitrary playfield rows
have not been proved. The editable previews retain their previous limits.

Next: connect the `.c26` scheduling constants to static assembler-conditional
renderer templates with complete procedure blocks, removing the test bridge and
byte-layout helper from the user path. Then prove live PF/storage intervals and
independent score handoffs before public extraction. Do not resume seam28/seam30
prefix extensions.
