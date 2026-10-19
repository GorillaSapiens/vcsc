#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: diagnostic subprocess timeouts ok
# expectexit: 0
use strict;
use warnings;
use Time::HiRes qw(time sleep);
my($repo,$tmp)=@ARGV;
open(my$f,'<',"$repo/test/vcs_diagnostic_cartridge_stella.pl") or die$!;
local$/;my$source=<$f>;close$f;
$source =~ s/\n\@ARGV==2.*\z//s or die 'diagnostic helper boundary';
eval "package DiagnosticCapture;\n$source";die$@ if$@;
sub capture { return DiagnosticCapture::capture(@_); }
my($rc,$sig,$out,$err)=capture(10,$^X,'-e','print "out";warn "err\n";exit 7');
$rc==7&&$sig==0&&$out eq'out'&&$err eq"err\n" or die 'capture lost status/output';
my$start=time();
($rc,$sig,$out,$err)=capture(10,$^X,'-e','select undef,undef,undef,.25;print "finished"');
$rc==0&&$sig==0&&$out eq'finished'&&time()-$start>=.2 or die 'longer command budget ignored';
my$marker="$tmp/surviving-grandchild";
my$child=<<'PERL';
$|=1; print "partial stdout\n"; warn "partial stderr\n";
my$p=fork();defined$p or die$!;
if(!$p){$SIG{TERM}='IGNORE';select undef,undef,undef,4;open(my$f,'>',$ARGV[0]) or die$!;print{$f}"leaked";exit 0;}
$SIG{TERM}='IGNORE';select undef,undef,undef,20;
PERL
$start=time();eval { capture(2,$^X,'-e',$child,$marker); };
my$failure=$@;
$failure =~ /command timed out after 2 seconds/ &&
   $failure =~ /partial stdout/ && $failure =~ /partial stderr/
   or die "timeout lost diagnostics: $failure";
time()-$start<8 or die 'timeout did not bound a hung command';
sleep 2.2;
!-e$marker or die 'timed-out compiler grandchild survived process-group cleanup';
$source =~ /sub ok \{ return ok_timeout\(45,\@_\); \}/ &&
   do { open(my$f,'<',"$repo/test/vcs_diagnostic_cartridge_stella.pl") or die$!;
        my$all=<$f>;close$f;
        $all =~ /VCSC_DIAGNOSTIC_BUILD_TIMEOUT\}\/\/180/ &&
        $all =~ /ok_timeout\(\$build_timeout,"build \$name diagnostic"/ }
   or die 'build and digest timeout policies are not separate';
print "diagnostic subprocess timeouts ok\n";
