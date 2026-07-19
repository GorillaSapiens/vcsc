# N compiler and language notes

N is a mostly C-like systems language aimed at small targets, especially 8-bit machines. This document describes the language model and the current compiler/runtime behavior as implemented in this tree.

## Big differences from C

- Assignment uses `:=` instead of `=`.
- Braces are required on `if`, `else`, loops, and similar statements. There is no dangling-`else` ambiguity.
- Included files behave like `pragma once` automatically. Include-file identity is based on an MD5 of file contents, so duplicate content is only compiled once.
- There are no implicit built-in integer type names. Types are declared explicitly.
- Struct and union names become types directly. There is no separate `typedef struct foo foo;` dance.
- Functions return `void`, an integer value no wider than two bytes, or a pointer.
- Static function parameters are supported.
- Operator overloading is intentionally unsupported.
- Strings can be translated through named `xform` mappings.
- Inline assembly statements are supported as raw one-line passthroughs with `asm ...` inside functions.

## Aliases

The compiler supports newline-terminated lexical aliases:

```n
alias LIMIT 314
alias inc(x) (x + 1)
alias add(a,b) (a + b)
```

Object-like aliases replace a bare identifier with the stored replacement text. Function-like aliases declare a fixed parameter list and are expanded only when invoked as `name(...)` immediately after the alias name.

Current alias rules:

- alias names are unique within a translation unit; redefining an alias name is a hard error even if one form is object-like and the other is function-like
- function-like aliases are not overloaded with object-like aliases
- function-like alias arguments are split using balanced parentheses and quoted string/character handling
- alias parameters are local to one expansion and shadow outer/global aliases only for that expansion
- recursive alias expansion is rejected

Pitfalls:

- aliases are lexer-level textual substitution, not typed functions or templates
- a function-like alias name used without an immediate `(` is an error, so `foo(...)` works but `foo (...)` does not
- object-like alias replacement text is the rest of the definition line after stripping trailing `/* ... */` and `// ...` comments outside quoted text; if you put a semicolon there, that semicolon becomes part of the expansion text
- argument splitting tracks parentheses plus quoted strings/chars; careless use of commas in other syntactic constructs can surprise you
- repeated parameter use duplicates the argument text, so side-effect-heavy arguments are easy to misuse

Use aliases for small, local convenience rewrites... not for hiding control flow, declarations, or anything that would make the source lie about what it does.

## Conditional compilation

The lexer also supports simple beginning-of-line conditional directives inspired by the C preprocessor:

```n
alias FEATURE 2

#if defined(FEATURE) && (FEATURE >= 2)
alias MODE 1
#else
alias MODE 0
#endif

#ifdef FEATURE
#ifndef DISABLE_THING
...
#endif
#endif
```

Supported directives:

- `#if expr`
- `#ifdef NAME`
- `#ifndef NAME`
- `#elif expr`
- `#else`
- `#endif`

Current expression support inside `#if` / `#elif`:

- integer literals in the same forms the lexer already accepts
- `defined(NAME)` and `defined NAME`
- object-like alias expansion
- unary `!`, unary `+`, unary `-`
- `&&` and `||`
- integer comparisons `== != < > <= >=`
- parentheses for grouping

Current rules and pitfalls:

- directives only count at beginning-of-line, optionally preceded by horizontal whitespace
- undefined names in conditional expressions evaluate to `0`
- object-like aliases expand recursively inside conditional expressions; recursive alias use there is rejected
- function-like aliases do not expand in conditional expressions yet
- skipped branches are lexer-inert other than nested conditional directives, so syntax errors inside a skipped branch are ignored as long as the conditionals balance
- conditional blocks must balance before the end of the current source input

As with aliases, keep conditional compilation boring and local. It is useful for configuration gates and small compile-time switches... not for turning one source file into twelve different personalities.

## Type system

The stock machine interface exposes four integer types, one pointer type, and `void`:

```n
type void     { $size:0 };
type *        { $size:2 $integer:unsigned $endian:little };
type int8_t   { $size:1 $integer:signed };
type uint8_t  { $size:1 $integer:unsigned };
type int16_t  { $size:2 $integer:signed $endian:little };
type uint16_t { $size:2 $integer:unsigned $endian:little };
```

### Required type declarations

The compiler requires these declarations when their language semantics need them:

