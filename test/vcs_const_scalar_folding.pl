#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: compile
# expectstdout: vcs_const_scalar_folding ok
# expectexit: 0

# A `const` scalar's value is known when its initializer folds, so an expression that
# uses it should be computed by the compiler rather than by the processor.
#
# What this pins is measured behaviour, and the measurement corrected the premise.  The
# obvious framing -- "a use should be an immediate instead of a load" -- is nearly
# worthless here: a bare read is ALREADY four instructions, because `v := W` compiles to
# the same code as `v := 300`.  Replacing one load with one immediate saves nothing.
#
# The real cost is arithmetic ON the constant.  When the compiler cannot fold, the
# expression runs through scratch a byte at a time and then copies the result out:
#
#     uint16_t v; v := W & 255;     26 instructions, for a value already known
#     uint16_t v; v := 300 & 255;    4 instructions, the same value
#     uint8_t w;  w := 1 << K;      20 instructions
#     uint8_t w;  w := 1 << 7;       2 instructions
#
# So the property under test is FOLDING, and each case is compared against the identical
# expression written with the literal in place of the constant.  Matching the literal is
# the strongest available statement: it says the constant is worth exactly what the
# number is worth, and no more.
#
# What must NOT change is pinned just as firmly, because a fold that is too eager is a
# wrong answer rather than a slow one:
#
#   * A local declaration shadows a file-scope one.  `page const uint8_t K := 7;` beside
#     `uint8_t K;` in a function body is legal, and folding that use to 7 would silently
#     compute the wrong thing.
#   * The object KEEPS its storage.  Only the read is folded.  A non-static object is
#     `.export`ed, carries ABI and use-contract metadata, and can be named by inline
#     assembly -- none of which can see an expression-level fold, so an elided label
#     would break all three.
#   * The gate is the same one the link-time table record uses: plain read-only ROM only.
#     A `const` object in a NAMED memory region is excluded on purpose, because there the
#     byte's addressability is the contract rather than its value, and folding a read
#     would erase the very reference the linker diagnoses.

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);

@ARGV == 2 or die "usage: $0 REPO TMP\n";
my ($repo, $tmp) = @ARGV;
make_path($tmp);
$repo = abs_path($repo) or die "could not resolve repo\n";
$tmp = abs_path($tmp);

my $cc1 = File::Spec->catfile($repo, 'compiler', 'vcsc-cc1');
-f $cc1 or -x $cc1 or die "vcsc-cc1 not built at $cc1\n";
my $runtime = File::Spec->catdir($repo, 'test');

sub capture {
   my (@cmd) = @_;
   my $err = gensym;
   my $pid = open3(my $in, my $out, $err, @cmd);
   close($in);
   my $stdout = do { local $/; <$out> };
   my $stderr = do { local $/; <$err> };
   waitpid($pid, 0);
   $stdout = '' unless defined $stdout;
   $stderr = '' unless defined $stderr;
   return ($? >> 8, $stdout, $stderr);
}

sub compile_cc1 {
   my ($source, $tag) = @_;
   my $src = File::Spec->catfile($tmp, "$tag.c26");
   my $out = File::Spec->catfile($tmp, "$tag.s26");
   unlink $out;
   open(my $fh, '>', $src) or die "could not write $src: $!\n";
   print {$fh} qq{include "machine_6502.c26"\n$source\n};
   close($fh);
   my ($rc, $so, $se) = capture($cc1, '-quiet', '-I', $runtime, '-o', $out, $src);
   my $log = $se . $so;
   my $at = index($log, 'Error');
   my $err = $at >= 0 ? substr($log, $at) : '';
   $err =~ s/\s+\z//;
   return ($rc, $err, (($rc == 0 && -f $out) ? $out : undef));
}

# Instruction count of the one procedure that matters.  Counting emitted instructions
# rather than comparing text is deliberate: the claim is about work done, and a rewrite
# that emits different code for the same work would be a false failure.
sub proc_instructions {
   my ($asm) = @_;
   open(my $fh, '<', $asm) or die "could not read $asm: $!\n";
   my $code = do { local $/; <$fh> };
   close($fh);
   my ($body) = $code =~ /^\.proc main\b(.*?)^\.endproc/ms;
   defined $body or return -1;
   my $n = 0;
   for my $line (split /\n/, $body) {
      $n++ if $line =~ /^\s+(lda|sta|ldx|ldy|adc|sbc|and|ora|eor|cmp|cpx|cpy|clc|sec|asl|lsr|rol|ror|inc|dec|tax|tay|txa|tya|jmp|jsr|beq|bne|bcc|bcs|bcs)\b/;
   }
   return $n;
}

