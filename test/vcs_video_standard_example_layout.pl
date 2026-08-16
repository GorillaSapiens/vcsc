#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# timeout: 20
# expectstdout: vcs_video_standard_example_layout ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;

sub read_file {
   my($path)=@_;
   open(my$fh,'<:raw',$path) or die "read $path: $!\n";
   local $/;
   my$data=<$fh> // '';
   close($fh);
   return $data;
}

@ARGV == 1 or die "usage: $0 REPO\n";
my $repo=abs_path($ARGV[0]) // die "repo\n";
my $root=File::Spec->catdir($repo,qw(examples 17_video_standards));

opendir(my$dh,$root) or die "open $root: $!\n";
my @standard_dirs=sort grep {
   $_ ne '.' && $_ ne '..' && -d File::Spec->catdir($root,$_)
} readdir($dh);
closedir($dh);
join(' ',@standard_dirs) eq 'pal secam'
   or die "examples/17_video_standards subdirectories must be exactly pal secam\n";

my @cases=(
   ['pal','__builtin_pal_rgb','00_blank','pal50_blank.c26'],
   ['pal','__builtin_pal_rgb','01_all_five','pal_all_five_192_interactive.c26'],
   ['secam','__builtin_secam_rgb','00_blank','secam50_blank.c26'],
   ['secam','__builtin_secam_rgb','01_all_five','secam_all_five_192_interactive.c26'],
);
for my$case(@cases) {
   my($standard,$builtin,$numbered,$file)=@$case;
   my$dir=File::Spec->catdir($root,$standard,$numbered);
   -d$dir or die "missing $dir\n";
   my$source=File::Spec->catfile($dir,$file);
   -f$source or die "missing $source\n";
   my$text=read_file($source);
   $text =~ /\Q$builtin\E\s*\(/
      or die "$source does not use $builtin directly\n";
   $text !~ /^\s*include\s+"color_(?:pal|secam)\.c26"/m
      or die "$source hides RGB matching behind a color alias include\n";
}

for my$standard(qw(pal secam)) {
   my$dir=File::Spec->catdir($root,$standard);
   opendir(my$sdh,$dir) or die "open $dir: $!\n";
   my@numbered=sort grep {
      $_ ne '.' && $_ ne '..' && -d File::Spec->catdir($dir,$_)
   } readdir($sdh);
   closedir($sdh);
   join(' ',@numbered) eq '00_blank 01_all_five'
      or die "$standard example numbering must be 00_blank 01_all_five\n";
}

print "vcs_video_standard_example_layout ok\n";
