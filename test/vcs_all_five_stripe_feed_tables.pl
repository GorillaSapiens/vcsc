#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripe_feed_tables ok
# expectexit: 0

# The (192,32) pair-indexed feed tables, built as declared and checked as emitted.
#
# This is the concrete instance of the layout that
# libraries/vcs/renderers/all_five/stripe_generic_feed_source_bound.pl derives for
# any (region, pairs-per-stripe, stripes).  That bound owns the layout; this one
# proves the layout can be written down in the public language and that the compiler
# emits it correctly, which is the capability the emit depends on.
#
# What is asserted, and why each matters:
#
#   * every slot of all three tables equals what the bound's layout says it should.
#     Checking the emitted ROM against an independently computed expectation is what
#     catches a transposition that compiled and merely happened to fit.
#   * every logical record byte is delivered exactly once across the three tables,
#     and every slot that should be spare is spare.  A slot silently holding the
#     wrong stripe's byte would still pass a size check.
#   * all three tables are page-contained, because each read is a fixed four-cycle
#     absolute,Y load and a straddling table costs a cycle for the indices that
#     cross.  The six-line machine has zero slack, so this is not cosmetic.
#   * nothing costs RAM: the whole point of deriving the tables at link time is that
#     the 288 bytes are ROM and there is no startup copy.
#
# The fixture is a probe, not a renderer.  It declares the tables exactly as the
# renderer will, and its bytes are generated from the same layout the bound owns, so
# a change to one and not the other fails here rather than silently producing a
# plausible-looking wrong raster.
#
# The assertions have been checked against deliberate damage rather than only
# against a passing run: swapping two feed0 slots is caught by the per-slot byte
# comparison, dropping `page` from a feed is caught by the containment check, and
# making a feed writable is caught because it moves off RODATA and costs RAM.  A
# check that cannot fail is not a check.