sub asm_text {
   my ($asm) = @_;
   open(my $fh, '<', $asm) or die "could not read $asm: $!\n";
   my $code = do { local $/; <$fh> };
   close($fh);
   return $code;
}

# --- the fold, each measured against the identical literal expression ------------
# Every case is a pair: the constant form and the literal form.  The constant form must
# match the literal form, which is also a check that the test is looking at a real
# difference -- if the two were already equal there would be nothing to prove.
my @folded = (
   ['a 16-bit mask',      'page const uint16_t W := 300;', 'uint16_t v; v := W & 255;',
    '',                                                    'uint16_t v; v := 300 & 255;'],
   ['a shift by a const', 'page const uint8_t K := 7;',    'uint8_t w; w := 1 << K;',
    '',                                                    'uint8_t w; w := 1 << 7;'],
   ['addition',           'page const uint8_t K := 7;',    'uint8_t v; v := K + 1;',
    '',                                                    'uint8_t v; v := 8;'],
   ['a 16-bit copy',      'page const uint16_t W := 300;', 'uint16_t v; v := W;',
    '',                                                    'uint16_t v; v := 300;'],
   ['a bare byte read',   'page const uint8_t K := 7;',    'uint8_t v; v := K;',
    '',                                                    'uint8_t v; v := 7;'],
   ['a constant inside a loop bound',
    'page const uint8_t K := 7;',                         'uint8_t i; uint8_t n; for (i := 0; i < K; i++) { n := i; }',
    '',                                                    'uint8_t i; uint8_t n; for (i := 0; i < 7; i++) { n := i; }'],
);

my $i = 0;
for my $case (@folded) {
   my ($what, $decls, $body, $decls2, $body2) = @{$case};
   $i++;
   my ($crc, $cerr, $casm) = compile_cc1("$decls\nvoid main(void){ $body }", "fold$i");
   $crc == 0 or die "the constant form did not compile: $what\n$cerr\n";
   my ($lrc, $lerr, $lasm) = compile_cc1("$decls2\nvoid main(void){ $body2 }", "lit$i");
   $lrc == 0 or die "the literal form did not compile: $what\n$lerr\n";

   my $got = proc_instructions($casm);
   my $want = proc_instructions($lasm);
   $got >= 0 or die "no main procedure was emitted for: $what\n";
   $want >= 0 or die "no main procedure was emitted for the literal form: $what\n";
   $got == $want
      or die "$what did not fold: the constant form emitted $got instructions and the"
            . " identical literal form emitted $want\n";
}

# --- a local shadows a file-scope constant ---------------------------------------
# This is the case where an eager fold is silently WRONG rather than merely slow, so it
# is checked by reading the code: the local must be stored and then loaded back, and the
# value 7 must not appear where the local's 3 was stored.
{
   my ($rc, $err, $asm) = compile_cc1(<<'SHADOW', 'shadow');
page const uint8_t K := 7;
void main(void) { uint8_t K; K := 3; uint8_t v; v := K; }
SHADOW
   $rc == 0 or die "a local shadowing a page const no longer compiles\n$err\n";
   my ($body) = asm_text($asm) =~ /^\.proc main\b(.*?)^\.endproc/ms;
   defined $body or die "no main procedure was emitted for the shadowing case\n";
   $body =~ /sta\s+main\$K\b/
      or die "the shadowing local is never stored, so the case is not testing what it claims\n";
   $body =~ /lda\s+main\$K\b/
      or die "a use of the shadowing local was folded to the file-scope constant;"
            . " a local declaration shadows a page const and the two must not be confused\n";
}

