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

`static_global.c26` now embeds that allocation policy and the complete renderer
as maintained `.c26` source. Eight heights and sixteen palette bytes are ordinary
`instantiate` parameters. The `fine_global_static` test path loads no planning or
lowering helper, does not decode a descriptor cartridge, and invokes only the
normal compiler/assembler/linker. Existing preview leaves are not switched yet.

Normal bodies select palette/route/M1 slots using assembly conditionals. Packed
bodies are retained only for actual phase-14 events, with a shared non-writing
tail otherwise. Complete procedures retain all final-link timing contracts.
Each row target is a zero-byte scoped label at the selected packed entry, **not
an equate alias**: equates do not carry the placed label's relocation into o26.
The first address-macro implementation preserved relocation but expanded every
candidate at every route-table byte; matrix timeouts motivated the direct anchor
form. Route tables remain 192 bytes on one page.

All helpers are inline, not `require inline`: inactive/zero-byte assembly arms
cannot satisfy a required-function link usage contract. Separate helper bodies
also bound parser stack use. The assembler must skip inactive instructions when
validating `.same`/`.cross`, just as it does during layout and emission; the new
`asm_inactive_branch_contracts.pl` checks both inactive acceptance and active
long-branch rejection. No timing assertion is removed from the active kernel.

The `vcs_all_five_colors_sections_global_*.test` gates cover dense first/middle/
late/terminal rows, mixed seams, row-boundary palettes, line190, nonempty edge
poses, runtime object controls, uniform PF, and a rejected palette mutation.
Their references are independently drawn ordinary-renderer cartridges. RAM and
drawing-bank budgets are checked in each linked map. A 32-geometry compile matrix
checks both lowering paths. The `.c26` allocator is independently checked for
35 geometries, zero RAM and zero planning instructions, then certified with
moving RGB/control cases. Palette/refill mutations must fail exact RGB.
Static gates additionally use hexadecimal palette overrides, reverse all eight
palettes including the first, and check invalid geometry/colour diagnostics.
The static 32-geometry compile matrix has its own workload-specific 600-second
budget; the original two-path matrix keeps 240 seconds. All map gates retain
128-byte RAM and 3840-byte drawing-bank limits. Snapshot deadlines/worker/process
cleanup policy is unchanged.
The final scoped-target static matrix passed in 412.75 seconds. The initial
terminal moving-palette gate needed the existing 104-unit clipped-terminal pose
sweep enabled for global profiles too; it then passed without relaxing canonical
glyph, exact-RGB or nonempty seam-straddle checks.

## Not yet a public renderer

The new static path no longer needs a test transformation, but still folds two
alternating playfield patterns. Score composition, full interactive state/stack
budgets and arbitrary playfield rows have not been proved. The editable previews
retain their previous limits. Do not advertise the private profile as general
all-five sections support.

Next: schedule actual PF/mask storage intervals rather than folding two PF rows,
then prove independent score handoffs and full application budgets before public
extraction. The static path is the no-generator baseline for that work. Do not
resume seam28/seam30 prefix extensions.

## Runnable no-score integration

The runnable no-score leaf now uses the maintained copy at
`examples/_common/all_five_colors_sections_global_preview.c26`; the original
`static_global.c26` remains the frozen baseline used by exact static probes.
The example's default heights are `6,12,28,34,34,36,40,2`, exposing
fine boundaries throughout the display, including line190. The complete
application links at 106/128 RAM bytes (95 objects + 11 stack), bank0 3456/3840
and bank1 1002/3840. A manual check of the actual leaf passed frame timing,
all-five controls, endpoints and reset, including its Y=103 clipping endpoint.
The maintained exact tests continue to consume private fixtures, not editable
example constants; ordinary example smoke builds cover the runnable leaf.

This is not arbitrary-playfield or score completion. A row/section-intersection
loop attempt with immediate per-row PF writes exceeded bank0 capacity even for
the dense first-row geometry, before raster validation. It is not retained as
maintained source. The remaining redesign must share PF/object pipeline code
without duplicating row bodies and must schedule all four PF-byte refills in
addition to the route/M1 refills; promoting this alternating-PF implementation
to a general public renderer would conceal that unsolved requirement.
