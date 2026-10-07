#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: compile
# expectstdout: vcs_ternary_node_detection ok
# expectexit: 0

# One ternary detector, and it must match the shape the grammar builds.
#
# This tree once had THREE definitions of expr_is_ternary_node: one shared in
# compile_expr_info.c and two file-local `static` copies, in compile_init.c and
# compile_type.c.  A static copy shadows the shared declaration inside its own
# translation unit, so each file silently kept using its own.  All three predated the
# current grammar: the copies looked for an "expr" node holding a "question_expr"
# child, or a node named "?:" with three children, while the grammar has always built
# a `conditional_expr` with four children whose first is an identifier "?:".
#
# The copies therefore could not match anything.  In compile_init.c that silently
# disabled the ternary arm of the constant evaluator; in compile_type.c it disabled
# the ternary arm of expr_value_size.  Nothing reported either, because a ternary in a
# page-const initializer still folded -- expropt.c folds the same shape later -- so the
# gap was invisible from the outside until something needed the constant evaluator
# itself.
#
# The invariant worth keeping is not "these three functions are correct" but "there is
# exactly one detector and it is shared".  Three dead copies is a shape a review will
# not catch and a grep for the function name finds all three at once.

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;

@ARGV == 2 or die "usage: $0 REPO TMP\n";
my ($repo, $tmp) = @ARGV;
$repo = abs_path($repo) or die "could not resolve repo\n";

my $compdir = File::Spec->catdir($repo, 'compiler');

sub slurp {
   my ($path) = @_;
   open(my $fh, '<', $path) or die "could not read $path: $!\n";
   my $text = do { local $/; <$fh> };
   close($fh);
   return $text;
}

# --- exactly one definition, and it is not file-local --------------------------
{
   my (@definitions, @copies);
   for my $file (sort glob(File::Spec->catfile($compdir, '*.c'))) {
      my $src = slurp($file);
      my $base = (File::Spec->splitpath($file))[2];
      while ($src =~ /^(static\s+)?bool\s+expr_is_ternary_node\s*\(/gm) {
         my $is_static = defined($1) && $1 =~ /static/ ? 1 : 0;
         push @definitions, { file => $base, static => $is_static };
         push @copies, $base;
      }
   }
   scalar(@definitions) == 1
      or die "expr_is_ternary_node has " . scalar(@definitions)
           . " definitions (" . join(', ', @copies) . "); a file-local copy shadows the"
           . " shared one in its own translation unit, so keep exactly one\n";
   $definitions[0]{static}
      and die "expr_is_ternary_node is file-local in $definitions[0]{file}; a static copy"
            . " shadows the shared declaration for that whole file\n";
}

# --- the accessors come from the one place too ---------------------------------
{
   my @accessors;
   for my $file (sort glob(File::Spec->catfile($compdir, '*.c'))) {
      my $src = slurp($file);
      my $base = (File::Spec->splitpath($file))[2];
      while ($src =~ /^static\s+ASTNode\s+\*expr_ternary_(?:test|true|false)\s*\(/gm) {
         push @accessors, $base;
      }
   }
   @accessors
      and die "file-local ternary accessor copies exist: " . join(', ', @accessors)
            . "; delete them and use the shared ones\n";
}

# --- the grammar shape the detector matches is the shape it gets ---------------
# A detector and a grammar drift apart silently.  The shared detector accepts a
# `conditional_expr` of four children whose first is an identifier "?:", so the
# grammar must still build exactly that.
{
   my $grammar = slurp(File::Spec->catfile($compdir, 'parser.y'));
   $grammar =~ /logical_or_expr\s+'\?'\s+expr\s+':'\s+conditional_expr/
      or die "the ternary rule no longer has the shape the shared detector matches\n";
   $grammar =~ /MAKE_NODE\(make_identifier_leaf\("\?:"\),\s*\$1,\s*\$3,\s*\$5\)/
      or die "the ternary rule no longer builds a conditional_expr with a \"?:\" marker"
            . " followed by the test and both branches\n";
}

# --- and it matches ONLY that --------------------------------------------------
# The detector used to also accept a node literally named "?: " with three children.
# Nothing can produce one: "?:" is not a nonterminal, so MAKE_NODE can never give a
# node that name, and no MAKE_NAMED_NODE("?:", ...) exists.  The tolerance was
# inherited, it was never exercised, and it cost a name branch in every accessor.
# Keeping it re-admits exactly the kind of shape drift this test exists to prevent.
{
   my $shared = slurp(File::Spec->catfile($compdir, 'compile_expr_info.c'));
   my $body = ($shared =~ /bool\s+expr_is_ternary_node\s*\([^)]*\)\s*\{(.*?)\n\}/s) ? $1 : '';
   $body or die "could not read the body of expr_is_ternary_node\n";
   $body =~ /strcmp\(expr->name,\s*"\?:"\)/
      and die "expr_is_ternary_node still accepts a node named \"?:\", which the grammar"
            . " cannot build; match only what the grammar produces\n";
   # No other file should re-derive the shape either.
   for my $file (sort glob(File::Spec->catfile($compdir, '*.c'))) {
      my $base = (File::Spec->splitpath($file))[2];
      next if $base eq 'compile_expr_info.c';
      # parser.tab.c and lex.yy.c are generated from parser.y and lexer.l, and
      # legitimately carry the grammar action text that builds the marker.
      next if $base eq 'parser.tab.c' || $base eq 'lex.yy.c';
      my $src = slurp($file);
      $src =~ /strval,\s*"\?:"/
         and die "$base re-derives the ternary shape instead of calling the shared"
               . " detector; a second copy is how this drifted in the first place\n";
      $src =~ /strcmp\([^,]+,\s*"\?:"\)/
         and die "$base still tests for a node named \"?:\", which the grammar cannot"
               . " build\n";
   }
}

# --- and it folds, which is what the constant evaluator needs it for ------------
{
   my $cc1 = File::Spec->catfile($compdir, 'vcsc-cc1');
   -x $cc1 or -f $cc1 or die "vcsc-cc1 not built at $cc1\n";
   my $src = File::Spec->catfile($tmp, 'ternary.c26');
   open(my $fh, '>', $src) or die "could not write $src: $!\n";
   # The extent is resolved by the constant evaluator, not by expropt, so this is the
   # path that was dead while a ternary in an initializer still folded.
   print {$fh} qq{include "machine_6502.c26"\npage const uint8_t p[1 ? 5 : 6] := { 1 };\n};
   close($fh);
   my $err = File::Spec->catfile($tmp, 'ternary.log');
   my $runtime = File::Spec->catdir($repo, 'test');
   my $rc = system("'$cc1' -I '$runtime' '$src' >'$err' 2>&1");
   $rc == 0 or do {
      open($fh, '<', $err) or die "could not read $err: $!\n";
      my $log = do { local $/; <$fh> };
      close($fh);
      die "a ternary no longer folds in a constant expression\n$log\n";
   };
}

print "vcs_ternary_node_detection ok\n";
exit 0;