# --- the object keeps its storage ------------------------------------------------
# Only the READ is folded.  A non-static object is exported, carries ABI and
# use-contract metadata, and may be named by inline assembly, none of which can see an
# expression-level fold.  Dropping the label would break all three silently, so the
# label and its bytes are asserted to still be there.
{
   my ($rc, $err, $asm) = compile_cc1(<<'KEPT', 'kept');
page const uint8_t K := 7;
page const uint16_t W := 300;
void main(void) { uint8_t v; v := K; }
KEPT
   $rc == 0 or die "the storage-retention case did not compile\n$err\n";
   my $code = asm_text($asm);
   $code =~ /^K:\n\t\.byte \$07$/m
      or die "the folded const scalar no longer occupies storage; only the READ may be"
            . " folded, because the object is still exported and still nameable by"
            . " inline assembly\n";
   $code =~ /^W:\n\t\.byte \$2c, \$01$/m
      or die "a folded 16-bit const scalar no longer occupies storage\n";
   $code =~ /\.export K\b/
      or die "a folded const scalar is no longer exported; the linker cross-checks"
            . " every use against the export, so dropping it changes what a program means\n";
}

# --- a const scalar passed BY VALUE is stored as an immediate --------------------
# This is a different code path from the evaluator above: an argument is lowered by
# compile_expr_to_slot, which already had the shape this needs -- it stores an immediate
# when a name has a compile-time value -- but only for a value the inliner had proven
# constant.  Without this, `takes(K)` loads K and stores that, which is both a wasted
# read and the reason the object's storage has to stay.
#
# Asserted on the immediate rather than on an instruction count, because the count alone
# cannot tell this case apart: the literal and the constant happened to emit the same
# number of instructions while differing in exactly the way that matters here.
{
   my ($rc, $err, $asm) = compile_cc1(<<'ARG', 'arg_value');
page const uint8_t K := 7;
page const uint16_t W := 300;
void takes8(uint8_t x) { uint8_t y; y := x; }
void takes16(uint16_t x) { uint8_t y; y := x; }
void main(void) { takes8(K); takes16(W); }
ARG
   $rc == 0 or die "passing a const scalar by value did not compile\n$err\n";
   my ($body) = asm_text($asm) =~ /^\.proc main\b(.*?)^\.endproc/ms;
   defined $body or die "no main procedure was emitted for the by-value case\n";
   $body =~ /lda\s+#\$07\b/
      or die "an 8-bit const scalar passed by value is not stored as an immediate\n";
   $body =~ /lda\s+#\$2c\b/
      or die "a 16-bit const scalar passed by value is not stored as an immediate\n";
   $body =~ /lda\s+#\$01\b/
      or die "the high byte of a 16-bit const scalar is not stored as an immediate\n";
   $body !~ /\blda\s+K\b/
      or die "a const scalar passed by value is still loaded from its object\n";
   $body !~ /\blda\s+W\b/
      or die "a 16-bit const scalar passed by value is still loaded from its object\n";
}

# --- and passing a SHADOWED name by value still uses the local --------------------
# The argument path resolves the name through the Context first, so a local of the same
# name must win.  This is the same hazard as the direct-use case above, on a different
# code path, and it is pinned separately because the two paths do not share an
# implementation.
{
   my ($rc, $err, $asm) = compile_cc1(<<'ARGSHADOW', 'arg_shadow');
page const uint8_t K := 7;
void takes8(uint8_t x) { uint8_t y; y := x; }
void main(void) { uint8_t K; K := 3; takes8(K); }
ARGSHADOW
   $rc == 0 or die "passing a shadowed name by value did not compile\n$err\n";
   my ($body) = asm_text($asm) =~ /^\.proc main\b(.*?)^\.endproc/ms;
   defined $body or die "no main procedure was emitted for the shadowed argument case\n";
   $body =~ /lda\s+main\$K\b/
      or die "a shadowed argument was not read from the local; the file-scope constant"
            . " was substituted for it\n";
   $body !~ /lda\s+#\$07\b/
      or die "the file-scope constant's value was stored in place of the shadowing"
            . " local's\n";
}

