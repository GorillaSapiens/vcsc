#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: Stella snapshot deadlines ok
# expectexit: 0
use strict;
use warnings;
use Time::HiRes qw(time sleep);
my($repo,$tmp)=@ARGV;
require "$repo/test/stella_test_lib.pl";
sub write_snapshot {
   my($name)=@_;
   open(my$f,'>',"$tmp/$name.png") or die$!;
   print{$f}"fixture";close$f;
}
write_snapshot('ready');
my$start=time();
my@found=vcsc_stella_wait_snapshots("$tmp/ready*.png",1);
@found==1 && time()-$start<5 or die 'ready snapshot did not return promptly';
open(my$empty,'>',"$tmp/delayed_empty.png") or die$!;close$empty;
my$p=fork();defined$p or die$!;
if(!$p) { sleep .3;write_snapshot('delayed_1');sleep .3;write_snapshot('delayed_2');exit 0; }
$start=time();
@found=vcsc_stella_wait_snapshots("$tmp/delayed*.png",2,10);
waitpid($p,0);
@found==2 && time()-$start>=.5 or die 'wait returned before all nonempty snapshots existed';
$start=time();
@found=vcsc_stella_wait_snapshots("$tmp/missing*.png",1,.2);
!@found && time()-$start>=.18 && time()-$start<5 or die 'missing snapshot deadline ignored';
@found=vcsc_stella_wait_snapshots("$tmp/delayed*.png",1);
@found==2 or die 'unexpected extra snapshots were hidden';
print "Stella snapshot deadlines ok\n";
