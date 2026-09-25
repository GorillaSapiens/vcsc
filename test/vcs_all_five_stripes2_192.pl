#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes2_192 ok
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
sub without_usage {
   my($out)=@_; $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $out;
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
$tmp=abs_path($tmp) // die "resolve temporary directory\n";

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $source=File::Spec->catfile($repo,qw(test fixtures all_five_stripes2_192 smoke.c26));
my $bin=File::Spec->catfile($tmp,'all_five_stripes2_192.bin');
my $mapfile=File::Spec->catfile($tmp,'all_five_stripes2_192.map');
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$mapfile,$source,'-o',$bin);
$rc==0 && !$sig or die "stripe build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "stripe build wrote output\n$out$err";
-s $bin == 4096 or die "stripe cartridge is not exactly 4096 bytes\n";

my $map=read_file($mapfile);
$map =~ /^\s+BSS\.__vcsc_object\$game_stripe_cache\s+run=\$[0-9A-Fa-f]{4}\s+size=\$0006\b/m
   or die "stripe A/cache buffer is not six bytes\n";
$map =~ /^\s+BSS\.__vcsc_object\$game_stripe_buffer_b\s+run=\$[0-9A-Fa-f]{4}\s+size=\$0006\b/m
   or die "stripe B buffer is not six bytes\n";
$map =~ /^\s+BSS\.__vcsc_object\$game_stripe_next_color\s+run=\$[0-9A-Fa-f]{4}\s+size=\$0002\b/m
   or die "stripe next-color latch is not two bytes\n";
$map !~ /__vcsc_object\$game_playfield\b/
   or die "positive-stripe cartridge retained obsolete packed playfield ROM\n";
$map =~ /^\s+RODATA\.__vcsc_object\$game_playfield_colors\s+load=\$[0-9A-Fa-f]{4}\s+size=\$0004\b/m
   or die "stripe color payload is not four bytes\n";
$map =~ /^\s+RODATA\.__vcsc_object\$game_playfield_data\s+load=\$[0-9A-Fa-f]{4}\s+size=\$000C\b/m
   or die "stripe playfield payload is not twelve bytes\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my @checks=(
   ['timing','vcs_frame_timing.cpp',[50,'--no-audio','--raw-lines',264],
      "vcs_frame_timing ok: 47 frames at 262 lines, 1 AUDV0 writes\n"],
   ['phase','vcs_playfield_phase.cpp',[12,12,40,'all-five-stripes2-192'],
      "vcs_playfield_stripes2_192 ok: exact 96/96 data boundary with stable six-write phases\n"],
   ['objects','vcs_standard_objects.cpp',['--hblank'],
      "vcs_standard_objects ok: P0=7 P1=7 M0=6 M1=8 BL=4\n"],
);
for my $check (@checks) {
   my($name,$srcname,$args,$expect)=@$check;
   my $exe=File::Spec->catfile($tmp,"all_five_stripes_192_$name");
   my $src=File::Spec->catfile($repo,'test',$srcname);
   ($rc,$sig,$out,$err)=capture(
      $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$src,@mos_input,'-o',$exe);
   $rc==0 && !$sig or die "$name harness build failed\n$out$err";
   $out eq '' && $err eq '' or die "$name harness build wrote output\n$out$err";
   ($rc,$sig,$out,$err)=capture($exe,$bin,@$args);
   $rc==0 && !$sig or die "$name harness failed\n$out$err";
   $out eq $expect or die "unexpected $name output: $out";
   $err eq '' or die "$name harness stderr: $err";
}

print "vcs_all_five_stripes2_192 ok\n";
