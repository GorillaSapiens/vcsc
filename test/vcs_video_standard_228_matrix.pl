#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: vcs_video_standard_228_matrix ok: 4 parameterized renderer families have native PAL and SECAM 228-line examples
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Find qw(find);
use File::Spec;

sub read_file {
   my($path)=@_;
   open(my$fh,'<:raw',$path) or die "read $path: $!\n";
   local$/; my$text=<$fh>; close$fh; return $text // '';
}

my$repo=abs_path(shift@ARGV // die "usage: $0 REPO\n");
die "usage: $0 REPO\n" if @ARGV;
my$renderers=File::Spec->catdir($repo,qw(libraries vcs renderers));
my$examples=File::Spec->catdir($repo,qw(examples 17_video_standards));
my@families;
find({no_chdir=>1,wanted=>sub {
   return unless -f $_ && /\.c26\z/;
   my$path=$File::Find::name;
   my$text=read_file($path);
   return unless $text =~ /^parameter\s+lines\s*;/m;
   return unless $text =~ /TEMPLATE_lines\s*==\s*228/;
   my($vol,$dir,$file)=File::Spec->splitpath($path);
   my@parts=File::Spec->splitdir($dir);
   pop@parts while @parts && $parts[-1] eq '';
   push@families,[$parts[-1],File::Spec->abs2rel($path,File::Spec->catdir($repo,qw(libraries vcs)))];
}},$renderers);
@families=sort{$a->[0]cmp$b->[0]}@families;
@families==4 or die "native-228 parameterized renderer inventory changed: found ".scalar(@families)."\n";

for my$f(@families) {
   my($family,$renderer_rel)=@$f;
   for my$standard(qw(pal secam)) {
      my@matches;
      my$root=File::Spec->catdir($examples,$standard);
      find({no_chdir=>1,wanted=>sub {
         return unless -f $_ && /\.c26\z/;
         my$text=read_file($File::Find::name);
         push@matches,$File::Find::name
            if $text =~ /instantiate\s+"\Q$renderer_rel\E"\s+as\s+\w+\s*\(\s*lines\s*:=\s*228\s*\)/;
      }},$root);
      @matches==1 or die "$standard $family native-228 example count is ".scalar(@matches).", expected 1\n";
      my$text=read_file($matches[0]);
      $text =~ /vcs_${standard}_end_vblank\(\).*?game_draw\(\).*?vcs_${standard}_component_to_overscan_handoff\(\).*?vcs_${standard}_begin_overscan\(\)/s
         or die "$matches[0] does not hand a native 228-line renderer directly from VBLANK to overscan\n";
      $text !~ /wait_component_scanlines|wait_visible_tail_scanlines|border_handoff|hide_border/
         or die "$matches[0] reintroduced synthetic visible padding\n";
   }
}

print "vcs_video_standard_228_matrix ok: 4 parameterized renderer families have native PAL and SECAM 228-line examples\n";
