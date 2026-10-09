#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: compile
# expectstdout: vcs_array_extent_constant_expression ok
# expectexit: 0

# An array extent is a compile-time integer CONSTANT, not merely an integer token.
#
# The grammar accepted only a literal there, so a size written as `WIDTH * 2` or
# `BASE + COUNT - 1` had to be recomputed by hand at each declaration, and the two
# spellings could drift apart.  An enum constant, a shift, a conditional and a
# character difference are all extents now.
#
# The point of this regression is the resolved VALUE, not that the source parses.
# Every accepted case compiles one `page const uint8_t probe[<expr>]` and counts the
# bytes actually emitted for it, so `9 / 2` is proved to be 4 by allocation and not
# by inspection.  Every rejected case is proved to be refused with a diagnostic that
# names the offending extent, because a refusal that cannot be located is a refusal
# nobody can act on.
#
# The arithmetic is ordinary integer arithmetic -- long long, division truncating
# toward zero -- and the result must be strictly positive.

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
   return ($? >> 8, $? & 127, $stdout, $stderr);
}

sub compile_cc1 {
   my ($source, $tag) = @_;
   my $src = File::Spec->catfile($tmp, "$tag.c26");
   my $out = File::Spec->catfile($tmp, "$tag.s26");
   unlink $out;
   open(my $fh, '>', $src) or die "could not write $src: $!\n";
   print {$fh} qq{include "machine_6502.c26"\n$source\n};
   close($fh);
   my ($rc, $sig, $so, $se) = capture($cc1, '-I', $runtime, '-o', $out, $src);
   # A diagnostic is more than one line -- a syntax error prints the position and then
   # what it expected -- so keep everything from the first "Error" rather than just
   # that line, or a refusal cannot be matched against its own explanation.
   my $log = $se . $so;
   my $at = index($log, 'Error');
   my $err = $at >= 0 ? substr($log, $at) : '';
   $err =~ s/\s+\z//;
   return ($rc, $err, (($rc == 0 && -f $out) ? $out : undef));
}

# Bytes emitted for SYMBOL in an assembly file.  This is the allocation the resolved
# extent produced, which is what makes the value checks below meaningful.
sub emitted_bytes {
   my ($asm, $symbol) = @_;
   open(my $fh, '<', $asm) or die "could not read $asm: $!\n";
   my $text = do { local $/; <$fh> };
   close($fh);
   my ($body) = $text =~ /^\Q$symbol\E:\n(.*?)(?=^[A-Za-z_.][A-Za-z0-9_.]*:|\z)/ms;
   defined $body or return undef;
   my $bytes = 0;
   while ($body =~ /^\s*\.byte\s+(.*)$/mg) {
      $bytes += scalar(split /,/, $1);
   }
   return $bytes;
}

