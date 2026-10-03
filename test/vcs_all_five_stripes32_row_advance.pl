#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_row_advance ok
# expectexit: 0
use strict; use warnings; use File::Spec;
my($root,$tmp)=@ARGV; die "usage: $0 ROOT TMP\n" unless defined $root;
my$solver=File::Spec->catfile($root,'libraries/vcs/renderers/kernel_schedule_search.pl');
my$problem=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_row_advance_search.pl');
for my $after (qw(p0 p1 p2)) {
   local $ENV{VCSC_STRIPE32_ROW_AFTER}=$after;
   my$out=`perl '$solver' '$problem' 2>&1`; die "row advance $after failed ($?)\n$out" if $?;
   $out =~ /event GRP0\s+\@\s+2 \(0:04\)/ or die "$after pair0 GRP0 phase changed\n$out";
   $out =~ /event PF2R\s+\@\s+439 \(5:61\)/ or die "$after final PF2R phase changed\n$out";
   $out !~ /\bIDLE\b/ or die "$after used fictitious idle cycles\n$out";
   if ($after eq 'p0') {
      $out =~ /lda\.zx object_masks\+35,x/ or die "p0 exact row cache missing\n$out";
      $out =~ /inx.*?txs/s or die "p0 X\/S advance missing\n$out";
   } elsif ($after eq 'p1') {
      $out =~ /sta\.a GRP0/ or die "p1 one-cycle repayment missing\n$out";
      $out =~ /cpy\.z next_event_threshold.*?txs/s or die "p1 shadow update did not consume selector NOP\n$out";
   } else {
      $out =~ /inx.*?txs.*?lda\.z stripe_cache\+3.*?sta PF0/s or die "p2 P0-mid row advance missing\n$out";
      $out =~ /lsr\.zx object_masks\+23,x/ or die "p2 old-row M0 alias missing\n$out";
   }
}
print "vcs_all_five_stripes32_row_advance ok\n";