- `*` ... the two-byte machine pointer type
- `uint8_t` ... result type used by comparisons and logical expressions
- `int8_t` ... character constants and string-element type
- `int16_t` ... untyped integer literals, `sizeof`, enum defaults, and pointer differences
- `void` ... the canonical no-value type used for empty parameter lists and no-result functions

The stock machine definition also supplies `uint16_t`. The names `bool`, `char`, and `int` are not built in or reserved. A source file may introduce them as transparent aliases, for example:

```n
typedef uint8_t bool;
typedef uint8_t char;
typedef int16_t int;
```

Until such a typedef appears, those names are ordinary identifiers rather than types.

Integer value types must be exactly one or two bytes and say whether they are signed or unsigned with `$integer:signed` or `$integer:unsigned`. Untyped integer literals larger than 16 bits are rejected. Comparisons and logical expressions produce an ordinary `uint8_t`, not a special boolean-only type. `void` remains flagless. Floating-point type flags are rejected.

Bitfield reads follow the declared integer style of the field type: signed integer types sign-extend, unsigned integer types zero-extend.

### Type flags

Recognized flags include:

- `$size:N`
- `$integer:signed`
- `$integer:unsigned`

Floating-point flags are not recognized as value types; `$float` and `$float:*` declarations are rejected.

Operator overloading and `$exactops` are not supported. The lexer recognizes their spellings only to issue direct diagnostics.

Multibyte integer and pointer types use `$endian:little`. `$endian:big` is rejected; the target language has no selectable byte order.

## Declarators

The compiler supports:

- pointers
- arrays
- functions
- combinations such as arrays of pointers and multidimensional arrays where the grammar allows them

Current `const` behavior on declarators follows the common C reading for leading `const` on pointer declarations:

- `const T* p` means a pointer to const `T`
- the pointer object itself is mutable, so it does not require an initializer just because the pointee type is const
- non-pointer declarations such as `const T x` are const objects and require an initializer
- syntax for a const pointer object in the C sense (`T * const p`) is not supported

Struct and union declarations immediately introduce their names as usable types.


### Pointer arithmetic

Subtracting two compatible object pointers yields `int16_t`, the signed type with
the same width as a VCS pointer. The value is an element count, not a byte count:
the compiler subtracts the 16-bit addresses and divides the result by the size of
the pointed-to type. Byte-sized element pointers therefore need no scaling.
Pointer subtraction between incompatible pointed-to types is rejected. As in C,
a result outside the range of `int16_t` is undefined.

### Function declarations

Ordinary function declarations work. Multiple compatible declarations are allowed, and a later definition may follow an earlier declaration. Incompatible redeclarations are rejected.

```n
int16_t twice(int16_t x);

int16_t main(void) {
   return twice(21);
}

int16_t twice(int16_t x) {
   return x + x;
}
```

`extern` function declarations are also supported and cause the compiler to emit an import for the referenced symbol. Direct calls require a visible function signature in the current translation unit or via an `extern` declaration; the compiler rejects bare calls to unknown symbols instead of guessing at a call ABI.

### One function signature per name

Each source-level function name identifies exactly one signature. Matching declarations and a later definition are allowed, but declaring the same name with different parameter or return types is rejected. Ordinary function overloading is intentionally unsupported.

Direct calls are checked against that single visible signature. Exact matches, safe widening integer conversions, null pointer literals, and object-pointer conversion to `void*` are accepted. `ref` parameters require an lvalue of the exact declared type, and converting `void*` back to a typed pointer requires an explicit cast.

### Function pointers and indirect calls

Function pointers are not supported. The parser still recognizes pointer-to-
function declarators so the compiler can issue a direct diagnostic, but such
declarations are rejected. Function names may appear only as direct call
targets; using a function name or `&name` as a value is also rejected.

This keeps the call graph statically knowable and eliminates the indirect-call
runtime trampoline and its software-stack frame. Linker-visible graph metadata
also lets VCS configurations derive a hardware-stack reserve from the longest
whole-program call path.


### Variadic functions

Variadic functions and variadic callable types are not supported. The lexer
rejects `...` directly. The reduced VCS ABI has no `stdarg`, `va_list`, hidden
variadic metadata, or raw variadic argument blob.

## Expressions

### Truthiness

Truth-testing uses the builtin zero/nonzero rule. The compiler applies it to:

