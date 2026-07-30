```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# VCSC compiler and language reference

VCSC is a small C-like language and compiler specialized for the Atari
2600/VCS. This document describes the behavior implemented by `vcsc-cc1`; it
does not assume familiarity with another compiler.

VCSC originated as an Atari-focused specialization of the broader
[N project](https://github.com/GorillaSapiens/n). The projects now have
separate source suffixes, object formats, runtimes, calling conventions, and
language surfaces. Parent-project features deliberately absent from VCSC are
listed tersely at the end of this document.

## Language summary

The largest differences from C are:

- Assignment uses `:=`; `=` is not the assignment operator.
- Braces are required for `if`, `else`, `while`, `do`, and `for` bodies.
- Integer and pointer types are declared by the target support source. There
  are no implicit `char`, `short`, `int`, `long`, or `bool` types.
- Every ordinary function has one statically described activation: parameters,
  named locals, compiler scratch, and any return object use linker symbols rather
  than a per-call frame. The linker overlays activations whose call-graph
  lifetimes cannot overlap.
- Consequently, ordinary functions are non-reentrant and recursion is
  forbidden. The compiler and linker reject direct and mutual call cycles.
- Every ordinary call target is a directly named function with one visible
  signature.
- `inline` means mandatory source expansion, not an optimization hint.
- All language operators are built in.
- Inline assembly is available for cycle-counted and hardware-specific code.

## Includes, aliases, and conditional compilation

### Includes

```vcsc
include "vcs.c26"
```

An included file is processed once per translation unit. Identity is based on
an MD5 digest of its contents, so including identical content through different
paths still produces one inclusion.

### Templates

```vcsc
template "component.c26" as first
template "component.c26" as second
```

A template uses the ordinary include search path but is processed on every
invocation rather than participating in include's MD5-based include-once set.
Within the instantiated source, the exact identifier `TEMPLATE` becomes the
instance identifier and an identifier beginning with `TEMPLATE_` receives the
instance prefix. Comments, strings, and unrelated identifier substrings are not
rewritten. Rewriting occurs before identifier classification and UTF-8 symbol
mangling, so ordinary and UTF-8 instance names are both supported.

Ordinary includes inside a template remain include-once. Nested templates are
allowed, while recursive template inclusion is diagnosed. Alias names,
parameters, and identifier tokens in alias replacement text participate in the
same rewriting. Exact `TEMPLATE` and leading `TEMPLATE_` identifier tokens in
inline assembly are also rewritten and UTF-8-mangled on assembler-identifier
boundaries; quoted assembler data and unrelated identifiers remain unchanged.
Definitions written directly in a template file must name every instance-owned
file-scope function, object, typedef, tag, enum constant, table, and
source-visible assembler label with exact `TEMPLATE` or the leading
`TEMPLATE_` prefix. Ordinary included support files are exempt, so genuinely
shared declarations can live in one include-once header instead of being
redeclared by every instance. Assembler-local `@labels`, function locals,
parameters, and aggregate members do not require the prefix.

### Aliases

Aliases are newline-terminated lexical substitutions:

```vcsc
alias LIMIT 314
alias inc(x) (x + 1)
alias add(a,b) (a + b)
```

Object-like aliases replace a bare identifier. Function-like aliases expand
only as `name(...)` with no whitespace before `(`.

Rules worth remembering:

- An alias name may be defined only once in a translation unit.
- Arguments are split with balanced-parenthesis and quoted-text awareness.
- Parameters shadow outer aliases during one expansion.
- Recursive alias expansion is rejected.
- Repeated parameter use duplicates argument text and therefore duplicates any
  side effects in that text.
- Replacement text is the rest of the definition line after trailing comments
  are removed; a trailing semicolon becomes part of the expansion.

Aliases are untyped text substitution, not functions or templates.

### Conditional compilation

Supported beginning-of-line directives are:

```text
#if expression
#ifdef NAME
#ifndef NAME
#elif expression
#else
#endif
```

`#if` and `#elif` accept integer literals, object-like aliases,
`defined(NAME)`, registered compiler-builtin calls, unary `!`, unary `+`/`-`,
`&&`, `||`, integer comparisons, and parentheses. Undefined names evaluate to
zero. Function-like aliases are not expanded in conditional expressions.
Skipped branches are lexer-inert except for nested conditional directives.

## Compiler builtins

Compiler builtins use ordinary call syntax but are owned by the compiler rather
than declared by source code. Their names are reserved, their arguments are
validated and folded at compile time, and they emit no runtime call or lookup
table. Registered builtins are available anywhere the compiler accepts an
integer constant expression, including global initializers, ordinary
expressions, and `#if`/`#elif` conditionals.

The current builtin is:

```vcsc
uint8_t color := __builtin_ntsc_rgb(0xfd, 0x86, 0x85);
```

`__builtin_ntsc_rgb(r, g, b)` requires three compile-time integer arguments in
`0..255`. It compares the requested RGB triplet with the 128 meaningful even
Atari NTSC TIA color values using squared Euclidean RGB distance and returns the
nearest TIA byte as `uint8_t`. Odd TIA bytes select the same color as the
preceding even byte and are therefore not candidates. Exact distance ties choose
the lower TIA byte. Display palettes are approximations, so this is a convenient
source-color matcher, not a promise that every television or emulator will show
identical RGB values.

The implementation is intentionally extensible. `builtin.c` contains the
name/type/arity/argument-contract registry and shared dispatch used by both the
parser and conditional preprocessor. Domain-specific evaluators live in
separate modules; `builtin_rgb.c` provides the reusable nearest-palette matcher
and the NTSC table. A future PAL or SECAM matcher can add another palette,
evaluator, and registry row without changing call lowering or preprocessor
parsing.

## Types

The stock VCS machine definition, `libraries/vcs/vcs.c26`, declares:

```vcsc
type void     { $size:0 };
type *        { $size:2 $integer:unsigned $endian:little };
type int8_t   { $size:1 $integer:signed };
type uint8_t  { $size:1 $integer:unsigned };
type int16_t  { $size:2 $integer:signed $endian:little };
type uint16_t { $size:2 $integer:unsigned $endian:little };
type int24_t  { $size:3 $integer:signed $endian:little };
type uint24_t { $size:3 $integer:unsigned $endian:little };
type int32_t  { $size:4 $integer:signed $endian:little };
type uint32_t { $size:4 $integer:unsigned $endian:little };
type bcd8_t   { $size:1 $integer:unsigned $bcd };
type bcd16_t  { $size:2 $integer:unsigned $endian:little $bcd };
type bcd24_t  { $size:3 $integer:unsigned $endian:little $bcd };
type bcd32_t  { $size:4 $integer:unsigned $endian:little $bcd };
```

Most VCS programs should include `vcs.c26` instead of repeating these
declarations.

### Required names

The compiler requires `void`, `uint8_t`, and the two-byte unsigned pointer type
`*`. Other canonical names are required when their semantics are used:

- `int8_t` for character constants and string elements;
- `int16_t` for unannotated integer literals, `sizeof`, default enum values,
  and pointer differences.

The names `char`, `int`, and `bool` are ordinary identifiers until explicitly
introduced, for example:

```vcsc
typedef uint8_t bool;
typedef int8_t char;
typedef int16_t int;
```

`typedef` creates a simple alias for an already declared named type.

### Type declarations and flags

Ordinary binary integer types may be one through four bytes. Recognized flags
are:

- `$size:N`;
- `$integer:signed` or `$integer:unsigned`;
- `$endian:little` for multibyte values;
- `$bcd` on one- through four-byte unsigned packed-BCD types.

The pointer type `*` must be exactly two bytes and unsigned. Multibyte values
have one fixed little-endian representation.

### Structs, unions, enums, and bitfields

Struct and union names become types directly:

```vcsc
struct Pair {
   uint8_t first;
   uint16_t second;
};

// "Pair" is now directly usable as a type
Pair pair;

union WordBytes {
   uint16_t word;
   uint8_t bytes[2];
};

// "WordBytes" is now directly usable as a type
WordBytes wb;
```

Forward declarations are supported. Struct and union layouts may contain
arrays, pointers, nested aggregates, and integer bitfields. Signed bitfield
reads sign-extend; unsigned reads zero-extend. Packed-BCD bitfields are rejected.

Enum values are integer constants. The compiler chooses the smallest declared
ordinary binary integer type that represents the enum's complete value range.

## Integer literals and expression typing

Integer literals may be decimal, hexadecimal (`0x`), octal (leading `0`), or
binary (`0b`). Underscores may separate digits.

Binary literals also accept visual digits:

- `.` means zero;
- `X` or `x` means one.

For example, `0b..XXX...` is the same value as `0b00111000`. Visual and normal
binary digits may be mixed.

An integer literal may carry an explicit type annotation:

```vcsc
42`uint8_t
0x123456`uint24_t
```

Unannotated literals use `int16_t` until a typed operand or destination supplies
a different context. Literal-only expressions are folded at compile time. When
a literal interacts with a typed value, parameter, assignment target, return
object, or cast, it adopts that type at the boundary.

For runtime integer expressions:

- equal types keep that type;
- a narrower operand widens to the wider width;
- widening sign-extends signed values and zero-extends unsigned values;
- narrowing truncates high bytes;
- mixed signed/unsigned operations are rejected when width adjustment still
  leaves different signedness, unless the source writes an explicit cast.

VCSC does not implement C's usual arithmetic conversions.

### Casts

Ordinary casts use C-like syntax:

```vcsc
(uint16_t)value
```

A backtick annotation is literal-only:

```vcsc
123`uint16_t
```

The shortcut casts `($signed)` and `($unsigned)` preserve width while changing
signedness. They apply only to already typed ordinary integers, not literals,
pointers, or packed-BCD values.

### Packed BCD

Packed-BCD values store two decimal digits per byte, least-significant pair at
the lowest address:

```vcsc
bcd8_t  a := 42;       // $42
bcd16_t b := 1234;     // $34, $12
bcd24_t c := 567890;   // $90, $78, $56
bcd32_t d := 12345678; // $78, $56, $34, $12
```

Ranges are 0..99, 0..9999, 0..999999, and 0..99999999. Literal spelling does
not change conversion: `42`, `0x2a`, `052`, and `0b101010` all become packed
BCD `$42` in a `bcd8_t` destination.

Supported BCD operations are assignment, same-representation widening or
truncation, `+`, `-`, `+=`, `-=`, prefix/postfix `++` and `--`, comparisons,
truth tests, logical operators, and `switch` comparison. Several constant
multiply/divide/remainder forms also lower inline:

- multiplication, division, and remainder by a positive constant expression
  exactly equal to `10^n`, including `1` as `10^0`;
- remainder by `2` or `5`, determined entirely from the lowest decimal digit;
- multiplication by a constant expressible as the sum or positive difference
  of two decimal powers, `10^a + 10^b` or `10^a - 10^b`, provided that the
  constant fits the BCD type. Examples include `2`, `9`, `11`, `20`, `99`, and
  `101`.

Multiplication accepts the constant on either side. Division and remainder
require it on the right. The compound forms `*=`, `/=`, and `%=` support the
same applicable constants. Other BCD multiplication, division, and remainder
remain rejected rather than silently selecting a general arithmetic helper.

Decimal-power operations are packed-digit moves, not general BCD arithmetic.
Even powers move whole bytes; odd powers use four accumulator shifts plus
masks to join adjacent nibbles. Multiplication discards digits shifted past the
destination width, division discards shifted-off low digits, and remainder
retains only the low `n` decimal digits. Thus, for example, `bcd16_t` value
`1234` produces `2340` for `* 10`, `123` for `/ 10`, and `34` for `% 100`.
Remainder by `2` is a low-bit mask; remainder by `5` masks the lowest digit and
conditionally subtracts five.

Cheap constant multiplication forms shifted copies and combines them with one
packed-BCD addition or subtraction. For example, `x * 9` is lowered as
`x * 10 - x`, while `x * 101` is `x * 100 + x`. These forms use one tightly
scoped `SED`/`CLD` pair around the final decimal add/subtract but never call a
multiply helper.

Chains of decimal-power operations are fused into one contiguous digit-window
copy. Expressions such as `(x / 100) * 100`, `(x / 100) % 1000`, and
`(x % 1000) * 100` therefore avoid intermediate BCD temporaries. The equivalent
truncation spelling `x - (x % 100)` is fused when `x` is an ordinary variable;
function calls, indirect values, and absolute hardware refs retain their full
source evaluation behavior.

Addition and subtraction wrap at the destination width. The compiler brackets
only their decimal `ADC`/`SBC` chains with `SED` and `CLD`, so generated code
leaves decimal mode clear.

Runtime conversion between binary and BCD variables is not implemented. BCD
multiplication, division, or remainder with any other operand, along with BCD
shifts, bitwise operations, unary minus, signedness shortcut casts, and BCD
bitfields, is rejected.

## Declarations and storage

### Global and local objects

Globals, named locals, parameters, return objects, and compiler temporaries are
all linker-resolved static storage.

An unqualified local still has automatic *initialization timing*: its initializer
runs whenever control reaches the declaration. The object itself is not created
on entry and destroyed on return. Without an initializer, its previous bytes
remain until overwritten.

```vcsc
uint16_t count_once(void) {
   uint16_t value := 1; // writes 1 on every call
   return value;
}
```

A function-scope `static` object is initialized once, either as static data or
by a startup initializer when its expression needs runtime code.

Local arrays reserve their complete size in the owning activation. After all
objects and archive members are selected, `vcsc-ld` overlays mutually exclusive
function activations by call-graph lifetime. Caller and callee bytes remain
distinct; sibling functions may occupy the same physical addresses.

### `const`

For a non-pointer object, `const` requires an initializer and prohibits later
writes. In `const uint8_t *p`, the pointed-to bytes are const while the pointer
object remains mutable. C's `uint8_t * const p` spelling is not supported.

### Memory regions

A source file may declare named storage regions:

```vcsc
mem fast { $start:0x0080 $size:0x0010 $rw };

fast uint16_t counter;
```

A used region must provide `$start`, either `$size` or `$end`, and exactly one
of `$rw` or `$ro`. The compiler emits metadata and the linker verifies that the
linker configuration defines the same start, size, and access type.

A region is treated as zero page when its declared address range fits entirely
within `$0000..$00ff`; the region's name has no special meaning.

### Pointers and arrays

Pointers are 16-bit addresses. Arrays decay to pointers to their first element
in pointer-valued expressions and assignments. Pointer addition and subtraction
scale by the pointed-to element size.

Subtracting compatible pointers produces an `int16_t` element count. Pointers
to incompatible element types cannot be subtracted. Typed object pointers may
convert to `void *`; converting `void *` back to a typed pointer requires an
explicit cast.

## References

A `ref` parameter is pass-by-reference:

```vcsc
void swap(ref int16_t a, ref int16_t b) {
   int16_t temporary := a;
   a := b;
   b := temporary;
}
```

The caller passes an address. Reads and writes in the callee dereference it.
The argument must be an lvalue of the exact declared type. The parameter's
backing symbol is pointer-sized.

Absolute `ref` declarations bind source names to memory-mapped addresses:

```vcsc
ref uint8_t port@0x10;
ref uint8_t status@STATUS_REG;
ref uint8_t write_only@[none/0x00];
ref uint8_t read_only@[0x30/none];
ref uint16_t split@[0x100/0x180];
```

`@address` is shorthand for `@[address/address]`. Loads use the read address;
stores use the write address. Reading a write-only ref, writing a read-only ref,
or taking the address of a split-address ref is rejected. Every `@...` address
binding requires a `ref` declaration; ordinary allocated objects cannot carry
an ignored or advisory placement annotation. An address binding with no usable
side (`@none` or `@[none/none]`) is also rejected on a `ref`. The address terms
are single integer literals or identifiers, not arbitrary expressions.

## Functions and calls

### Declarations and linkage

Each function name has exactly one signature. Compatible declarations followed
by one definition are allowed; conflicting declarations and multiple
definitions are errors.

```vcsc
extern uint16_t twice(uint16_t value);
```

`extern` emits imports as needed. `static` gives a function internal linkage.
Calls require a visible declaration and a directly named target.

Arguments are evaluated left-to-right. Value arguments permit the normal
integer widening and pointer conversions described above. `ref` arguments are
strict exact-type lvalues. Ordinary calls stage every converted argument in the
caller's activation before writing any callee parameter symbol; a function call
inside a later argument therefore cannot clobber an earlier argument through
sibling activation overlay.

### All parameters are static

Every non-void parameter of every ordinary VCSC function is a callee-owned
symbol. Before `JSR`, the caller evaluates and converts each argument and writes
it into the corresponding parameter symbol. No parameter bytes are pushed onto
a language stack.

```vcsc
uint16_t add(uint16_t left, uint16_t right) {
   return left + right;
}
```

`left` and `right` are fixed objects owned by `add`, not per-call variables.
The `static` modifier is accepted on a parameter but is redundant; all
parameters already use static storage. A memory-region modifier changes where
the parameter symbol is placed:

```vcsc
mem fast { $start:0x0080 $size:0x0010 $rw };

void capture(fast uint16_t value) {
   // value lives in the fast region
}
```

Combining `static` with a memory-region modifier is rejected as redundant and
ambiguous.

### Static activation and recursion

Every ordinary function body owns one logical activation consisting of its
parameters, named locals, return object, and private compiler scratch. The
compiler emits those pieces in function-owned activation segments. `vcsc-ld`
uses the complete acyclic call graph to assign one weighted activation path per
memory region: a callee starts after every live caller, while sibling functions
reuse the same bytes. Internal-linkage functions are qualified by object so
same-named static helpers in separate translation units remain distinct.

A function therefore cannot be active twice.

- Direct self-recursion is rejected.
- Mutual recursion is rejected.
- The compiler detects cycles wholly visible in one translation unit.
- `vcsc-ld` detects cycles completed across `.o26` files and `.l26` members.
- A call hidden in inline assembly or an opaque assembly object is outside that
  analysis; such code must not re-enter a live VCSC function.

This restriction applies even to parameterless functions and functions whose
bodies happen not to declare locals.

### Returns and `$$`

A value-returning function owns an exact-sized hidden zero-page return object.
Legal return types are:

- one- through four-byte ordinary binary integers;
- `bcd8_t` through `bcd32_t`;
- a 16-bit pointer.

`void` returns no object. Structs, unions, and arrays cannot be returned.

Inside a value-returning function, `$$` names its return object:

```vcsc
uint16_t twice(uint16_t value) {
   $$ := value + value;
   return;
}
```

`return expression;` writes the same object. The callee ends with `RTS`; it does
not place a language return value in A, X, or Y. After the call, a caller that
uses the value copies it from the callee's return symbol.

### Inline functions

`inline` requires source expansion at every call site:

```vcsc
inline uint8_t add_one(uint8_t value) {
   return value + 1`uint8_t;
}
```

The complete definition must be visible before a call. `extern inline` and an
inline `main` are rejected. Inline and non-inline declarations of the same name
are incompatible.

Each expansion receives private static symbols for its parameters, locals, and
return object, plus private source and assembler-local labels. It emits no
callable function symbol, `JSR`, `RTS`, or hardware-stack level. Calls made
inside the expanded body remain ordinary calls attributed to the enclosing
ordinary function. Direct and mutual inline-expansion cycles are rejected.

Expansion storage is intentionally not shared between call sites. This costs
RAM as well as ROM, so inline helpers should remain small.

## Expressions and operators

VCSC provides the usual arithmetic, comparison, logical, bitwise, shift,
address, dereference, indexing, member, ternary, comma, assignment, compound
assignment, and prefix/postfix increment/decrement operators supported by the
parser. All are compiler-defined built-ins.

Truth is zero versus nonzero. `!`, `&&`, and `||` produce `uint8_t`; `&&` and
`||` short-circuit. Comparisons also produce `uint8_t`.

Constant negative shift counts and counts at least as wide as the left operand
are errors. Signed right shift is arithmetic; unsigned right shift is logical.

`sizeof(type)` and `sizeof(expression)` produce `int16_t` and do not evaluate an
expression operand for side effects.

Runtime division or remainder by a known positive power of two greater than one
emits a performance warning. The compiler does not silently replace the
operation because shifts and masks differ for signed negative values.

## Initializers, strings, and xforms

Constant global and static initializers are emitted as bytes. A non-constant
global or static initializer creates a translation-unit startup function that
the runtime calls before `main`.

Braced initializers support scalars, arrays, structs, unions, nested aggregates,
and designated fields. Simple assignment also accepts a braced initializer:

```vcsc
Pair pair;
uint16_t values[3];

pair := { .second := 5, .first := 4 };
values := { 2, 3 }; // remaining elements are zero-filled
```

Compound assignment does not accept a braced initializer.

A string literal is a NUL-terminated read-only array of `int8_t`. It may
initialize an `int8_t` array or decay to `int8_t *`; writing through such a
pointer is invalid even though const-correctness is not yet fully enforced.

Named `xform` tables translate character and string literals at compile time:

```vcsc
xform upper { 'a' 0x41, 'b' 0x42 };
int8_t message[] := "abba"`upper;
```

## Control flow

Supported statements are blocks, declarations, expressions, `if`/`else`,
`while`, `do`/`while`, `for`, `switch`, `return`, `goto`, labels, `break`, and
`continue`. `break` and `continue` may name an enclosing labeled statement.

`case` labels accept constant expressions and inclusive ranges:

```vcsc
switch (value) {
   case 1:
      break;
   case 2 to 5:
      break;
   default:
      break;
}
```

A reversed range is diagnosed and compiled with its bounds exchanged.

## Inline assembly

Within a function, `asm` emits one assembler source line at that point:

```vcsc
asm lda #$01
asm sta COLUBK
asm @again:
```

The compiler leaves general assembler text under programmer control, with three
source-aware rewrites:

- exact `TEMPLATE` and leading `TEMPLATE_` identifiers inside a template
  instance receive the instance prefix and ordinary UTF-8 symbol mangling;
- absolute `ref` operands select the legal read or write address from the
  instruction's access kind;
- assembler-local `@labels` inside an inline-function expansion receive a
  private expansion prefix.

Loads from write-only refs, stores to read-only refs, and read-modify-write use
of a split ref are compile-time errors. Register, flag, decimal-mode, stack, and
cycle timing remain the programmer's responsibility.

## Generated-code and runtime model

The runtime workspace is eight zero-page bytes: one byte each for `arg0` and
`arg1`, plus two bytes each for `ptr0` through `ptr2`. Each cell is a separate
archive member, and stock startup selects the complete set. Compiler-generated
objects, inline assembly, and selected runtime helpers import only the cells
they reference. `vcsc-runtime.inc` defines short assembler aliases but imports
no storage.

One- through four-byte copies, fills, integer extension, negation, comparison,
and bitwise operations are emitted inline. Variable shifts call width-specific
8-, 16-, 24-, or 32-bit helpers. Multiplication and division/remainder likewise
select fixed-width helpers that use the already-live compiler expression
scratch for operands and results. Compile-time identities and annihilators are
removed before helper selection: multiplication by zero or one, division by
one, remainder by one, and division/remainder by a positive constant larger
than every possible left operand value lower to evaluation plus a copy or zero.
Operand side effects are preserved. Packed-BCD decimal-power operations,
remainder by two or five, cheap two-decimal-term constant multiplication, and
fused digit-window expressions also lower inline. All scalar helper families
stay at the eight-byte runtime baseline and own no private BSS. Objects wider
than four bytes may use the aggregate byte-copy/fill helpers.

Compiler expression scratch is part of the owning function activation. It is
pooled by nesting depth during compilation, then overlaid with mutually
exclusive function activations by the whole-program linker call graph.

There is no language software stack or frame pointer. The 6502 hardware stack
is used for `JSR`/`RTS` and the startup initializer cursor. A linker memory
region marked `callstack = callgraph` reserves two hardware-stack bytes per
active ordinary-function level, plus the documented startup allowance. Stack
use hidden in assembly must be declared separately by the integration's linker
configuration.

A, X, Y, and P are caller-clobbered across ordinary calls. No register carries
a language return value. Generated code expects decimal mode clear except
inside its own tightly scoped packed-BCD arithmetic.

The compiler applies a conservative peephole pass to generated assembly by
default. `-fno-peephole` disables every peephole rewrite for inspection and
regression work; `-fpeephole` explicitly re-enables the default. These switches
do not disable source-expression optimization.

Every recognized rewrite kind has a pattern-level optimizer regression. A
separate source-level regression compiles ordinary VCSC twice, first with
`-fno-peephole` to prove the compiler actually emits the candidate pattern and
then with the default enabled to prove the rewrite occurs. The currently emitted
source patterns cover duplicate `LDA`/`LDY` loads and branches or jumps to their
immediately following labels.

Inline assembly is opaque. The pass neither rewrites instructions inside an
`asm` block nor carries register, flag, or scratch-value facts across it. The
inline-assembly delimiters are removed from final `.s26` output even when
`-fno-peephole` is selected.

Source identifiers may contain valid UTF-8. Non-ASCII scalars are escaped into
assembler-safe `?uXXXX?` or `?uXXXXXXXX?` forms and converted back in user-facing
diagnostics.

## Intentional language limits

- Alias and conditional-compilation facilities are deliberately small.
- Mixed signed/unsigned arithmetic requires an explicit choice by the source.
- Typed object pointers convert to `void *`; the reverse conversion is explicit.
- `switch` case expressions use the compiler's restricted constant-expression
  grammar rather than arbitrary runtime expressions.
- Assembly calls and stack operations are not inferred by source call-graph
  analysis.

## Minimal example

```vcsc
include "vcs.c26"

void bump(ref int16_t value) {
   value++;
}

uint16_t twice(uint16_t value) {
   return value + value;
}

void main(void) {
   int16_t counter := 1;
   uint16_t result := twice(21`uint16_t);

   bump(counter);
   if (counter == 2 && result == 42) {
      COLUBK := 0x84;
   }
}
```

## Unsupported/removed parent project features

- Floating-point types, literals, helpers, and libraries.
- Big-endian types and endian shortcut casts.
- Ordinary function overloading.
- Operator overloading and `$exactops`.
- Function pointers and indirect calls.
- Variadic functions and `stdarg` support.
- Recursive or reentrant functions and software call frames.
- Struct, union, and array returns.
- The parent runtime's software stack, frame pointer, `sbrk`, and interrupt-entry library.

### Page-aware data objects

Every file-scope data-object definition is emitted in a private compiler-owned
segment. This preserves the size and boundary of even a one- or two-byte scalar
so the linker can reuse same-page holes without changing source order or adding
padding. The ordinary placement is a soft preference only.

At file scope, `page` requests hard 256-byte page containment, for example
`page const uint8_t table[80] := { ... };`. The same private segment is marked
with `.pagecontain`, and for objects of at most 256 bytes the compiler also
emits `.indexrange 0, size-1` as explicit full-declaration access metadata. The
linker must find a legal address or reject the link. A non-inline function definition is likewise emitted as its own `CODE` layout,
so the linker knows its exact boundary and size. Ordinary functions receive the
same soft containment preference. `page` on a function definition upgrades that
function to hard containment; declarations without a body reject `page` because
the final size is not yet known. Locals, extern data declarations, absolute refs,
and named `mem` data regions do not yet accept the hard `page` modifier. Ordinary
objects in named `mem` regions still receive private soft-placement segments.
