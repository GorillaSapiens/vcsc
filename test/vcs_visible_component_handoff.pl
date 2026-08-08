#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 4
# expectstdout: vcs_visible_component_handoff ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;

sub usage { die "usage: $0 REPO TMP\n"; }
sub read_file {
   my($path)=@_;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $text=<$fh>; close($fh);
   return defined($text) ? $text : '';
}
sub require_value {
   my($text,$name,$value,$label)=@_;
   $text =~ /\bTEMPLATE_\Q$name\E\s*:=\s*\Q$value\E\b/
      or die "$label has no TEMPLATE_$name := $value contract\n";
}
sub draw_body {
   my($text,$label)=@_;
   $text =~ /require\s+inline\s+void\s+TEMPLATE_draw\s*\(void\)\s*\{(.*?)\n\}\s*\n\s*require\s+inline\s+void\s+TEMPLATE_overscan/s
      or die "$label draw body was not found\n";
   my $body=$1;
   $body =~ s{//[^\n]*}{}g;
   return $body;
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
$tmp=abs_path($tmp) // die "resolve tmp\n";

my @components=(
   ['six_glyph_component.c26',                                      11,1,1,'centered six-glyph'],
   ['six_glyph_wide_component.c26',                                 11,1,1,'wide six-glyph'],
   ['six_glyph_color_component.c26',                                11,1,1,'mutable-color six-glyph'],
   ['six_glyph_left_component.c26',                                 11,1,1,'left six-glyph'],
   ['six_glyph_right_component.c26',                                11,1,1,'right six-glyph'],
   ['two_plus_two_score_component.c26',                              11,1,1,'two-plus-two score'],
   ['renderers/poison_debug_score/poison_debug_score.c26',           11,1,1,'poison score'],
   ['renderers/player_color_181/player_color_181.c26',              181,1,1,'player-color 181'],
   ['renderers/player_color_181_unofficial/player_color_181_unofficial.c26',181,1,1,'player-color 181 unofficial'],
   ['renderers/all_five/all_five.c26',                              181,1,1,'all-five 181'],
   ['renderers/all_five/all_five.c26',                              170,1,1,'all-five 170'],
   ['renderers/all_five_181_unofficial/all_five_181_unofficial.c26',181,1,1,'all-five 181 unofficial'],
   ['renderers/player_color_192/player_color_192.c26',              192,0,0,'player-color 192'],
   ['renderers/all_five/all_five.c26',                              192,0,0,'all-five 192'],
);

for my $spec (@components) {
   my($rel,$lines,$hmove,$successor,$label)=@$spec;
   my $path=File::Spec->catfile($repo,'libraries','vcs',split('/', $rel));
   my $text=read_file($path);
   my $parameterized_all_five = $rel eq 'renderers/all_five/all_five.c26';
   if ($parameterized_all_five) {
      my $branch;
      if ($lines == 192) {
         $text =~ /#if TEMPLATE_lines == 192(.*?)#elif TEMPLATE_lines == 181/s
            or die "could not isolate all-five 192 branch\n";
         $branch=$1;
      } elsif ($lines == 181) {
         $text =~ /#elif TEMPLATE_lines == 181(.*?)#elif TEMPLATE_lines == 170/s
            or die "could not isolate all-five 181 branch\n";
         $branch=$1;
      } else {
         $text =~ /#elif TEMPLATE_lines == 170(.*?)#else/s
            or die "could not isolate all-five 170 branch\n";
         $branch=$1;
      }
      $text=$branch;
      $text =~ /\bTEMPLATE_VISIBLE_SCANLINES\s*:=\s*TEMPLATE_lines\b/
         or die "$label has no parameterized visible-scanline contract\n";
   } else {
      require_value($text,'VISIBLE_SCANLINES',$lines,$label);
   }
   require_value($text,'DRAW_ENTRY_CYCLE',3,$label);
   require_value($text,'DRAW_RETURN_CYCLE',0,$label);
   if ($parameterized_all_five) {
      $text =~ /\bTEMPLATE_DRAW_COMPLETE_SCANLINES\s*:=\s*TEMPLATE_lines\b/
         or die "$label has no parameterized complete-scanline contract\n";
   } else {
      require_value($text,'DRAW_COMPLETE_SCANLINES',$lines,$label);
   }
   require_value($text,'DRAW_PARTIAL_ENTRY_CYCLES',0,$label);
   require_value($text,'DRAW_PARTIAL_EXIT_CYCLES',0,$label);
   require_value($text,'DRAW_TERMINAL_WSYNC',1,$label);
   require_value($text,'DRAW_HMOVE_COUNT',$hmove,$label);
   require_value($text,'DRAW_SUCCESSOR_ON_RETURN_LINE',$successor,$label);

   my $body=draw_body($text,$label);
   my $actual_hmove=()=$body =~ /(?:\bHMOVE\s*:=|\bsta(?:\.[A-Za-z]+)?\s+HMOVE\b)/g;
   $actual_hmove==$hmove
      or die "$label draw has $actual_hmove HMOVE strobes, contract says $hmove\n";
   $body =~ /(?:\bsta(?:\.[A-Za-z]+)?\s+WSYNC\b|\bWSYNC\s*:=\s*0)\s*;(?:\s*asm\s+\@[A-Za-z0-9_]+:;)*\s*\z/s
      or die "$label draw does not end through its own terminal WSYNC\n";
   $body !~ /\b(?:VSYNC|VBLANK|TIM1T|TIM8T|TIM64T|T1024T|INTIM|TIMINT|AUDC0|AUDC1|AUDF0|AUDF1|AUDV0|AUDV1)\s*:=/
      or die "$label draw writes scheduler or audio state\n";
   $body !~ /\bsta(?:\.[A-Za-z]+)?\s+(?:VSYNC|VBLANK|TIM1T|TIM8T|TIM64T|T1024T|AUDC0|AUDC1|AUDF0|AUDF1|AUDV0|AUDV1)\b/
      or die "$label draw writes scheduler or audio state in assembly\n";
   if ($label =~ /six-glyph/) {
      $body =~ /sta\s+REFP0;\s*asm\s+sta\s+REFP1;\s*asm\s+nop;/s
         or die "$label does not clear hostile reflection in the measured eight-cycle slot\n";
   }
   if ($label eq 'two-plus-two score') {
      $body =~ /sta\s+REFP0;\s*asm\s+sta\s+REFP1;\s*asm\s+sta\s+HMM0;\s*asm\s+sta\s+HMM1;\s*asm\s+sta\s+HMBL;/s
         or die "$label does not establish hostile-safe reflection and preserved-object motion\n";
      $body =~ /sta\s+GRP0;\s*asm\s+sta\s+GRP1;\s*asm\s+sta\s+GRP0;\s*asm\s+sta\s+VDELP0;\s*asm\s+sta\s+VDELP1;/s
         or die "$label does not flush the hostile player pipelines\n";
   }
}

my $frame=read_file(File::Spec->catfile($repo,qw(libraries vcs frame_ntsc.c26)));
$frame =~ /inline\s+void\s+vcs_ntsc_component_handoff\s*\(void\)\s*\{\s*asm\s+bit\.z\s+CXM0P;\s*\}/s
   or die "component handoff is not the measured single three-cycle BIT.z CXM0P bridge\n";

my $doc=read_file(File::Spec->catfile($repo,qw(libraries vcs renderers COMPONENT_CONVERSION.md)));
for my $required (
   '## Measured visible-component handoff',
   'TEMPLATE_DRAW_ENTRY_CYCLE',
   'TEMPLATE_DRAW_RETURN_CYCLE',
   'TEMPLATE_DRAW_COMPLETE_SCANLINES',
   'TEMPLATE_DRAW_PARTIAL_ENTRY_CYCLES',
   'TEMPLATE_DRAW_PARTIAL_EXIT_CYCLES',
   'TEMPLATE_DRAW_TERMINAL_WSYNC',
   'TEMPLATE_DRAW_HMOVE_COUNT',
   'TEMPLATE_DRAW_SUCCESSOR_ON_RETURN_LINE',
   'Production six-glyph displays',
   'Widely spaced six-glyph display',
   'Left/right two-plus-two score',
   'Poison debug score',
   '181-line player-color gameplay',
   '170-line all-five gameplay',
   '181-line all-five gameplay',
   '192-line player-color gameplay',
   '192-line all-five gameplay',
) {
   index($doc,$required)>=0 or die "handoff document is missing '$required'\n";
}

print "vcs_visible_component_handoff ok\n";
