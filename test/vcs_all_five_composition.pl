#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 8
# expectstdout: vcs_all_five_composition ok
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
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }
sub map_symbol {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map is missing $name\n";
   my $v=hex($1); $v <= 0xff or die "$name is not zero page\n"; return $v;
}
sub object_size {
   my($map,$name)=@_;
   $map =~ /^\s+(?:BSS|DATA)\.__vcsc_object\$\Q$name\E(?:\s+load=\$[0-9A-Fa-f]{4})?\s+run=\$[0-9A-Fa-f]{4}\s+size=\$([0-9A-Fa-f]{4})\b/m
      or die "map is missing RAM object $name\n";
   return hex($1);
}

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
$tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $cfg=File::Spec->catfile($vcs,qw(renderers standard_4k_ntsc vcs_standard_4k_ntsc.cfg));
my $fixture_dir=File::Spec->catdir($repo,qw(test fixtures all_five_181));
my %built;
for my $mode (qw(static motion)) {
   for my $order (qw(above below)) {
      my $key="${mode}_score_${order}";
      my $src=File::Spec->catfile($fixture_dir,"$key.c26");
      my $bin=File::Spec->catfile($tmp,"$key.bin");
      my $mapfile=File::Spec->catfile($tmp,"$key.map");
      my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,'-Map',$mapfile,$src,'-o',$bin);
      $rc==0 && !$sig or die "$key build failed\n$out$err";
      without_usage($out) eq '' && $err eq '' or die "$key build wrote output\n$out$err";
      -s $bin == 4096 or die "$key is not a 4K ROM\n";
      my $source=read_file($src);
      $source =~ /game_draw\(\);\s*score_draw\(\);/s xor
      $source =~ /score_draw\(\);.*game_draw\(\);/s
         or die "$key does not contain exactly one explicit draw order\n";
      my $map=read_file($mapfile);
      my $game_ram=0;
      $game_ram += object_size($map,$_) for qw(
         game_object_x game_player0_y game_player1_y game_missile1_height
         game_missile1_y game_ball_y game_player0_graphics game_player1_graphics
         game_player0_height game_player1_height game_missile0_height
         game_missile0_y game_ball_height game_workspace game_playfield_position
         game_object_masks
      );
      $game_ram==69 or die "$key game RAM is $game_ram, expected 69\n";
      my $score_ram=0;
      $score_ram += object_size($map,$_) for qw(score_score score_pointers score_row score_delayed);
      $score_ram==17 or die "$key score RAM is $score_ram, expected 17\n";
      $map =~ /score_font/ or die "$key did not link the independent font\n";
      $built{$key}=[$bin,$map];
   }
}

# Re-prove that the gameplay-only link carries none of the independent score cost.
my $plain_src=File::Spec->catfile($fixture_dir,'smoke.c26');
my $plain_bin=File::Spec->catfile($tmp,'gameplay_only.bin');
my $plain_mapfile=File::Spec->catfile($tmp,'gameplay_only.map');
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,'-Map',$plain_mapfile,$plain_src,'-o',$plain_bin);
$rc==0 && !$sig or die "gameplay-only build failed\n$out$err";
my $plain_map=read_file($plain_mapfile);
$plain_map !~ /(?:score_score|score_pointers|score_row|score_delayed|score_font)/
   or die "gameplay-only link retained independent score state or ROM\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $src=File::Spec->catfile($repo,qw(test vcs_all_five_composition.cpp));
my $exe=File::Spec->catfile($tmp,'vcs_all_five_composition');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$src,@mos_input,'-o',$exe);
$rc==0 && !$sig or die "composition harness build failed\n$out$err";
$out eq '' && $err eq '' or die "composition harness build wrote output\n$out$err";

# Build the strict intended-pixel oracle too. The score-above layout starts the
# first gameplay row at frame line 54; score-below starts it at line 43.
my $raster_src=File::Spec->catfile($repo,qw(test vcs_playfield_phase.cpp));
my $raster_exe=File::Spec->catfile($tmp,'vcs_all_five_composition_raster');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$raster_src,@mos_input,'-o',$raster_exe);
$rc==0 && !$sig or die "raster harness build failed\n$out$err";
$out eq '' && $err eq '' or die "raster harness build wrote output\n$out$err";
for my $order (qw(above below)) {
   my $key="static_score_${order}";
   my($bin)=@{$built{$key}};
   my $first=$order eq 'above' ? 54 : 43;
   ($rc,$sig,$out,$err)=capture($raster_exe,$bin,'11','11',$first);
   $rc==0 && !$sig or die "$key raster failed\n$out$err";
   $out eq "vcs_playfield_raster ok: 11 rows x 16 lines x 160 pixels\n"
      or die "unexpected $key raster output: $out";
   $err eq '' or die "$key raster stderr: $err";
}
for my $mode (qw(static motion)) {
   for my $order (qw(above below)) {
      my $key="${mode}_score_${order}";
      my($bin,$map)=@{$built{$key}};
      my @args=($exe,$bin,$order,$mode);
      if ($mode eq 'motion') {
         push @args,map { sprintf('0x%02x',map_symbol($map,$_)) } qw(
            game_object_x game_player0_y game_player1_y game_missile0_y
            game_missile1_y game_ball_y motion_frame
         );
      }
      ($rc,$sig,$out,$err)=capture(@args);
      $rc==0 && !$sig or die "$key composition failed\n$out$err";
      $out eq "vcs_all_five_composition $mode $order ok\n"
         or die "unexpected $key output: $out";
      $err eq '' or die "$key composition stderr: $err";
   }
}
print "vcs_all_five_composition ok\n";