- `if (x)`
- `while (x)`
- `for (...; x; ...)`
- `!x`
- `x && y`
- `x || y`
- conditional-expression tests

`!`, `&&`, and `||` are builtin short-circuit operators. Truth is zero versus nonzero; there is no user-defined truthiness hook.

### Literal typing, casts, and mixed integer expressions

The language model for integer expressions is deliberately simpler than C:

- a literal used only with other literals is folded on the host at compile time, and the result remains a literal
- a literal interacting with a typed nonliteral operand adopts that operand's type for the operation
- a literal consumed by a typed sink such as assignment, return, or argument passing adopts the sink type at that boundary
- two operands of the same type produce that same type
- for integers of different widths, the narrower operand widens to the wider width first
- widening sign-extends signed integers and zero-extends unsigned integers
- narrowing truncates bitwise; there is no saturation or range check by default
- if width adjustment leaves one operand signed and the other unsigned, the expression is rejected unless the user writes an explicit cast

This is intentionally less C-like than the usual arithmetic conversions. The compiler should widen by width automatically, but it should not guess signedness automatically.

### Cast forms

The language uses two cast families:

- backtick casts such as ``123`u2`` are literal-only and always happen immediately on the host
- parenthesized casts such as `(u2)expr` are ordinary expression casts; when applied to a literal they may also fold on the host at compile time

There are also two shortcut casts:

- ``($signed)expr``
- ``($unsigned)expr``

They preserve width while changing signedness, but are legal only on already-typed ordinary fixed-width integers. They are never legal on literals or pointers. The former endian shortcut casts `($big)` and `($little)` are rejected.

### Shifts

The intended shift rules are:

- the result type is the type of the left operand after ordinary literal typing and any explicit casts have been applied
- if the right operand is a literal, it adopts the type needed by the surrounding operation just like any other literal
- a literal-only shift is folded on the host and remains a literal until consumed by a typed sink
- signed right shift uses arithmetic shift
- unsigned right shift uses logical shift
- negative constant shift counts are hard errors
- oversized constant shift counts are hard errors
- runtime negative shift counts are not a supported language feature; codegen should not reinterpret `x << -n` as `x >> n`


### Byte order

All multibyte integers and pointers are little-endian. Assignments, casts, arithmetic, comparisons, indexing, initializers, calls, and returns therefore use one fixed byte order. Big-endian type declarations and endian shortcut casts are rejected.

## Inline assembly

Inside a function body, a line of the form:

```n
asm nop
asm lda #$01
asm loop_start:
```

emits the remainder of the line directly into the generated assembler output at that point.

Current rules:

- it is a single-line statement
- ordinary assembler text is emitted unchanged after the `asm ` prefix is removed
- source-level absolute `ref` names in instruction operands are resolved according to the opcode:
  - loads, compares, and other read instructions use the ref read address
  - stores use the ref write address
  - read-modify-write instructions require identical non-`none` read and write addresses
- reading from a write-only ref, writing to a read-only ref, or using a split-address ref with a read-modify-write instruction is a compile-time error
- immediate/control-address uses require one identical read/write address; split refs have no canonical address
- register and flag clobber tracking remains the programmer's responsibility

For example, with the VCS TIA declarations, `asm lda CXM0P` emits `lda $30`, while `asm sta VSYNC` emits `sta $00`. `asm lda VSYNC` is rejected because VSYNC is write-only.

## Operators

All language operators use compiler-defined semantics. User-defined operator functions,
`operator...` declarators, `$exactops`, weak operator dispatch, and operator ABI symbols
are unsupported.

Explicit runtime division or remainder by a compile-time positive power of two
greater than one emits a performance warning for `/`, `%`, `/=`, and `%=`. The
compiler does not silently replace these operations: signed division truncates
toward zero, signed remainder follows the dividend, right shift may round
differently for negative values, and a mask produces a nonnegative residue. The
programmer may write the shift or mask explicitly when those semantics are
intended. Literal-only expressions are folded before lowering and do not warn;
divisor one and non-power-of-two constants also remain silent.

The lexer retains explicit rejection rules so obsolete source receives a
clear diagnostic rather than a generic parse error.

Compound assignment is builtin syntactic sugar: for example, `a += b` computes the
builtin `a + b` result and stores it back through the original lvalue. `++` and `--` are
also builtin and support ordinary, indirect, absolute, pointer, and bit-field lvalues.

### User identifier symbol escaping

Source identifiers may contain valid UTF-8 non-ASCII characters. The lexer validates UTF-8 inside the `{IDENT}` rule before alias lookup, typedef lookup, symbol table insertion, or any other processing. Malformed UTF-8 in an identifier is a compile-time error.

The compiler keeps assembler-safe ASCII identifiers unchanged, but each non-ASCII Unicode scalar in an identifier is escaped in place before it reaches assembler and linker symbols:

```text
cafe     -> cafe
café     -> caf?u00E9?
λ_count  -> ?u03BB?_count
🦍       -> ?u0001F98D?
```

The escape uses only assembler-identifier-safe characters. ASCII punctuation that is not valid in N identifiers is not accepted as source identifier text; `?` is therefore reserved for compiler-generated Unicode escapes in emitted symbols.

Diagnostics reverse these escapes when reporting user-facing names, so an error involving `🥹` is printed as `🥹`, not `?u0001F979?`. Diagnostic source columns are one-based. For UTF-8 identifiers, columns are counted in Unicode scalar values rather than raw bytes, so the reported column for a non-ASCII identifier points at the source character the programmer sees.

## `ref` parameters

`ref` parameters are real pass-by-reference parameters.

- callers pass an address, not a copied value
- reads and writes in the callee dereference the referenced object
- direct-call validation distinguishes `ref` parameters from value parameters

Example:

```n
void swap(ref s2 a, ref s2 b) {
   s2 t;
   t := a;
   a := b;
   b := t;
}
```

### `static ref` parameters

`static ref` parameters work. Their backing symbol storage is pointer-sized, not referent-sized.

### Absolute `ref` declarations

The compiler supports `ref` declarations bound directly to absolute addresses. This is intended for memory-mapped hardware registers and similar machine-defined storage that already exists outside normal compiler allocation.

Supported forms:

```n
ref u8 port@0x10;
ref u8 status@STATUS_REG;
ref u8 vsync@[none/0x00];
ref u8 cxm0p@[0x00/none];
ref u16 banked@[0x100/0x180];
```

Meaning:

- `ref T x@addr` is shorthand for `ref T x@[addr/addr]`
- `@[read/write]` gives separate address expressions for loads and stores
- either side may be `none` to model read-only or write-only hardware
- each side intentionally accepts only a single integer literal or identifier, not an arbitrary expression

Intentional behavior and limits:

- reading uses the read address
- writing uses the write address
- storing to a `@[read/none]` declaration is rejected as write to a read-only absolute ref
- loading from a `@[none/write]` declaration is rejected as read from a write-only absolute ref
- taking the address of a split-address absolute ref such as `@[0x100/0x180]` is rejected by design, because it does not have one canonical address
- if both sides name the same address, `&name` behaves normally
- identifiers used in the address slots are passed through to the assembler/linker; the compiler does not require them to be declared as N symbols

Absolute address binding is only meaningful on `ref` declarations. Using `@...` on a non-`ref` declaration is accepted but ignored, and the compiler warns about it.

## Function parameters

### Direct functions

Every ordinary parameter of a directly named function is symbol-backed by default. The callee owns one fixed storage symbol for each parameter, and the caller evaluates arguments left-to-right and writes each converted value directly into the corresponding symbol before `jsr`. Fixed direct-call parameters do not occupy the N software stack.

An unqualified parameter uses ordinary BSS-backed storage. A `mem` modifier may place it in another region; a zero-page region produces zero-page parameter symbols. The older `static` parameter spelling remains accepted as a redundant compatibility spelling while the language is being reduced.

Compiler-generated temporary storage is pooled by function and nesting depth. Symbols are named `__n65_scratch_N`; sequential expressions in the same non-reentrant function reuse the same depth slot, while nested expressions receive deeper slots. Different functions receive distinct physical slots because caller scratch can remain live across a callee invocation. Each slot is emitted once at the maximum size observed for that depth.

An ordinary direct call leases the caller function's current scratch depth while evaluating and converting arguments, then copies values into callee-owned parameter symbols. The same live lease may capture A:X when the surrounding expression needs a memory-backed converted result. The lease remains caller-private transitional machinery, not parameter storage and not part of the function ABI. LIFO lease checks and an end-of-compilation zero-depth check turn accidental lifetime overlap into a compiler error.

Several common one-byte paths bypass scratch entirely. Discarded `uint8_t` increment/decrement, unsigned byte comparisons against constants or byte lvalues, constant byte stores, and byte stores into absolute hardware refs emit direct 6502 instructions. A simple unsigned one-byte runtime index into an array whose element size is a power of two is scaled inline through compiler-owned `arg0:arg1`; the resulting element address is left in `ptr0`, with no generic multiplication helper. This is sufficient for natural `music[music_index].field` access in the VCS sound example, including indices whose scaled offset crosses a page.

When two operands of one binary expression are direct fields of the same runtime-indexed aggregate element, with structurally identical index expressions and no pointer, bitfield, absolute-ref, conversion, or side-effect ambiguity, the compiler calculates the element address once and loads both fields by fixed offsets from `ptr0`. Other cases conservatively calculate each address independently. Unsupported index forms continue to use generic lowering, now backed by the same lifetime pool rather than fixed per-site objects. No compiler source path emits `_pushN` or `_popN`.

Every function body owns one fixed activation record containing its parameters, automatic locals, and return object when present. Functions are therefore non-reentrant even when they take no parameters. The compiler rejects direct and mutual call cycles inside a translation unit, and the linker rejects cycles completed across object files.

Function pointers are not part of the VCS subset. Every call target must be a directly named function, so call-graph cycle analysis sees every edge and no indirect-call ABI is required.

## Storage classes and memory regions

### Globals, locals, static locals

The compiler supports:

- globals
- fixed-address automatic locals
- function-scope `static`
- mem-backed symbol storage for locals and parameters

Every named automatic local receives a function-qualified symbol. Its initializer, if any, executes when control reaches the declaration on each function invocation; fixed storage does not give it C `static` duration semantics. Distinct function frames are not overlaid yet.

### Memory regions

Memory region handling is driven by `mem` declarations, not by hard-coded names.

A declaration is treated as zero-page only if its referenced `mem` declaration fits entirely inside `$0000..$00FF` according to `$start` plus `$size` or `$end`.

So a region named `banana` can be zero-page if its declared address range fits there, and a region literally named `zeropage` is **not** magically zero-page if its range does not fit.

When a `mem` region is actually used for symbol storage, the compiler emits object metadata describing the region name, `$start`, size, and `$rw`/`$ro` type. `n65ld` validates that metadata against the linker config `MEMORY` entry before laying out the image. This turns stale cfg/source mismatches into link-time errors instead of silent placement surprises.

For validation to work, any used `mem` declaration must provide `$start`, either `$size` or `$end`, and exactly one of `$rw` or `$ro`.

## Initializers

### Static and global initializers

The compiler supports real constant-expression evaluation for static/global initializers, including:

- integers
- booleans
- comparisons and logical expressions
- ternary expressions
- nested aggregate initializers
- simple relocatable address constants such as `&symbol + 1`

When a non-constant global initializer cannot be emitted as static bytes, the compiler places the object in writable storage and emits a translation-unit `__init_*` function so startup code can perform the runtime initialization before `main`.

### Braced assignment

Simple assignment also accepts braced initializers. The compiler lowers these through the same initializer machinery used for declarations, so scalar, array, struct, union, designated aggregate, indirect, static/global, absolute-ref, and bitfield assignment targets use the target type as the initializer sink.

Examples:

```n
int16_t x;
int16_t a[3];
Pair p;