# --- a const scalar used as a SUBSCRIPT -------------------------------------------
# A subscript index was folded only when it was spelled as a literal, because the
# resolver tested `kind == AST_INTEGER`.  `a[K]` therefore became a runtime-computed
# address and a load of K -- the constant losing its value purely by being used as an
# index.  Index resolution happens in two places, so both are pinned: the lvalue
# resolver, and the store path that separately chooses between an indexed-X form and a
# direct displacement.
{
   my ($rc, $err, $asm) = compile_cc1(<<'INDEX', 'index');
page const uint8_t K := 7;
page const uint16_t W := 300;
void main(void) {
   uint8_t a[8];
   uint8_t big[400];
   uint8_t v;
   a[K] := 1;
   v := a[K];
   big[W] := 2;
}
INDEX
   $rc == 0 or die "a const scalar as a subscript did not compile\n$err\n";
   my ($body) = asm_text($asm) =~ /^\.proc main\b(.*?)^\.endproc/ms;
   defined $body or die "no main procedure was emitted for the subscript case\n";
   # The displacement form, which is what a literal index produces.  `ldx K` followed by
   # a store through X is the shape that says the index was treated as unknown.
   $body =~ /sta\s+[\w\$]+\s*\+\s*7\b/
      or die "a const scalar subscript did not fold into a displacement; the index is"
            . " still being resolved at runtime\n";
   $body !~ /ldx\s+K\b/
      or die "a const scalar subscript still loads the constant into an index register\n";
   $body !~ /\b(lda|ldx|ldy)\s+K\b/
      or die "a const scalar used as a subscript is still loaded from its object\n";
   $body =~ /sta\s+[\w\$]+\s*\+\s*300\b/
      or die "a 16-bit const scalar subscript did not fold into a displacement\n";
}

# --- a shadowed name used as a subscript ------------------------------------------
# Pinned separately for the same reason as the argument case: the subscript path is a
# different implementation, so passing this one does not imply the other.
{
   my ($rc, $err, $asm) = compile_cc1(<<'IDXSHADOW', 'index_shadow');
page const uint8_t K := 7;
void main(void) { uint8_t a[8]; uint8_t K; K := 2; a[K] := 1; }
IDXSHADOW
   $rc == 0 or die "a shadowed subscript index did not compile\n$err\n";
   my ($body) = asm_text($asm) =~ /^\.proc main\b(.*?)^\.endproc/ms;
   defined $body or die "no main procedure was emitted for the shadowed subscript case\n";
   # The local's value is a runtime value here: it is assigned, not declared constant,
   # and the compiler does not propagate an assignment into a subscript.  So the correct
   # behaviour is a runtime index, and the thing that must not happen is the FILE-SCOPE
   # constant being substituted for the shadowed name.  Asserting a folded `+ 2` here
   # would be asserting an optimization that does not exist.
   $body =~ /ldx\s+main\$K\b/
      or die "a shadowed subscript index was not read from the local at runtime\n";
   $body !~ /sta\s+[\w\$]+\s*\+\s*7\b/
      or die "the file-scope constant's value was used as a subscript index in place of"
            . " the shadowing local's\n";
   $body !~ /\bldx\s+K\b/
      or die "the file-scope constant was loaded as a subscript index despite being"
            . " shadowed by a local\n";
}

# --- a const scalar as a BINARY OPERAND, and returned -----------------------------
# These two are separate code paths again, and both used to read the object.  A binary
# operand goes through the byte-operand classifier, which had no constant case at all --
# it produced a memory operand, and the ALU form emitted `adc K`.  The return path has
# its own one-byte fast path that copied straight from the object's symbol.
#
# The binary cases assert the immediate form specifically, because `adc #7` and `adc K`
# differ by two cycles and one byte and nothing else -- an instruction count would call
# them equal.
{
   my ($rc, $err, $asm) = compile_cc1(<<'BINARY', 'binary');
page const uint8_t K := 7;
page const uint8_t M := 200;
uint8_t get(void) { return K; }
uint8_t add(uint8_t v) { return v + K; }
void main(void) {
   uint8_t v;
   v := 1;
   v := v + K;
   v := v & M;
   v := v | M;
   v := K - v;
   v := 100 - K;
   v := get();
   v := add(v);
}
BINARY
   $rc == 0 or die "a const scalar as a binary operand or return value did not compile\n$err\n";
   my $code = asm_text($asm);

   $code =~ /adc\s+#\$07\b/
      or die "a const scalar as an addend is not an immediate; the ALU form still reads"
            . " the object, which costs two cycles and a byte more for nothing\n";
   $code =~ /and\s+#\$c8\b/
      or die "a const scalar as an AND operand is not an immediate\n";
   $code =~ /ora\s+#\$c8\b/
      or die "a const scalar as an OR operand is not an immediate\n";
   # `return K` on a one-byte unsigned return slot: the immediate replaces a read.
   $code =~ /lda\s+#\$07\s*\n\s*sta\s+get\$__return/
      or die "a returned const scalar is not stored as an immediate\n";

   # Nothing anywhere may still read the object.  Checked across every procedure rather
   # than one, because the two paths are in different functions.
   my $reads = 0;
   while ($code =~ /^\s*(?:lda|ldx|ldy|adc|sbc|and|ora|eor|cmp)\s+([A-Za-z_]\w*)\s*$/gm) {
      $reads++ if $1 eq 'K' || $1 eq 'M';
   }
   $reads == 0
      or die "a const scalar is still read by name in $reads place(s) after folding;"
            . " an immediate was expected instead\n";
}

