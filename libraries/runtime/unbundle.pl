#!/usr/bin/env perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.

use strict;
use warnings;

mkdir 'wrk' unless -d 'wrk';
system('cp', 'vcsc-runtime.inc', 'wrk') == 0 or die "could not copy vcsc-runtime.inc\n";

my %workspace_alias = (
   arg0 => '_vcsc_arg0',
   arg1 => '_vcsc_arg1',
   ptr0 => '_vcsc_ptr0',
   ptr1 => '_vcsc_ptr1',
   ptr2 => '_vcsc_ptr2',
);

sub workspace_imports_for {
   my ($lines, $aliases) = @_;
   my %imports;
   for my $line (@$lines) {
      $line =~ s/;.*//;
      while ($line =~ /([A-Za-z_][A-Za-z0-9_]*)/g) {
         my $token = $1;
         if (exists $aliases->{$token}) {
            $imports{$aliases->{$token}} = 1;
         }
         elsif ($token =~ /^_vcsc_(?:arg[01]|ptr[0-2])$/) {
            $imports{$token} = 1;
         }
      }
   }
   return sort keys %imports;
}

for my $file (sort glob('asm/*.asm')) {
   print "== $file\n";
   open(my $in, '<', $file) or die "cannot open $file: $!\n";
   my @file = <$in>;
   close($in) or die "cannot close $file: $!\n";

   my @head;
   my @constants;
   my $mode = 0;
   my @func;
   my @imports;
   my %aliases = %workspace_alias;

   for my $line (@file) {
      if ($line =~ /^\s*\.def\s+([A-Za-z_][A-Za-z0-9_]*)\s+(_vcsc_(?:arg[01]|ptr[0-2]))(?:\s*\+\s*\d+)?/i) {
         $aliases{$1} = $2;
      }
      if ($line =~ /^[^;]*\.def/i) {
         push @constants, $line;
      }
      if ($line =~ /^[A-Za-z0-9_]+:/) {
         print "WARN: $line";
      }

      if ($line =~ /^\.include/) {
         $mode = 1;
      }
      elsif ($mode == 0) {
         push @head, $line;
      }
      elsif ($line =~ /^\.proc/) {
         @imports = ();
         @func = ($line);
      }
      elsif ($line =~ /^\.endproc/) {
         push @func, $line;

         my $name = $func[0];
         $name =~ s/^\.proc//;
         $name =~ s/\s//g;

         print "--- $name.s26\n";
         open(my $out, '>', "wrk/$name.s26") or die "cannot create wrk/$name.s26: $!\n";
         print {$out} ";;; $name wrk from $file\n";
         print {$out} @head;
         print {$out} ".export $name\n\n";
         if (@imports) {
            my %seen;
            my @unique = grep { !$seen{$_}++ } @imports;
            print {$out} ".import " . join(', ', @unique) . "\n\n";
         }
         my @zpimports = workspace_imports_for(\@func, \%aliases);
         if (@zpimports) {
            print {$out} ".importzp " . join(', ', @zpimports) . "\n\n";
         }
         print {$out} ".include \"../vcsc-runtime.inc\"\n";
         print {$out} @constants;
         print {$out} "\n";
         print {$out} @func;
         close($out) or die "cannot close wrk/$name.s26: $!\n";
      }
      else {
         if ($line =~ /jsr/ || $line =~ /jmp/ || $line =~ /lda\s+#[<>]/) {
            my $target = $line;
            $target =~ s/[\x0a\x0d]//g;
            $target =~ s/;.*//g;
            $target =~ s/jsr//g;
            $target =~ s/jmp//g;
            $target =~ s/lda\s+#[<>]//g;
            $target =~ s/\s//g;
            if ($target !~ /[\(\@]/ && $target =~ /[A-Za-z]/) {
               push @imports, $target;
            }
         }
         push @func, $line;
      }
   }
}