x := { 1 };
a := { 2, 3 };              // remaining bytes/elements are zero-filled
p := { .b := 5, .a := 4 };
```

Braced initializers are valid only for simple assignment. Compound assignment operates on ordinary expressions, so forms such as `x += { 1 }` are rejected.

### String initializers

Strings can initialize pointer values and byte arrays where appropriate. String bytes may be translated through an `xform`. A string literal is a NUL-terminated `uint8_t` array stored in read-only output storage. In a pointer initializer it decays to `uint8_t *`; the type system does not yet enforce `const`, so writing through that pointer is invalid even though the declaration is accepted.

## Arrays

### Local arrays

Automatic local arrays receive function-qualified fixed storage for their full declared size. Their initializers execute at run time whenever control reaches the declaration.

In a pointer-targeted initializer or assignment, an array expression decays to
its first-element address. Compiler-generated `__n65_scratch_N` temporaries
retain the destination pointer declarator, so local, static, global, member,
and indirect pointer destinations receive the array address rather than bytes
copied from the first element.


### Return object: `$$` and A:X

Inside a function that returns a value, `$$` names the current function's
return object. It behaves like a scalar or pointer lvalue, so code may assign to
it directly, read it back, or use compound assignment on it. The spelling
`return expr;` writes the converted expression into the same object.

The only legal return types are `void`, one- or two-byte little-endian integers,
and 16-bit pointers. A one-byte result is returned in A. For a two-byte integer
or pointer, A holds the low byte and X holds the high byte. `$$` is a hidden
callee-owned zero-page symbol. The common epilogue uses a direct `LDA` for an
8-bit result or direct `LDA`/`LDX` loads for a 16-bit result, then executes RTS.
On the VCS these assemble as zero-page instructions.

Example:

```n
uint16_t twice(uint16_t value) {
   $$ := value + value;
   return;
}
```

A conventional return is equivalent:

```n
uint16_t twice(uint16_t value) {
   return value + value;
}
```

The caller never allocates callee return storage. An ordinary direct call may
copy A:X into a live caller-function `__n65_scratch_N` lease so the
memory-based expression machinery can consume it; that scratch is not part of
the function ABI.
Indirect calls are unsupported; no call path uses an indirect-call software-stack frame.

Functions returning aggregates, arrays, floating-point values, or values larger than two bytes are rejected at compile time. The
`$$` name is reserved; it cannot be declared as a global, local, function, or
parameter name, and it is invalid in `void` functions or outside a function
body.

### Array returns

Array returns are rejected. Pass an explicit result pointer instead.

## Control flow

The compiler supports:

- `if` / `else`
- `while`
- `do` / `while`
- `for`
- `switch`
- labeled `break` and `continue`
- `goto`

### `switch` / `case`

`switch` compares the switch expression against each `case` label in source order.

`case` labels accept either a single numeric primary expression or an inclusive range:

```n
switch (x) {
   case 1:
      break;
   case 2 to 5:
      break;
   default:
      break;
}
```

Range bounds are inclusive on both ends. If the programmer writes a reversed range such as `case 9 to 3:`, the compiler emits a warning and compiles it as `case 3 to 9:`.

`default` remains optional and may appear anywhere inside the switch body.

## Strings and xforms

A string literal may optionally specify an `xform` name after a backtick.

```n
int8_t msg1[] = "hello"`cp437;
int8_t msg2[] = "hello";
```

