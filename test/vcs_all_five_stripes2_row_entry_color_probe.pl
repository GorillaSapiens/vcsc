#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes2_row_entry_color_probe ok
# expectexit: 0
use strict; use warnings; use Cwd qw(abs_path); use File::Spec; use IPC::Open3; use Symbol qw(gensym);
sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture { my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in); my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0); return ($?>>8,$?&127,$so,$se); }
sub without_usage { my($out)=@_; $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $out; }
sub read_file { my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return defined($d)?$d:''; }
sub map_addr {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\s/m or die "map lost symbol $name\n";
   return hex($1);
}
sub addr { sprintf('0x%04x',$_[0]&0xffff) }

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo); $tmp=abs_path($tmp);
my $driver=$ENV{VCSC_DRIVER} || File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $source=File::Spec->catfile($repo,qw(test fixtures all_five_stripes2_192 refill_dual_pointer.c26));
my $ref=File::Spec->catfile($tmp,'row_entry_color_ref.bin');
my $bin=File::Spec->catfile($tmp,'row_entry_color.bin');
my $mapfile=File::Spec->catfile($tmp,'row_entry_color.map');
my($rc,$sig,$o,$er)=capture($driver,'-I',$vcs,$source,'-o',$ref);
$rc==0&&!$sig or die "row-entry reference build failed\n$o$er";
without_usage($o) eq ''&&$er eq '' or die "row-entry reference build wrote output\n$o$er";
($rc,$sig,$o,$er)=capture($driver,'-I',$vcs,'-Map',$mapfile,'-DVCS_STRIPES2_ROW_ENTRY_COLOR_PROBE',$source,'-o',$bin);
$rc==0&&!$sig or die "row-entry color probe build failed\n$o$er";
my $usage=$o; without_usage($o) eq ''&&$er eq '' or die "row-entry color probe build wrote output\n$o$er";
$usage =~ /^  ram\s+used=103 bytes .* free=25 bytes/m or die "row-entry color probe RAM footprint changed\n$usage";
$usage =~ /^  rom\s+used=(\d+) bytes/m && $1<=4096 or die "row-entry color probe no longer fits 4K\n$usage";
my $map=read_file($mapfile);
my $next=map_addr($map,'game_stripe_next_color');

my $cxx=$ENV{CXX}||'c++'; my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $old_mos=$ENV{VCSC_MOS6502_OBJECT};
my @mi=$old_mos && -f $old_mos ? ($old_mos) : (-f File::Spec->catfile($mos,'mos6502.o')?(File::Spec->catfile($mos,'mos6502.o')):(File::Spec->catfile($mos,'mos6502.cpp')));
my $timing=File::Spec->catfile($tmp,'row_entry_color_timing');
($rc,$sig,$o,$er)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp)),@mi,'-o',$timing);
$rc==0&&!$sig or die "timing harness build failed\n$o$er";
$o eq ''&&$er eq '' or die "timing harness build wrote output\n$o$er";
($rc,$sig,$o,$er)=capture($timing,$bin,50,'--no-audio','--raw-lines',264,
   '--expect-memory',addr($next),'0x4e','--expect-memory',addr($next+1),'0x24');
$rc==0&&!$sig or die "row-entry color timing failed\n$o$er";
$o eq "vcs_frame_timing ok: 47 frames at 262 lines, 1 AUDV0 writes\n" or die "row-entry color timing output changed: $o";
$er eq '' or die "row-entry color timing stderr: $er";

my $objects=File::Spec->catfile($tmp,'row_entry_color_objects');
($rc,$sig,$o,$er)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,File::Spec->catfile($repo,qw(test vcs_standard_objects.cpp)),@mi,'-o',$objects);
$rc==0&&!$sig or die "objects harness build failed\n$o$er";
$o eq ''&&$er eq '' or die "objects harness build wrote output\n$o$er";
my($rrc,$rsig,$ro,$re)=capture($objects,$ref,'--hblank','--player-values');
$rrc==0&&!$rsig or die "reference objects failed\n$ro$re";
($rc,$sig,$o,$er)=capture($objects,$bin,'--hblank','--player-values');
$rc==0&&!$sig or die "row-entry color objects failed\n$o$er";
$o eq $ro or die "row-entry service changed object sequence\nreference:\n$ro probe:\n$o";
$er eq '' or die "row-entry color objects stderr: $er";
print "vcs_all_five_stripes2_row_entry_color_probe ok\n";
