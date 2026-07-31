#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: vcs_all_five_interactive_examples ok: five all-five interactive renderer examples pass build, frame, five-object controls, filtered score controls, endpoints, reset, and opcode-policy checks
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture { my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in); my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0); return ($?>>8,$?&127,$so,$se); }
sub read_file { my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return defined($d)?$d:''; }
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }
sub map_zp { my($map,$name)=@_; $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n"; my $v=hex($1); $v<=0xff or die "$name is not zero-page\n"; return sprintf('0x%02x',$v); }

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n"; make_path($tmp); $tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my @cases=(
 { dir=>'05_all_five_192/01_interactive', stem=>'all_five_192_interactive', profile=>'all5_192', score=>0, extra=>[] },
 { dir=>'06_all_five_181/01_score_above/01_interactive', stem=>'all_five_181_score_above_interactive', profile=>'all5_above', score=>1, extra=>[] },
 { dir=>'06_all_five_181/02_score_below/01_interactive', stem=>'all_five_181_score_below_interactive', profile=>'all5_below', score=>1, extra=>[] },
 { dir=>'08_all_five_181_unofficial/01_score_above/01_interactive', stem=>'all_five_181_unofficial_score_above_interactive', profile=>'all5_above', score=>1, extra=>['-Wa,--illegals'], unofficial=>1 },
 { dir=>'08_all_five_181_unofficial/02_score_below/01_interactive', stem=>'all_five_181_unofficial_score_below_interactive', profile=>'all5_below', score=>1, extra=>['-Wa,--illegals'], unofficial=>1 },
);

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my $hsrc=File::Spec->catfile($repo,qw(test vcs_all_five_interactive_example_matrix.cpp));
my $harness=File::Spec->catfile($tmp,'vcs_all_five_interactive_example_matrix');
my($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$hsrc,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "all-five interactive harness build failed\n$out$err";
$out eq '' && $err eq '' or die "all-five interactive harness wrote output\n$out$err";

for my $case (@cases) {
   my $dir=$case->{dir}; my $stem=$case->{stem};
   my $src=File::Spec->catfile($repo,'examples',$dir,"$stem.c26");
   my $text=read_file($src);
   my $renderer=$case->{unofficial}
      ? 'renderers/all_five_181_unofficial/all_five_181_unofficial.c26'
      : ($case->{profile} eq 'all5_192'
         ? 'renderers/all_five_192/all_five_192.c26'
         : 'renderers/all_five_181/all_five_181.c26');
   $text =~ /\Q$renderer\E/ or die "$dir does not use the selected all-five renderer\n";
   if ($case->{unofficial}) {
      join(' ',@{$case->{extra}}) eq '-Wa,--illegals'
         or die "$dir does not opt into unofficial opcodes explicitly\n";
   }
   $text =~ /SELECTED_PLAYER0/ && $text =~ /SELECTED_PLAYER1/ &&
   $text =~ /SELECTED_MISSILE0/ && $text =~ /SELECTED_MISSILE1/ && $text =~ /SELECTED_BALL/
      or die "$dir does not expose all five selectable objects\n";
   $text =~ /game_MISSILE0_X/ && $text =~ /game_MISSILE1_X/ &&
   $text =~ /game_missile0_y/ && $text =~ /game_missile1_y/
      or die "$dir does not initialize and move both missiles\n";
   $text =~ /asm jmp \(\$fffc\);/ or die "$dir RESET does not jump through the reset vector\n";
   if ($case->{score}) {
      $text =~ /uint8_t object_control_state := 0x98;/ &&
      $text =~ /uint8_t score_control_state := 0x8f;/
         or die "$dir lacks packed RAM-safe control state\n";
      $text =~ /asm sbc #\$08;/ && $text =~ /asm ora #\$98;/
         or die "$dir lacks twentieth-frame score sampling\n";
      $text =~ /asm adc #\$10;.*?asm sta score_color;/s
         or die "$dir does not advance the score color\n";
      my $score=index($text,'score_draw();'); my $game=index($text,'game_draw();');
      ($case->{profile} eq 'all5_above' ? $score<$game : $game<$score)
         or die "$dir draw order is wrong\n";
   }

   my $bin=File::Spec->catfile($tmp,"$stem.bin");
   my $mapfile=File::Spec->catfile($tmp,"$stem.map");
   ($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$mapfile,@{$case->{extra}},$src,'-o',$bin);
   $rc==0 && !$sig or die "$dir build failed\n$out$err";
   without_usage($out) eq '' && $err eq '' or die "$dir build wrote output\n$out$err";
   length(read_file($bin))==4096 or die "$dir ROM is not 4096 bytes\n";
   my $map=read_file($mapfile);
   my @args=(
      $bin,$case->{profile},map_zp($map,'game_object_x'),
      map_zp($map,'game_player0_y'),map_zp($map,'game_player1_y'),
      map_zp($map,'game_missile0_y'),map_zp($map,'game_missile1_y'),map_zp($map,'game_ball_y'),
   );
   if ($case->{score}) {
      push @args,map_zp($map,'object_control_state'),map_zp($map,'score_control_state'),
                 map_zp($map,'score_score'),map_zp($map,'score_color');
   } else {
      push @args,map_zp($map,'selected_object'),map_zp($map,'select_switch_ready'),qw(none none);
   }
   ($rc,$sig,$out,$err)=capture($harness,@args);
   $rc==0 && !$sig or die "$dir runtime failed\n$out$err";
   $out =~ /^vcs_all_five_interactive_example_matrix \Q$case->{profile}\E ok: five-object controls and reset across \d+ frames\n$/
      or die "$dir unexpected runtime output: $out";
   $err eq '' or die "$dir runtime stderr: $err";
}

print "vcs_all_five_interactive_examples ok: five all-five interactive renderer examples pass build, frame, five-object controls, filtered score controls, endpoints, reset, and opcode-policy checks\n";
