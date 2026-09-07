#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: bankswitch glyph pointer setup uses C26
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Find;
use File::Spec;

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO\n");
die "usage: $0 REPO\n" if @ARGV;
my $root=File::Spec->catdir($repo,qw(examples 09_bankswitching));

my $assignments=0;
find({no_chdir=>1,wanted=>sub {
   return unless -f $_ && /\.c26\z/;
   my $path=$File::Find::name;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $text=<$fh> // ''; close($fh);

   if ($text =~ /^\s*asm\b[^\n]*(?:status_result_pointers|cart_type_pointers|(?:status_(?:big|small)|cart_type)_glyphs)/m) {
      my $rel=File::Spec->abs2rel($path,$repo); $rel =~ s{\\}{/}g;
      die "bankswitch glyph-pointer setup uses inline asm in $rel\n";
   }
   while ($text =~ /(?:status_result_pointers|cart_type_pointers)\s*\[\s*\d+\s*\]\s*:=\s*\(uint16_t\)&(?:status_(?:big|small)_glyphs|cart_type_glyphs)\s*\[\s*\d+\s*\]/g) {
      ++$assignments;
   }
}},$root);

$assignments > 0 or die "bankswitch diagnostics contain no typed glyph-pointer assignments\n";
print "bankswitch glyph pointer setup uses C26\n";
