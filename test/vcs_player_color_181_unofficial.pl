#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 12
# expectstdout: vcs_player_color_181_unofficial ok: official=1787 unofficial=1785 saving=2
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
sub used_rom {
   my($out)=@_; $out =~ /^  rom\s+used=(\d+) bytes\b/mi or die "missing ROM usage:\n$out";
   return 0+$1;
}
sub map_symbol {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n";
   return hex($1);
}

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
$tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $cfg=File::Spec->catfile($vcs,qw(renderers standard_4k_ntsc vcs_standard_4k_ntsc.cfg));
my $official_dir=File::Spec->catdir($repo,qw(test fixtures player_color_181));
my $unofficial_dir=File::Spec->catdir($repo,qw(test fixtures player_color_181_unofficial));
my @cases=qw(smoke static_score_above static_score_below motion_score_above motion_score_below);
my %built;
for my $case (@cases) {
   for my $kind (qw(official unofficial)) {
      my $dir=$kind eq 'official' ? $official_dir : $unofficial_dir;
      my $src=File::Spec->catfile($dir,"$case.c26");
      my $bin=File::Spec->catfile($tmp,"player_color_${case}_${kind}.bin");
      my $mapfile=File::Spec->catfile($tmp,"player_color_${case}_${kind}.map");
      my @extra=$kind eq 'unofficial' ? ('-Wa,--illegals') : ();
      my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,@extra,
                                      '-Map',$mapfile,$src,'-o',$bin);
      $rc==0 && !$sig or die "$case $kind build failed\n$out$err";
      $err eq '' or die "$case $kind build stderr: $err";
      -s $bin == 4096 or die "$case $kind is not 4K\n";
      $built{$case}{$kind}=[$bin,read_file($mapfile),used_rom($out)];
   }
}
my $official_used=$built{smoke}{official}[2];
my $unofficial_used=$built{smoke}{unofficial}[2];
$official_used==1787 or die "official smoke now uses $official_used bytes, expected 1787\n";
$unofficial_used==1785 or die "unofficial smoke now uses $unofficial_used bytes, expected 1785\n";
$official_used-$unofficial_used==2
   or die "unexpected savings: official=$official_used unofficial=$unofficial_used\n";

my @ram_symbols=qw(
   game_object_x game_player0_y game_player1_y game_ball_y
   game_player0_graphics game_player1_graphics game_player0_height
   game_player1_height game_ball_height game_workspace game_playfield_position
   game_object_masks
);
for my $name (@ram_symbols) {
   my $a=map_symbol($built{smoke}{official}[1],$name);
   my $b=map_symbol($built{smoke}{unofficial}[1],$name);
   $a==$b or die "$name RAM address differs: $a vs $b\n";
}

my $asm=File::Spec->catfile($tmp,'player_color_181_unofficial.s26');
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Wa,--illegals','-S',
   File::Spec->catfile($unofficial_dir,'smoke.c26'),'-o',$asm);
$rc==0 && !$sig or die "unofficial assembly generation failed\n$out$err";
$out eq '' && $err eq '' or die "unofficial assembly generation wrote output\n$out$err";
my $text=read_file($asm);
my $axs_count=()=($text =~ /^\s*axs\s+#252\s*$/gim);
$axs_count==2 or die "unofficial assembly has $axs_count AXS substitutions, expected 2\n";
my $zpnop_count=()=($text =~ /^\s*nop\.z\s+\$00\s*$/gim);
$zpnop_count==1 or die "unofficial assembly has $zpnop_count zero-page NOP substitutions, expected 1\n";
$text !~ /^\s*(?:dcp|lax|sax|isc|isb|rla|rra|slo|sre|anc|alr|arr|xaa|ahx|shx|shy|tas|las)\b/im
   or die "unofficial assembly contains an unreviewed unofficial mnemonic\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my $compare=File::Spec->catfile($tmp,'player_color_181_pair_compare');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   File::Spec->catfile($repo,qw(test vcs_visible_trace_compare.cpp)),@mos_input,'-o',$compare);
$rc==0 && !$sig or die "pair comparator build failed\n$out$err";
for my $case (@cases) {
   ($rc,$sig,$out,$err)=capture($compare,$built{$case}{official}[0],
      $built{$case}{unofficial}[0],'262','262');
   $rc==0 && !$sig or die "$case pair comparison failed\n$out$err";
   $out =~ /^vcs_visible_trace_compare ok: \d+ events and 42 stable frames per ROM\n$/
      or die "unexpected $case comparison output: $out";
   $err eq '' or die "$case comparison stderr: $err";
}

my $composition=File::Spec->catfile($tmp,'player_color_181_unofficial_composition');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   File::Spec->catfile($repo,qw(test vcs_player_color_181.cpp)),@mos_input,'-o',$composition);
$rc==0 && !$sig or die "composition harness build failed\n$out$err";
for my $mode (qw(static motion)) {
   for my $order (qw(above below)) {
      my $case="${mode}_score_${order}";
      my $map=$built{$case}{unofficial}[1];
      my @args=($composition,$mode,$built{$case}{unofficial}[0],map {
         sprintf('0x%02x',map_symbol($map,$_))
      } qw(game_object_x game_player0_y game_player1_y game_ball_y));
      push @args,sprintf('0x%02x',map_symbol($map,'motion_directions')) if $mode eq 'motion';
      push @args,$order;
      ($rc,$sig,$out,$err)=capture(@args);
      $rc==0 && !$sig or die "$case unofficial composition failed\n$out$err";
      $out eq "vcs_player_color_181 composition $mode $order ok\n"
         or die "unexpected $case output: $out";
      $err eq '' or die "$case stderr: $err";
   }
}

print "vcs_player_color_181_unofficial ok: official=$official_used unofficial=$unofficial_used saving=2\n";
