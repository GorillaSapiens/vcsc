#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: compile
# expectexit: 0
use strict;
use warnings;
use File::Find qw(find);
use File::Spec;

@ARGV==2 or die "usage: $0 REPO TMP\n";
my($repo,$tmp)=@ARGV;
my$examples=File::Spec->catdir($repo,'examples');
my@makefiles;
find(sub { push @makefiles,$File::Find::name if $_ eq 'Makefile' && -f $_; },$examples);
my$launches=0;
for my$path (sort @makefiles) {
   open(my$fh,'<',$path) or die "open $path: $!\n";
   my$line_no=0;
   while(my$line=<$fh>) {
      ++$line_no;
      next unless $line =~ /^\s*stella\s/;
      ++$launches;
      index($line,'-userdir "$(CURDIR)"')>=0
         or die "$path:$line_no Stella play launch lacks example-local -userdir\n";
      my$count=()=$line =~ /\$\(CURDIR\)/g;
      $count>=2
         or die "$path:$line_no Stella play launch does not pass an absolute example ROM path\n";
      $line !~ /(?:^|\s)\*\.bin(?:\s|$)/
         or die "$path:$line_no Stella play launch still passes a cwd-relative ROM glob\n";
      $line !~ /\s\$\(TARGET\)(?:\s|;|$)/
         or die "$path:$line_no Stella play launch still passes cwd-relative TARGET\n";
      $line !~ /\s"\$\$bin"(?:\s|;)/
         or die "$path:$line_no Stella play loop still passes a cwd-relative ROM path\n";
   }
   close$fh;
}
$launches>=100 or die "unexpectedly found only $launches example Stella play launches\n";

my$ode=File::Spec->catfile($examples,qw(01_basics ode_to_joy Makefile));
open(my$of,'<',$ode) or die "open $ode: $!\n"; local$/; my$ot=<$of>; close$of;
index($ot,'stella -userdir "$(CURDIR)" "$(CURDIR)"/*.bin')>=0
   or die "Ode to Joy play target is not pinned to its example directory\n";

print "example Stella play path contract passed ($launches launches)\n";
