#!/usr/bin/perl
# runner: perl @FILE@
# phase: e2e
# expectstdout: runner serial scheduling ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(getcwd);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

my $tmp=tempdir('vcsc_runner_serial_XXXX',TMPDIR=>1,CLEANUP=>1);
my $active=File::Spec->catfile($tmp,'active');
my $helper=File::Spec->catfile($tmp,'helper.pl');
open(my $hf,'>',$helper) or die "write $helper: $!\n";
print {$hf} <<'HELPER';
use strict;
use warnings;
use Time::HiRes qw(sleep);
my($active,$mode)=@ARGV;
if($mode eq 'parallel') {
   open(my $f,'>>',$active) or die $!;
   print {$f} "active\n";
   close($f);
   sleep(0.50);
   unlink($active) or die "unlink active: $!\n";
   exit 0;
}
if($mode eq 'serial') {
   sleep(0.10);
   -e $active and die "serial case overlapped a parallel worker\n";
   sleep(0.10);
   exit 0;
}
die "bad mode\n";
HELPER
close($hf) or die "close $helper: $!\n";

sub fixture {
   my($name,$mode,$serial)=@_;
   my $path=File::Spec->catfile($tmp,$name);
   open(my $fh,'>',$path) or die "write $path: $!\n";
   print {$fh} "# runner: perl $helper $active $mode\n";
   print {$fh} "# phase: e2e\n";
   print {$fh} "# serial\n" if $serial;
   print {$fh} "# expectexit: 0\n";
   close($fh) or die "close $path: $!\n";
   return $path;
}

my $before=fixture('01_before.test','parallel',0);
my $serial=fixture('02_serial.test','serial',1);
my $after=fixture('03_after.test','parallel',0);
my $runner=File::Spec->catfile($Bin,'test.pl');
my $cwd=getcwd();
chdir($Bin) or die "chdir $Bin: $!\n";
my $rc=system($^X,$runner,'--jobs','3','--e2e-only',$before,$serial,$after);
chdir($cwd) or die "restore cwd: $!\n";
$rc==0 or die "nested serial runner failed: $rc\n";
print "runner serial scheduling ok\n";
