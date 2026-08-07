#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: align language placement ok: page containment permits nonzero page offsets while align(256) fixes only the object start
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub capture { my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in); my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0); return ($?>>8,$?&127,$so,$se); }
sub read_file { my($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$fh>; close($fh); return $d // ''; }
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $src=File::Spec->catfile($tmp,'align_placement.c26');
my $map=File::Spec->catfile($tmp,'align_placement.map');
my $bin=File::Spec->catfile($tmp,'align_placement.bin');
open(my $fh,'>',$src) or die "write $src: $!\n";
print {$fh} <<'C26';
include "vcs.c26"
mem odd { $start:0xf010 $size:0x00f0 $ro };
odd page const uint8_t contained[16] := {0};
align(256) const uint8_t spanning[300] := {0};
align(16) uint8_t workspace[3];
uint8_t probe;
void main(void) {
   workspace[0] := contained[0];
   probe := workspace[0] ^ spanning[0];
   while (1) { }
}
C26
close($fh) or die "close $src: $!\n";
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$map,$src,'-o',$bin);
$rc==0 && !$sig or die "align placement build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "align placement build wrote output\n$out$err";
my $m=read_file($map);
$m =~ /^\s+RODATA\.odd\.__vcsc_object\$contained\s+load=\$F010\s+size=\$0010\s+page=hard/m
   or die "page-contained object did not retain legal nonzero page offset F010\n";
$m =~ /^\s+RODATA\.__vcsc_object\$spanning\s+load=\$([0-9A-Fa-f]{4})\s+size=\$012C\s+page=crossing.*component-align=\$0100/m
   or die "align(256) spanning object did not retain independent alignment metadata\n";
my $addr=hex($1);
($addr & 0xff)==0 or die sprintf("align(256) object starts at %04X\n",$addr);
(($addr & 0xff)+300)>256 or die "300-byte aligned object unexpectedly fits one page\n";
$m =~ /^\s+BSS\.__vcsc_object\$workspace\s+run=\$([0-9A-Fa-f]{4})\s+size=\$0003\s+page=\S+.*component-align=\$0010/m
   or die "align(16) writable object lost its runtime alignment contract\n";
(hex($1) & 0x0f)==0 or die "align(16) writable object is misaligned\n";
print "align language placement ok: page containment permits nonzero page offsets while align(256) fixes only the object start\n";
