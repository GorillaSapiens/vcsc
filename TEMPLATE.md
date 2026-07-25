```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Template instantiation and use contracts

## Status

This document specifies a VCSC feature under staged implementation.
`require`/`recommend` declarations, declaration and semantic-use metadata,
link-time reachable external-use enforcement, and repeatable
`template ... as ...` source instantiation with controlled identifier rewriting
are implemented. Inline-assembly rewriting, template-hygiene enforcement, and
the component lifecycle/frame scheduler work remain roadmap items.

The feature is deliberately smaller than C++ templates or a general module
system. Its purpose is to let one source component be instantiated repeatedly
under different symbol prefixes, and to let a component declare which of its
public functions and objects the containing program must or should use.

The first intended application is reusable, composable VCS display components:
for example, two independent six-glyph score displays drawn in either order.

## Goals

The feature must provide all of the following:

1. Instantiate the same `.c26` component more than once without symbol
   collisions or shared instance state.
2. Preserve source-level type checking and normal VCSC compilation after name
   substitution.
3. Let a component require or recommend use of selected functions and objects.
4. Diagnose missing uses after archive selection and whole-program reachability
   are known.
5. Work for true inline functions even when no callable linker symbol or `JSR`
   remains.
6. Keep ordinary `include` behavior unchanged.
7. Permit display components to expose a consistent frame-lifecycle interface
   and a machine-readable visible-scanline count.
8. Keep cycle-counted inline assembly under the component author's control.

## Non-goals

This proposal does not add:

- C++-style type or value template parameters;
- function or class templates;
- overload resolution;
- namespaces or a general qualified-name operator;
- automatic inference that two cycle-counted raster components are compatible;
- automatic proof of TIA register, CPU register, stack, page, or cycle contracts;
- textual macro substitution in comments or string literals.

A future module system could provide automatic namespacing and qualified access
such as `score1.draw()`. This proposal instead uses controlled identifier-prefix
rewriting because it fits the present compiler and object format much more
closely.

## `require` and `recommend`

### Syntax

`require` and `recommend` are declaration specifiers accepted on file-scope
object and function declarations or definitions:

```c
require uint8_t required_state;
recommend bcd24_t displayed_score;

require void initialize(void);
require inline void draw(void) {
    /* ... */
}
```

They are not valid on:

- automatic locals;
- parameters;
- structure or union members;
- typedef declarations;
- enum constants;
- labels.

A declaration may be both repeated and later defined, subject to the ordinary
VCSC rule that all declarations of one name have one compatible type. If
contract levels are merged, `require` dominates `recommend`.

### Meaning

After the linker has selected archive members and computed reachable code:

- an unused `require` contract is a fatal link error;
- an unused `recommend` contract is a link warning;
- an ordinary undefined symbol remains an ordinary undefined-symbol error.

Examples:

```text
six_glyph_display.c26:18.1:
required variable 'bcd24_t score1_score' is not used
  instantiated as 'score1' at main.c26:3.1
```

```text
six_glyph_display.c26:21.1:
recommended function 'void score2_overscan(void)' is not used
  instantiated as 'score2' at main.c26:4.1
```

Diagnostics should use the final instantiated source name and type, identify the
contract's original source location, and identify the template invocation when
one exists.

### What counts as use

A contract is satisfied only by a reachable semantic use from outside the
contract owner.

The contract owner is:

- the declaring template instance for a declaration produced by `template`;
- otherwise, the declaring translation unit.

For a function, a use is a reachable direct call from outside the owner. A mere
prototype, address-sized metadata record, or call from unreachable code does
not count.

For an object, a use is a reachable read, write, address-taking operation, or
`ref` use from outside the owner. A declaration, definition, initializer, or
`sizeof`-only reference does not count.

This external-use rule is essential. A component commonly reads its own public
state while drawing it:

```c
recommend bcd24_t TEMPLATE_score;

