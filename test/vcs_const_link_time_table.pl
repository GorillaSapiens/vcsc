#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_const_link_time_table ok
# expectexit: 0

# A file-scope `const` object whose initializer is entirely constant is folded at
# link time, so its bytes are readable as a constant expression and a table
# derived from another table is link-time data rather than RAM plus a startup
# copy.
#
# This is the capability the generic positive-stripe renderer needs: its three
# pair-indexed feed tables are the logical eight-byte stripe record transposed, and
# the public record is the only thing a program should have to author.  See
# libraries/vcs/renderers/all_five/stripe_generic_feed_source_bound.pl, which
# measures the renderer side.
#
# This reads the generated assembly rather than a link map.  Placement and bytes are
# both decided by the compiler, and asserting on them there avoids inventing a
# cartridge profile that has nothing to do with either.
#
# Both the placement and the bytes are asserted, because either alone would be
# weak: placement alone would pass a fold that compiled but produced the wrong
# transposition, and bytes alone would pass a table that happened to be right while
# still costing RAM and a startup copy.  The negative cases matter as much as the
# positive ones.  The fold is byte-granular by construction, an out-of-range read
# must be refused rather than folded to an adjacent byte, and a wider element type
# must keep its runtime-read behaviour.

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

my $cc1=File::Spec->catfile($repo,'compiler','vcsc-cc1');
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $testdir=File::Spec->catdir($repo,'test');

# ---------------------------------------------------------------- positive case
my $pos=File::Spec->catfile($testdir,'const_link_time_table_codegen_test.c26');
my $asm=File::Spec->catfile($tmp,'const_link_time_table.s26');
my ($rc,$sig,$out,$err)=capture($cc1,'-I',$testdir,$pos,'-o',$asm);
$rc==0 && !$sig
   or die "link-time derived table compile failed\n$out$err";
my $text=slurp($asm);
defined $text && length $text
   or die "link-time derived table compile produced no assembly\n$out$err";

# Where the compiler put each object: the segment that precedes its label.
my %where;
while ($text=~/^\.segment "(\w+)\.__vcsc_object\$(\w+)"\n(.*?)^(\w+):$/msg) {
   $where{$4}=$1;
}
scalar(keys %where) >= 7
   or die "expected every declared object in the assembly, found ".join(',',sort keys %where)."\n";

