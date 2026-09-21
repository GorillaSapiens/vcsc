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
$selector_text =~ /TEMPLATE_missiles == 1 && TEMPLATE_player_colors == 1/
   or die "selector is missing combined all-five player-color specialization\n";

my $retired=File::Spec->catfile($vcs,qw(renderers player_color player_color.c26));
!-e $retired or die "retired player_color source still exists\n";
my $retired_combined=File::Spec->catdir($vcs,qw(renderers all_five_player_color_192));
!-e $retired_combined or die "retired all_five_player_color_192 directory still exists\n";

my @all_five_cases=(
   ['af170',[qw(test fixtures all_five_170 smoke.c26)],170],
   ['af181',[qw(test fixtures all_five_181 smoke.c26)],181],
   ['af192',[qw(test fixtures all_five_192 smoke.c26)],192],
   ['af228',[qw(examples 05_video_standards all_five pal pal_all_five_228_interactive.c26)],228],
);
for my $case (@all_five_cases) {
   my($name,$parts,$lines)=@$case;
   my $source=File::Spec->catfile($repo,@$parts);
   my $text=read_file($source);
   my $compat=qq{instantiate "renderers/all_five/all_five.c26" as game (lines:=$lines)};
   index($text,$compat)>=0 or die "$name fixture is missing compatibility renderer instantiation\n";
   my $compat_bin=File::Spec->catfile($tmp,"selector_${name}_compat.bin");
   compile_source($driver,$vcs,$source,$compat_bin);
   my $explicit=$text;
   my $selected=qq{instantiate "renderers/all_five/all_five.c26" as game (lines:=$lines, missiles:=1, player_colors:=0)};
   $explicit =~ s/\Q$compat\E/$selected/ or die "could not make $name selector explicit\n";
   my $explicit_src=File::Spec->catfile($tmp,"selector_${name}.c26");
   my $explicit_bin=File::Spec->catfile($tmp,"selector_${name}.bin");
   write_file($explicit_src,$explicit);
   compile_source($driver,$vcs,$explicit_src,$explicit_bin);
   read_file($compat_bin) eq read_file($explicit_bin)
      or die "$name explicit selector differs from compatibility default\n";
}

my @player_color_cases=(
   ['pc170',[qw(test fixtures player_color_170 smoke.c26)],170],
   ['pc181',[qw(test fixtures player_color_181 smoke.c26)],181],
   ['pc192',[qw(test fixtures player_color_192 smoke.c26)],192],
   ['pc228',[qw(examples 05_video_standards player_color pal pal_player_color_228_interactive.c26)],228],
);
for my $case (@player_color_cases) {
   my($name,$parts,$lines)=@$case;
   my $source=File::Spec->catfile($repo,@$parts);
   my $text=read_file($source);
   my $selected=qq{instantiate "renderers/all_five/all_five.c26" as game (lines:=$lines, missiles:=0, player_colors:=1)};
   index($text,$selected)>=0 or die "$name fixture did not migrate to the player-color selector specialization\n";
   my $bin=File::Spec->catfile($tmp,"selector_${name}.bin");
   compile_source($driver,$vcs,$source,$bin);
}

my $combined_source=File::Spec->catfile($repo,qw(test fixtures all_five_player_color_192 smoke.c26));
my $combined_text=read_file($combined_source);
my $combined_selected=qq{instantiate "renderers/all_five/all_five.c26" as game (lines:=192, missiles:=1, player_colors:=1)};
index($combined_text,$combined_selected)>=0
   or die "combined fixture did not migrate to the gameplay selector specialization\n";
compile_source($driver,$vcs,$combined_source,File::Spec->catfile($tmp,'selector_combined192.bin'));

print "vcs_gameplay_selector ok\n";
