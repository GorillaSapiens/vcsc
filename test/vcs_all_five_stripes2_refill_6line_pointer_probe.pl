#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes2_refill_6line_pointer_probe ok
# expectexit: 0
use strict; use warnings; use Cwd qw(abs_path); use File::Spec; use IPC::Open3; use Symbol qw(gensym);
sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture { my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in); my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0); return ($?>>8,$?&127,$so,$se); }
sub without_usage { my($out)=@_; $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $out; }
my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV; $repo=abs_path($repo); $tmp=abs_path($tmp);
my $driver=$ENV{VCSC_DRIVER} || File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $source=File::Spec->catfile($repo,qw(test fixtures all_five_stripes2_192 refill_pointer_mixed.c26));
my $ref=File::Spec->catfile($tmp,'refill6_pointer_ref.bin');
my $bin=File::Spec->catfile($tmp,'refill6_pointer.bin');
my $mapfile=File::Spec->catfile($tmp,'refill6_pointer.map');
my($rc,$sig,$o,$er)=capture($driver,'-I',$vcs,'-DVCS_STRIPES2_CERT_TAIL7',$source,'-o',$ref);
$rc==0&&!$sig or die "pointer reference build failed\n$o$er"; without_usage($o) eq ''&&$er eq '' or die "pointer reference build wrote output\n$o$er";
($rc,$sig,$o,$er)=capture($driver,'-I',$vcs,'-Map',$mapfile,'-DVCS_STRIPES2_CERT_TAIL7','-DVCS_STRIPES2_REFILL_6LINE_POINTER_PROBE',$source,'-o',$bin);
$rc==0&&!$sig or die "pointer refill build failed\n$o$er"; without_usage($o) eq ''&&$er eq '' or die "pointer refill build wrote output\n$o$er";
my $map=do { open(my $f,'<:raw',$mapfile) or die "read $mapfile: $!\n"; local $/; <$f> // '' };
$map !~ /game_stripe_refill_grp1/ or die "pointer refill introduced a sprite cache\n";
$map =~ /^  ram\s+used=98 bytes .* free=30 bytes/m or die "pointer refill RAM footprint changed\n";
my $cxx=$ENV{CXX}||'c++'; my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $old_mos=$ENV{VCSC_MOS6502_OBJECT};
my @mi=$old_mos && -f $old_mos ? ($old_mos) : (-f File::Spec->catfile($mos,'mos6502.o')?(File::Spec->catfile($mos,'mos6502.o')):(File::Spec->catfile($mos,'mos6502.cpp')));
my %h; for my $e (['timing','vcs_frame_timing.cpp'],['phase','vcs_playfield_phase.cpp'],['objects','vcs_standard_objects.cpp']) { my($n,$ss)=@$e; my $x=File::Spec->catfile($tmp,"refill6_pointer_$n"); ($rc,$sig,$o,$er)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,File::Spec->catfile($repo,'test',$ss),@mi,'-o',$x); $rc==0&&!$sig or die "$n build failed\n$o$er"; $h{$n}=$x; }
($rc,$sig,$o,$er)=capture($h{timing},$bin,50,'--no-audio','--raw-lines',264); $rc==0&&!$sig or die "timing failed\n$o$er"; $o eq "vcs_frame_timing ok: 47 frames at 262 lines, 1 AUDV0 writes\n" or die "timing output: $o";
($rc,$sig,$o,$er)=capture($h{phase},$bin,12,12,40,'all-five-stripes2-refill6-pointer-tail7-192'); $rc==0&&!$sig or die "phase failed\n$o$er"; $o eq "vcs_playfield_stripes2_refill6_pointer_tail7_192 ok: exact-P1-pointer/live-P0 six-line refill with stable service phases\n" or die "phase output: $o";
my($rrc,$rsig,$ro,$re)=capture($h{objects},$ref,'--hblank','--player-values'); $rrc==0&&!$rsig or die "reference objects failed\n$ro$re";
($rc,$sig,$o,$er)=capture($h{objects},$bin,'--hblank','--player-values'); $rc==0&&!$sig or die "pointer objects failed\n$o$er";
$o eq $ro or die "pointer player-value sequence differs from fixed-tail reference\nreference:\n$ro pointer:\n$o";
$o =~ /^vcs_standard_objects ok: P0=4 P1=4 M0=6 M1=8 BL=4\n/m or die "pointer transition object output changed: $o";
print "vcs_all_five_stripes2_refill_6line_pointer_probe ok\n";
