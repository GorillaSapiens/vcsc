#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: driver temp cleanup ok


use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use File::Temp qw(tempdir);
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO_ROOT TMP_DIR\n"; }
sub slurp_fh { my ($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub write_file {
   my ($path,$text)=@_;
   open(my $fh,'>:raw',$path) or die "could not create $path: $!\n";
   print {$fh} $text;
   close($fh) or die "could not close $path: $!\n";
}
sub run_capture {
   my ($env,@cmd)=@_;
   my $err=gensym;
   local %ENV=(%ENV,%$env);
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in);
   my $stdout=slurp_fh($out);
   my $stderr=slurp_fh($err);
   waitpid($pid,0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "could not resolve repo root\n";
$tmp=abs_path($tmp) // die "could not resolve temp root\n";

my $sandbox=tempdir('vcsc_driver_cleanup_XXXXXX',DIR=>$tmp,CLEANUP=>1);
my $src=File::Spec->catfile($sandbox,'cleanup_probe.c26');
my $bad_cfg=File::Spec->catfile($sandbox,'missing.cfg');
my $out=File::Spec->catfile($sandbox,'cleanup_probe.bin');
my $driver=File::Spec->catfile($repo,'driver','vcsc');

write_file($src,"include \"vcs.c26\"\n\nvoid main(void) {\n}\n");
my ($exit,$sig,$stdout,$stderr)=run_capture(
   { TMPDIR=>$sandbox },
   $driver,'-I',File::Spec->catdir($repo,'libraries','vcs'),'-T',$bad_cfg,$src,'-o',$out);
$exit != 0 && !$sig or die "intentional driver failure unexpectedly succeeded\n";
$stdout eq '' or die "intentional driver failure wrote stdout:\n$stdout";
$stderr =~ /could not (?:open|read).*missing\.cfg|missing\.cfg/
   or die "intentional driver failure did not reach the linker/config error:\n$stderr";

my @left=glob(File::Spec->catfile($sandbox,'vcsc.*'));
@left==0 or die "driver left temporary paths after failure:\n" . join("\n",@left) . "\n";

print "driver temp cleanup ok\n";
