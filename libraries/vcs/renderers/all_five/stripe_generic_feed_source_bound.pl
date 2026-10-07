#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Where the generic positive-stripe raster's next-stripe bytes must come from.
#
# The raster needs, for renderer pair q of the region, the next stripe's bytes at
# fixed absolute addresses reached by the frame-wide pair index Y.  Those bytes are
# the logical eight-byte stripe record (C0, C1, PF0..PF5) transposed into pair
# order.  stripe32_feed_layout.pl proves the layout for the stripes=32 case; this
# file owns the two questions that layout does not answer:
#
#   1. does the layout generalise to every legal (region, pairs-per-stripe) pair,
#      and what exactly is its legality condition; and
#   2. can those three tables be produced at all.
#
# Part 1 generalises the layout instead of assuming the six-scanline case.  A pair
# consumes three bytes, so three page-contained tables are needed, and with at most
# three bytes per pair, three pairs are needed to carry eight bytes.  That is why
# the geometry authority rejects P<3, and the two derivations below are written so
# they cannot silently disagree.
#
# Part 2 proves the tables are load-bearing rather than convenient.  The record
# form that keeps X holding a record offset was already rejected
# (stripe32_record_common_index_bound.pl).  The other record form, a zero-page
# record pointer with a compile-time field offset, is searched here, and each of
# its three reads is rejected on its own so the rejections are attributable.
#
# Part 3 and Part 4 measure the two places the tables could otherwise live.
#
# ROM: they fit, as a DERIVATION of the public record.  A file-scope `const`
# object whose initializer is entirely constant is folded at link time, and its
# bytes are then readable as a constant expression, so a table built from another
# table's element reads is itself link-time data -- no RAM, no startup copy, no
# per-count data in the public authoring form.  That fold is verified here by
# building a transposed table and checking the emitted ROM bytes, and covered on
# its own terms by test/vcs_const_link_time_table.pl.
#
# RAM: they do not come close.  3*region bytes does not fit a 128-byte cartridge by
# more than a factor of two, and no rearrangement of the prototype's own scratch
# makes room.  This is recorded because it is what rules out the runtime-built
# alternative that used to be the recorded first step.
#
# CONSEQUENCE.  Timing is settled (Part 2), the ROM budget is settled
# (stripe_generic_rom_bound.pl), and the feed's origin is settled here.  The emit is
# unblocked: the renderer can declare its three page-contained feed tables as a
# transposition of the public eight-byte record and read them at four cycles a byte
# with no stripe index and no RAM.
use strict;
use warnings;
use File::Spec;

sub slurp {
   my($p)=@_;
   open(my $f,'<:raw',$p) or return undef;
   local $/; my $d=<$f>; close($f);
   return $d;
}

my $dir=$ENV{VCSC_ALL_FIVE_DIR}
   or die "VCSC_ALL_FIVE_DIR must name libraries/vcs/renderers/all_five\n";
my $root=$ENV{VCSC_ALL_FIVE_REPO}
   or die "VCSC_ALL_FIVE_REPO must name the repository root\n";
my $solver=File::Spec->catfile($dir,'..','kernel_schedule_search.pl');
-f $solver or die "missing solver $solver\n";

sub capture {
   my(@cmd)=@_;
   require IPC::Open3;
   require Symbol;
   my $err=Symbol::gensym();
   my $pid=IPC::Open3::open3(my $in,my $out,$err,@cmd);
   close($in);
   local $/; my $so=<$out>; my $se=<$err>;
   waitpid($pid,0);
   return ($?>>8, defined($so)?$so:'', defined($se)?$se:'');
}