## ABI and runtime notes

### Hardware stack vs N stack

The 6502 hardware stack is used for `jsr`, `rts`, temporary saves, and similar low-level operations. A linker `MEMORY` region marked `callstack = callgraph` is shortened from the top according to the longest linked source-level call path. The present reserve is four bytes per active function level: a two-byte return address plus a two-byte allowance for compiler-generated `fp` preservation/transient saves.

Inline-assembly stack operations and stack use hidden inside separately assembled routines are not included in that calculation yet and must be treated as future work.

Direct fixed parameters and named automatic locals are callee-owned symbols.
Compiler-generated code emits no `_pushN` or `_popN`, and the runtime no longer
provides `_nl_sp` or any software-stack helper. Lifetime-pooled BSS scratch uses
`_nl_fp` only as a temporary addressing base.

### `_nl_fp`

Startup initializes `_nl_fp` from `__stack_start` to give temporary scratch redirection a
deterministic baseline. Compiled functions have no software-stack entry prologue.

### Frame pointer preservation

Compiled calls save and restore the caller's frame pointer around calls so nested calls do not smash the caller's frame-relative addressing.

### Peephole optimization

The compiler runs a conservative peephole pass over compiler-generated assembly after code generation. It removes duplicate `lda`, `ldx`, and `ldy` loads when the register value and the load's N/Z flag effects are already proven equivalent or the load's N/Z flag effects are proven dead, removes redundant stores to compiler-owned scratch bytes when the same value is already known to be there, removes redundant `tax`, `tay`, `txa`, and `tya` transfers when the destination register and observable N/Z flag effects are already equivalent, removes redundant repeated simple status-flag setters (`clc`, `sec`, `cld`, `sed`, `cli`, `sei`, and `clv`) when the same flag state is already proven, folds adjacent `lda #byte` plus immediate `and`, `eor`, or `ora` into a single equivalent `lda #byte`, removes a dead adjacent `lda`/`ldx`/`ldy` when it is immediately overwritten by another load into the same register before the earlier value or N/Z flags can be observed, removes conditional branches that are provably never taken from known N/Z, C, or V flag facts, removes `jmp` and all 6502 conditional branches (`bcc`, `bcs`, `beq`, `bmi`, `bne`, `bpl`, `bvc`, `bvs`) that target the immediately following label or an adjacent label in the same following label run, and keeps byte-saved statistics for `-X peephole`.

