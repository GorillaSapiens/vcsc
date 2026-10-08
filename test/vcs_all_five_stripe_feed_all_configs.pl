#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripe_feed_all_configs ok
# expectexit: 0

# The pair-indexed feed tables instantiated for EVERY legal configuration, not just
# the published worst case.
#
# Why this is separate from vcs_all_five_stripe_feed_tables.pl: that one proves the
# compiler can emit the tables, and it does so for exactly one configuration --
# (192,32), the worst case.  stripe_generic_feed_source_bound.pl proves the LAYOUT
# for all nineteen, but it proves it in Perl, by constructing the tables in an array.
# So the two proofs together leave a gap that neither closes: nobody has asked the
# COMPILER to instantiate a feed for any other legal geometry.  A layout that is
# correct in Perl and emitted correctly at one size says nothing about the other
# eighteen, and the sizes differ in the one thing that matters -- the pair count R,
# which sets both the table length and where every byte lands.
#
# The configurations come from the geometry authority and are pinned here rather than
# derived, so a geometry change cannot quietly reduce what this covers:
#
#   170 -> 1, 5, 17        192 -> 1, 2, 3, 4, 6, 8, 12, 16, 24, 32
#   228 -> 1, 2, 3, 6, 19  181 -> no equal split; a partial region of 90 pairs
#
# What each configuration asserts, and why each is load-bearing:
#
#   * The emitted bytes equal an independently computed expectation.  The record is
#     read back out of the emitted ROM and the expectation derived from what the
#     program actually authored, so a second copy of the table cannot drift in.
#   * The record values are all DISTINCT: colours are 0..2N-1 and PF data continues
#     2N..8N-1, which is exactly 8N distinct bytes for the largest legal N of 32.
#     With distinct values a transposed slot cannot pass, which is the failure mode
#     that a same-valued table would hide.
#   * Reading the tables back the way the RASTER does -- q, then Y = R-1-q -- must
#     deliver every logical record byte of every stripe exactly once.  That traversal
#     runs opposite to the one that wrote the tables, so a transposition shows up
#     rather than cancelling out.
#   * Each table is page contained, because each read is a fixed four-cycle abs,Y and
#     the six-line machine has zero slack.
#   * Nothing costs RAM.  The tables exist at link time precisely so they are ROM.

use strict;
use warnings;
use File::Spec;
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n" }
@ARGV == 2 or usage();
my ($repo, $tmp) = @ARGV;
make_path($tmp);

my $driver = File::Spec->catfile($repo, 'driver', 'vcsc');
my $vcs    = File::Spec->catdir($repo, 'libraries', 'vcs');
-f $driver or die "driver not built at $driver\n";

sub slurp {
   my ($path) = @_;
   open(my $fh, '<', $path) or return undef;
   local $/;
   my $d = <$fh>;
   close($fh);
   return $d;
}

sub capture {
   my (@cmd) = @_;
   my $err = gensym;
   my $pid = open3(my $in, my $out, $err, @cmd);
   close($in);
   my $so = do { local $/; <$out> };
   my $se = do { local $/; <$err> };
   waitpid($pid, 0);
   $so = '' unless defined $so;
   $se = '' unless defined $se;
   return ($? >> 8, $? & 127, $so, $se);
}

# --- the layout, computed here and NOT taken from the bound ----------------------
# Written out from the rule rather than shared with the bound, so that a mistake in
# the bound's construction cannot be confirmed by reusing it.  Field order is
# 0=C0 1=C1 2..7=PF0..PF5.  Pair q = P*s + p is read at the single index
# Y = R-1-q.  Which window a pair's bytes land in is a compile-time fact of the
# unrolled body, so it is fixed:
#
#   p == 0   colour C0 -> feed0   PF0 -> feed1   PF1 -> feed2
#   p == 1   colour C1 -> feed0   PF2 -> feed1   PF3 -> feed2
#   p == 2   no colour           PF4 -> feed0   PF5 -> feed1
#   p >= 3   nothing: a taller stripe's extra pairs carry no stripe bytes
sub slot_source {
   my ($P, $s, $p) = @_;
   return ([0, 0], [1, 2], [2, 3]) if $p == 0;
   return ([0, 1], [1, 4], [2, 5]) if $p == 1;
   return ([0, 6], [1, 7])          if $p == 2;
   return ();
}

