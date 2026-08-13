```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Source instantiation and component templates

VCSC has a small source-instantiation mechanism for reusable `.c26` components.
It is not C++ templates and it is not a general module system. A component is
ordinary VCSC source written with instance-qualified `TEMPLATE` names; a caller
processes that source with `instantiate`, giving the instance a concrete prefix.

The language keyword is **`instantiate`**. The former `template` keyword has
been removed and is intentionally rejected.

This guide covers both sides of the mechanism:

- how an application instantiates and uses a component;
- how a component author writes repeatable instance-local source;
- how integer configuration parameters work;
- how `require` and `recommend` describe the public use contract;
- how maintained VCS display components apply the mechanism.

For beam-level renderer timing, RAM, stack, and TIA ownership rules, also read
`libraries/vcs/renderers/AUTHORING.md`.

## 1. Using a component

The basic form is:

```c
instantiate "component.c26" as first
instantiate "component.c26" as second
```

There is no semicolon after an `instantiate` directive.

The file is found with the ordinary `include` search path. The instance name is an
ordinary VCSC identifier; UTF-8 identifiers use the same validation and assembler-safe
mangling as elsewhere in the language. Unlike `include`, an `instantiate` is processed
every time it appears, so the same source can be instantiated repeatedly in one
translation unit.

If `component.c26` contains:

```c
uint8_t TEMPLATE_value;

inline void TEMPLATE_set(uint8_t value) {
   TEMPLATE_value := value;
}
```

then the two instances above provide independent names such as:

```text
first_value
first_set
second_value
second_set
```

and therefore independent state.

### Real VCSC examples

The maintained renderers use the same mechanism:

```c
instantiate "renderers/all_five/all_five.c26" as game (lines:=181)
instantiate "six_glyph_component.c26" as score (mutable_color:=1)
```

The first instance selects the 181-visible-line renderer profile. The second
uses the centered six-glyph score component with its optional mutable-color
feature enabled.

The 170-line examples instantiate the same score component twice:

```c
instantiate "renderers/player_color/player_color.c26" as game (lines:=170)
instantiate "six_glyph_component.c26" as top_score (mutable_color:=1)
instantiate "six_glyph_component.c26" as bottom_score (mutable_color:=1)
```

`top_score_*` and `bottom_score_*` are separate objects and functions even
though both came from the same source file.

## 2. Instantiation parameters

A directly instantiated source file may declare integer-literal configuration
parameters at file scope.

A declaration without an assignment is required:

```c
parameter lines;
```

A declaration with `:=` supplies a default and is optional:

```c
parameter color := 0x20;
parameter enabled := 1;
```

Parameter declarations end with semicolons. They must appear before uses of the
corresponding `TEMPLATE_name`.

The caller supplies or overrides values after the instance name:

```c
instantiate "renderer.c26" as full (lines:=192)
instantiate "renderer.c26" as short (lines:=181, color:=0x2e)
```

Arguments use `:=`, not `=`.

Parameter values are integer literals. VCSC decimal, hexadecimal, octal,
binary, and visual-binary literal forms are accepted. Arbitrary expressions or
identifiers are not instantiation arguments.

The compiler diagnoses:

- a missing required argument;
- an unknown argument name;
- the same argument supplied twice;
- the same parameter declared twice;
- a non-integer argument value;
- a `parameter` declaration outside a directly instantiated source file.

### Parameter substitution

Inside the component, a declared parameter is referenced through its
`TEMPLATE_` name:

```c
parameter lines;
parameter color := 0x20;

uint8_t TEMPLATE_rows[TEMPLATE_lines];
uint8_t TEMPLATE_background := TEMPLATE_color;
```

For:

```c
instantiate "component.c26" as game (lines:=181, color:=0x2e)
```

`TEMPLATE_lines` and `TEMPLATE_color` are compile-time literals. They do not
create runtime parameter storage.

A declared parameter name is treated specially: `TEMPLATE_lines` substitutes
the selected literal instead of becoming an instance symbol such as
`game_lines`. Other `TEMPLATE_` identifiers continue to receive the normal
instance prefix.

### Compile-time profile selection

Declared parameters are also integer constants in `#if` and `#elif` while the
component is being instantiated:

