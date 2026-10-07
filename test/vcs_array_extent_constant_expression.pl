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
   my ($err) = ($se . $so) =~ /^(Error.*)$/m;
   return ($rc, defined($err) ? $err : '', (($rc == 0 && -f $out) ? $out : undef));
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
my @rejected = (
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
   ['a local variable',            'void main(void) { uint8_t n; n := 3; uint8_t p[n]; p[0] := 1; }',
    qr/array size 'n' must be a compile-time integer constant/],
   ['a global variable',           "page const uint8_t p[g] := { 1 };\nuint8_t g;",
    qr/array size 'g' must be a compile-time integer constant/],
   ['sizeof, which the constant evaluator does not fold',
    'page const uint8_t p[sizeof(uint8_t) * 4] := { 1 };',
    qr/array size 'sizeof\(\.\.\.\) \* 4' must be a compile-time integer constant/],
);

for my $i (0 .. $#rejected) {
   my ($what, $source, $want) = @{$rejected[$i]};
   my ($rc, $err) = compile_cc1($source, "rej$i");
   $rc != 0 or die "an extent that must be refused was accepted: $what\n";
   $err =~ $want
      or die "the refusal for $what did not match $want\n$err\n";
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

# ------------------------------------------------------------------ contract
# The behaviour above is worth nothing if the grammar narrows again, and the
# capability is a one-line rule, so the rule itself is pinned.
{
   open(my $fh, '<', File::Spec->catfile($repo, 'compiler', 'parser.y'))
      or die "could not read parser.y: $!\n";
   my $grammar = do { local $/; <$fh> };
   close($fh);
   $grammar =~ /direct_declarator\s+'\['\s+conditional_expr\s+'\]'/
      or die "the array extent rule no longer takes a constant expression\n";
   $grammar =~ /direct_declarator\s+'\['\s+INTEGER\s+'\]'/
      and die "an integer-only array extent rule is present again\n";
}

print "vcs_array_extent_constant_expression ok\n";
exit 0;