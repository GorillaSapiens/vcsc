#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
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
   my($s)=@_;
   $s =~ s/\ACARTRIDGE ROM USAGE\n(?:  [^\n]+\n)+RAM USAGE\n(?:  [^\n]+\n)+//;
   return $s;
}
sub map_zp {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map is missing $name\n";
   my $value=hex($1); $value <= 0xff or die "$name is not zero page\n";
   return sprintf('0x%02x',$value);
}

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $cfg=File::Spec->catfile($vcs,qw(kernels standard_4k_ntsc vcs_standard_4k_ntsc.cfg));
my $fixtures=File::Spec->catdir($repo,qw(test fixtures poison_debug_score));
my %cases=(
   player_color_181_above => 'poison-above',
   player_color_181_below => 'poison-below',
   player_color_192_prior => 'poison-prior',
);
my %built;
for my $name (sort keys %cases) {
   my $src=File::Spec->catfile($fixtures,"$name.c26");
   my $bin=File::Spec->catfile($tmp,"$name.bin");
   my $mapfile=File::Spec->catfile($tmp,"$name.map");
   my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,'-Map',$mapfile,$src,'-o',$bin);
   $rc==0 && !$sig or die "$name build failed\n$out$err";
   without_usage($out) eq '' && $err eq '' or die "$name build wrote output\n$out$err";
   -s $bin == 4096 or die "$name is not a 4K ROM\n";
   my $map=read_file($mapfile);
   $map !~ /(?:score_font|score_score|score_pointers|score_row|score_delayed)/
      or die "$name linked production score state\n";
   $map =~ /BSS\.__vcsc_object\$poison_exit_background\s+run=\$[0-9A-Fa-f]{4}\s+size=\$0001\b/
      or die "$name does not allocate exactly the poison background handoff byte\n";
   $map !~ /\bpoison_(?:score|pointers|row|delayed|workspace)\b/
      or die "$name allocated unexpected poison instance RAM\n";
   $built{$name}=[$bin,$map];
}

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my $frame_src=File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp));
my $frame=File::Spec->catfile($tmp,'vcs_frame_timing_poison_handoff');
my($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$frame_src,@mos_input,'-o',$frame);
$rc==0 && !$sig or die "frame harness build failed\n$out$err";
$out eq '' && $err eq '' or die "frame harness build wrote output\n$out$err";
for my $name (sort keys %cases) {
   my($bin)=@{$built{$name}};
   ($rc,$sig,$out,$err)=capture($frame,$bin,'50','--no-audio','--raw-lines','262');
   $rc==0 && !$sig or die "$name frame timing failed\n$out$err";
   $out =~ /vcs_frame_timing ok: 47 frames at 262 lines/
      or die "unexpected $name frame output: $out";
   $err eq '' or die "$name frame harness stderr: $err";
}

my %player;
for my $lines (181,192) {
   my $player_src=File::Spec->catfile($repo,'test',"vcs_player_color_$lines.cpp");
   $player{$lines}=File::Spec->catfile($tmp,"vcs_player_color_${lines}_poison_handoff");
   ($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
      $player_src,@mos_input,'-o',$player{$lines});
   $rc==0 && !$sig or die "player-color $lines harness build failed\n$out$err";
   $out eq '' && $err eq '' or die "player-color $lines harness build wrote output\n$out$err";
}
for my $name (sort keys %cases) {
   my($bin,$map)=@{$built{$name}};
   my $lines=$name =~ /192/ ? 192 : 181;
   my @args=($player{$lines},'static',$bin,map { map_zp($map,$_) }
      qw(game_object_x game_player0_y game_player1_y game_ball_y));
   push @args,$cases{$name} if $lines==181;
   ($rc,$sig,$out,$err)=capture(@args);
   $rc==0 && !$sig or die "$name register-raster probe failed\n$out$err";
   if ($name eq 'player_color_181_above') {
      $out eq "vcs_player_color_181 composition static poison-above ok\n"
         or die "unexpected $name output: $out";
   }
   elsif ($name eq 'player_color_181_below') {
      $out eq "vcs_player_color_181 composition static poison-below ok\n"
         or die "unexpected $name output: $out";
   }
   else {
      $out eq "vcs_player_color_192 static ok: exact 192-line frame, VBLANK positioning, P0/P1 rows, Ball, and no missiles\n"
         or die "unexpected $name output: $out";
   }
   $err eq '' or die "$name player harness stderr: $err";
}

# The formerly open score-above defect is now a positive source and runtime
# contract. Adjacent components use the explicit phase bridge, and gameplay
# re-establishes P0/P1 coarse position, fine motion, NUSIZ, and HMOVE before
# the timed raster begins. The simulator checks P0/P1/Ball position and clipped
# pixel endpoints for all three hostile compositions above.
my $above=read_file(File::Spec->catfile($fixtures,'player_color_181_above.c26'));
$above =~ /poison_draw\(\);\s*vcs_ntsc_component_handoff\(\);\s*game_draw\(\);/s
   or die "score-above fixture is missing the explicit component handoff\n";
my $below=read_file(File::Spec->catfile($fixtures,'player_color_181_below.c26'));
$below =~ /game_draw\(\);\s*vcs_ntsc_component_handoff\(\);\s*poison_draw\(\);/s
   or die "score-below fixture is missing the explicit component handoff\n";
my $game=read_file(File::Spec->catfile($vcs,qw(kernels player_color_181 player_color_181.c26)));
for my $required (qw(RESP0 RESP1 HMP0 HMP1 HMOVE NUSIZ0 NUSIZ1)) {
   $game =~ /\b\Q$required\E\b/ or die "gameplay handoff is missing $required\n";
}
$game =~ /TEMPLATE_player_position_table\s*\[\s*160\s*\]/
   or die "gameplay handoff is missing its full-range packed position table\n";

print "poison player-color handoff ok: hostile score composition preserves P0/P1/BL positions and pixel endpoints\n";
