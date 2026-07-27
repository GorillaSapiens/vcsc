#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
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
sub without_usage { my($s)=@_; $s =~ s/\ACARTRIDGE ROM USAGE\n(?:  [^\n]+\n)+RAM USAGE\n(?:  [^\n]+\n)+//; return $s; }

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
$tmp=abs_path($tmp) // die "resolve tmp\n";
my $oracle_dir=File::Spec->catdir($repo,qw(test oracles pristine_basic_v1.9_playercolors));
my $oracle_src=File::Spec->catfile($oracle_dir,'faithful_legacy_playercolors.bas');
my $oracle_bin=File::Spec->catfile($oracle_dir,'faithful_legacy_playercolors.bin');
my $source=read_file($oracle_src);
my $rom=read_file($oracle_bin);
length($rom)==4096 or die "pristine upstream BASIC oracle is not exactly 4096 bytes\n";
sha256_hex($source) eq 'f8572691ca8e8ab301f369f865934f589634cfe35543c8d53baa623c69f82303'
   or die "pristine upstream BASIC source hash changed\n";
sha256_hex($rom) eq 'eaae118b4770b7d7e45a5f0ca958ef1c1c54e51d8bc992dba293c09d753fc364'
   or die "pristine upstream BASIC ROM hash changed\n";
$source =~ /^\s*const\s+playercolors\s*=\s*1\s*$/m
   or die "oracle source no longer selects playercolors\n";
$source =~ /^\s*const\s+player1colors\s*=\s*1\s*$/m
   or die "oracle source no longer selects player1colors\n";
$source !~ /^\s*set\s+renderer_options\s+playercolors\s*$/m
   or die "oracle source uses the upstream compiler's rejected setter combination\n";
for my $pair ([qw(missile0height player0color)], [qw(missile0y player0color)],
              [qw(missile1height player1color)], [qw(missile1y player1color)]) {
   my($assignment,$table)=@$pair;
   my $a=index($source," $assignment=0");
   my $t=index($source," $table:\n");
   $a >= 0 && $t >= 0 && $a < $t
      or die "$assignment must be initialized before $table installs its aliased pointer\n";
}

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $profile=File::Spec->catdir($vcs,qw(renderers faithful_legacy_playercolors));
my $cfg=File::Spec->catfile($profile,'faithful_legacy_playercolors.cfg');
my $reference_asm=File::Spec->catfile($profile,'faithful_legacy_playercolors_reference.s26');
my $reference_src=File::Spec->catfile($repo,qw(test fixtures faithful_legacy_playercolors reference_static.c26));
my $reference_bin=File::Spec->catfile($tmp,'retained_audit_reference.bin');
my $reference_map=File::Spec->catfile($tmp,'retained_audit_reference.map');
my($rc,$sig,$out,$err)=capture(
   $driver,'-I',$vcs,'-I',$profile,'-Wa,--illegals','-T',$cfg,'-Map',$reference_map,
   $reference_src,$reference_asm,'-o',$reference_bin);
$rc==0 && !$sig or die "retained audit reference build failed\n$out$err";
without_usage($out) eq '' && $err eq ''
   or die "retained audit reference build wrote output\n$out$err";
length(read_file($reference_bin))==4096
   or die "retained audit reference is not exactly 4096 bytes\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $hsrc=File::Spec->catfile($repo,qw(test vcs_faithful_legacy_compare.cpp));
my $harness=File::Spec->catfile($tmp,'vcs_pristine_basic_compare');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$hsrc,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "oracle comparator build failed\n$out$err";
$out eq '' && $err eq '' or die "oracle comparator build wrote output\n$out$err";

($rc,$sig,$out,$err)=capture($harness,$oracle_bin,'264','--sprites');
$rc==0 && !$sig or die "pristine upstream BASIC sprite oracle failed\n$out$err";
$out eq "vcs_faithful_legacy_compare sprite oracle ok: 8 P0 rows, 8 P1 rows, exact row colors\n"
   or die "unexpected sprite-oracle output: $out";
$err eq '' or die "sprite-oracle stderr: $err";

# The repaired retained-source audit must now match the independent upstream
# cartridge positively.  The comparator checks every nonblank visible TIA write
# (ignoring only hardware-insensitive strobe bus values) and stable frame periods.
($rc,$sig,$out,$err)=capture($harness,$oracle_bin,$reference_bin,'264','264');
$rc==0 && !$sig or die "retained audit differs from pristine upstream BASIC oracle\n$out$err";
$out eq "vcs_faithful_legacy_compare ok: 1230 events and 42 stable frames per ROM\n"
   or die "unexpected positive-oracle output: $out";
$err eq '' or die "positive-oracle stderr: $err";

print "vcs_pristine_basic_oracle ok: stock upstream BASIC ROM locked; retained audit matches 1230 visible events and 264-line frames\n";