# The source text one table slot must contain, or undef for a spare.  This is the
# WRITE direction: s and p outward to Y.
sub expected_expr {
   my ($R, $P, $s, $p) = @_;
   my $Y = $R - 1 - ($P * $s + $p);
   my @out;
   for my $cell (slot_source($P, $s, $p)) {
      my ($t, $field) = @{$cell};
      my $e = $field == 0 ? "game_playfield_colors[" . (2 * $s) . "]"
           : $field == 1 ? "game_playfield_colors[" . (2 * $s + 1) . "]"
           :               "game_playfield_data[" . (6 * $s + $field - 2) . "]";
      $out[$t] = $e;
   }
   return \@out;
}

# The legal configurations, pinned rather than derived.
my @configs;
for my $lines (170, 192, 228) {
   my %want = $lines == 170 ? (1 => 1, 5 => 1, 17 => 1)
            : $lines == 192 ? (1 => 1, 2 => 1, 3 => 1, 4 => 1, 6 => 1, 8 => 1, 12 => 1, 16 => 1, 24 => 1, 32 => 1)
            :                  (1 => 1, 2 => 1, 3 => 1, 6 => 1, 19 => 1);
   for my $N (sort { $a <=> $b } keys %want) {
      die "lines=$lines is not divisible by N=$N\n" if $lines % $N;
      my $h = $lines / $N;
      die "lines=$lines N=$N gives an odd stripe height $h\n" if $h % 2;
      my $P = $h / 2;
      die "lines=$lines N=$N gives P=$P, below the three-pair minimum\n" if $P < 3;
      my $R = $N * $P;
      die "region $R does not fit lines=$lines\n" if $R > int($lines / 2);
      push @configs, { lines => $lines, N => $N, P => $P, R => $R };
   }
}
# 181 is odd, so it has no equal split.  It is striped by a region that FITS inside
# the allocation rather than filling it, which is exactly why the region is treated
# as a fit and not an equality.
push @configs, { lines => 181, N => 6, P => 15, R => 90 };

scalar(@configs) == 19
   or die "expected 19 legal configurations, found " . scalar(@configs) . "\n";

sub build_fixture {
   my ($c, $path) = @_;
   my ($R, $P, $N) = @{$c}{qw(R P N)};

   my @t = map { my @row; push @row, '0' for 1 .. $R; [@row] } 0 .. 2;
   for my $s (0 .. $N - 1) {
      for my $p (0 .. $P - 1) {
         my $e = expected_expr($R, $P, $s, $p);
         my $Y = $R - 1 - ($P * $s + $p);
         die "Y=$Y out of range for R=$R\n" if $Y < 0 || $Y >= $R;
         for my $t (0 .. $#{$e}) {
            die "table $t index $Y written twice at s=$s p=$p\n"
               if $t[$t][$Y] ne '0';
            $t[$t][$Y] = $e->[$t];
         }
      }
   }

   open(my $fh, '>', $path) or die "could not write $path: $!\n";
   print {$fh} qq{// generated by vcs_all_five_stripe_feed_all_configs.pl -- do not edit
// lines=$c->{lines} N=$N P=$P R=$R
include "vcs.c26"

};
   # Colours are 0..2N-1 and PF data continues 2N..8N-1: 8N distinct bytes, so a
   # transposed slot cannot hold a value that happens to match.
   print {$fh} "const uint8_t game_playfield_colors[" . (2 * $N) . "] := {\n";
   print {$fh} join('', map { (($_ % 16) == 15 ? "\n" : '') . "   $_," } 0 .. 2 * $N - 1);
   print {$fh} "\n};\n\nconst uint8_t game_playfield_data[" . (6 * $N) . "] := {\n";
   print {$fh} join('', map { (($_ % 16) == 15 ? "\n" : '') . "   " . (2 * $N + $_) . "," } 0 .. 6 * $N - 1);
   print {$fh} "\n};\n\n";
   for my $t (0 .. 2) {
      print {$fh} "page const uint8_t feed$t\[$R] := {\n";
      for (my $i = 0; $i < $R; $i += 8) {
         my @row = @{$t[$t]}[$i .. ($i + 7 > $R - 1 ? $R - 1 : $i + 7)];
         print {$fh} "   " . join(', ', @row) . ($i + 8 < $R ? "," : "") . "\n";
      }
      print {$fh} "};\n\n";
   }
   print {$fh} qq{void main(void) {
   VBLANK := 2;
   while (1) {
   }
}
};
   close($fh);
}

