#!/usr/bin/perl

$mode = 0;
open FILE, "lexer.l";
while (<FILE>) {
   if (/^\%\%/) {
      $mode++;
   }
   elsif ($mode == 1) {
      if (/^\"/) {
         $tmp = $_;
         $tmp =~ s/^\"([^"]*)\"[\s]*return[\s]*([^;]*);/$a=$1,$b=$2/ge;
         $map{$b} = $a;
      }
   }
}
close FILE;

@keys = sort {
   length($b) <=> length($a) || $a cmp $b
} keys(%map);

foreach $key (@keys) {
   print "\"$key\", \"'$map{$key}'\",\n";
}
