#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: runner process group cleanup ok
# expectexit: 0
use strict;
use warnings;
use File::Spec;
use Time::HiRes qw(sleep);
my($repo,$tmp)=@ARGV;
my$helper=File::Spec->catfile($tmp,'helper.pl');
my$marker=File::Spec->catfile($tmp,'leaked');
open(my$f,'>',$helper) or die$!;
print{$f} <<'HELPER';
use strict;
use warnings;
$SIG{TERM}='IGNORE';
my$p=fork();defined$p or die$!;
if(!$p) {
   select undef,undef,undef,4;
   open(my$f,'>',$ARGV[0]) or die$!;
   print{$f}"leaked";
   exit 0;
}
select undef,undef,undef,20;
HELPER
close$f;
my$fixture=File::Spec->catfile($tmp,'timeout.test');
open($f,'>',$fixture) or die$!;
print{$f}"# runner: perl $helper $marker\n# phase: e2e\n# timeout: 2\n# expectexit: 0\n";
close$f;
open(my$pipe,'-|',$^X,"$repo/test/test.pl",'--e2e-only','--jobs','2','--timings','0',$fixture) or die$!;
my$output=do { local$/; <$pipe> };close$pipe;
($?>>8)==1 && $output =~ /command timed out/ or die "nested timeout was not reported: $output";
sleep 2.3;
!-e$marker or die 'runner timeout left a grandchild running';
print "runner process group cleanup ok\n";
