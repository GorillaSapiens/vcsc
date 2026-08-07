#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: scratch lifetime overlay ok: branches, loops, three sequential inline expansions, and nested inline expressions
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($?>>8,$?&127,$so,$se);
}
sub require_ok {
   my($label,@cmd)=@_; my($rc,$sig,$out,$err)=capture(@cmd);
   $rc==0 && !$sig or die "$label failed rc=$rc sig=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return($out,$err);
}
sub write_file {
   my($path,$text)=@_; open(my $fh,'>:raw',$path) or die "write $path: $!\n";
   print {$fh} $text; close($fh) or die "close $path: $!\n";
}
sub read_file {
   my($path)=@_; open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $text=<$fh> // ''; close($fh); return $text;
}
sub parse_symbol {
   my($text,$name)=@_; $text =~ /^\Q$name\E\s+([0-9A-Fa-f]{4})\s*$/m
      or die "symbol file missing $name\n"; return hex($1);
}
sub parse_dump {
   my($text)=@_; my @mem=(0)x65536;
   for my $line (split /\n/,$text) {
      next unless $line =~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
      my($count,$addr,$bytes)=(hex($1),hex($2),$3);
      length($bytes)==$count*2 or die "bad Intel HEX record\n";
      for my $i (0..$count-1) { $mem[$addr+$i]=hex(substr($bytes,$i*2,2)); }
   }
   return \@mem;
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
$tmp=File::Spec->rel2abs($tmp);
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve temporary directory\n";
my $cc1=File::Spec->catfile($repo,qw(compiler vcsc-cc1));
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $sim=File::Spec->catfile($repo,qw(simulator vcsc-sim));
my $inc=File::Spec->catdir($repo,'test');
my $cfg=File::Spec->catfile($repo,qw(test generic_6502.cfg));
my $src=File::Spec->catfile($tmp,'scratch_lifetime_overlay.c26');
my $asm=File::Spec->catfile($tmp,'scratch_lifetime_overlay.s26');
my $hex=File::Spec->catfile($tmp,'scratch_lifetime_overlay.hex');
my $sym=File::Spec->catfile($tmp,'scratch_lifetime_overlay.sym');

write_file($src,<<'SRC');
include "machine_6502.c26"
uint8_t status;
uint8_t flag;
uint16_t a;
uint16_t b;
uint16_t c;
uint16_t d;

inline void bump(void) {
   a += 2;
   if (a >= 30) { a := 0; }
   b := a + 1;
}

inline uint16_t inner(uint16_t x) {
   return x + 1;
}

inline void outer(void) {
   c := inner(a + b) + d;
}

void simulator_done(void) { while (1) {} }
void fail(uint8_t code) {
   status := code;
   asm jmp simulator_done;
}

void main(void) {
   b := 5;
   a := b + 1;
   flag := 1;
   if (flag) {
      c := b + 2;
   }
   else {
      c := b + 3;
   }
   while (flag) {
      d := b + 4;
      flag--;
   }
   bump();
   bump();
   bump();
   outer();
   if (a != 12) { fail(1); }
   if (b != 13) { fail(2); }
   if (c != 35) { fail(3); }
   if (d != 9) { fail(4); }
   if (flag != 0) { fail(5); }
   status := 0xaa;
   asm jmp simulator_done;
}
SRC

my($out,$diag)=require_ok('compile lifetime diagnostic',
   $cc1,'-quiet','-X','scratch','-I',$inc,$src,'-o',$asm);
$out eq '' or die "compiler diagnostic wrote stdout:\n$out";
my @rows;
for my $line (split /\n/,$diag) {
   next unless $line =~ /^SCRATCH\s+/;
   $line =~ /^SCRATCH scope=(\S+) owner=(\S+) slot=(\d+) symbol=(\S+) size=(\d+) group=(\S+) allocation=(\S+) reason=(\S+) acquisitions=(\d+)$/
      or die "malformed scratch diagnostic: $line\n";
   push @rows,{scope=>$1,owner=>$2,slot=>0+$3,symbol=>$4,size=>0+$5,
               group=>$6,allocation=>$7,reason=>$8,acquisitions=>0+$9};
}
@rows or die "compiler emitted no scratch diagnostics\n";
for my $row (@rows) {
   $row->{owner} eq 'main' or die "scratch escaped main activation: $row->{owner}\n";
   $row->{group} eq "main:$row->{slot}" or die "bad lifetime group $row->{group}\n";
   $row->{allocation} eq 'lifetime-overlay' or die "scratch is not lifetime overlaid\n";
   $row->{reason} eq 'nonoverlapping-compiler-temporary-lifetimes'
      or die "unexpected lifetime reason $row->{reason}\n";
}
my %symbols=map { $_->{symbol}=>1 } @rows;
join(',',sort keys %symbols) eq '__vcsc_scratch_0,__vcsc_scratch_1,__vcsc_scratch_2,__vcsc_scratch_3'
   or die "unexpected scratch symbols: ".join(',',sort keys %symbols)."\n";
my @bumps=grep { $_->{scope}=~/^__inline\$\d+\$bump$/ } @rows;
my %bump_scopes=map { $_->{scope}=>1 } @bumps;
keys(%bump_scopes)==3 or die "expected three sequential bump expansions\n";
for my $scope (keys %bump_scopes) {
   my %groups=map { $_->{group}=>1 } grep { $_->{scope} eq $scope } @bumps;
   $groups{'main:0'} && $groups{'main:1'} && keys(%groups)==2
      or die "$scope did not reuse the common two-slot footprint\n";
}
my @inner=grep { $_->{scope}=~/\$inner$/ } @rows;
@inner && !grep($_->{slot}<2,@inner)
   or die "nested inline expression aliased an outer live scratch level\n";
my $assembly=read_file($asm);
my @decls=($assembly =~ /^(__vcsc_scratch_\d+):\n\s*\.res\s+(\d+)/mg);
my @ids=($assembly =~ /^__vcsc_scratch_(\d+):/mg);
join(',',@ids) eq '0,1,2,3' or die "BSS scratch is not exactly four depth slots\n";
$assembly !~ /^__vcsc_scratch_4:/m or die "sequential control flow allocated a fifth slot\n";

require_ok('build lifetime runtime fixture',
   $driver,'-I',$inc,'-T',$cfg,'-Sym',$sym,$src,'-o',$hex);
my $symbols_text=read_file($sym);
my $done=parse_symbol($symbols_text,'simulator_done');
my $status=parse_symbol($symbols_text,'status');
my($dump,$simerr)=require_ok('simulate lifetime runtime fixture',
   $sim,'-T',$cfg,sprintf('--stop-pc=0x%04X',$done),'--dump-on-stop',$hex);
$simerr eq '' or die "simulator wrote stderr:\n$simerr";
my $mem=parse_dump($dump);
$mem->[$status]==0xaa
   or die sprintf("lifetime runtime status is %02X, expected AA\n",$mem->[$status]);

print "scratch lifetime overlay ok: branches, loops, three sequential inline expansions, and nested inline expressions\n";