# --- a shadowed local beats the constant on the binary path too -------------------
{
   my ($rc, $err, $asm) = compile_cc1(<<'BINSHADOW', 'binary_shadow');
page const uint8_t K := 7;
void main(void) { uint8_t K; uint8_t v; K := 3; v := 1; v := v + K; }
BINSHADOW
   $rc == 0 or die "a shadowed binary operand did not compile\n$err\n";
   my ($body) = asm_text($asm) =~ /^\.proc main\b(.*?)^\.endproc/ms;
   defined $body or die "no main procedure was emitted for the shadowed binary case\n";
   $body =~ /adc\s+main\$K\b/
      or die "a shadowed binary operand was not read from the local; the file-scope"
            . " constant was substituted for it\n";
   $body !~ /adc\s+#\$07\b/
      or die "the file-scope constant's value was added in place of the shadowing"
            . " local's\n";
}

# --- the two cases that CANNOT fold, and why -------------------------------------
# Both were checked by hand before being pinned here, because each looks like a missing
# fold and is not.  Recording the reason is the point: a future reader who sees "a const
# passed by ref does not fold" must not conclude the fold is broken.
#
#   * `ref` binds a WRITABLE alias, so a const argument is refused outright.  That is
#     the correct answer, not a lost optimisation -- there is no value to fold, because
#     the whole point of the binding is that the callee may write through it.
#   * A read through a pointer genuinely needs the value at an address.  There is no
#     rewrite that keeps `p := &K; v := p[0]` correct while removing K's storage, which
#     is precisely why storage elision is separate work and why this change folds reads
#     only.
{
   my ($rc, $err) = compile_cc1(<<'REFBIND', 'refbind');
page const uint8_t K := 7;
void byref(ref uint8_t x) { uint8_t y; y := x; }
void main(void) { byref(K); }
REFBIND
   $rc != 0
      or die "a const scalar now binds to a read/write ref parameter; a ref is a"
            . " writable alias, so the refusal is the correct answer\n";
   $err =~ /const and cannot bind to read\/write ref parameter/
      or die "the refusal for a const ref argument no longer explains itself:\n$err\n";

   my ($prc, $perr, $pasm) = compile_cc1(<<'PTRREAD', 'ptrread');
page const uint8_t K := 7;
void main(void) { uint8_t *p; p := &K; uint8_t v; v := p[0]; }
PTRREAD
   $prc == 0 or die "reading a const scalar through a pointer no longer compiles\n$perr\n";
   my $pcode = asm_text($pasm);
   $pcode =~ /^K:\n\t\.byte \$07$/m
      or die "the object read through a pointer has no storage; a pointer read needs"
            . " the value to exist at an address, which is why storage is not elided\n";
}

# --- address-taking still needs real storage --------------------------------------
# `&K` is legal and cannot be folded to a value.  If it ever were, the address would be
# replaced by the number, which is the failure mode that makes elision unsafe and the
# reason elision is a separate piece of work.
{
   my ($rc, $err, $asm) = compile_cc1(<<'ADDR', 'addr');
page const uint8_t K := 7;
void main(void) { uint8_t *p; p := &K; }
ADDR
   $rc == 0 or die "taking the address of a const scalar no longer compiles\n$err\n";
   my $code = asm_text($asm);
   $code =~ /^K:\n\t\.byte \$07$/m
      or die "the object whose address is taken has no storage left to take\n";
   $code =~ /lda\s+#<\{?K\b/
      or die "the address of a const scalar is no longer formed from its symbol\n";
}

