#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes2_refill_6line_exact_cache_probe ok
# expectexit: 0
use strict; use warnings; use Cwd qw(abs_path); use File::Spec; use IPC::Open3; use Symbol qw(gensym);
sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture { my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in); my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0); return ($?>>8,$?&127,$so,$se); }
sub without_usage { my($out)=@_; $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $out; }
my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV; $repo=abs_path($repo); $tmp=abs_path($tmp);
my $driver=$ENV{VCSC_DRIVER} || File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $source=File::Spec->catfile($repo,qw(test fixtures all_five_stripes2_192 refill_exact_cache.c26));
my $ref=File::Spec->catfile($tmp,'refill6_exact_cache_ref.bin');
my $bin=File::Spec->catfile($tmp,'refill6_exact_cache.bin');
my $mapfile=File::Spec->catfile($tmp,'refill6_exact_cache.map');
my($rc,$sig,$o,$er)=capture($driver,'-I',$vcs,'-DVCS_STRIPES2_CERT_TAIL7',$source,'-o',$ref);
$rc==0&&!$sig or die "exact-cache reference build failed\n$o$er"; without_usage($o) eq ''&&$er eq '' or die "exact-cache reference build wrote output\n$o$er";
($rc,$sig,$o,$er)=capture($driver,'-I',$vcs,'-Map',$mapfile,'-DVCS_STRIPES2_CERT_TAIL7','-DVCS_STRIPES2_REFILL_6LINE_EXACT_CACHE_PROBE',$source,'-o',$bin);
$rc==0&&!$sig or die "exact-cache refill build failed\n$o$er"; without_usage($o) eq ''&&$er eq '' or die "exact-cache refill build wrote output\n$o$er";
my $map=do { open(my $f,'<:raw',$mapfile) or die "read $mapfile: $!\n"; local $/; <$f> // '' };
# Fixture service pairs 49..51 cross inactive->active for both players:
# original P1 57 gives q=8,7,6 and original P0 58 gives q=8,7,6, while
# both prepared heights are 8.  This prevents an all-zero/all-active false proof.
$map !~ /game_stripe_refill_grp1/ or die "exact-cache refill introduced a sprite cache\n";
$map =~ /^  ram\s+used=98 bytes .* free=30 bytes/m or die "exact-cache refill RAM footprint changed\n";
my $cxx=$ENV{CXX}||'c++'; my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $old_mos=$ENV{VCSC_MOS6502_OBJECT};
my @mi=$old_mos && -f $old_mos ? ($old_mos) : (-f File::Spec->catfile($mos,'mos6502.o')?(File::Spec->catfile($mos,'mos6502.o')):(File::Spec->catfile($mos,'mos6502.cpp')));
my %h; for my $e (['timing','vcs_frame_timing.cpp'],['phase','vcs_playfield_phase.cpp'],['objects','vcs_standard_objects.cpp']) { my($n,$ss)=@$e; my $x=File::Spec->catfile($tmp,"refill6_exact_cache_$n"); ($rc,$sig,$o,$er)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,File::Spec->catfile($repo,'test',$ss),@mi,'-o',$x); $rc==0&&!$sig or die "$n build failed\n$o$er"; $h{$n}=$x; }
($rc,$sig,$o,$er)=capture($h{timing},$bin,50,'--no-audio','--raw-lines',264); $rc==0&&!$sig or die "timing failed\n$o$er"; $o eq "vcs_frame_timing ok: 47 frames at 262 lines, 1 AUDV0 writes\n" or die "timing output: $o";
# The exact-cache body is deliberately phase-identical to the dual-pointer body, so
# reuse that phase contract rather than adding a duplicate expected-phase set.
($rc,$sig,$o,$er)=capture($h{phase},$bin,12,12,40,'all-five-stripes2-refill6-dual-pointer-tail7-192'); $rc==0&&!$sig or die "phase failed\n$o$er";
$o eq "vcs_playfield_stripes2_refill6_dual_pointer_tail7_192 ok: dual-uniform-pointer six-line PF+color refill with stable service phases\n" or die "phase output: $o";
my($rrc,$rsig,$ro,$re)=capture($h{objects},$ref,'--hblank','--player-values'); $rrc==0&&!$rsig or die "reference objects failed\n$ro$re";
($rc,$sig,$o,$er)=capture($h{objects},$bin,'--hblank','--player-values'); $rc==0&&!$sig or die "exact-cache objects failed\n$o$er";
$o eq $ro or die "exact-cache player-value sequence differs from fixed-tail reference\nreference:\n$ro exact-cache:\n$o";
$o =~ /^vcs_standard_objects ok: P0=7 P1=7 M0=6 M1=8 BL=4\n/m or die "exact-cache transition object output changed: $o";
print "vcs_all_five_stripes2_refill_6line_exact_cache_probe ok\n";