# ------------------------------------------------------- Part 1: the layout
#
# Region pairs R, P pairs per stripe, N stripes, so R == N*P.
# Logical record field order is 0=C0 1=C1 and 2..7 = PF0..PF5.
# Pair q = P*s + p consumes, at the single index Y = R-1-q, one byte from each
# table.  Which table feeds which window is a compile-time fact of the unrolled
# body, so it is fixed:
#
#   p == 0   colour <- T0 = C0      even PF <- T1 = PF0     odd PF <- T2 = PF1
#   p == 1   colour <- T0 = C1      even PF <- T1 = PF2     odd PF <- T2 = PF3
#   p == 2   no colour              even PF <- T0 = PF4     odd PF <- T1 = PF5
#   p >= 3   nothing: a taller stripe's extra pairs carry no stripe bytes
#
# Delivers the tables, the spare-slot count and the delivered-byte count.  Every
# logical byte of every stripe is checked to be delivered exactly once, by reading
# the tables back the way the raster does.
sub build_feed {
   my($R,$P,$N)=@_;
   die "region $R is not $N stripes of $P pairs\n" unless $N*$P == $R;
   die "pairs-per-stripe $P cannot carry eight bytes\n" if $P < 3;

   my @t=map { my @row; push @row,undef for 1..$R; [@row] } 0..2;
   for my $s (0..$N-1) {
      for my $p (0..$P-1) {
         my $Y=$R-1-($P*$s+$p);
         my @take;
         if    ($p==0) { @take=([0,0],[1,2],[2,3]) }
         elsif ($p==1) { @take=([0,1],[1,4],[2,5]) }
         elsif ($p==2) { @take=([0,6],[1,7]) }
         for my $take (@take) {
            my($tab,$field)=@$take;
            die "index $Y out of range\n" if $Y<0 || $Y>=$R;
            die "table $tab index $Y written twice\n" if defined $t[$tab][$Y];
            $t[$tab][$Y]=[$s,$field];
         }
      }
   }

   # Read every table back exactly as the raster does and check that each read
   # yields a byte of the NEXT stripe, and that each such byte is read once only.
   my %seen;
   my $delivered=0;
   for my $q (0..$R-1) {
      my $Y=$R-1-$q;
      my $p=$q % $P;
      my @field = $p==0 ? (0,2,3) : $p==1 ? (1,4,5) : $p==2 ? (6,7) : ();
      for my $tab (0..$#field) {
         my $cell=$t[$tab][$Y];
         defined $cell
            or die "pair $q (Y=$Y) table $tab is not filled\n";
         my($s,$field)=@$cell;
         $s == int($q/$P)
            or die "pair $q table $tab reads stripe $s, expected ".int($q/$P)."\n";
         $field == $field[$tab]
            or die "pair $q table $tab holds field $field, expected $field[$tab]\n";
         my $key=($s+1)%$N;
         $seen{"$key:$field"}++
            and die "stripe $key field $field delivered twice\n";
         $delivered++;
      }
   }
   for my $s (0..$N-1) {
      for my $field (0..7) {
         $seen{"$s:$field"} == 1
            or die "stripe $s field $field delivered ".($seen{"$s:$field"}//0)." times\n";
      }
   }

   my $spare=0;
   $spare++ for grep { !defined $_ } map { @$_ } @t;
   return (\@t,$spare,$delivered);
}

# (192,32) is the published worst case and must reproduce the maintained proof.
my($t32,$spare32,$deliv32)=build_feed(96,3,32);
die "feed size changed\n" unless 3*96==288;
die "delivered count changed\n" unless $deliv32==256;
die "spare count changed\n" unless $spare32==32;
my(undef,$out)=capture($^X,File::Spec->catfile($dir,'stripe32_feed_layout.pl'));
$out =~ /3x96=288 bytes/ && $out =~ /feed2 has 32 spare pair2 slots/
   or die "maintained feed layout proof changed\n$out";

# The layout generalises: every legal region, not only the stripes=32 instance.
# Equal splits of the maintained line modes must all work, and the count is pinned
# so a geometry change cannot silently alter what the feed has to cover.
my %want=(
   170 => [1,5,17],
   181 => [],
   192 => [1,2,3,4,6,8,12,16,24,32],
   228 => [1,2,3,6,19],
);
my @legal;
for my $lines (sort { $a <=> $b } keys %want) {
   my @got;
   for my $n (1..32) {
      next if $lines % $n;
      my $h=$lines/$n;
      next if $h % 2 || $h < 6;
      my $P=$h/2;
      my $R=$n*$P;
      next if $R > int($lines/2);      # the region has to fit the allocation
      my(undef,$spare,$deliv)=build_feed($R,$P,$n);
      $deliv == 8*$n
         or die "lines=$lines N=$n delivered $deliv bytes, expected ".8*$n."\n";
      $spare == 3*$R-8*$n
         or die "lines=$lines N=$n spare accounting is wrong\n";
      push @legal,sprintf('lines=%d/N=%d(P=%d,R=%d,rom=%d)',$lines,$n,$P,$R,3*$R);
      push @got,$n;
   }
   my $g=join(',',@got);
   my $w=join(',',@{$want{$lines}});
   $g eq $w or die "legal stripe counts for lines=$lines changed: '$g' vs '$w'\n";
}
# 181 is odd, so it takes no equal split; it is striped by a partial region, which
# is exactly why the region is treated as a fit rather than an equality.
my(undef,$spare181,$deliv181)=build_feed(90,15,6);
die "181-line partial region changed\n" unless $deliv181==48 && $spare181==3*90-48;

# P<3 cannot carry eight bytes in pairs of at most three.  Derive that rather than
# restate it, so this file and the geometry authority cannot drift apart.
for my $P (1,2) {
   die "pairs-per-stripe $P unexpectedly has room for eight bytes\n"
      if 3*$P >= 8;
}

# ------------------------------- how many tables the whole generic range needs
#
# An earlier claim in this workstream was that the feeds are "uniform for the whole
# 2..32 range".  That is true of the ROM cost and false of the SOURCE cost.
#
# A note on WHY, because the first explanation offered here was wrong.  It was
# attributed to the compiler having no arithmetic in array sizes.  That WAS a real
# limitation -- the grammar accepted only a literal -- but it was not the cause, and
# the grammar no longer has it: `direct_declarator '[' conditional_expr ']'` now
# folds a compile-time integer constant extent.  Even when the limitation was real it
# could not have been the cause, because a size expression cannot change WHICH byte
# goes in which slot, only how the extent is spelled.  The cause is that the feed
# content depends on P = pairs-per-stripe: q = P*s + p decides the stripe, so 192/2
# fills 48 pairs from stripe 0 while 192/32 fills 3 and moves on.  The tables differ
# because the DATA LAYOUT differs, which is inherent to being generic in stripes.
#
# So relaxing the grammar would let a renderer write `[3*(TEMPLATE_lines/2)]` instead
# of enumerating extents.  That is a readability win at a handful of sites and it
# would not reduce the table count at all.  Measure the layout dependence below
# rather than restating either explanation.
my @configs;
for my $lines (sort { $a <=> $b } keys %want) {
   for my $n (1..32) {
      next if $lines % $n;
      my $h=$lines/$n;
      next if $h % 2 || $h < 6;
      my $P=int($h/2);
      my $R=$n*$P;
      next if $R > int($lines/2);          # the region has to fit the allocation
      my @sig;
      for my $q (0..$R-1) {
         my($s,$p)=(int($q/$P),$q%$P);
         my @f = $p==0 ? (0,2,3) : $p==1 ? (1,4,5) : $p==2 ? (6,7) : ();
         push @sig, join(',', map { "$s/$_" } @f);
      }
      push @configs,{lines=>$lines,n=>$n,P=>$P,R=>$R,sig=>join('|',@sig)};
   }
}
# The 181 partial region, which is the configuration that exercises "the region only
# has to fit" and therefore is not in the equal-split sweep above.
{
   my($R,$P,$N)=(90,15,6);
   my @sig;
   for my $q (0..$R-1) {
      my($s,$p)=(int($q/$P),$q%$P);
      my @f = $p==0 ? (0,2,3) : $p==1 ? (1,4,5) : $p==2 ? (6,7) : ();
      push @sig, join(',', map { "$s/$_" } @f);
   }
   push @configs,{lines=>181,n=>$N,P=>$P,R=>$R,sig=>join('|',@sig)};
}
# 18 equal splits plus the 181 partial region, which is the configuration that
# exercises "the region only has to fit".
scalar(@configs)==scalar(@legal)+1
   or die "legal stripe configuration count changed: ".scalar(@configs)
        ." for ".scalar(@legal)." equal splits plus one partial region\n";
my %distinct;
$distinct{$_->{sig}}=1 for @configs;
scalar(keys %distinct)==scalar(@configs)
   or die "two legal stripe configurations now share a feed; the per-configuration "
        . "table count is no longer what this file reports\n";

# Show the dependence is on the LAYOUT, not on the size spelling: 192/16 and 228/19
# are the only pair of configurations that share a pairs-per-stripe value, and their
# feeds still differ because the region length differs.  If they ever matched, this
# would report it rather than leaving the "no arithmetic in sizes" story standing.
my %shared_P;
push @{$shared_P{$_->{P}}}, $_->{lines}."/".$_->{n} for @configs;
for my $P (sort { $a <=> $b } keys %shared_P) {
   next if scalar(@{$shared_P{$P}}) < 2;
   my %sig;
   $sig{$_->{sig}}++ for grep { $_->{P} == $P } @configs;
   scalar(keys %sig)==scalar(@{$shared_P{$P}})
      or die "configurations sharing P=$P now share a feed; the table count changed\n";
}
my $source_entries=0;
$source_entries += 3*$_->{R} for @configs;
# ROM cost per build is set by the line mode, not by the stripe count: a full region
# is always half the allocated lines.  Check that, because it is what makes the feed
# uniform at run time even though it is not uniform in source.
my %rom_by_lines;
for my $c (@configs) {
   $rom_by_lines{$c->{lines}} //= 3*$c->{R};
}
for my $lines (sort { $a <=> $b } keys %rom_by_lines) {
   for my $c (grep { $_->{lines} == $lines } @configs) {
      3*$c->{R} == $rom_by_lines{$lines}
         or die "feed ROM cost varies with the stripe count at lines=$lines\n";
   }
}
my $rom_per_build=$rom_by_lines{192};
die "feed ROM per build changed\n" unless $rom_per_build==288;

# ------------------------------------------- Part 2: the feed is load-bearing
#
# Each record-based read is searched on its own, so a rejection is attributable to
# that read rather than to the sum of the extra cycles.  The window is named, not
# just counted: a relaxation that moved a rejection to a different operation would
# mean a different window had become available, which is a different claim.
my %window=(
   color => 'p0_a_visible',
   even  => 'p0_p1_feed',
   odd   => 'p0_p0_mid',
);
my @rejected;
for my $which (sort keys %window) {
   local $ENV{VCSC_STRIPE_POINTER_SOURCE}=$which;
   my(undef,$rep,$rerr)=capture($^X,$solver,'--max-solutions','1',
      File::Spec->catfile($dir,'stripe_feed_pointer_source_search.pl'));
   $rep .= $rerr;
   my @bad=grep { m/cannot fit between earliest\/latest_end/ } split /\n/,$rep;
   @bad==1 or die "record-pointer $which source did not fail cleanly\n$rep";
   my($op)=$bad[0]=~m{^(\S+?)/};
   $op eq $window{$which}
      or die "record-pointer $which source failed in $op, expected $window{$which}\n";
   push @rejected,sprintf('%s(%s)',$which,$op);
}
# The unmodified machine must still schedule, or the rejections above prove nothing.
my(undef,$rep0,$rerr0)=capture($^X,$solver,'--max-solutions','1',
   File::Spec->catfile($dir,'stripe32_sixline_machine_search.pl'));
$rep0 .= $rerr0;
$rep0 =~ /^solution 1 for all_five stripes32 six-scanline rolling machine$/m
   or die "authoritative six-line machine no longer schedules\n$rep0";
$rep0 !~ /\bIDLE\b/
   or die "authoritative six-line machine used fictitious idle time\n$rep0";

# ------------------------------------------- Part 3: the tables cannot be RAM
#
# Total cartridge RAM is read back from the reference build rather than assumed, so
# the comparison cannot drift if the linker's accounting moves.
# Scratch files go in the caller's temporary directory when it supplies one, and in
# a private mkdtemp directory otherwise.
#
# This matters more than it looks.  A previous version wrote to FIXED names in the
# shared system temporary directory, so two people running the suite at the same time
# in different checkouts would overwrite each other's map and cartridge mid-build.
# That is a real hazard for this project, because concurrent runs in separate
# directories are normal.  The runners already hand down a unique directory per test;
# use it.
my $tmpdir=$ENV{VCSC_ALL_FIVE_TMP};
if (!$tmpdir || !-d $tmpdir) {
   require File::Temp;
   $tmpdir=File::Temp::tempdir("vcsc_feed_source_XXXXXX", TMPDIR => 1, CLEANUP => 1);
}
my($ref_rc,$refout,$referr)=capture(
   File::Spec->catfile($root,'driver','vcsc'),
   '-I',File::Spec->catdir($root,'libraries','vcs'),
   '-Map',File::Spec->catfile($tmpdir,'feed_source_stripes2.map'),
   File::Spec->catfile($root,'test','fixtures','all_five_stripes2_192','smoke.c26'),
   '-o',File::Spec->catfile($tmpdir,'feed_source_stripes2.bin'));
# Check the exit code BEFORE parsing its output.  Discarding it turned every possible
# driver failure -- a missing binary, a stale build, a link error -- into a complaint
# about the RAM footprint, which names a symptom rather than the cause.
$ref_rc==0
   or die "reference stripes=2 build failed (exit $ref_rc)\nstdout:\n$refout\nstderr:\n$referr\n";
my($refmap)=slurp(File::Spec->catfile($tmpdir,'feed_source_stripes2.map'));
defined $refmap
   or die "reference build wrote no map\nstdout:\n$refout\nstderr:\n$referr\n";
$refout =~ /^\s+ram\s+used=(\d+) bytes .*free=(\d+) bytes/m
   or die "could not read the reference RAM footprint\nexit $ref_rc\nstdout:\n$refout\nstderr:\n$referr\n";
my($ram_used,$ram_free)=($1,$2);
my $ram_total=$ram_used+$ram_free;
$ram_total==128
   or die "cartridge RAM total is no longer 128 bytes: $ram_total\n";
# Measured stripe scratch the generic machine would replace.  Read it from the
# reference map rather than hard-coding it, so the arithmetic cannot drift.
my $scratch=0;
my $scratch_objects=0;
while ($refmap=~/^\s+BSS\.__vcsc_object\$game_stripe_(\w+)\s+run=\$[0-9A-Fa-f]{4}\s+size=\$([0-9A-Fa-f]{4})/mg) {
   $scratch += hex($2);
   $scratch_objects++;
}
$scratch>0 or die "no measured stripe scratch found in the reference map\n";
my $feed_bytes=3*96;
die "feed size changed\n" unless $feed_bytes==288;
my $best_case=$ram_used-$scratch;
$feed_bytes < $best_case
   and die "the feed unexpectedly fits once the prototype scratch is freed\n";
$feed_bytes < $ram_total
   and die "the feed unexpectedly fits the whole cartridge RAM\n";

# ---------------------------- Part 4: the tables ARE derived ROM, and contained
#
# The same probe build answers both questions that remain.  A table derived from the
# public record's element reads is link-time ROM with no RAM and no startup copy,
# and a `page const` table of the feed's own 96-byte shape is placed page-contained,
# which is what makes the four-cycle absolute,Y reads exact.
my($probe_rc,$probeout,$probeerr)=capture(
   File::Spec->catfile($root,'driver','vcsc'),
   '-I',File::Spec->catdir($root,'libraries','vcs'),
   '-Map',File::Spec->catfile($tmpdir,'feed_source_derived.map'),
   File::Spec->catfile($root,'test','fixtures','all_five_stripe_feed','derived_ro_probe.c26'),
   '-o',File::Spec->catfile($tmpdir,'feed_source_derived.bin'));
my $probemap=slurp(File::Spec->catfile($tmpdir,'feed_source_derived.map'));
defined $probemap && length $probemap
   or die "derived-table probe produced no map (exit $probe_rc)\n"
        ."stdout:\n$probeout\nstderr:\n$probeerr\n";
$probe_rc==0
   or die "derived-table probe build failed (exit $probe_rc)\n"
        ."stdout:\n$probeout\nstderr:\n$probeerr\n";
$probemap =~ /^\s+RODATA\.__vcsc_object\$src\s+load=/m
   or die "the source const table is no longer ROM data\n$probemap";

# The compiler now folds element reads of a link-time `const` table, so the derived
# table IS ROM data and this is no longer the blocker it used to be.  Assert the
# derived bytes too: ROM placement alone would pass a fold that produced the wrong
# transposition, and the feed tables are exactly this shape.
$probemap =~ /^\s+RODATA\.__vcsc_object\$derived\s+load=/m
   or die "a const table derived from const element reads is no longer ROM data\n$probemap";
my $probebin=slurp(File::Spec->catfile($tmpdir,'feed_source_derived.bin'));
defined $probebin && length $probebin==4096
   or die "derived-table probe did not produce a 4K cartridge (exit $probe_rc)\n"
        ."stdout:\n$probeout\nstderr:\n$probeerr\n";
my ($derived_addr)=$probemap=~/^\s+RODATA\.__vcsc_object\$derived\s+load=\$([0-9A-Fa-f]+)/m;
defined $derived_addr
   or die "could not read the derived table's ROM address\n";
my @derived=unpack('C*',substr($probebin,hex($derived_addr)-0xf000,8));
my @want=(0x88,0x77,0x66,0x55,0x44,0x33,0x22,0x11);
join(',',@derived) eq join(',',@want)
   or die "derived table holds ".join(',',@derived).", expected ".join(',',@want)."\n";

# The feed tables are derived from the record AND page-contained, so measure that
# combination rather than a hand-written page table: it is the shape the renderer
# will declare, and a containment constraint that only worked on a literal
# initializer would be lost exactly where it is needed.
my ($feed_page_lo,$feed_page_hi)=
   $probemap=~/^\s+RODATA\.__vcsc_object\$feed_page\s+base=\$[0-9A-Fa-f]+ offset=\$0000 max=\$[0-9A-Fa-f]+ effective=\$([0-9A-Fa-f]+)-\$([0-9A-Fa-f]+)/m;
$feed_page_lo && $feed_page_hi
   or die "derived page-contained feed data reported no effective range\n";
my $feed_page_size=hex($feed_page_hi)-hex($feed_page_lo)+1;
$feed_page_size==96
   or die "derived page-contained feed data spans $feed_page_size bytes, expected 96\n";
((hex($feed_page_lo) & 0xff) + $feed_page_size) <= 0x100
   or die sprintf("derived page-contained feed data straddles a page: \$%s-\$%s\n",
                  $feed_page_lo,$feed_page_hi);
# A derived table must repeat its source byte, so the containment is measured on the
# real shape and not merely on a table that happens to fit.
my ($feed_page_addr)=$probemap=~/^\s+RODATA\.__vcsc_object\$feed_page\s+load=\$([0-9A-Fa-f]+)/m;
my @feed_page=unpack('C*',substr($probebin,hex($feed_page_addr)-0xf000,$feed_page_size));
my @repeat = map { join(',',@want) } 1 .. 12;   # the reversal repeated twelve times
join(',',@feed_page) eq join(',',@repeat)
   or die "derived feed data does not carry the transposed source bytes\n";
# `page const` delivers the containment the fixed-cost reads need, and the linker
# enforces it.  Check the effective ranges the linker reports rather than the
# requested addresses, because containment is what the reads care about.
my $page_size=0x60;             # three 96-byte tables, the (192,32) feed shape
my @contained;
for my $n (0,1,2) {
   $probemap =~ /^\s+RODATA\.__vcsc_object\$page$n\s+load=\$([0-9A-Fa-f]+)\s+size=\$[0-9A-Fa-f]+ page=hard/m
      or die "page const table $n lost its hard page policy\n$probemap";
   $probemap =~ /^\s+RODATA\.__vcsc_object\$page$n\s+base=\$([0-9A-Fa-f]+) offset=\$0000 max=\$[0-9A-Fa-f]+ effective=\$([0-9A-Fa-f]+)-\$([0-9A-Fa-f]+)/m
      or die "page const table $n reported no effective range\n$probemap";
   my($lo,$hi)=(hex($2),hex($3));
   $hi-$lo+1 == $page_size
      or die "page const table $n spans ".($hi-$lo+1)." bytes, expected $page_size\n";
   (($lo & 0xff) + $page_size) <= 0x100
      or die sprintf("page const table $n straddles a page: \$%04X-\$%04X\n",$lo,$hi);
   push @contained,sprintf('$%04X-$%04X',$lo,$hi);
}
# `page` only helps a table whose initializer is a link-time constant: the same
# modifier on a table initialized from another array lands in BSS and, at this
# size, overflows the cartridge RAM.  That is a property worth keeping explicit,
# because the feed is exactly the table shape where the two differ.
my $probe_src=slurp(File::Spec->catfile($root,'test','fixtures','all_five_stripe_feed','derived_ro_probe.c26'));
$probe_src =~ /page const uint8_t page1\[96\] := \{/s
   or die "the probe no longer builds its page tables from link-time constants\n";
$probe_src !~ /page const uint8_t \w+\[\d+\] := \w+;/s
   or die "the probe reintroduced a non-constant page-table initializer\n";

printf "stripe_generic_feed_source_bound ok: the pair-indexed layout generalises -- three page-contained tables with one index each, pair q read at Y=region-1-q, pairs 0 and 1 carrying a colour plus two PF bytes and pair 2 carrying two, so three pairs are needed for eight bytes and P<3 is exactly what the geometry authority rejects; (192,32) reproduces the maintained proof at %d bytes with %d spare slots, and %d legal equal splits across the maintained line modes are covered plus the 181 partial region; the tables are load-bearing, since a zero-page record pointer is rejected separately for %s; and they fit ROM as a derivation of the public record, verified by building a transposed table from another const table's element reads and checking the emitted ROM bytes, with the containment their fixed-cost reads need already available as three %d-byte page const tables at %s; the only remaining placement bar is RAM, where they do not come close (%d bytes against %d used and %d free in the reference build, only %d bytes of stripe scratch in %d objects to free, and %d bytes of cartridge RAM in total); one correction to an earlier claim: the feeds are uniform in ROM cost (%d bytes per build regardless of the stripe count) but NOT in source, because the content depends on the DATA LAYOUT -- q=P*s+p picks the stripe, so 192/2 fills 48 pairs from one stripe while 192/32 fills 3 and moves on -- which is inherent to being generic in stripes and would NOT be fixed by allowing arithmetic in array sizes (the grammar now folds a constant expression there, and it never reduced the table count: a size expression cannot change WHICH byte goes in which slot, only how the extent is spelled, so that change bought readability alone); so all %d legal configurations need their own tables, %d source entries in total, which is a source-size cost and not a runtime one; so the feed origin is settled and the emit is unblocked\n",
   $feed_bytes,$spare32,scalar(@legal),join(', ',@rejected),
   $page_size,join(', ',@contained),
   $feed_bytes,$ram_used,$ram_free,$scratch,$scratch_objects,$ram_total,
   $rom_per_build,scalar(@configs),$source_entries;