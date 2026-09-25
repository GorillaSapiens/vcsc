#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes2_schedule_variants ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub read_file {
   my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n";
   local $/; my $d=<$f>; close($f); return defined($d)?$d:'';
}
sub without_usage { my($out)=@_; $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $out; }

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
$tmp=abs_path($tmp) // die "resolve temporary directory\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $source=File::Spec->catfile($repo,qw(test fixtures all_five_stripes2_192 smoke.c26));

for my $case (
   ['tail1',[],[49,47],[6,1,5,7]],
   ['tail2',['-DVCS_STRIPES2_CERT_TAIL2'],[50,46],[6,2,5,6]],
) {
   my($name,$defs,$heights,$schedule)=@$case;
   my $bin=File::Spec->catfile($tmp,"all_five_stripes2_${name}.bin");
   my $mapfile=File::Spec->catfile($tmp,"all_five_stripes2_${name}.map");
   my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,@$defs,'-Map',$mapfile,$source,'-o',$bin);
   $rc==0 && !$sig or die "$name build failed\n$out$err";
   without_usage($out) eq '' && $err eq '' or die "$name build wrote output\n$out$err";
   -s $bin == 4096 or die "$name cartridge is not exactly 4096 bytes\n";
   my $map=read_file($mapfile);
   $map =~ /^\s+RODATA\.__vcsc_object\$game_stripe_pair_heights\s+load=\$([0-9A-Fa-f]{4})\s+size=\$0002\b/m
      or die "$name pair-height table missing\n";
   my $height_addr=hex($1);
   $map =~ /^\s+RODATA\.__vcsc_object\$game_stripe_schedule\s+load=\$([0-9A-Fa-f]{4})\s+size=\$0004\b/m
      or die "$name schedule table missing\n";
   my $schedule_addr=hex($1);
   my $rom=read_file($bin);
   substr($rom,$height_addr-0xf000,2) eq pack('C*',@$heights)
      or die "$name pair-height bytes changed\n";
   substr($rom,$schedule_addr-0xf000,4) eq pack('C*',@$schedule)
      or die "$name coarse/tail bytes changed\n";
}
print "vcs_all_five_stripes2_schedule_variants ok\n";
