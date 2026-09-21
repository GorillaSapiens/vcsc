#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_video_standard_ntsc_matrix ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

our($tmp,$driver,$vcs);

sub slurp_path {
   my($path)=@_;
   open(my$fh,'<:raw',$path) or die "read $path: $!\n";
   local$/; my$s=<$fh>; close$fh; return $s // '';
}
sub capture {
   my(@cmd)=@_; my$err=gensym; my$pid=open3(my$in,my$out,$err,@cmd); close$in;
   local$/; my$so=<$out>//''; my$se=<$err>//''; waitpid($pid,0);
   return($?>>8,$?&127,$so,$se);
}
sub build_rom {
   my($tag,$flags,$inputs)=@_;
   my$out=File::Spec->catfile($tmp,"$tag.bin");
   my($r,$sig,$so,$se)=capture($driver,'-I',$vcs,@$flags,@$inputs,'-o',$out);
   $r==0&&!$sig or die "$tag build failed\n$so$se";
   return slurp_path($out);
}

@ARGV==2 or die "usage: $0 REPO TMP\n";
my$repo=abs_path(shift@ARGV)//die"repo\n";
$tmp=shift@ARGV; make_path($tmp); $tmp=abs_path($tmp)//die"tmp\n";
$driver=File::Spec->catfile($repo,qw(driver vcsc));
$vcs=File::Spec->catdir($repo,qw(libraries vcs));
my$root=File::Spec->catdir($repo,qw(examples 05_video_standards));

# Blank keeps one RGB intent across all three standard-specific palette builtins.
my$blank=File::Spec->catfile($root,qw(blank ntsc ntsc_blank.c26));
my$blank_text=slurp_path($blank);
$blank_text =~ /include "frame_ntsc\.c26"/ &&
$blank_text =~ /__builtin_ntsc_rgb\(0x12,\s*0x13,\s*0x9d\)/ &&
$blank_text =~ /vcs_ntsc_wait_scanlines\(VCS_NTSC_VISIBLE_SCANLINES`uint8_t\)/
   or die "NTSC blank cell lost the explicit NTSC frame/RGB comparison contract\n";
for my$standard(qw(pal secam)) {
   my$src=File::Spec->catfile($root,'blank',$standard,"${standard}50_blank.c26");
   my$text=slurp_path($src);
   $text =~ /__builtin_${standard}_rgb\(0x12,\s*0x13,\s*0x9d\)/
      or die "$standard blank cell lost shared dark-blue RGB intent\n";
}

# Four NTSC cells deliberately reuse canonical NTSC examples byte-for-byte.
my@reused=(
   ['player_color','ntsc_player_color_192_interactive.c26',
      File::Spec->catfile($repo,qw(examples 04_renderers player_color no_score player_color_192_interactive.c26)),[],[]],
   ['all_five','ntsc_all_five_192_interactive.c26',
      File::Spec->catfile($repo,qw(examples 04_renderers all_five no_score all_five_192_interactive.c26)),[],[]],
   ['multisprite','ntsc_multisprite_192_interactive.c26',
      File::Spec->catfile($repo,qw(examples 04_renderers multisprite no_score multisprite_192_interactive.c26)),['-Wa,--illegals'],[]],
   ['enhanced_multisprite_asymmetric','ntsc_enhanced_multisprite_asymmetric_192_interactive.c26',
      File::Spec->catfile($repo,qw(examples 04_renderers enhanced_multisprite no_score_asymmetric enhanced_multisprite_192_asymmetric.c26)),
      ['-nostdlib','-DVCS_NTSC_EXTENDED_VBLANK','-DMULTISPRITE_NO_RETAINED_PF_ROWS'],
      [File::Spec->catfile($repo,qw(examples 04_renderers enhanced_multisprite no_score_asymmetric enhanced_multisprite_192_asymmetric_startup.s26))]],
);
for my$spec(@reused) {
   my($family,$file,$canonical,$flags,$extra)=@$spec;
   my$wrapper=File::Spec->catfile($root,$family,'ntsc',$file);
   my$wt=slurp_path($wrapper);
   my$rel=File::Spec->abs2rel($canonical,File::Spec->catdir($root,$family,'ntsc'));
   $rel =~ s{\\}{/}g;
   index($wt,qq{include "$rel"})>=0
      or die "$wrapper does not reuse canonical NTSC $family source\n";
   my$a=build_rom("$family-wrapper",$flags,[$wrapper,@$extra]);
   my$b=build_rom("$family-canonical",$flags,[$canonical,@$extra]);
   $a eq $b or die "$family NTSC standards cell is not byte-identical to canonical NTSC example\n";
}

# The unofficial all-five cell shares the exact official scene source, changing
# only renderer identity; its Makefile must keep illegal-opcode assembly explicit.
my$unoff=File::Spec->catfile($root,qw(all_five_unofficial ntsc ntsc_all_five_unofficial_192_interactive.c26));
my$official=File::Spec->catfile($repo,qw(examples 04_renderers all_five no_score all_five_192_interactive.c26));
my$ut=slurp_path($unoff); my$ot=slurp_path($official);
$ut =~ s{\A(// This file is covered[^\n]*\n)// NTSC standards peer:[^\n]*\n}{$1};
$ut =~ s{renderers/all_five_unofficial/all_five_unofficial\.c26}{renderers/all_five/all_five.c26};
$ut eq $ot or die "NTSC all_five_unofficial scene drifted from official all_five peer\n";
my$umake=slurp_path(File::Spec->catfile($root,qw(all_five_unofficial ntsc Makefile)));
index($umake,'-Wa,--illegals')>=0 or die "NTSC all_five_unofficial Makefile lost explicit illegal-opcode opt-in\n";
build_rom('all-five-unofficial-ntsc',['-Wa,--illegals'],[$unoff]);

# PAL/SECAM peers keep the same renderer identity at their native 228-line height.
my%renderer=(
   player_color=>'renderers/all_five/all_five.c26',
   all_five=>'renderers/all_five/all_five.c26',
   all_five_unofficial=>'renderers/all_five_unofficial/all_five_unofficial.c26',
   multisprite=>'renderers/multisprite/multisprite.c26',
   enhanced_multisprite_asymmetric=>'renderers/enhanced_multisprite_asymmetric/enhanced_multisprite.c26',
);
for my$family(sort keys%renderer) {
   for my$standard(qw(pal secam)) {
      my($src)=glob(File::Spec->catfile($root,$family,$standard,"${standard}_*.c26"));
      defined$src or die "missing $standard $family standards source\n";
      my$text=slurp_path($src);
      if ($family eq 'player_color') {
         $text =~ /instantiate\s+"\Q$renderer{$family}\E"\s+as\s+game\s*\(\s*lines\s*:=\s*228\s*,\s*missiles\s*:=\s*0\s*,\s*player_colors\s*:=\s*1\s*\)/
            or die "$standard $family cell does not select the 228-line player-color specialization\n";
      } else {
         $text =~ /instantiate\s+"\Q$renderer{$family}\E"\s+as\s+game\s*\(\s*lines\s*:=\s*228\s*\)/
            or die "$standard $family cell does not use the same renderer identity at 228 lines\n";
      }
   }
}

print "vcs_video_standard_ntsc_matrix ok\n";