```c
parameter lines;

#if TEMPLATE_lines == 192
   /* 192-line implementation */
#elif TEMPLATE_lines == 181
   /* 181-line implementation */
#elif TEMPLATE_lines == 170
   /* 170-line implementation */
#else
   extern const uint8_t TEMPLATE_bad_lines[TEMPLATE_lines_must_be_170_181_or_192];
#endif
```

This is how `all_five.c26` and `player_color.c26` select their maintained
192-, 181-, and 170-line implementations. The choice is compile-time only; no
runtime branch or line-count variable is emitted.

When a parameter controls a timing-sensitive profile, support only values that
have a real measured implementation. Do not silently map an unsupported value
to a nearby profile.

## 3. Writing repeatable component source

Every file-scope definition owned by an instance must be named with either the
exact identifier `TEMPLATE` or the leading prefix `TEMPLATE_`.

Typical component source looks like:

```c
parameter enabled := 1;

enum TEMPLATE_contract {
   TEMPLATE_ENABLED := TEMPLATE_enabled
};

uint8_t TEMPLATE_state;

static inline void TEMPLATE_prepare(void) {
   TEMPLATE_state := 0;
}

inline void TEMPLATE_update(void) {
#if TEMPLATE_enabled
   TEMPLATE_prepare();
#endif
}
```

For an instance named `foo`, identifier rewriting is:

```text
TEMPLATE          -> foo
TEMPLATE_state    -> foo_state
TEMPLATE_prepare  -> foo_prepare
TEMPLATE_update   -> foo_update
```

Rewriting is identifier-aware, not arbitrary text replacement. These do not
change:

```text
MY_TEMPLATE_HELPER
NOTTEMPLATE_state
```

Comments and quoted strings also remain unchanged.

### What must carry the prefix

Directly instantiated source must qualify instance-owned file-scope names,
including:

- functions;
- objects and tables;
- typedef names;
- structure, union, and enum tags;
- enum constants;
- source-visible nonlocal assembler symbols.

The compiler rejects an unqualified instance-owned file-scope definition because
multiple instances would otherwise collide or accidentally share state.

The prefix rule does **not** apply to:

- function locals;
- function parameters;
- aggregate members;
- instantiation-parameter declaration names such as `lines`;
- assembler-local `@labels`.

### Shared support belongs in `include`

A component may ordinarily include shared support:

```c
include "vcs.c26"
```

Ordinary included files keep normal include-once behavior even while an
instantiation is active. Definitions originating from an ordinary included
support file are not treated as instance-owned definitions and therefore do not
need a `TEMPLATE_` prefix.

Use this distinction deliberately:

- `instantiate` for state or code that must exist independently per instance;
- `include` for genuinely shared declarations, types, constants, and helpers.

Do not duplicate common support inside every instance merely to satisfy the
prefix rule.

## 4. `include` versus `instantiate`

`include` and `instantiate` intentionally have different repetition semantics.

### `include`

```c
include "support.c26"
```

An included file is processed once per translation unit. Identity is based on
the file contents, so identical included content is suppressed even if reached
through different paths.

### `instantiate`

```c
instantiate "component.c26" as a
instantiate "component.c26" as b
```

The component source is processed once for each invocation. Instantiation does
not consult or update the ordinary include-once set.

Includes encountered *inside* that component still use normal include-once
semantics.

Nested instantiations are supported. Recursive instantiation cycles are
rejected.

## 5. Aliases and inline assembly

Alias names, alias parameters, and identifier tokens in alias replacement text
participate in instance rewriting. Per-instance aliases should therefore use
`TEMPLATE_` names just like the state they expose. Identifier tokens in inline assembly
participate in the same rewriting.

For example:

```c
alias TEMPLATE_PLAYER_X TEMPLATE_object_x[0]

asm lda TEMPLATE_state;
asm jsr TEMPLATE_helper;
```

inside an instance named `game` refers to `game_object_x`, `game_state`, and
`game_helper`.

Declared instantiation parameters are substituted as literals where their
`TEMPLATE_name` appears in supported alias or inline-assembly identifier
contexts.