The pass tracks compiler-owned zero-page scratch operands such as `arg0`, `fp`, and `ptr0` conservatively. Stores to a tracked scratch byte update or invalidate the corresponding known memory value, so a later load or duplicate scratch-store is removed only when the store proves the same value is present. If the source register's exact value is unknown, a store to tracked scratch still proves that the source register and scratch byte contain the same byte; a following reload of that scratch byte can therefore be removed only when the reload's N/Z flag effects are proven dead. Dead adjacent load removal is limited to side-effect-free compiler-known loads, namely immediates and compiler-owned zero-page scratch bytes; untracked memory reads are preserved. `brk` is treated as observing N/Z through the status byte it pushes. Conditional branches are treated as N/Z liveness barriers unless the branch itself is removed as a branch to the next label or as provably never taken, because a C/V-only branch can skip a later N/Z overwrite. The never-taken branch cleanup is intentionally one-sided: it removes false `beq`/`bne`/`bmi`/`bpl` branches when N/Z is known from a plain immediate byte, false `bcc`/`bcs` branches after known `sec`/`clc`, and false `bvs` branches after known `clv`; it does not replace always-taken conditional branches with `jmp`, because that is usually larger on 6502. Stores through unknown addresses and calls reset the tracked memory facts rather than guessing. Peephole byte accounting recognizes one-byte implied/register instructions, accumulator shifts/rotates, relative branches, `jmp`/`jsr`, immediate operands, compiler zero-page operands, compiler zero-page indexed operands such as `arg0,x`, and indirect zero-page forms. The immediate ALU fold is deliberately limited to plain byte literals so expression-valued assembler operands are not guessed at by the compiler.

