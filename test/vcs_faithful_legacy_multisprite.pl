#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# timeout: 30
# expectstdout: vcs_faithful_legacy_multisprite ok: 1471 ROM, exact 122+6 RAM, 264-line frame, five multiplexed P1 sprites plus P0
# expectexit: 0
# Faithful fixed diagnostic and source-integration contract for the retained
# unbanked/non-Superchip multisprite renderer.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol qw(gensym);

sub slurp {
   my($path)=@_;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/;
   my $text=<$fh>//'';
   close($fh);
   return $text;
}
sub slurp_fh { my($fh)=@_; local $/; return <$fh>//''; }
sub capture {
   my(@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in);
   my $stdout=slurp_fh($out);
   my $stderr=slurp_fh($err);
   waitpid($pid,0);
   return($?>>8,$?&127,$stdout,$stderr);
}
sub run_ok {
   my($label,@cmd)=@_;
   my($rc,$sig,$out,$err)=capture(@cmd);
   $rc==0 && !$sig or die "$label failed rc=$rc sig=$sig\n@cmd\n$out$err";
   return($out,$err);
}
sub require_re {
   my($text,$re,$message)=@_;
   $text =~ $re or die "$message\n";
}

@ARGV==1 or die "usage: $0 REPO\n";
my $repo=abs_path($ARGV[0]) or die "resolve repo\n";
my $tmp=tempdir(CLEANUP=>1);
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $profile=File::Spec->catdir($vcs,qw(renderers faithful_legacy_multisprite));
my $source=File::Spec->catfile($repo,qw(examples 10_faithful_legacy_multisprite 01_diagnostic faithful_legacy_multisprite_diagnostic.c26));
my $fixture=File::Spec->catfile($repo,qw(examples 10_faithful_legacy_multisprite 01_diagnostic faithful_legacy_multisprite_diagnostic_data.s26));
my $renderer=File::Spec->catfile($profile,'faithful_legacy_multisprite_renderer.s26');
my $startup=File::Spec->catfile($profile,'faithful_legacy_multisprite_startup.s26');
my $cfg=File::Spec->catfile($profile,'faithful_legacy_multisprite.cfg');
my $normalizer=File::Spec->catfile($profile,'normalize.pl');
my $contract=File::Spec->catfile($profile,'faithful_legacy_multisprite.c26');
my $bin=File::Spec->catfile($tmp,'faithful_legacy_multisprite_diagnostic.bin');
my $map=File::Spec->catfile($tmp,'faithful_legacy_multisprite_diagnostic.map');

for my $path($driver,$source,$fixture,$renderer,$startup,$cfg,$normalizer,$contract) {
   -f $path or die "missing faithful multisprite input $path\n";
}

my($out,$err)=run_ok('faithful multisprite normalization',$^X,$normalizer,'--check');
$out eq "faithful_legacy_multisprite normalize ok\n"
   or die "unexpected normalizer output: $out";
$err eq '' or die "faithful multisprite normalizer stderr: $err";

my $generated=slurp($renderer);
require_re($generated,qr/^\.callstackextra\s+2\s*$/m,
   'faithful multisprite renderer lost its exact hidden-stack reconciliation');
require_re($generated,qr/^vcs_multisprite_setup:/m,
   'faithful multisprite setup entry missing');
require_re($generated,qr/^vcs_multisprite_drawscreen:/m,
   'faithful multisprite drawscreen entry missing');
require_re($generated,qr/\blax\b/i,
   'faithful multisprite renderer no longer retains its selected unofficial opcode path');
require_re($generated,qr/\btxs\b.*?\bphp\b.*?\bphp\b.*?\bphp\b/s,
   'faithful multisprite renderer lost the retained stack-pointer/PHP object-enable path');
$generated !~ /^\s*(?:ifconst|ifnconst|if|else|endif)\b/im
   or die "faithful multisprite generated renderer still contains retained conditionals\n";

my $state=slurp($contract);
require_re($state,qr/VCS_MULTISPRITE_RAM_BYTES\s*:=\s*122/,
   'faithful multisprite state contract no longer declares 122 retained bytes');
require_re($state,qr/uint8_t\s+score\[3\]/,
   'faithful multisprite score must remain three display-order raw BCD bytes');

my $startup_text=slurp($startup);
require_re($startup_text,qr/\bjmp\s+main\b/i,
   'faithful multisprite startup must tail-enter main');
$startup_text !~ /\bjsr\s+main\b/i
   or die "faithful multisprite startup reintroduced a physical main return pair\n";
require_re($startup_text,qr/lda\s+#0.*?ldx\s+#\$7f.*?sta\s+\$80,x/s,
   'faithful multisprite startup no longer clears the full RIOT RAM window directly');

($out,$err)=run_ok('faithful multisprite diagnostic build',
   $driver,'-nostdlib','-I',$vcs,'-Wa,--illegals','-T',$cfg,'-Map',$map,
   $source,$fixture,$renderer,$startup,'-o',$bin);
$err eq '' or die "faithful multisprite build stderr: $err";
require_re($out,qr/ROM\s+used=1471 bytes .* free=2619 bytes/s,
   'faithful multisprite fixed diagnostic ROM cost changed from 1471 bytes');
require_re($out,qr/ram\s+used=128 bytes .* objects=122 bytes hardware-stack=6 bytes/s,
   'faithful multisprite fixed diagnostic RAM accounting changed');
length(slurp($bin))==4096 or die "faithful multisprite diagnostic is not a 4096-byte ROM\n";

my $map_text=slurp($map);
require_re($map_text,qr/BSS\.__vcsc_object\$vcs_multisprite_state\s+run=\$0080\s+size=\$007A/,
   'faithful multisprite state no longer occupies exact $80-$F9');
require_re($map_text,qr/TOTAL source-bytes=\$0004 hidden-bytes=\$0002 total-bytes=\$0006/,
   'faithful multisprite six-byte hardware-stack proof changed');
require_re($map_text,qr/\$0006\s+__call_stack_size\b/,
   'faithful multisprite linker no longer reports six hardware-stack bytes');
require_re($map_text,qr/\$00FA\s+__call_stack_start\b/,
   'faithful multisprite hardware stack no longer starts at $FA');
require_re($map_text,qr/\$00FF\s+__call_stack_top\b/,
   'faithful multisprite hardware stack no longer tops at $FF');
$map_text !~ /BSS\.__vcsc_activation\$/
   or die "faithful multisprite fixed diagnostic unexpectedly allocates compiler activation RAM\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my $hsrc=File::Spec->catfile($repo,qw(test vcs_faithful_legacy_compare.cpp));
my $harness=File::Spec->catfile($tmp,'faithful_multisprite_oracle');
($out,$err)=run_ok('faithful multisprite oracle build',
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$hsrc,@mos_input,'-o',$harness);
$out eq '' && $err eq '' or die "faithful multisprite oracle compiler wrote output\n$out$err";
($out,$err)=run_ok('faithful multisprite timing/raster oracle',
   $harness,$bin,'264','--multisprite');
$out eq "vcs_faithful_legacy_compare multisprite oracle ok: 390 visible events, 264-line frames, six exact players\n"
   or die "unexpected faithful multisprite oracle output: $out";
$err eq '' or die "faithful multisprite oracle stderr: $err";

print "vcs_faithful_legacy_multisprite ok: 1471 ROM, exact 122+6 RAM, 264-line frame, five multiplexed P1 sprites plus P0\n";
