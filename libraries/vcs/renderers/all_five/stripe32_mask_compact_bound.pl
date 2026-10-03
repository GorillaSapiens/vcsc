#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Prove a temp-free in-place transpose of the 192-line all_five non-player mask.
#
# prepare_object_masks() historically leaves 12 rows in stride-four form:
#   [BL,M1,M0,scratch] x 12
# The stripes32 raster wants three compact 12-byte lanes indexed by row X:
#   BL[0..11], M1[0..11], M0[0..11]
# object_masks[47] remains the public playfield-position alias and is untouched.
#
# Every move is LDA.z source / STA.z destination = 6 cycles and 4 ROM bytes.
# The dependency graph is acyclic once the sole identity move 0->0 is omitted,
# so a topological order preserves every source without a temporary byte.
use strict;
use warnings;

my %dst;
for my $row (0..11) {
   for my $lane (0..2) {
      my $src=4*$row+$lane;
      my $to=12*$lane+$row;
      next if $src==$to;
      $dst{$src}=$to;
   }
}
die "move count changed\n" unless keys(%dst)==35;

my (%mark,@order);
sub visit {
   my($s)=@_;
   die "mask compaction dependency cycle at $s\n" if ($mark{$s}//0)==1;
   return if ($mark{$s}//0)==2;
   $mark{$s}=1;
   my $d=$dst{$s};
   visit($d) if exists $dst{$d}; # preserve a live source before overwriting it
   $mark{$s}=2;
   push @order,$s;
}
visit($_) for sort {$a<=>$b} keys %dst;
die "topological move count changed\n" unless @order==35;

# Simulate distinct source bytes and execute the move list.
my @m=map { 0x40+$_ } 0..47;
my @before=@m;
for my $s (@order) { $m[$dst{$s}]=$m[$s]; }
for my $row (0..11) {
   die "BL row $row mismatch\n" unless $m[$row]==$before[4*$row];
   die "M1 row $row mismatch\n" unless $m[12+$row]==$before[4*$row+1];
   die "M0 row $row mismatch\n" unless $m[24+$row]==$before[4*$row+2];
}
die "playfield-position alias was clobbered\n" unless $m[47]==$before[47];

my $cycles=6*@order;
my $rom=4*@order;
die "compaction cost changed\n" unless $cycles==210 && $rom==140;
my $list=join(' ',map { $_.'>'.$dst{$_} } @order);
print "stripe32_mask_compact_bound ok: 35 temp-free moves, 210 VBLANK cycles, 140 ROM bytes; order $list\n";