# A pure element read folds into ROM.
$where{reversed} && $where{reversed} eq 'RODATA'
   or die "a table derived by pure element reads is not RODATA: ".($where{reversed}//'absent')."\n";

# A read composed with constant arithmetic folds too, which is what makes the feed
# tables expressible as a transposition rather than as raw bytes.
$where{with_arithmetic} && $where{with_arithmetic} eq 'RODATA'
   or die "a table derived through constant arithmetic is not RODATA: ".($where{with_arithmetic}//'absent')."\n";

# Writable derived data must be DATA, not RODATA, because it is still writable and
# must be copied into RAM at startup.
$where{writable_derived} && $where{writable_derived} eq 'DATA'
   or die "writable derived data is not DATA: ".($where{writable_derived}//'absent')."\n";

# Derivations compose.
$where{second_generation} && $where{second_generation} eq 'RODATA'
   or die "a table derived from a derived table is not RODATA: ".($where{second_generation}//'absent')."\n";

# Wider element types are deliberately not recorded, so this keeps its runtime-read
# behaviour.  Pinning it means the byte-granular limit cannot be mistaken for a bug
# or widened by accident.
$where{from_wide} && $where{from_wide} eq 'BSS'
   or die "a read of a wider-element table no longer stays a runtime read: ".($where{from_wide}//'absent')."\n";

# Page-contained derived data, the shape the feed tables need for their fixed-cost
# absolute,Y reads.  The containment constraint has to survive the derivation.
$where{paged_derived} && $where{paged_derived} eq 'RODATA'
   or die "page-contained derived data is not RODATA: ".($where{paged_derived}//'absent')."\n";
my ($paged_block)=$text=~/\.segment "RODATA\.__vcsc_object\$paged_derived"\n(.*?)^paged_derived:$/ms;
$paged_block && $paged_block=~/^\.pagecontain$/m
   or die "page-contained derived data lost its page containment\n";
$paged_block && $paged_block=~/^\.indexrange 0, 2$/m
   or die "page-contained derived data lost its index range\n";

# The derived bytes must be the SOURCE's bytes.  Placement alone would not notice a
# fold that produced the wrong transposition.
my @record=(0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88);
sub expect_bytes {
   my ($name,$want)=@_;
   my ($body)=$text=~/\.segment "\w+\.__vcsc_object\$$name"\n(.*?)^\Q$name\E:\n\t\.byte ([^\n]*)$/ms;
   defined $body
      or die "object '$name' has no link-time byte initializer\n";
   my @got=map { my $t=$_; $t=~s/[^0-9A-Fa-f]//g; hex($t) } split(/,/, $2);
   join(',',@got) eq join(',',@$want)
      or die "object '$name' holds ".join(',',@got)." expected ".join(',',@$want)."\n";
}
expect_bytes('record',\@record);
expect_bytes('reversed',[reverse @record]);
expect_bytes('with_arithmetic',[$record[2]+1, 2*$record[4], $record[0]+$record[1], $record[6]]);
expect_bytes('second_generation',[$record[7], $record[0]]);
expect_bytes('paged_derived',[$record[4],$record[5],$record[6]]);
expect_bytes('writable_derived',[$record[1],$record[3],$record[5]]);

# A derived table must not cost a runtime initializer.  The whole point of the fold
# is that the table becomes plain link-time data instead of RAM plus startup code,
# so a fold that emitted a copy loop as well would defeat it.
$text !~ /\b(?:__init_table|__vcsc_global_init)\b.*(?:reversed|with_arithmetic|second_generation)/
   or die "a folded derived table still schedules a runtime initializer\n";

# ----------------------------------------------------------------- negative case
# An out-of-range element read must be refused, not folded to an adjacent byte: a
# constant expression has no runtime bounds check left to defer to.
my $neg=File::Spec->catfile($testdir,'const_link_time_table_fold_test.c26');
($rc,$sig,$out,$err)=capture($cc1,'-I',$testdir,$neg,'-o',File::Spec->catfile($tmp,'const_fold_neg.s26'));
$rc!=0
   or die "an out-of-range constant table read was accepted\n$out$err";
($out.$err) =~ /constant read index 8 must be less than the size of link-time table 'source_table' \(8\)/
   or die "out-of-range constant table read lost its diagnostic\n$out$err";

# ------------------------------------------- the fold inside an instantiated template
#
# This is the only place the stripe renderer declares its feed tables, so a fold that
# worked only in a flat translation unit would be useless.  Checked through a real
# link, because the placement contract that matters (page containment, no RAM) is the
# linker's to enforce, and the bytes are read back from the cartridge.
# The checked-in fixture, not a generated one, so the case the suite compiles is the
# case this asserts on.  It uses machine_6502.c26 and its own template rather than
# the VCS driver profile, so it builds standalone.
my $tpl=File::Spec->catfile($testdir,'const_link_time_table_template_codegen_test.c26');
my $tasm=File::Spec->catfile($tmp,'const_link_time_template.s26');
($rc,$sig,$out,$err)=capture($driver,'-S','-I',$testdir,'-o',$tasm,$tpl);
$rc==0 && !$sig
   or die "template link-time derived table build failed\n$out$err";
my $ttext=slurp($tasm);
defined $ttext && length $ttext
   or die "template build produced no assembly\n$out$err";

# The derived table must be link-time RODATA, page-contained, and carry the
# transposed record bytes.  Read from the compiler's own output: this fixture exists
# to prove the FOLD reaches into an instantiated template, and page containment is
# already asserted end-to-end through the linker in the feed-table test.
$ttext=~/^\.segment "RODATA\.__vcsc_object\$game_feed"\n(.*?)^game_feed:\n\t\.byte ([^\n]*)$/ms
   or die "a derived table inside an instantiated template is not link-time ROM data\n$ttext";
my @tfeed=map { my $t=$_; $t=~s/[^0-9A-Fa-f]//g; hex($t) } split(/,/,$2);
my @twant=reverse @record;
join(',',@tfeed) eq join(',',@twant)
   or die "the template's derived table holds ".join(',',@tfeed).", expected ".join(',',@twant)."\n";
$ttext=~/^\.segment "RODATA\.__vcsc_object\$game_feed"\n.*?^\.pagecontain$/ms
   or die "the template's derived table lost its page containment\n$ttext";
$ttext=~/^\.segment "RODATA\.__vcsc_object\$game_feed"\n.*?^\.indexrange 0, 7$/ms
   or die "the template's derived table lost its index range\n$ttext";

# The record itself must still be plain ROM data, so the fold had a real source.
$ttext=~/^\.segment "RODATA\.__vcsc_object\$game_record"\ngame_record:\n\t\.byte \$11, \$22, \$33, \$44, \$55, \$66, \$77, \$88$/m
   or die "the template's source record is not link-time ROM data\n$ttext";

# And the derived table must not also be a runtime-initialised RAM object.
$ttext !~ /^\.segment "BSS\.__vcsc_object\$game_feed"$/m
   or die "the template's derived table also allocated a RAM object\n$ttext";

# Declaration order decides whether a read folds, and that has to stay a documented
# property rather than an accident.  A derived table declared BEFORE its source
# cannot fold, because the source's bytes are not known yet; it stays a runtime read,
# which is correct and merely not optimised.  Asserted in both directions so a future
# change cannot quietly make the fold order-dependent in a way the renderer relies on.
my $fwd=File::Spec->catfile($tmp,'const_fold_order.c26');
open(my $fh,'>',$fwd) or die "write $fwd: $!\n";
print {$fh} <<'C26';
include "machine_6502.c26"
const uint8_t early[4] := { late_source[0], late_source[1], late_source[2], late_source[3] };
const uint8_t late_source[4] := { 9,8,7,6 };
void main(void) { }
C26
close($fh);
($rc,$sig,$out,$err)=capture($cc1,'-I',$testdir,$fwd,'-o',File::Spec->catfile($tmp,'const_fold_order.s26'));
$rc==0
   or die "a forward-referencing derived table stopped compiling\n$out$err";
my $fwdtext=slurp(File::Spec->catfile($tmp,'const_fold_order.s26'));
defined $fwdtext
   or die "the forward-reference build produced no assembly\n";
$fwdtext=~/^\.segment "BSS\.__vcsc_object\$early"$/m
   or die "a table derived from a LATER declaration became link-time data\n";
$fwdtext=~/^\.segment "RODATA\.__vcsc_object\$late_source"$/m
   or die "the forward-referencing source table is no longer link-time data\n";

my $rev=File::Spec->catfile($tmp,'const_fold_order_rev.c26');
open(my $fh2,'>',$rev) or die "write $rev: $!\n";
print {$fh2} <<'C26';
include "machine_6502.c26"
const uint8_t early_source[4] := { 9,8,7,6 };
const uint8_t late[4] := { early_source[0], early_source[1], early_source[2], early_source[3] };
void main(void) { }
C26
close($fh2);
($rc,$sig,$out,$err)=capture($cc1,'-I',$testdir,$rev,'-o',File::Spec->catfile($tmp,'const_fold_order_rev.s26'));
$rc==0
   or die "a derived table following its source stopped compiling\n$out$err";
my $revtext=slurp(File::Spec->catfile($tmp,'const_fold_order_rev.s26'));
defined $revtext && $revtext=~/^\.segment "RODATA\.__vcsc_object\$late"$/m
   or die "a table derived from an EARLIER declaration did not fold into link-time data\n";

# A `const` object in a NAMED memory region must NOT be folded.  There the byte's
# addressability is the contract, not just its value: a data-only bank has no 6507
# address, and the whole point of the linker's diagnostic is that reading such an
# object from the CPU is rejected.  A fold would erase the reference and turn an
# illegal program into a legal one, so this is a correctness boundary and not a
# limitation.  It was found by test/vcs_dpc.pl failing, not by inspection.
my $region=File::Spec->catfile($tmp,'const_fold_region.c26');
open(my $fh4,'>',$region) or die "write $region: $!\n";
print {$fh4} <<'C26';
include "machine_6502.c26"
mem tbl { $start:0xD000 $size:0x1000 $ro };
tbl const uint8_t region_table[4] := { 1,2,3,4 };
const uint8_t from_region[2] := { region_table[3], region_table[0] };
void main(void) { }
C26
close($fh4);
($rc,$sig,$out,$err)=capture($cc1,'-I',$testdir,$region,'-o',File::Spec->catfile($tmp,'const_fold_region.s26'));
$rc==0
   or die "a table derived from a named-region source stopped compiling\n$out$err";
my $regtext=slurp(File::Spec->catfile($tmp,'const_fold_region.s26'));
defined $regtext
   or die "the named-region build produced no assembly\n";
# A named-region source must not be recorded, so the derived table must NOT have
# gained a link-time initializer.  This is the shape that made the DPC diagnostic
# disappear: there the read of the data-only object is a relocation, and folding it
# would remove the relocation the linker exists to reject.
$regtext=~/^\.segment "BSS\.__vcsc_object\$from_region"$/m
   or die "a table derived from a named-region source folded into link-time data\n$regtext";

# The in-range neighbour must still be accepted, so the bound cannot be satisfied by
# refusing every read.
my $ok=File::Spec->catfile($tmp,'const_fold_inrange.c26');
open(my $fh3,'>',$ok) or die "write $ok: $!\n";
print {$fh3} <<'C26';
include "machine_6502.c26"
const uint8_t source_table[8] := { 1,2,3,4,5,6,7,8 };
const uint8_t last_byte[1] := { source_table[7] };
void main(void) { }
C26
close($fh3);
($rc,$sig,$out,$err)=capture($cc1,'-I',$testdir,$ok,'-o',File::Spec->catfile($tmp,'const_fold_inrange.s26'));
$rc==0
   or die "an in-range constant table read was rejected\n$out$err";
my $oktext=slurp(File::Spec->catfile($tmp,'const_fold_inrange.s26'));
defined $oktext && $oktext=~/^\.segment "RODATA\.__vcsc_object\$last_byte"$/m
   or die "the last in-range byte did not fold into link-time ROM\n";

print "vcs_const_link_time_table ok\n";