inline void TEMPLATE_vblank(void) {
    /* Internal preparation reads TEMPLATE_score. */
}
```

That internal read must not satisfy the recommendation. The application must
actually read, write, or otherwise use `score1_score`.

Likewise, one required component function calling another required function
inside the same instance must not make the second function appear to have been
used by the application.

### Reachability

A syntactic reference in dead code is insufficient. The linker should evaluate
contracts after:

1. object and archive selection;
2. ordinary symbol resolution;
3. hidden assembly call-edge import;
4. whole-program call-graph reachability.

Contracts in archive members that were never selected do not produce errors or
warnings.

### Inline functions

A true inline function may have no out-of-line symbol, relocation, `JSR`, or
`RTS`. The compiler must therefore emit semantic contract and use metadata for
inline calls rather than asking the linker to infer them from machine code.

The metadata must survive even when normal code generation completely removes
the call boundary.

## Object-file contract metadata

Each contracted declaration needs linker-visible metadata containing at least:

- contract level: `require` or `recommend`;
- symbol kind: object or function;
- final source-level symbol name;
- canonical type or function signature;
- contract-owner identity;
- original source file, line, and column;
- template instance name and invocation location, when applicable.

Each semantic use record needs at least:

- referenced contract symbol;
- owner identity of the referencing code;
- containing function, when any;
- source location;
- use kind: call, read, write, address, or `ref`.

The linker should consume this metadata only after ordinary object and archive
selection. Existing VCSC hidden metadata mechanisms may be extended if they can
represent these records without losing source locations or inline calls.

## `template`

### Syntax

```c
template "six_glyph_display.c26" as score1
template "six_glyph_display.c26" as score2
```

The instance argument after `as` is one ordinary VCSC identifier. UTF-8
identifiers follow the same validation and assembler-safe mangling rules as
other source identifiers.

File lookup follows the ordinary `include` search path and relative-path rules.
A conventional `.c26` suffix may be omitted only if ordinary `include` already
supports the same omission; `template` should not introduce a second, different
file-search policy.

### Difference from `include`

Ordinary `include` retains its current MD5-based include-once behavior.

`template` intentionally does not consult or update that MD5-seen set. Every
invocation processes the requested source again, even when the same bytes or
same path were instantiated earlier:

```c
template "six_glyph_display.c26" as score1
template "six_glyph_display.c26" as score2
```

Ordinary `include` directives encountered inside a template retain ordinary
include-once behavior. Nested `template` directives create nested instance
contexts and remain subject to a finite nesting limit and cycle diagnostic.

### Identifier rewriting

Substitution is identifier-aware, not raw text replacement.

For an instance named `score1`:

```text
TEMPLATE          -> score1
TEMPLATE_score    -> score1_score
TEMPLATE_update   -> score1_update
```

The recognized forms are exactly:

- the complete identifier `TEMPLATE`;
- an identifier beginning with `TEMPLATE_`.

The compiler must not replace an arbitrary occurrence in the middle of another
identifier:

```text
MY_TEMPLATE_HELPER    -> unchanged
NOTTEMPLATE_score     -> unchanged
```

Comments and string literals remain unchanged:

```c
/* TEMPLATE_score remains documentation. */
uint8_t *text := "TEMPLATE_score";
```

Rewriting occurs before ordinary identifier classification, type lookup, and
UTF-8-to-assembler mangling. This permits instance-prefixed functions, objects,
types, enum tags, enum constants, aliases, and tables.

### Inline assembly

Instance-local identifiers used by inline assembly must be rewritten on
assembler-identifier boundaries:

```c
asm lda TEMPLATE_score;
asm jsr TEMPLATE_helper;
```

becomes the equivalent of:

```c
asm lda score1_score;
asm jsr score1_helper;
```

This rewriting must preserve the current rule that inline assembly is otherwise
opaque to compiler peephole optimization. No unrestricted substring replacement
may occur inside assembler comments or quoted data.

Assembler-local `@labels` remain governed by the existing inline-assembly and
assembler hygiene rules.

### Template hygiene

Every instance-owned file-scope definition in a template should use either
`TEMPLATE` or the `TEMPLATE_` prefix. This includes:

- functions and objects;
- private helpers and private state;
- typedefs, tags, and enum constants;
- tables;
- source-visible assembler symbols.

The compiler should reject an unqualified file-scope definition created directly
inside a template instance, because two instances would otherwise collide or
silently share state. Shared declarations should come from an ordinary included
support file rather than being redefined by each template instance.

The initial implementation may need a narrow explicit escape for declarations
that are proven to be shared, but silently accepting forgotten prefixes is not
safe enough for cycle-sensitive kernel code.

## Standard display-component contract

Reusable display components should expose four lifecycle functions:

```c
require inline void TEMPLATE_init(void) {
}

require inline void TEMPLATE_vblank(void) {
}

require inline void TEMPLATE_draw(void) {
}