The rewriting is still token-aware. Quoted assembler data and unrelated
identifier substrings are not changed. Inline assembly remains opaque to the
compiler's normal peephole reasoning except for this source-name rewriting and
normal assembler integration.

Assembler-local `@labels` do not need an instance prefix. Source-visible
nonlocal assembler labels do.

## 6. Public use contracts: `require` and `recommend`

A reusable component can mark file-scope functions or objects that its caller is
expected to use.

```c
require inline void TEMPLATE_init(void) {
}

require inline void TEMPLATE_draw(void) {
}

recommend uint8_t TEMPLATE_color := 0x0e;
```

`require` means that a linked application must make a reachable semantic use of
the declaration from outside the component instance. If it does not, linking
fails.

`recommend` uses the same external-use test but produces a linker warning rather
than an error when unused.

For functions, a real reachable direct call counts as use. Inline calls count
even when no `JSR` remains in the generated machine code.

For objects, reads, writes, address-taking, and `ref` use count. A component's
own internal references to its public state do not satisfy the contract; the
application has to use the API itself.

This matters for components such as `six_glyph_component.c26`:

```c
recommend bcd24_t TEMPLATE_score := 0;
```

The component reads the score internally when preparing glyph pointers, but that
does not pretend the application has supplied or intentionally used the score.

Use `require` for operations that are necessary for correct integration. Use
`recommend` for public state or helpers that are normally meaningful to an
application but may legitimately be left at their default.

`require` and `recommend` are ordinary VCSC declaration contracts; they are not
limited to instantiated source. In a template, however, the contract owner is
the individual instance, so `score1_draw` and `score2_draw` are checked
independently.

## 7. Maintained VCS display-component convention

VCSC's maintained visible renderers and score components use instantiation to
provide a common lifecycle. A display component normally exports:

```c
require inline void TEMPLATE_init(void);
require inline void TEMPLATE_vblank(void);
require inline void TEMPLATE_draw(void);
require inline void TEMPLATE_overscan(void);
```

The four names are a project component convention, not special parser syntax.
The `require` declarations make omission of a lifecycle phase a link-time error.

Typical application structure is:

```c
game_init();
score_init();

while (1) {
   vcs_ntsc_vsync();

   vcs_ntsc_begin_vblank();
   game_vblank();
   score_vblank();
   vcs_ntsc_end_vblank();

   score_draw();
   vcs_ntsc_component_handoff();
   game_draw();

   vcs_ntsc_begin_overscan();
   game_overscan();
   score_overscan();
   vcs_ntsc_end_overscan();
}
```

The frame scheduler owns VSYNC, VBLANK transitions, and the frame timer. A
component owns only the work documented for its lifecycle phases.

### Machine-readable component contract

Maintained visible components publish an instance-qualified contract enum. The
common fields include:

```c
enum TEMPLATE_contract {
   TEMPLATE_VISIBLE_SCANLINES := 11,
   TEMPLATE_DRAW_ENTRY_CYCLE := 3,
   TEMPLATE_DRAW_RETURN_CYCLE := 0,
   TEMPLATE_DRAW_COMPLETE_SCANLINES := 11,
   TEMPLATE_DRAW_PARTIAL_ENTRY_CYCLES := 0,
   TEMPLATE_DRAW_PARTIAL_EXIT_CYCLES := 0,
   TEMPLATE_DRAW_TERMINAL_WSYNC := 1,
   TEMPLATE_DRAW_HMOVE_COUNT := 1,
   TEMPLATE_DRAW_SUCCESSOR_ON_RETURN_LINE := 1,
   TEMPLATE_VBLANK_MAX_CYCLES := 260,
   TEMPLATE_OVERSCAN_MAX_CYCLES := 0
};
```

An instance named `score` exports names such as
`score_VISIBLE_SCANLINES`. Parameterized renderers commonly set these fields
from the selected compile-time profile, for example:

```c
TEMPLATE_VISIBLE_SCANLINES := TEMPLATE_lines
```

The enum is part of the component's documented and regression-tested public
contract. Renderer authors should follow `libraries/vcs/renderers/AUTHORING.md`
for the complete timing, TIA ownership, RAM/ROM, stack, page, and branch-timing
requirements.