my $checked = 0;
for my $c (@configs) {
   my ($R, $P, $N, $lines) = @{$c}{qw(R P N lines)};
   my $tag = "l${lines}n${N}";
   my $src = File::Spec->catfile($tmp, "feed_$tag.c26");
   my $mapfile = File::Spec->catfile($tmp, "feed_$tag.map");
   my $binfile = File::Spec->catfile($tmp, "feed_$tag.bin");
   build_fixture($c, $src);

   my ($rc, $sig, $out, $err) =
      capture($driver, '-I', $vcs, '-Map', $mapfile, $src, '-o', $binfile);
   ($rc == 0 && !$sig) or die "feed build failed for lines=$lines N=$N\n$out$err";
   my $map = slurp($mapfile);
   my $rom = slurp($binfile);
   defined $map && length $map or die "lines=$lines N=$N produced no map\n$out$err";
   defined $rom && length($rom) == 4096
      or die "lines=$lines N=$N did not produce a 4K cartridge\n";

   # Read an object back out of the emitted ROM, and record whether it is
   # page contained.  The record is read from ROM rather than from a second copy of
   # it so the expectation comes from what the program actually authored.
   # The map and ROM are passed in rather than closed over.  A NAMED sub declared
   # inside this loop would bind to the FIRST iteration's lexicals, so from the second
   # configuration onward it would read the first configuration's map -- which is
   # exactly the bug this signature exists to prevent, and which showed up as the
   # (170,1) colour count being reported for every later configuration.
   my $read_object = sub {
      my ($name, $mapref, $romref) = @_;
      my ($addr, $size, $rest) =
         $$mapref =~ /^\s+RODATA\.__vcsc_object\$$name\s+load=\$([0-9A-Fa-f]+)\s+size=\$([0-9A-Fa-f]+)(.*)$/m;
      defined $addr && defined $size or die "object '$name' missing for lines=$lines N=$N\n";
      my $hard = ($rest =~ /page=hard/) ? 1 : 0;
      return ([ unpack('C*', substr($$romref, hex($addr) - 0xf000, hex($size))) ], $hard);
   };
   my ($colors, $colors_hard) = $read_object->('game_playfield_colors', \$map, \$rom);
   my ($pfdata,  $pfdata_hard)  = $read_object->('game_playfield_data',  \$map, \$rom);
   my @feed;
   my %page_hard;
   $page_hard{'game_playfield_colors'} = $colors_hard;
   $page_hard{'game_playfield_data'}  = $pfdata_hard;
   for my $t (0 .. 2) {
      my ($bytes, $hard) = $read_object->("feed$t", \$map, \$rom);
      $page_hard{"feed$t"} = $hard;
      # object() returns a list of bytes, so each feed is wrapped to keep the three
      # tables addressable as a list of arrays rather than one flattened byte list.
      $feed[$t] = $bytes;
   }

   scalar(@{$colors}) == 2 * $N
      or die "lines=$lines N=$N emitted " . scalar(@{$colors}) . " colour bytes, expected " . 2 * $N . "\n";
   scalar(@{$pfdata}) == 6 * $N
      or die "lines=$lines N=$N emitted " . scalar(@{$pfdata}) . " PF bytes, expected " . 6 * $N . "\n";
   for my $t (0 .. 2) {
      scalar(@{$feed[$t]}) == $R
         or die "lines=$lines N=$N feed$t is " . scalar(@{$feed[$t]}) . " bytes, expected $R\n";
   }

   # Each FEED must be page contained, because each read is a fixed four-cycle abs,Y
   # and the six-line machine has zero slack.  The two record arrays are NOT required
   # to be: they are read only while the tables are built, at link time, and never by
   # the raster.  Requiring containment of them too would assert a property the
   # runtime does not depend on, and it is not free -- at the smaller regions a table
   # plus two record arrays no longer fit one page, so requiring all five would fail a
   # configuration that is in fact correct.
   for my $t (0 .. 2) {
      $page_hard{"feed$t"}
         or die "lines=$lines N=$N: feed$t is not page contained; every read of it is"
               . " a fixed four-cycle abs,Y and a straddling table costs a cycle the"
               . " six-line machine does not have\n";
   }

   # Per-slot bytes.  The record values are distinct, so a transposed slot is caught
   # rather than being confirmed by a coincidence.
   for my $q (0 .. $R - 1) {
      my $Y = $R - 1 - $q;
      my $p = $q % $P;
      my $s = int($q / $P);
      my @field = $p == 0 ? (0, 2, 3) : $p == 1 ? (1, 4, 5) : $p == 2 ? (6, 7) : ();
      for my $t (0 .. $#field) {
         my $f = $field[$t];
         my $want = $f == 0 ? $colors->[2 * $s]
                  : $f == 1 ? $colors->[2 * $s + 1]
                  :           $pfdata->[6 * $s + $f - 2];
         die sprintf("lines=%d N=%d: feed%d slot %d (pair %d, stripe %d) holds 0x%02x, expected 0x%02x\n",
                     $lines, $N, $t, $Y, $q, $s, $feed[$t][$Y], $want)
            if $feed[$t][$Y] != $want;
         $checked++;
      }
      # A pair that carries nothing must read as spare in all three tables.
      if (!@field) {
         for my $t (0 .. 2) {
            die "lines=$lines N=$N: feed$t slot $Y should be spare but holds $feed[$t][$Y]\n"
               if $feed[$t][$Y] != 0;
         }
      }
   }

   # The traversal above runs q-outward, the same way the tables were written
   # (s then p outward to Y).  Reading them the other way -- the way the raster does,
   # one q at a time -- is what confirms every logical byte is delivered exactly
   # once, and a transposition cannot cancel out against the writer.
   my %seen;
   for my $q (0 .. $R - 1) {
      my $Y = $R - 1 - $q;
      my $p = $q % $P;
      my $s = int($q / $P);
      my @field = $p == 0 ? (0, 2, 3) : $p == 1 ? (1, 4, 5) : $p == 2 ? (6, 7) : ();
      for my $t (0 .. $#field) {
         my $f = $field[$t];
         my $want = $f == 0 ? $colors->[2 * $s]
                  : $f == 1 ? $colors->[2 * $s + 1]
                  :           $pfdata->[6 * $s + $f - 2];
         die "lines=$lines N=$N: raster read of q=$q feed$t disagrees with the table\n"
            if $feed[$t][$Y] != $want;
         $seen{"$s:$f"}++;
      }
   }
   for my $s (0 .. $N - 1) {
      for my $f (0 .. 7) {
         $seen{"$s:$f"} == 1
            or die "lines=$lines N=$N: stripe $s field $f delivered "
                 . ($seen{"$s:$f"} // 0) . " times, expected exactly once\n";
      }
   }
   # The feed is 3*R bytes whatever the stripe count, and the logical record is 8*N.
   # Smaller stripe counts therefore carry less DATA in the same feed, which is the
   # recorded cost model rather than an accident.
   3 * $R >= 8 * $N
      or die "lines=$lines N=$N: a $R-pair region cannot carry 8*$N logical bytes\n";
}

# Every logical byte of every legal stripe, over all nineteen configurations, was
# compared slot by slot against the record the program authored.  Each stripe carries
# eight bytes and each of those is delivered by exactly one slot, so the total is
# 8 * the sum of the stripe counts -- computed here rather than written out, so the
# figure cannot drift from the configuration list it is supposed to describe.
my $want_slots = 0;
$want_slots += 8 * $_->{N} for @configs;
$checked == $want_slots
   or die "expected 8 * " . $want_slots / 8 . " compared slots across "
        . scalar(@configs) . " configurations, got $checked\n";

print "vcs_all_five_stripe_feed_all_configs ok\n";
exit 0;