require inline void TEMPLATE_overscan(void) {
}
```

An empty phase remains an empty inline function. Requiring all four calls gives
components one uniform interface without paying `JSR`/`RTS` overhead for empty
or inlined phases.

### `TEMPLATE_init()`

Called exactly once before entering the frame loop.

Expected contract:

- VBLANK is asserted;
- no scanline deadline is active;
- initializes instance-owned persistent state;
- returns with the hardware stack balanced;
- returns with decimal mode clear.

### `TEMPLATE_vblank()`

Called once per frame after the application scheduler asserts VBLANK and starts
the shared vertical-blank deadline, but before visible drawing.

Expected contract:

- prepares data used by the current visible frame;
- VBLANK is asserted;
- the caller owns and has already started the blanking timer;
- all component `vblank()` calls share the remaining 37-scanline budget;
- the function returns before the shared deadline expires;
- the function does not write VBLANK, WSYNC, a RIOT timer-start register,
  INTIM, or TIMINT, and does not wait on the scheduler's timer;
- returns with the hardware stack balanced;
- returns with decimal mode clear.

The scheduler must start the deadline before invoking the first component. It
must not spend all 37 blank scanlines first and then call `vblank()`: that would
run component preparation outside the nominal vertical-blank interval and could
clear VBLANK in the middle of a scanline.

### `TEMPLATE_draw()`

Called once per frame in the application's selected visible-component order.

Expected contract:

- enters at CPU cycle zero of its first visible scanline;
- VBLANK is clear;
- produces exactly `TEMPLATE_VISIBLE_SCANLINES` scanlines;
- exits at CPU cycle zero of the following scanline;
- returns with the hardware stack balanced;
- returns with decimal mode clear;
- leaves any enabled TIA graphics in its documented exit state.

`draw` is preferred over naming the function `scanlines`: the function performs
the drawing, while the exact scanline count is separate machine-readable
metadata.

### `TEMPLATE_overscan()`

Called once per frame after visible drawing and after VBLANK is asserted.

Expected contract:

- the caller owns and has started the overscan timer;
- performs work whose results normally affect the next frame;
- returns with the hardware stack balanced;
- returns with decimal mode clear.

### Do not standardize `update()`

A generic `update()` call cannot express when data becomes visible or prove that
it was called after every state change. Preparation should normally occur in
`vblank()` or `overscan()`.

A component that needs an immediate operation may expose a component-specific
setter or helper, for example:

```c
inline void TEMPLATE_set_score(bcd24_t value);
```

Such helpers are not part of the universal four-phase lifecycle.

## Machine-readable scanline count

The exact visible line count must not live only in prose. A display component
should export a compile-time constant such as:

```c
enum TEMPLATE_contract {
    TEMPLATE_VISIBLE_SCANLINES := 12,
    TEMPLATE_VBLANK_MAX_CYCLES := 300,
    TEMPLATE_OVERSCAN_MAX_CYCLES := 300
};
```

`TEMPLATE_VBLANK_MAX_CYCLES` and `TEMPLATE_OVERSCAN_MAX_CYCLES` are
conservative worst-case work bounds, not private timers. The application
scheduler owns both phase deadlines and may eventually use the declared maxima
to reject or warn about a composition whose combined work cannot fit.

Two instances then provide independent names:

```c
score1_VISIBLE_SCANLINES
score2_VISIBLE_SCANLINES
```

The application can calculate remaining visible lines without duplicating a
magic number:

```c
wait_scanlines(
    192
    - score1_VISIBLE_SCANLINES
    - score2_VISIBLE_SCANLINES
);
```

The source comments and component README must still state the expected entry and
exit cycles and explain what those lines contain.

## Resource and timing contract

Lifecycle names and scanline counts alone do not prove that display components
can be freely reordered. Every component must document and test:

- exact visible scanline count;
- entry and exit cycle;
- TIA registers read and written;
- TIA state left behind;
- A, X, Y, and status-flag clobbers;
- hardware-stack behavior;
- instance RAM and shared RAM requirements;
- ROM cost;
- page containment, alignment, adjacency, and indexed-range requirements;
- conservative maximum VBLANK and overscan cycle counts;
- ownership of VBLANK, WSYNC, and the RIOT timer/status registers;
- collision-latch assumptions;
- whether another component must clear or preserve particular graphics.

The first implementation may keep most of this contract in documentation and
regression tests. A later linker-visible component manifest may make selected
resource conflicts machine-checkable.

## Example composition

A two-instance score application should be expressible approximately as:

```c
template "six_glyph_display.c26" as score1
template "six_glyph_display.c26" as score2