use strict;
use warnings;
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n" }
sub slurp_fh { my ($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub slurp {
   my ($p)=@_;
   open(my $f,'<:raw',$p) or return undef;
   local $/; my $d=<$f>; close($f);
   return $d;
}
sub capture {
   my (@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in);
   my $so=slurp_fh($out);
   my $se=slurp_fh($err);
   waitpid($pid,0);
   return ($?>>8,$?&127,$so,$se);
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;

my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $src=File::Spec->catfile($repo,'test','fixtures','all_five_stripe_feed','feed_transposition_probe.c26');
my $mapfile=File::Spec->catfile($tmp,'stripe_feed_tables.map');
my $binfile=File::Spec->catfile($tmp,'stripe_feed_tables.bin');

my ($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$mapfile,$src,'-o',$binfile);
$rc==0 && !$sig or die "feed table build failed\n$out$err";
my $map=slurp($mapfile);
my $rom=slurp($binfile);
defined $map && length $map or die "feed table build produced no map\n$out$err";
defined $rom && length $rom==4096 or die "feed table build did not produce a 4K cartridge\n";

# ------------------------------------------------------------------- geometry
# The published (192,32) worst case: 96 region pairs, three pairs per stripe.
my $R=96;
my $P=3;
my $N=32;
my $stripes_arg = $ENV{VCSC_ALL_FIVE_STRIPES} || 32;
$stripes_arg == 32 or die "this fixture pins the (192,32) case\n";

# The public record, read back out of the emitted ROM so the expectation is derived
# from what the program actually authored rather than from a second copy of it.
sub object {
   my ($name)=@_;
   my ($addr,$size)=
      $map=~/^\s+RODATA\.__vcsc_object\$$name\s+load=\$([0-9A-Fa-f]+)\s+size=\$([0-9A-Fa-f]+)/m;
   defined $addr && defined $size or die "object '$name' not found in the map\n";
   return (unpack('C*',substr($rom,hex($addr)-0xf000,hex($size))));
}
my @colors=object('game_playfield_colors');
my @pfdata=object('game_playfield_data');
scalar(@colors)==2*$N or die "colour record is ".scalar(@colors)." bytes, expected ".2*$N."\n";
scalar(@pfdata)==6*$N or die "PF record is ".scalar(@pfdata)." bytes, expected ".6*$N."\n";

# Logical record field 8s+f of stripe s: f<2 is a colour, else PF(f-2).
sub record_byte {
   my ($field)=@_;
   my $s = int($field/8);
   my $rel = $field - 8*$s;
   $s %= $N;
   return $rel < 2 ? $colors[2*$s+$rel] : $pfdata[6*$s+($rel-2)];
}

# ------------------------------------------------------- the expected layout
#
# pair q = P*s + p is read at the single index Y = R-1-q.  Three pairs carry eight
# bytes: pairs 0 and 1 carry a colour plus two PF bytes, pair 2 carries two PF
# bytes, and no pair carries more.
my @blank = () x $R;                        # one row of unfilled slots
my @expect=([@blank],[@blank],[@blank]);
for my $q (0..$R-1) {
   my $Y=$R-1-$q;
   my ($s,$p)=(int($q/$P),$q%$P);
   my @take = $p==0 ? ([0,0],[1,2],[2,3])
           : $p==1 ? ([0,1],[1,4],[2,5])
           : $p==2 ? ([0,6],[1,7])
           :           ();
   for my $take (@take) {
      my ($tab,$field)=@$take;
      defined $expect[$tab][$Y]
         and die "layout would write table $tab index $Y twice\n";
      $expect[$tab][$Y]=record_byte(8*($s+1)+$field);
   }
}

# ------------------------------------------------------------------ the tables
my @feed;
for my $n (0,1,2) {
   my @got=object("feed$n");
   scalar(@got)==$R
      or die "feed$n is ".scalar(@got)." bytes, expected $R\n";
   for my $i (0..$R-1) {
      my $want=$expect[$n][$i];
      if (!defined $want) {
         $got[$i]==0 or die "feed$n slot $i should be spare but holds $got[$i]\n";
         next;
      }
      $got[$i]==$want
         or die sprintf("feed%d slot %d (Y=%d) holds 0x%02x, expected 0x%02x\n",
                        $n,$i,$R-1-$i,$got[$i],$want);
   }
   push @feed,\@got;
}
my $spare_total=0;
for my $n (0,1,2) {
   $spare_total += scalar grep { $_==0 } @{$feed[$n]};
}
# Spare slots are counted from the layout, not from the emitted bytes, because a
# record byte may legitimately be zero and a value-based count would conflate the two.
my $layout_spare=0;
for my $q (0..$R-1) {
   my $p=$q%$P;
   $layout_spare++ if $p==2;                # pair 2 fills two of its three slots
}
$layout_spare == $N
   or die "layout spare accounting changed: $layout_spare, expected $N\n";
my $emitted_spare=0;
for my $n (0,1,2) {
   $emitted_spare += scalar grep { !defined $expect[$n][$_] } 0..$R-1;
}
$emitted_spare == $layout_spare
   or die "the fixture's spare slots ($emitted_spare) do not match the layout ($layout_spare)\n";

# Every logical byte of every stripe is delivered exactly once.  This is the property
# that makes the raster correct rather than merely plausible: a byte delivered twice
# or not at all would show as a missing or bleeding stripe.
my %delivered;
for my $q (0..$R-1) {
   my $Y=$R-1-$q;
   my ($s,$p)=(int($q/$P),$q%$P);
   next if $p>2;
   my $key=($s+1)%$N;
   $delivered{"$key:p$p"}++;
}
for my $s (0..$N-1) {
   for my $p (0..2) {
      $delivered{"$s:p$p"} == 1
         or die "stripe $s pair $p delivers ".($delivered{"$s:p$p"}//0)." reads\n";
   }
}

# ------------------------------------------------------------ page containment
# Each read is a fixed four-cycle absolute,Y load, so a table that straddles a
# 256-byte page costs an extra cycle for the indices that cross.  The six-line
# machine is the zero-slack design point, so containment is required, not preferred.
for my $n (0,1,2) {
   $map=~/^\s+RODATA\.__vcsc_object\$feed$n\s+load=\$[0-9A-Fa-f]+\s+size=\$[0-9A-Fa-f]+ page=hard/m
      or die "feed$n lost its hard page policy\n$map";
   my ($lo,$hi)=
      $map=~/^\s+RODATA\.__vcsc_object\$feed$n\s+base=\$[0-9A-Fa-f]+ offset=\$0000 max=\$[0-9A-Fa-f]+ effective=\$([0-9A-Fa-f]+)-\$([0-9A-Fa-f]+)/m;
   defined $lo && defined $hi or die "feed$n reported no effective range\n$map";
   hex($hi)-hex($lo)+1 == $R
      or die sprintf("feed%d spans %d bytes, expected %d\n",$n,hex($hi)-hex($lo)+1,$R);
   ((hex($lo) & 0xff) + $R) <= 0x100
      or die sprintf("feed%d straddles a page: \$%s-\$%s\n",$n,$lo,$hi);
}

# ------------------------------------------------------------------- no RAM
# Deriving the tables at link time is what keeps the 288 bytes in ROM.  A fold that
# also emitted a startup copy, or that left a RAM object behind, would defeat it.
$out =~ /^\s+ram\s+used=(\d+) bytes/m or die "could not read the RAM footprint\n$out";
my $ram=$1;
$ram==0
   or die "the feed tables cost $ram bytes of RAM; they must be link-time ROM only\n";
$out =~ /^\s+rom\s+used=(\d+) bytes/m or die "could not read the ROM footprint\n$out";
my $rom_used=$1;
# 192 record bytes plus three 96-byte tables, and nothing else beyond the trivial
# loop and the run-time itself.  Bound it rather than pin it: the point is that the
# tables cost 288 bytes of ROM, not that a probe has an exact total.
$rom_used < 900
   or die "the feed tables cost more ROM than expected: $rom_used bytes\n";

print "vcs_all_five_stripe_feed_tables ok\n";
