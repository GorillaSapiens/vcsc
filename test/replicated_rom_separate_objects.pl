#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: replicated ROM contracts survive separate compilation
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub write_file { my ($p,$t)=@_; open(my $f,'>:raw',$p) or die "write $p: $!\n"; print {$f} $t; close($f); }
sub slurp { my ($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $t=<$f>//''; close($f); return $t; }
sub run_capture { my (@c)=@_; my $e=gensym; my $p=open3(my $i,my $o,$e,@c); close($i); local $/; my $out=<$o>//''; my $err=<$e>//''; waitpid($p,0); return ($?>>8,$?&127,$out,$err); }
sub require_ok { my ($n,@c)=@_; my ($x,$s,$o,$e)=run_capture(@c); $x==0&&!$s or die "$n failed\n@c\n$o$e"; return ($o,$e); }
sub map_symbol { my ($m,$n)=@_; $m =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$n\E\s+/m or die "missing $n\n"; return hex($1); }
sub parse_dump { my ($t)=@_; my @m=(0)x65536; for(split/\n/,$t){ next unless /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/; my($c,$a,$b)=(hex($1),hex($2),$3); for my $i(0..$c-1){$m[$a+$i]=hex(substr($b,$i*2,2));}} return \@m; }

my $repo=abs_path(shift @ARGV//die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV//die "usage: $0 REPO TMP\n"; @ARGV and die "usage: $0 REPO TMP\n"; make_path($tmp); $tmp=abs_path($tmp);
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $profile=File::Spec->catfile($vcs,'F8SC/mapper.c26');
my $defs=File::Spec->catfile($tmp,'defs.c26');
my $caller=File::Spec->catfile($tmp,'caller.c26');
my $bin=File::Spec->catfile($tmp,'separate.bin');
my $map_path=File::Spec->catfile($tmp,'separate.map');

write_file($defs, <<'SRC');
include "F8SC/mapper.c26"
bank0 bank1 const uint8_t shared_table[2] := { 0x12, 0x34 };
bank1 bank0 cartram uint8_t shared_function(uint8_t index) {
   return shared_table[index];
}
SRC
write_file($caller, <<'SRC');
include "F8SC/mapper.c26"
extern bank1 bank0 const uint8_t shared_table[2];
bank0 cartram bank1 uint8_t shared_function(uint8_t index);
bank1 uint8_t bank1_caller(void) {
   return shared_function(1) + shared_table[0];
}
uint8_t result;
void simulator_done(void) { while (true) {} }
void main(void) {
   result := shared_function(0) + bank1_caller();
   simulator_done();
}
SRC
require_ok('link separately compiled replicas',$driver,'-I',$vcs,'-DVCS_NO_DEFAULT_ROM','-Map',$map_path,'-o',$bin,$profile,$caller,$defs);
my $map=slurp($map_path);
$map =~ /kind=function symbol=shared_function copies=2/ or die "missing function copies\n$map";
$map =~ /kind=object symbol=shared_table copies=2/ or die "missing object copies\n$map";
$map =~ /entries=1 jmp=0 jsr=1/ or die "external local replicas unexpectedly used trampolines\n$map";
$map !~ /JSR entry=.*__vcsc_function\$shared_function/ or die "external shared_function call did not bind locally\n$map";
my $done=map_symbol($map,'simulator_done');
my $result=map_symbol($map,'result');
for my $bank(0,1){ my($dump,$err)=require_ok("simulate separate image bank $bank",$sim,'--map',$map_path,"--start-bank=$bank",sprintf('--stop-pc=0x%04X',$done),'--dump-on-stop',$bin); $err eq '' or die $err; my $m=parse_dump($dump); $m->[$result]==0x58 or die sprintf("bank %d result %02X expected 58\n",$bank,$m->[$result]); }
print "replicated ROM contracts survive separate compilation\n";