## 8. A small complete template

This example shows required and defaulted parameters, per-instance state, a
public use contract, and compile-time selection without any runtime parameter
storage:

```c
// demo_component.c26
parameter rows;
parameter enabled := 1;

#if TEMPLATE_rows == 8
alias TEMPLATE_ROW_BYTES 8
#elif TEMPLATE_rows == 16
alias TEMPLATE_ROW_BYTES 16
#else
extern const uint8_t TEMPLATE_rows_must_be_8_or_16[TEMPLATE_bad_rows];
#endif

enum TEMPLATE_contract {
   TEMPLATE_ROWS := TEMPLATE_rows,
   TEMPLATE_ENABLED := TEMPLATE_enabled
};

recommend uint8_t TEMPLATE_value := 0;
uint8_t TEMPLATE_work;

require inline void TEMPLATE_init(void) {
   TEMPLATE_work := 0;
}

inline void TEMPLATE_prepare(void) {
#if TEMPLATE_enabled
   TEMPLATE_work := TEMPLATE_value;
#endif
}
```

A caller can create two differently configured copies:

```c
include "vcs.c26"

instantiate "demo_component.c26" as small (rows:=8)
instantiate "demo_component.c26" as large (rows:=16, enabled:=0)

void main(void) {
   small_value := 1;
   large_value := 2;

   small_init();
   large_init();

   small_prepare();
   large_prepare();
}
```

The generated source-level interface is independent:

```text
small_value      large_value
small_work       large_work
small_init       large_init
small_prepare    large_prepare
small_ROWS       large_ROWS
```

## 9. Common mistakes

### Using the retired keyword

Wrong:

```c
template "component.c26" as game
```

Right:

```c
instantiate "component.c26" as game
```

### Adding a semicolon after `instantiate`

Wrong:

```c
instantiate "component.c26" as game;
```

Right:

```c
instantiate "component.c26" as game
```

### Using `=` for an instantiation argument

Wrong:

```c
instantiate "component.c26" as game (lines=181)
```

Right:

```c
instantiate "component.c26" as game (lines:=181)
```

### Treating parameters as runtime variables

`parameter lines;` creates a compile-time substitution, not a byte of storage.
Use `TEMPLATE_lines` in constant expressions and `#if` selection. Declare a
normal `TEMPLATE_` object if the application must change a value at runtime.

### Forgetting the prefix on instance-owned file-scope names

Wrong inside directly instantiated source:

```c
uint8_t state;
inline void helper(void) { }
```

Right:

```c
uint8_t TEMPLATE_state;
inline void TEMPLATE_helper(void) { }
```

### Using `instantiate` for shared support

If a declaration should exist only once and be shared by every instance, put it
in an ordinarily included support file. Instantiating it repeatedly is the wrong
ownership model.

### Assuming one instance can satisfy another instance's contract

It cannot. `require` and `recommend` are checked per contract owner. Calling
`score1_draw()` does not satisfy `score2_draw()`.

## 10. Current examples worth copying

For real source rather than toy syntax, start with:

- `libraries/vcs/renderers/all_five/all_five.c26` for a required `lines`
  parameter and three compile-time renderer profiles;
- `libraries/vcs/renderers/player_color/player_color.c26` for another
  parameterized renderer with the same public API across profiles;
- `libraries/vcs/renderers/multisprite/multisprite.c26` for a parameterized
  timing-sensitive renderer;
- `libraries/vcs/six_glyph_component.c26` for defaulted feature parameters,
  `require` lifecycle hooks, and `recommend` public state;
- `examples/11_all_five_170/01_score_above_and_below/01_interactive/` for one
  renderer plus two independent instances of the same score component;
- `examples/04_player_color_181/01_score_above/01_interactive/` for a typical
  renderer-plus-score composition;
- `test/fixtures/templates/lifecycle_component.c26` for the minimal maintained
  four-phase lifecycle fixture;
- `test/fixtures/instantiation_parameters/` for focused parameter examples and
  diagnostics.

Those files describe the mechanism VCSC actually uses today. `TEMPLATE.md` is a
guide to that implemented behavior, not a proposal or implementation roadmap.