void main(void) {
    score1_init();
    score2_init();

    score1_score := 5;
    score2_score := 15;

    while (1) {
        VSYNC := 2;
        wait_scanlines(3);
        VSYNC := 0;

        VBLANK := 2;
        start_vblank_deadline(37);   /* Scheduler-owned pseudocode helper. */

        score1_vblank();
        score2_vblank();

        finish_vblank_deadline();    /* Detect overrun, wait remainder, WSYNC. */
        VBLANK := 0;                 /* Cycle zero of first visible line. */

        wait_scanlines(81);
        score1_draw();
        score2_draw();
        wait_scanlines(
            192
            - 81
            - score1_VISIBLE_SCANLINES
            - score2_VISIBLE_SCANLINES
        );

        VBLANK := 2;
        start_overscan_deadline();   /* Scheduler owns the overscan timer. */

        score1_overscan();
        score2_overscan();

        finish_overscan_deadline();  /* Detect overrun and finish the phase. */
    }
}
```

The deadline-helper names above are scheduler pseudocode, not additional
component lifecycle functions. A real helper must distinguish an unexpired timer
from an underflowed/wrapped timer, report an overrun, wait only for the unused
remainder, and use the final WSYNC needed to put the next phase at cycle zero.
A bare `while (INTIM)` loop is not sufficient after arbitrary component work
because an already-underflowed timer can wrap and appear nonzero again.

The exact timer preload and phase budgets remain application and component
contract decisions. The feature allows composition; it does not excuse the
program from meeting the 6507/TIA timing schedule.

## Required regression strategy

### Declaration contracts

Tests must cover:

- required function called and not called;
- recommended function called and not called;
- required object read, written, addressed, and unused;
- internal instance references not satisfying an external-use contract;
- unreachable external references not satisfying a contract;
- `require` dominating `recommend` on merged declarations;
- incompatible redeclarations retaining ordinary type errors;
- contracts in unselected archive members remaining silent;
- exact file, line, type, symbol, and instance diagnostics;
- true inline calls satisfying function contracts without a `JSR` relocation.

### Template instantiation

Tests must cover:

- two instances of the same source in one translation unit;
- distinct instance storage and functions;
- exact `TEMPLATE` and `TEMPLATE_` rewriting;
- no middle-of-identifier replacement;
- comments and strings remaining unchanged;
- UTF-8 instance identifiers and assembler-safe mangling;
- ordinary includes inside templates remaining include-once;
- repeated templates bypassing the MD5-seen set;
- nested template contexts and recursion/nesting diagnostics;
- unqualified file-scope definitions rejected by template hygiene;
- inline-assembly instance identifiers rewritten while the assembly itself
  remains opaque to peephole optimization.

### Display composition

The first real component conversion should prove:

- one six-glyph component behaves exactly as its non-template predecessor;
- two instances maintain independent scores and private state;
- both instances coexist within measured RAM, ROM, and stack budgets;
- the application may draw instance 1 above instance 2 or reverse the order;
- exact scanline counts, entry/exit cycles, glyph order, colors, and TIA writes;
- the VBLANK deadline starts before the first `vblank()` call, all component
  callbacks fit within the shared budget, overrun is detected, and VBLANK clears
  at cycle zero only after the scheduler's final WSYNC;
- component callbacks do not take ownership of VBLANK, WSYNC, or the RIOT timer;
- lifecycle calls are all externally visible to `require` checking;
- omitting `score1_init()` produces the intended link error;
- omitting a recommended score-state use produces only a warning;
- source and installed-toolchain builds behave identically.

## Implementation sequence

Implement this as vertical slices rather than one parser-to-kernel leap:

1. Add `require` and `recommend` to declaration parsing and type-compatible
   declaration merging, but initially emit metadata only.
2. Extend o26 metadata with declaration contracts and source locations; prove
   assembly, archive, and linker round trips before enforcing anything.
3. Emit semantic function/object use records, including true inline calls and
   reads/writes that produce no ordinary relocation.
4. Add linker enforcement after archive selection and reachability analysis,
   with exact error/warning diagnostics.
5. Add `template "file" as instance` using the ordinary include path but
   bypassing the MD5-seen set. **Complete.**
6. Add controlled `TEMPLATE`/`TEMPLATE_` identifier rewriting. **Complete.**
   Template-hygiene diagnostics remain part of the next slice.
7. Extend rewriting to identifier operands in inline assembly without exposing
   the block to compiler peephole optimization.
8. Standardize `init`, `vblank`, `draw`, `overscan`,
   `VISIBLE_SCANLINES`, and conservative VBLANK/overscan maximum-cycle metadata;
   define scheduler-owned phase deadlines, overrun detection, remaining-time
   waits, and cycle-zero phase transitions.
9. Convert the existing six-glyph display into the first reusable component and
   prove two independent instances in both draw orders.
10. Update the kernel-authoring documentation after the implementation has
    established real constraints and examples.

Each slice must leave the complete existing test suite green and must add focused
negative tests before relying on the new contract for maintained kernels.
