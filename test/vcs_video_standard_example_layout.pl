#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
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
my $root=File::Spec->catdir($repo,qw(examples 05_video_standards));
my @demos=qw(blank player_color all_five all_five_unofficial multisprite enhanced_multisprite_asymmetric);

opendir(my$dh,$root) or die "open $root: $!\n";
my @demo_dirs=sort grep {
   $_ ne '.' && $_ ne '..' && -d File::Spec->catdir($root,$_)
} readdir($dh);
closedir($dh);
join(' ',@demo_dirs) eq join(' ',sort @demos)
   or die "examples/05_video_standards demonstration directories are incomplete or unexpected\n";

my @cases=(
   ['pal','__builtin_pal_rgb','blank','pal50_blank.c26'],
   ['pal','__builtin_pal_rgb','all_five','pal_all_five_228_interactive.c26'],
   ['secam','__builtin_secam_rgb','blank','secam50_blank.c26'],
   ['secam','__builtin_secam_rgb','all_five','secam_all_five_228_interactive.c26'],
);
for my$case(@cases) {
   my($standard,$builtin,$demo,$file)=@$case;
   my$dir=File::Spec->catdir($root,$demo,$standard);
   -d$dir or die "missing $dir\n";
   my$source=File::Spec->catfile($dir,$file);
   -f$source or die "missing $source\n";
   my$text=read_file($source);
   $text =~ /\Q$builtin\E\s*\(/
      or die "$source does not use $builtin directly\n";
   $text !~ /^\s*include\s+"color_(?:pal|secam)\.c26"/m
      or die "$source hides RGB matching behind a color alias include\n";

   if ($demo eq 'blank') {
      $text =~ /\Q$builtin\E\s*\(0x12,\s*0x13,\s*0x9d\)/
         or die "$source must retain the NTSC dark-blue RGB intent\n";
   }
   else {
      for my$rgb ('0x24, 0x28, 0xb0', '0xea, 0xc2, 0x54',
                  '0x79, 0xdd, 0xfb', '0xea, 0x82, 0xdc') {
         $text =~ /\Q$builtin\E\s*\(\Q$rgb\E\)/
            or die "$source must use NTSC all-five RGB intent $rgb\n";
      }
   }

   my$makefile=File::Spec->catfile($dir,'Makefile');
   my$make=read_file($makefile);
   my$format=uc($standard);
   $make =~ /^play:\s*\$\(TARGET\)\s*$/m
      or die "$makefile play target must depend on TARGET\n";
   $make =~ /^\s*stella\s+-dev\.tv\.jitter\s+0\s+-basedir\s+"\$\(CURDIR\)"\s+-userdir\s+"\$\(CURDIR\)"\s+-format\s+\Q$format\E\s+"\$\(CURDIR\)\/\$\(TARGET\)"\s*$/m
      or die "$makefile play target must force Stella -format $format\n";
}

for my$demo(@demos) {
   my$dir=File::Spec->catdir($root,$demo);
   opendir(my$sdh,$dir) or die "open $dir: $!\n";
   my@standards=sort grep {
      $_ ne '.' && $_ ne '..' && -d File::Spec->catdir($dir,$_)
   } readdir($sdh);
   closedir($sdh);
   my$expected='ntsc pal secam';
   join(' ',@standards) eq $expected
      or die "$demo standards cells are '@standards', expected '$expected'\n";
}

print "vcs_video_standard_example_layout ok\n";