Inline `asm` statements are bracketed internally and treated as raw programmer assembly, even when the assembler text begins with whitespace. The peephole pass removes those internal markers from final assembly and resets its facts around the programmer-owned line instead of rewriting it.

## Intentional limitations and non-goals

The following limits are deliberate in the language and compiler design, not unknown missing work:

- Aliases are lexer-level textual substitution. They are not typed macros, templates, or inline functions; function-like aliases require `name(...)` with no whitespace before `(`, and repeated parameters duplicate the argument text.
- Conditional compilation is intentionally small. `#if` and `#elif` accept only the expression subset listed above, and function-like aliases are not expanded there.
- There is no separate textual preprocessor phase. Variadic functions are intentionally unsupported, and the lexer rejects `...`.
- `void*` conversion is one-way by default: typed object pointers may convert to `void*` or `const void*`, but converting `void*` back to a typed pointer requires an explicit cast.
- Ordinary mixed signed/unsigned integer operators require an explicit cast when width adjustment leaves the signedness ambiguous. The compiler widens by width, but it does not guess signedness.
- `switch case` labels use the compiler's restricted constant-case grammar. Numeric literals, character literals, enum constants, unary operators, and parenthesized forms are supported, but arbitrary identifier expressions such as `case y + 2:` are not.
- Floating-point types and literals are rejected.

## Incomplete or limited features

A few sharp edges remain:

- symbol-backed-parameter cycle checking spans the selected object files at link time, but truly dynamic call targets cannot be proven safe
- shift-count diagnostics are lax

## Minimal example

```n
type void     { $size:0 };
type *        { $size:2 $integer:unsigned $endian:little };
type int8_t   { $size:1 $integer:signed };
type uint8_t  { $size:1 $integer:unsigned };
type int16_t  { $size:2 $integer:signed $endian:little };
type uint16_t { $size:2 $integer:unsigned $endian:little };

void bump(ref int16_t x) {
   x++;
}

int16_t main(void) {
   int16_t x;
   x := 1;
   bump(x);
   if (x) {
      x += 2;
   }
   return x;
}
```
