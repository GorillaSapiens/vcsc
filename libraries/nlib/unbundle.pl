#!/usr/bin/perl

`mkdir -p wrk`;
`cp nlib.inc wrk`;
foreach $file (`ls asm/*.asm`) {
   $file =~ s/[\x0a\x0d]//g;

   print "== $file\n";
   open FILE, $file;
   @file = <FILE>;
   close FILE;

   @head = ();
   @constants = ();
   $mode = 0;
   foreach $line (@file) {
      if ($line =~ /^[^;]*\.def/i) {
         push @constants, $line;
      }

      if ($line =~ /^[a-zA-Z0-9_]+:/) {
         print "WARN: $line";
      }

      if ($line =~ /^\.include/) {
         $mode = 1;
      }
      elsif ($mode == 0) {
         push @head, $line;
      }
      elsif ($line =~ /^\.proc/) {
         @import = ();
         @func = ();
         push @func, $line;
      }
      elsif ($line =~ /^\.endproc/) {
         push @func, $line;

         $tmp = $func[0];
         $tmp =~ s/^\.proc//g;
         $tmp =~ s/[\s]//g;

         print "--- $tmp.s\n";
         open FILE, ">wrk/$tmp.s";
         print FILE ";;; $tmp wrk from $file\n";
         print FILE @head;
         print FILE ".export $tmp\n";
         print FILE "\n";
         if ($#import >= 0) {
            print FILE ".import " . join(", ", @import) . "\n";
            print FILE "\n";
         }
         print FILE ".include \"../nlib.inc\"\n";
         foreach $constant (@constants) {
            print FILE $constant;
         }
         print FILE "\n";
         print FILE @func;
         close FILE;
      }
      else {
         if ($line =~ /jsr/ || $line =~ /jmp/ || $line =~ /lda[\s]+#[<>]/ ) {
            $tmp = $line;
            $tmp =~ s/[\x0a\x0d]//g;
            $tmp =~ s/;.*//g;
            $tmp =~ s/jsr//g;
            $tmp =~ s/jmp//g;
            $tmp =~ s/lda[\s]+#[<>]//g;
            $tmp =~ s/[\s]//g;

            if (!($tmp =~ /[\(\@]/) && $tmp =~ /[a-zA-Z]/) {
               push @import, $tmp;
            }
         }

         push @func, $line;
      }
   }
}
