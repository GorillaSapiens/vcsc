#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_gameplay_selector ok
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
sub write_file {
   my($p,$d)=@_; open(my $f,'>:raw',$p) or die "write $p: $!\n";
   print {$f} $d; close($f) or die "close $p: $!\n";
}
sub compile_source {
   my($driver,$vcs,$source,$out)=@_;
   my($rc,$sig,$so,$se)=capture($driver,'-I',$vcs,$source,'-o',$out);
   $rc==0 && !$sig or die "build failed for $source\n$so$se";
   -s $out or die "build produced no cartridge for $source\n";
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
$tmp=abs_path($tmp) // die "resolve temporary directory\n";

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $selector=File::Spec->catfile($vcs,qw(renderers all_five all_five.c26));
my $selector_text=read_file($selector);
$selector_text =~ /parameter missiles := 1;/
   or die "selector is missing missiles compatibility default\n";
$selector_text =~ /parameter player_colors := 0;/
   or die "selector is missing player-color compatibility default\n";
$selector_text =~ /TEMPLATE_missiles == 1 && TEMPLATE_player_colors == 0/
   or die "selector is missing all-five specialization\n";
$selector_text =~ /TEMPLATE_missiles == 0 && TEMPLATE_player_colors == 1/
   or die "selector is missing player-color specialization\n";

my @cases=(
   ['af170',qw(test fixtures all_five_170 smoke.c26),'renderers/all_five/all_five.c26',170,1,0],
   ['af181',qw(test fixtures all_five_181 smoke.c26),'renderers/all_five/all_five.c26',181,1,0],
   ['af192',qw(test fixtures all_five_192 smoke.c26),'renderers/all_five/all_five.c26',192,1,0],
   ['af228',qw(examples 05_video_standards all_five pal pal_all_five_228_interactive.c26),'renderers/all_five/all_five.c26',228,1,0],
   ['pc170',qw(test fixtures player_color_170 smoke.c26),'renderers/player_color/player_color.c26',170,0,1],
   ['pc181',qw(test fixtures player_color_181 smoke.c26),'renderers/player_color/player_color.c26',181,0,1],
   ['pc192',qw(test fixtures player_color_192 smoke.c26),'renderers/player_color/player_color.c26',192,0,1],
   ['pc228',qw(examples 05_video_standards player_color pal pal_player_color_228_interactive.c26),'renderers/player_color/player_color.c26',228,0,1],
);

for my $case (@cases) {
   my($name,@rest)=@$case;
   my($oldpath,$lines,$missiles,$player_colors)=splice(@rest,-4);
   my $source=File::Spec->catfile($repo,@rest);
   my $text=read_file($source);
   my $old=qq{instantiate "$oldpath" as game (lines:=$lines)};
   index($text,$old)>=0 or die "$name fixture is missing expected renderer instantiation\n";

   my $legacy_bin=File::Spec->catfile($tmp,"selector_${name}_legacy.bin");
   compile_source($driver,$vcs,$source,$legacy_bin);

   my $selected=$text;
   my $new=qq{instantiate "renderers/all_five/all_five.c26" as game (lines:=$lines, missiles:=$missiles, player_colors:=$player_colors)};
   $selected =~ s/\Q$old\E/$new/ or die "could not rewrite $name fixture\n";
   my $selected_src=File::Spec->catfile($tmp,"selector_$name.c26");
   my $selected_bin=File::Spec->catfile($tmp,"selector_$name.bin");
   write_file($selected_src,$selected);
   compile_source($driver,$vcs,$selected_src,$selected_bin);

   read_file($legacy_bin) eq read_file($selected_bin)
      or die "$name selector cartridge differs from maintained source\n";
}

print "vcs_gameplay_selector ok\n";
