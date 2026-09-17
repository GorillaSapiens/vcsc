# Shared deterministic Stella test configuration.
# Required directly by maintained Stella certification scripts.
use strict;
use warnings;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use Digest::SHA qw(sha256_hex);

sub vcsc_stella_private_env {
   my($basedir)=@_;
   defined($basedir) or die "vcsc_stella_private_env requires BASEDIR\n";
   make_path($basedir);
   my$xdg=File::Spec->catdir($basedir,'.xdg');
   my$config=File::Spec->catdir($xdg,'config');
   my$data=File::Spec->catdir($xdg,'data');
   my$state=File::Spec->catdir($xdg,'state');
   my$cache=File::Spec->catdir($xdg,'cache');
   make_path($config,$data,$state,$cache);
   $ENV{HOME}=$basedir;
   $ENV{XDG_CONFIG_HOME}=$config;
   $ENV{XDG_DATA_HOME}=$data;
   $ENV{XDG_STATE_HOME}=$state;
   $ENV{XDG_CACHE_HOME}=$cache;
}

sub vcsc_stella_palette_args {
   my($repo,$basedir)=@_;
   defined($repo)&&defined($basedir) or die "vcsc_stella_palette_args requires REPO and BASEDIR\n";
   vcsc_stella_private_env($basedir);
   my$palette=File::Spec->catfile($repo,qw(test fixtures stella stella.pal));
   -f$palette or die "missing pinned Stella palette $palette\n";
   -s$palette==792 or die "pinned Stella palette must be exactly 792 bytes\n";
   open(my$fh,'<:raw',$palette) or die "open $palette: $!\n"; local$/; my$data=<$fh>; close$fh;
   sha256_hex($data) eq '912ce47e7c53e0e61a861bc0ff889d187644ac53d762f0c0091484c70a3bf8bd'
      or die "pinned Stella palette digest changed\n";
   make_path($basedir);
   my$dest=File::Spec->catfile($basedir,'stella.pal');
   copy($palette,$dest) or die "copy $palette -> $dest: $!\n";
   return (
      '-basedir',$basedir,
      '-palette','user',
      '-pal.hue','0',
      '-pal.saturation','0',
      '-pal.contrast','0',
      '-pal.brightness','0',
      '-pal.gamma','0',
      '-detectpal60','0',
      '-detectntsc50','0',
      '-plr.colorloss','0',
      '-dev.colorloss','0',
      '-tv.filter','0',
      '-tv.phosblend','0',
      '-tia.inter','0',
   );
}

1;