# --- the gate is plain read-only ROM only -----------------------------------------
# A `const` object in a NAMED memory region keeps its runtime read, for the same reason
# the link-time table record excludes one: there the byte's ADDRESSABILITY is the
# contract, and a folded read would erase the reference the linker diagnoses.  This is
# asserted as "the value is not folded", deliberately not as "it compiles", because what
# must not happen is a read quietly becoming a number.
{
   my ($rc, $err, $asm) = compile_cc1(<<'REGION', 'region');
mem myrom { $ro: const };
myrom page const uint8_t K := 7;
void main(void) { uint8_t v; v := K; }
REGION
   if ($rc == 0 && defined $asm) {
      my ($body) = asm_text($asm) =~ /^\.proc main\b(.*?)^\.endproc/ms;
      if (defined $body && $body =~ /lda\s+K\b/) {
         # expected: the read is still a read
      }
      else {
         die "a const object in a NAMED memory region had its read folded; there the"
               . " byte's addressability is the contract rather than its value, and"
               . " folding the read erases the reference the linker diagnoses\n";
      }
   }
   # A refusal here is also acceptable -- it means the region form is not accepted at
   # all in this configuration -- so only an accepted-and-folded program is a failure.
}

# --- the mechanism is where the fold is claimed to come from ----------------------
# Three things have to be true for the folding above to happen, and each is a separate
# opportunity to break it silently:
#
#   * the value is recorded when a const object's initializer folds to link-time bytes;
#   * it is recorded only under the plain-ROM gate;
#   * and the evaluation that folds it is the SCOPED one, because the unscoped entry
#     point is also used while PARSING to fold an array extent, where no scope exists.
{
   open(my $fh, '<', File::Spec->catfile($repo, 'compiler', 'compile_init.c'))
      or die "could not read compile_init.c: $!\n";
   my $init = do { local $/; <$fh> };
   close($fh);

   $init =~ /const_scalar_value_record/
      or die "the const scalar registry is gone; uses of a const scalar can no longer"
            . " be folded to its value\n";
   # The resolver has to consult the Context BEFORE the table.  Reversed, a local that
   # shadows a page const would be folded to the file-scope value.
   my ($resolver) = $init =~ /(static bool const_scope_constant_resolver\b.*?)\n\}/s;
   defined $resolver
      or die "the scope-aware const resolver is gone\n";
   my $ctx_at = index($resolver, 'ctx_lookup');
   my $tbl_at = index($resolver, 'const_scalar_value_lookup');
   $ctx_at >= 0 && $tbl_at >= 0 && $ctx_at < $tbl_at
      or die "the const resolver consults the recorded table before the Context; a local"
            . " declaration shadows a file-scope one, and that ordering substitutes the"
            . " wrong value for the shadowed name\n";

   open($fh, '<', File::Spec->catfile($repo, 'compiler', 'compile_toplevel.c'))
      or die "could not read compile_toplevel.c: $!\n";
   my $top = do { local $/; <$fh> };
   close($fh);
   # The record must sit inside the same condition as the table record, not beside it.
   my ($gate) = $top =~ /(if \(link_time_bytes && is_const.*?\n\s*\}\n)/s;
   defined $gate
      or die "the plain-ROM gate that admits a const object for folding is gone\n";
   $gate =~ /const_link_time_table_record/
      or die "the link-time table record is no longer under the plain-ROM gate\n";
   $gate =~ /const_scalar_value_record/
      or die "the const scalar record is not under the same plain-ROM gate as the table"
            . " record; a const object in a named memory region has an addressability"
            . " contract, and folding its read would erase it\n";
   # A scalar only.  An array is the table record's business, and a pointer is not a
   # value at all.
   $gate =~ /declarator_array_count\(declarator\)\s*==\s*0/
      or die "the const scalar record no longer excludes arrays\n";
   $gate =~ /declarator_pointer_depth\(declarator\)\s*==\s*0/
      or die "the const scalar record no longer excludes pointers\n";
}

print "vcs_const_scalar_folding ok\n";
exit 0;
