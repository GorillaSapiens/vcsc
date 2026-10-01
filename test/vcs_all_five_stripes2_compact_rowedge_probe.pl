#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes2_compact_rowedge_probe ok
# expectexit: 0
use strict; use warnings; use Cwd qw(abs_path); use File::Spec; use IPC::Open3; use Symbol qw(gensym);
sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture { my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in); my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0); return ($?>>8,$?&127,$so,$se); }
sub without_usage { my($out)=@_; $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $out; }
sub read_file { my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return defined($d)?$d:''; }
sub map_addr { my($map,$name)=@_; $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\s/m or die "map lost symbol $name\n"; return hex($1); }
sub addr { sprintf('0x%04x',$_[0]&0xffff) }

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo); $tmp=abs_path($tmp);
my $driver=$ENV{VCSC_DRIVER} || File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $source=File::Spec->catfile($repo,qw(test fixtures all_five_stripes2_192 refill_exact_cache.c26));
my $ref=File::Spec->catfile($tmp,'compact_rowedge_ref.bin');
my $bin=File::Spec->catfile($tmp,'compact_rowedge.bin');
my $mapfile=File::Spec->catfile($tmp,'compact_rowedge.map');
my($rc,$sig,$o,$er)=capture($driver,'-I',$vcs,'-DVCS_STRIPES2_CERT_TAIL0',$source,'-o',$ref);
$rc==0&&!$sig or die "compact-rowedge reference build failed\n$o$er";
without_usage($o) eq ''&&$er eq '' or die "compact-rowedge reference build wrote output\n$o$er";
($rc,$sig,$o,$er)=capture($driver,'-I',$vcs,'-Map',$mapfile,'-DVCS_STRIPES2_CERT_TAIL0','-DVCS_STRIPES2_POST_BOUNDARY_EXACT_REFILL_PROBE','-DVCS_STRIPES2_COMPACT_ROWEDGE_PROBE',$source,'-o',$bin);
$rc==0&&!$sig or die "compact-rowedge probe build failed\n$o$er";
my $usage=$o; without_usage($o) eq ''&&$er eq '' or die "compact-rowedge probe build wrote output\n$o$er";
$usage =~ /^  ram\s+used=98 bytes .* free=30 bytes/m or die "compact-rowedge probe RAM footprint changed\n$usage";
$usage =~ /^  rom\s+used=(\d+) bytes/m && $1<=4096 or die "compact-rowedge probe no longer fits 4K\n$usage";
my $map=read_file($mapfile);
my $cache=map_addr($map,'game_stripe_cache');
my $next=map_addr($map,'game_stripe_next_color');
$map !~ /game_stripe_row_entry_cache/ or die "compact-rowedge probe introduced the old 20-byte row cache\n";
$map !~ /game_stripe_refill_grp[01]/ or die "compact-rowedge probe introduced a six-byte sprite cache\n";
$map !~ /game_stripe_refill_p0_cache/ or die "compact-rowedge probe retained temporary three-byte refill P0 cache\n";

my $cxx=$ENV{CXX}||'c++'; my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $old_mos=$ENV{VCSC_MOS6502_OBJECT};
my @mi=$old_mos && -f $old_mos ? ($old_mos) : (-f File::Spec->catfile($mos,'mos6502.o')?(File::Spec->catfile($mos,'mos6502.o')):(File::Spec->catfile($mos,'mos6502.cpp')));
my %h;
for my $e (['timing','vcs_frame_timing.cpp'],['phase','vcs_playfield_phase.cpp'],['objects','vcs_standard_objects.cpp']) {
   my($n,$ss)=@$e; my $x=File::Spec->catfile($tmp,"compact_rowedge_$n");
   ($rc,$sig,$o,$er)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,File::Spec->catfile($repo,'test',$ss),@mi,'-o',$x);
   $rc==0&&!$sig or die "$n build failed\n$o$er"; $o eq ''&&$er eq '' or die "$n build wrote output\n$o$er"; $h{$n}=$x;
}
my @expect_pf=(0xf0,0xff,0xff,0xf0,0xff,0xff);
my @timing_args=($h{timing},$bin,50,'--no-audio','--raw-lines',264);
for my $i (0..5) { push @timing_args,'--expect-memory',addr($cache+$i),sprintf('0x%02x',$expect_pf[$i]); }
push @timing_args,'--expect-memory',addr($next),'0x2e','--expect-memory',addr($next+1),'0x84';
($rc,$sig,$o,$er)=capture(@timing_args);
$rc==0&&!$sig or die "compact-rowedge timing/refill failed\n$o$er";
$o eq "vcs_frame_timing ok: 47 frames at 262 lines, 1 AUDV0 writes\n" or die "compact-rowedge timing output changed: $o";
$er eq '' or die "compact-rowedge timing stderr: $er";
($rc,$sig,$o,$er)=capture($h{phase},$bin,12,12,40,'all-five-stripes2-rowedge-tail0-192');
$rc==0&&!$sig or die "compact-rowedge phase failed\n$o$er";
$o eq "vcs_playfield_stripes2_rowedge_tail0_192 ok: row edges use one steady two-line cadence after the 96/96 handoff\n" or die "compact-rowedge phase output changed: $o";
my($rrc,$rsig,$ro,$re)=capture($h{objects},$ref,'--hblank','--player-values');
$rrc==0&&!$rsig or die "reference objects failed\n$ro$re";
($rc,$sig,$o,$er)=capture($h{objects},$bin,'--hblank','--player-values');
$rc==0&&!$sig or die "compact-rowedge objects failed\n$o$er";
$o eq $ro or die "compact-rowedge probe changed object sequence\nreference:\n$ro probe:\n$o";
$er eq '' or die "compact-rowedge objects stderr: $er";
print "vcs_all_five_stripes2_compact_rowedge_probe ok\n";