# ------------------------------------------------------------------ accepted
my @accepted = (
   ['a bare literal still works',            'page const uint8_t p[8] := { 1 };',            8],
   ['multiplication',                         'page const uint8_t p[4 * 2] := { 1 };',         8],
   ['addition and subtraction',               'page const uint8_t p[1 + 2 * 3 - 1] := { 1 };', 6],
   ['parentheses change the result',          'page const uint8_t p[(1 + 1) * 3] := { 1 };',    6],
   ['unary minus',                            'page const uint8_t p[-(-5)] := { 1 };',          5],
   ['bitwise operators',                      'page const uint8_t p[12 & 6 | 1] := { 1 };',     5],
   ['shift',                                   'page const uint8_t p[1 << 3] := { 1 };',          8],
   ['division truncates toward zero',         'page const uint8_t p[9 / 2] := { 1 };',           4],
   ['comparison',                              'page const uint8_t p[3 > 2] := { 1 };',           1],
   ['sizeof of a type',                        'page const uint8_t p[sizeof(uint8_t) * 3] := { 1 };', 3],
   ['sizeof of a two-byte type',               'page const uint8_t p[sizeof(uint16_t)] := { 1 };', 2],
   ['sizeof of a typedef alias',               "typedef uint8_t byte_t;\npage const uint8_t p[sizeof(byte_t) + 1] := { 1 };", 2],
   ['sizeof of a chained alias',               "typedef uint8_t byte_t;\ntypedef byte_t alias_t;\npage const uint8_t p[sizeof(alias_t) * 4] := { 1 };", 4],
   ['sizeof of a pointer type',                'page const uint8_t p[sizeof(uint8_t *) * 2] := { 1 };', 4],
   ['sizeof composing with other arithmetic',  'page const uint8_t p[sizeof(uint8_t) + sizeof(uint16_t) - 1] := { 1 };', 2],
   ['sizeof inside a conditional',             'page const uint8_t p[1 ? sizeof(uint16_t) : 1] := { 1 };', 2],
   ['a user-declared type',                    "type mybyte { \$size:1 \$integer:unsigned };\npage const uint8_t p[sizeof(mybyte) * 3] := { 1 };", 3],
   # A struct or union carries no `$size:` flag -- its size is laid out from its fields --
   # so sizeof(S) in an extent works only because the size is recorded the moment the
   # declaration closes.  There are no forward references between structs, so that is
   # always early enough, and `calculate_struct_union_sizes` then finds the entry already
   # present and agrees with it.
   ['sizeof of a struct',                      "struct blob { uint8_t a; uint8_t b; };\npage const uint8_t p[sizeof(blob)] := { 1 };", 2],
   ['sizeof of a struct in arithmetic',        "struct blob { uint8_t a; uint8_t b; };\npage const uint8_t p[sizeof(blob) * 3] := { 1 };", 6],
   ['sizeof of a struct laid out from another struct',
    "struct small { uint8_t a; uint8_t b; };\nstruct nest { small inner; uint8_t t; };\npage const uint8_t p[sizeof(nest)] := { 1 };", 3],
   ['sizeof of a struct with an array field',  "struct arr { uint8_t a; uint8_t b[4]; };\npage const uint8_t p[sizeof(arr) + 1] := { 1 };", 6],
   ['sizeof of a struct with a pointer field', "struct ps { uint8_t *p; uint8_t t; };\npage const uint8_t p[sizeof(ps)] := { 1 };", 3],
   ['sizeof of a struct with bitfields',       "struct bits { uint8_t a : 3; uint8_t b : 5; uint8_t c; };\npage const uint8_t p[sizeof(bits) * 2] := { 1 };", 4],
   ['sizeof of a union',                       "union ub { uint8_t x; uint16_t y; };\npage const uint8_t p[sizeof(ub) * 2] := { 1 };", 4],
   ['sizeof of a struct used as a later field extent',
    "struct small { uint8_t a; uint8_t b; };\nstruct nest { uint8_t pad[sizeof(small) * 2]; };", 0],
   ['conditional',                             'page const uint8_t p[1 ? 5 : 6] := { 1 };',      5],
   ['conditional on a comparison',             'page const uint8_t p[2 > 1 ? 7 : 8] := { 1 };', 7],
   ['untaken conditional arm is not evaluated',
    'page const uint8_t p[0 ? 4 / 0 : 4] := { 1 };',                                             4],
   ['character difference',                    q{page const uint8_t p['B' - 'A'] := { 1 };},    1],
   ['enum constant',                           "enum s { C := 3 };\npage const uint8_t p[C] := { 1 };", 3],
   ['enum constant in arithmetic',
    "enum s { B := 4, C := 3 };\npage const uint8_t p[B + C] := { 1 };",                         7],
   ['two dimensions',                          'page const uint8_t p[2][3] := { 1 };',          6],
   ['expression in each dimension',
    'page const uint8_t p[1 + 1][2 * 2] := { 1 };',                                             8],
   ['a block-scope extent',
    'void main(void) { uint8_t v[4 * 2]; v[0] := 1; }',                                          0],
   ['a struct field extent',
    'struct s { uint8_t pad[2 * 2]; };',                                                          0],
);

for my $i (0 .. $#accepted) {
   my ($what, $source, $want) = @{$accepted[$i]};
   my ($rc, $err, $asm) = compile_cc1($source, "acc$i");
   $rc == 0 or die "an extent that should be accepted was refused: $what\n$err\n";
   next if $want == 0;    # nothing is allocated, so there is no size to read back
   my $got = emitted_bytes($asm, 'p');
   defined $got or die "no bytes were emitted for the probe: $what\n";
   $got == $want
      or die "extent resolved wrongly: $what resolved to $got bytes, expected $want\n";
}

# -7 % 3 is -1 in C: the remainder keeps the dividend's sign rather than becoming an
# absolute value.  That makes it a negative size, so it is refused, and the diagnostic
# has to say -1 rather than 1.
{
   my ($rc, $err) = compile_cc1('page const uint8_t p[-7 % 3] := { 1 };', 'modneg');
   $rc != 0 or die "-7 % 3 was accepted as an extent; division must follow C sign rules\n";
   $err =~ /greater than zero, not -1/
      or die "a negative remainder must report -1, not an absolute value\n$err\n";
}

