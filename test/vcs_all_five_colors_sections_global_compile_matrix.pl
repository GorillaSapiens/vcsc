#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 240
# expectstdout: global compile matrix ok
# expectexit: 0

use strict;
use warnings;
use File::Path qw(make_path);
my($repo,$tmp,$only_profile)=@ARGV;
my@profiles=$only_profile?($only_profile):qw(fine_global_compile fine_global_procedures_compile);
$only_profile eq 'fine_global_static_compile' or die 'unknown matrix profile' if$only_profile;
srand(192733);
for my$case(0..31){my@seams=sort{$a<=>$b}map{2+2*int(rand(95))}1..7;my(@h,$previous);$previous=0;
   for(@seams,192){push@h,$_-$previous;$previous=$_;}
   for my$profile(@profiles){
      my$dir="$tmp/${profile}_$case";make_path($dir);
      open(my$pipe,'-|',$^X,"$repo/test/vcs_all_five_colors_sections_probe.pl",$repo,$dir,$profile,0,16,join(',',@h))or die$!;
      local$/;my$result=<$pipe>;close$pipe or die "compile matrix geometry ".join(',',@h)." failed\n";
      $result eq "vcs_all_five_colors_sections_probe ok\n" or die 'compile matrix output';
   }
}
print "global compile matrix ok\n";
