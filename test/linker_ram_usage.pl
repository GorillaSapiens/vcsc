#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
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

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve tmp\n";
my $source=File::Spec->catfile($tmp,'ram_usage.c26');
my $bin=File::Spec->catfile($tmp,'ram_usage.bin');
my $mapfile=File::Spec->catfile($tmp,'ram_usage.map');
open(my $fh,'>:raw',$source) or die "write $source: $!\n";
print {$fh} <<'SRC';
include "vcs.c26"
uint8_t payload[5];
void leaf(void) { payload[0] := 1; }
void middle(void) { leaf(); }
void main(void) { middle(); while (1) { } }
SRC
close($fh) or die "close $source: $!\n";

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$mapfile,$source,'-o',$bin);
$rc==0 && !$sig or die "RAM-usage fixture failed\n$out$err";
$err eq '' or die "RAM-usage fixture wrote stderr:\n$err";
$out =~ /RAM USAGE\n  RAM\s+used=19 bytes \(14\.84%\) free=109 bytes \(85\.16%\) objects=13 bytes hardware-stack=6 bytes\n\z/
   or die "wrong terminal RAM usage report:\n$out";
my $map=read_file($mapfile);
$map =~ /RAM USAGE\n  RAM\s+used=19 bytes \(14\.84%\) free=109 bytes \(85\.16%\) objects=13 bytes hardware-stack=6 bytes/
   or die "map RAM usage section missing or wrong\n$map";
$map =~ /CALL STACK\n  region=RAM depth=3 bytes=\$0006 physical=\$00FA-\$00FF extra=\$0000/
   or die "map hardware-stack detail missing or wrong\n$map";
$map =~ /BSS\.__vcsc_object\$payload\s+run=\$[0-9A-Fa-f]{4}\s+size=\$0005/
   or die "payload storage missing from map\n$map";
print "linker reports occupied, free, and hardware-stack RAM bytes\n";