# ------------------------------------------------------------------ rejected
# Two kinds of refusal, and the split is the point of the design.
#
# An extent is `case_term`, the grammar's existing notion of a constant whose value is
# known here -- the same one a case label uses.  Its primaries are literals only, so
# an identifier cannot appear at all and the parser refuses it: no scope is needed at
# any point, and nothing downstream has to re-check that the expression was constant.
#
# What still reaches the folder is what IS constant-shaped but not answerable HERE: the
# size of an object (no scope exists yet) and the size of a name with no declaration.
# Those are refused by name.
my @refused_by_parser = (
   ['a local variable',  'void main(void) { uint8_t n; n := 3; uint8_t p[n]; p[0] := 1; }',
    qr/syntax error/],
   ['a global variable', "page const uint8_t p[g] := { 1 };\nuint8_t g;",
    qr/syntax error/],
);

my @refused_by_folder = (
   ['a zero literal',              'page const uint8_t p[0] := { 1 };',
    qr/array size must be greater than zero, not 0/],
   ['a zero-valued enum',          "enum s { Z := 0 };\npage const uint8_t p[Z] := { 1 };",
    qr/array size must be greater than zero, not 0/],
   ['a zero-valued conditional',   'page const uint8_t p[1 ? 0 : 4] := { 1 };',
    qr/array size must be greater than zero, not 0/],
   ['a negative literal',          'page const uint8_t p[-3] := { 1 };',
    qr/greater than zero, not -3/],
   ['arithmetic that goes negative', 'page const uint8_t p[2 - 5] := { 1 };',
    qr/greater than zero, not -3/],
   ['a zero divisor',              'page const uint8_t p[4 / 0] := { 1 };',
    qr/array size '4 \/ 0' divides by zero/],
   ['a zero remainder divisor',    'page const uint8_t p[4 % 0] := { 1 };',
    qr/array size '4 % 0' divides by zero/],
   # sizeof of an OBJECT is a genuine constant in C, but its size needs a scope that
   # does not exist while a declaration is being parsed.  It parses -- sizeof is a
   # literal-shaped primary -- so the folder is what refuses it, by name.
   ['sizeof of an object',       "uint16_t g;\npage const uint8_t p[sizeof(g)] := { 1 };",
    qr/array size 'sizeof\(g\)' is not a compile-time constant:.*an object's\s+size needs a scope/s],
   ['sizeof of void',            'page const uint8_t p[sizeof(void)] := { 1 };',
    qr/invalid application of sizeof to void type/],
   ['sizeof of an undefined name', 'page const uint8_t p[sizeof(nosuchtype)] := { 1 };',
    qr/array size 'sizeof\(nosuchtype\)' is not a compile-time constant/],
);

for my $set ([\@refused_by_parser], [\@refused_by_folder]) {
   for my $i (0 .. $#{$set->[0]}) {
      my ($what, $source, $want) = @{$set->[0][$i]};
      my ($rc, $err) = compile_cc1($source, "rej$what");
      $rc != 0 or die "an extent that must be refused was accepted: $what\n";
      $err =~ $want
         or die "the refusal for $what did not match $want\n$err\n";
   }
}

# A diagnostic has to locate the problem.  The renderer profile guards depend on
# this: their unsupported-configuration branch is a poison declaration whose only
# purpose is to fail with the offending identifier in the message.
{
   my ($rc, $err) = compile_cc1('extern const uint8_t p[TEMPLATE_lines_must_be_192];', 'poison');
   $rc != 0 or die "a poison extent naming an undefined identifier was accepted\n";
   $err =~ /TEMPLATE_lines_must_be_192/
      or die "the refusal did not name the offending identifier\n$err\n";
}

# sizeof must fold as a constant, not only in an extent: a `page const` initializer
# uses the same evaluator, and that is the cheaper spelling.
{
   my ($rc, $err, $asm) = compile_cc1('page const uint16_t n := sizeof(uint16_t) * 2;', 'szconst');
   $rc == 0 or die "sizeof does not fold in a constant initializer\n$err\n";
   my $got = emitted_bytes($asm, 'n');
   defined $got && $got == 2
      or die "a folded sizeof produced " . (defined $got ? $got : 'no') . " bytes, expected 2\n";
}

# ------------------------------------------------------------------ contract
# The behaviour above is worth nothing if the grammar narrows again, and the
# capability is a one-line rule, so the rule itself is pinned.
{
   open(my $fh, '<', File::Spec->catfile($repo, 'compiler', 'parser.y'))
      or die "could not read parser.y: $!\n";
   my $grammar = do { local $/; <$fh> };
   close($fh);
   $grammar =~ /direct_declarator\s+'\['\s+case_term\s+'\]'/
      or die "the array extent rule no longer takes case_term, the grammar's existing"
            . " notion of a constant whose value is known here\n";
   $grammar =~ /direct_declarator\s+'\['\s+INTEGER\s+'\]'/
      and die "an integer-only array extent rule is present again\n";
   # case_term is only usable as an extent once its primaries cover what an extent
   # must accept.  ENUMNAME moved into case_num_primary_expr so an enum constant works
   # in arithmetic and not only as a whole case term; SIZEOF sits beside it so a type
   # size is available too.  Both also widen what a case LABEL accepts, which is legal
   # C and folds, but is a language change and is therefore pinned deliberately.
   $grammar =~ /case_num_primary_expr:.*?ENUMNAME.*?SIZEOF\s+sizeof_operand/s
      or die "case_num_primary_expr no longer carries both ENUMNAME and SIZEOF;"
            . " an enum constant in arithmetic, or sizeof in an extent, stops parsing\n";

   # sizeof folds through the constant evaluator, and only because a type or typedef
   # declaration attaches its node while parsing.  Both halves are load-bearing: drop
   # either and every sizeof in the tree reports as not constant.
   open($fh, '<', File::Spec->catfile($repo, 'compiler', 'compile_init.c'))
      or die "could not read compile_init.c: $!\n";
   my $init = do { local $/; <$fh> };
   close($fh);
   $init =~ /expr_sizeof_type_size/
      or die "the constant evaluator no longer folds sizeof\n";
   # A `type X { ... }` declaration must attach its node while parsing, otherwise the
   # size is not reachable until the compile phase and no sizeof can fold.
   $grammar =~ /TYPE\s+IDENTIFIER\s+'\{'\s*opt_flags\s*'\}'
                  \s*';'\s*\{[^}]*attach_typename/x
      or die "a type declaration no longer attaches its node while parsing\n";
   $grammar =~ /TYPEDEF\s+TYPENAME\s+IDENTIFIER\s*';'
                  \s*\{[^}]*attach_typename/x
      or die "a typedef no longer attaches its target while parsing\n";

   # A struct or union carries no `$size:` flag -- its size is laid out from its fields
   # -- so sizeof(S) in an extent works only because the size is recorded the moment the
   # declaration closes.  Both keywords must do it, on BOTH of their grammar
   # alternatives, or a declaration written the other way silently stops working.
   for my $kw (['struct', 'true'], ['union', 'false']) {
      my ($word, $flag) = @{$kw};
      my $call = qr/record_declared_struct_union_size\(\s*\$\$\s*,\s*\$2\s*,\s*$flag\s*\)/;
      my $hits = () = $grammar =~ /$call/g;
      $hits == 2
         or die "expected a $word to record its size on both of its grammar"
               . " alternatives, found $hits calls\n";
      my ($rule) = $grammar =~ /^${word}_decl_stmt:\n(.*?)^ +;/ms;
      defined $rule && $rule =~ /$call/
         or die "the ${word}_decl_stmt rule no longer records a size with is_struct = $flag\n";
   }

   # And it must go through the ONE field walk the authoritative layout pass uses.  Two
   # copies of these rules is exactly how a size recorded while parsing and a size laid
   # out afterwards would come to disagree -- and nothing else would notice.
   open($fh, '<', File::Spec->catfile($repo, 'compiler', 'compile_toplevel.c'))
      or die "could not read compile_toplevel.c: $!\n";
   my $top = do { local $/; <$fh> };
   close($fh);
   my $walk = () = $top =~ /struct_union_size_from_fields/g;
   $walk == 3
      or die "struct_union_size_from_fields appears $walk times; it must be defined"
            . " once and called from both the parse-time recording and the layout pass\n";
}

# --- the same constants are legal where a case label is ------------------------
# case_primary_expr now feeds both an array extent and a case label, so widening it
# for extents widens case labels too: `case B - A:` and `case sizeof(uint16_t):` become
# legal.  Both are legal C and both fold, so this is a widening rather than a hole --
# but it is a language change, and it is only safe if the folded value is what actually
# reaches the compare.
{
   my $asm = File::Spec->catfile($tmp, 'caselabel.s26');
   unlink $asm;
   my ($rc, $err) = compile_cc1(<<'CASE', 'caselabel');
include "machine_6502.c26"
enum sizes { LOW := 2, HIGH := 5 };
void main(void) {
   uint8_t v := 1;
   switch (v) {
      case LOW: v := 1; break;
      case HIGH - LOW: v := 2; break;
      case sizeof(uint16_t): v := 3; break;
      default: v := 0;
   }
}
CASE
   $rc == 0 or die "the case-label fixture no longer compiles\n$err\n";
   my $code = do {
      open(my $r, '<', $asm) or die "could not read $asm: $!\n";
      local $/;
      <$r>;
   };
   # LOW is 2, HIGH - LOW is 3, and sizeof(uint16_t) is 2.
   $code =~ /cmp\s+#\$02\b/ or die "a case label of LOW or sizeof(uint16_t) is not compared as 2\n";
   $code =~ /cmp\s+#\$03\b/ or die "a case label of HIGH - LOW is not compared as 3\n";
}

# --- and a struct or union is a compile-time constant like any other ----------
# `struct S { ... }` registers S as a type directly, so S is declared without the
# `struct` keyword and sizeof(S) is the spelling.  That is the language's deliberate
# design, not an accident, and the extent limitation above must not be mistaken for
# the language being unable to size a struct.
#
# This asserts a LINK-TIME CONSTANT, not merely acceptance.  A const object whose
# initializer the compiler already knows belongs in link-time data; if sizeof(S)
# leaves a runtime initializer behind, the size was known and simply not folded.
{
   my ($rc, $err, $asm) = compile_cc1(<<'STRUCT', 'structsz');
include "machine_6502.c26"
struct blob { uint8_t a; uint8_t b; };
union ub { uint8_t x; uint16_t y; };
page const uint8_t s := sizeof(blob);
page const uint8_t u := sizeof(ub);
page const uint8_t tripled := sizeof(blob) * 3;
STRUCT
   $rc == 0 or die "sizeof of a struct or union is not accepted\n$err\n";
   my $code = do {
      open(my $r, '<', $asm) or die "could not read $asm: $!\n";
      local $/;
      <$r>;
   };
   # blob is two bytes; a union takes the larger of its members, so ub is two too.
   $code =~ /^s:\n\t\.byte \$02$/m       or die "sizeof(struct blob) is not link-time data\n";
   $code =~ /^u:\n\t\.byte \$02$/m       or die "sizeof(union ub) is not link-time data\n";
   $code =~ /^tripled:\n\t\.byte \$06$/m or die "sizeof(struct blob) * 3 did not fold\n";
   $code =~ /^\.proc __init_/m
      and die "a known struct size left a runtime initializer behind\n";
}

# --- the parse-time size recording must stay silent ----------------------------
# The compile phase is the ONLY place a malformed bitfield is diagnosed, and under
# -X coverage it never runs at all: vcsc-cc1 calls coverage_report() and exits the
# moment parsing succeeds.  So a diagnostic emitted from the parse-time size walk
# would fire on a run that is only supposed to parse -- which is exactly what the two
# grammar-coverage fixtures are, and both declare deliberately absurd bitfields.
#
# Both directions are pinned, because either alone is satisfiable by accident: a walk
# that never reported would pass the first check and silently accept a bad field, and a
# walk that always reported would pass the second and break those fixtures.
{
   my $bad = "struct bad { int16_t mantissa:23; };\npage const uint8_t p[1] := { 1 };";
   my $src = File::Spec->catfile($tmp, 'silent.c26');
   open(my $fh, '>', $src) or die "could not write $src: $!\n";
   print {$fh} qq{include "machine_6502.c26"\n$bad\n};
   close($fh);

   # Under -X coverage the compile phase never runs, so parsing must produce no
   # diagnostic.  The EXIT CODE cannot be used to say that: coverage_report() itself
   # exits non-zero when any grammar rule went unvisited, and a source this small
   # leaves most of them unvisited.  What is being asserted is the absence of a
   # diagnostic, so that is what is checked.
   my ($crc, $csig, $cso, $cse) = capture($cc1, '-quiet', '-I', $runtime, '-X', 'coverage', $src);
   my $clog = $cse . $cso;
   $clog !~ /Error/
      or die "a coverage-only run diagnosed a bitfield, but it never reaches the"
            . " compile phase that owns that diagnostic:\n$clog\n";

   # Without it, the same source must still be refused, by that same phase.
   my ($nrc, $nerr) = compile_cc1($bad, 'loud');
   $nrc != 0
      or die "an over-wide bitfield is accepted; the parse-time size walk has"
            . " silenced the compile phase instead of merely adding to it\n";
   $nerr =~ /bitfield 'mantissa' width 23 exceeds storage of 'int16_t'/
      or die "the over-wide bitfield is no longer diagnosed as one:\n$nerr\n";
}

print "vcs_array_extent_constant_expression ok\n";
exit 0;