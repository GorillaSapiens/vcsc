#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.

use strict;
use warnings;
use File::Basename qw(basename);

@ARGV=('standard_4k_ntsc_macros.inc','standard_4k_ntsc_renderer.s26') if !@ARGV;
my %unofficial=map { $_=>1 } qw(ASR DCP LAX SBX);
my %branch=map { $_=>1 } qw(BCC BCS BEQ BMI BNE BPL BVC BVS);
my %read=map { $_=>1 } qw(ADC AND BIT CMP CPX CPY EOR LDA LAX LDX LDY ORA SBC);

print "# This file is covered under CC0-1.0. See libraries/LICENSE.txt.\n";
print "file\tline\tkind\topcode\toperand\tpurpose\n";
for my $path (@ARGV) {
   open(my $fh,'<',$path) or die "could not open $path: $!\n";
   my $file=basename($path);
   my $line_no=0;
   while (my $raw=<$fh>) {
      ++$line_no;
      chomp $raw;
      my $code=$raw;
      $code =~ s/;.*$//;
      $code =~ s/^\s+|\s+$//g;
      next if $code eq '';

      if ($code =~ /^\.segment\s+"([^"]+)"/i) {
         print join("\t",$file,$line_no,'segment','.segment',$1,'linker placement range'),"\n";
         next;
      }
      if ($code =~ /^\.align\s+(.+)$/i) {
         print join("\t",$file,$line_no,'alignment','.align',$1,'page or offset anchor affecting timing placement'),"\n";
         next;
      }
      if ($code =~ /^SLEEP\s+(.+)$/i) {
         print join("\t",$file,$line_no,'padding','SLEEP',$1,'explicit cycle padding available for retiming'),"\n";
         next;
      }
      if ($code =~ /^([A-Za-z][A-Za-z0-9]*)(?:\.([A-Za-z]+))?(?:\s+(.*))?$/) {
         my ($op,$suffix,$operand)=(uc($1),defined($2)?lc($2):'',defined($3)?$3:'');
         $operand =~ s/^\s+|\s+$//g;
         if ($branch{$op}) {
            print join("\t",$file,$line_no,'relative_branch',$op,$operand,'taken branch gains one cycle if source and target pages differ'),"\n";
         }
         if ($read{$op} && $operand =~ /(?:,\s*[XY]\b|\)\s*,\s*Y\b)/i) {
            my $purpose=$operand =~ /^\(/ ?
               'indexed indirect read gains one cycle when effective address crosses a page' :
               'indexed read may gain one cycle when effective address crosses a page';
            print join("\t",$file,$line_no,'indexed_read',$op,$operand,$purpose),"\n";
         }
         if ($operand =~ /^\([^)]*\)\s*,\s*Y\b/i) {
            print join("\t",$file,$line_no,'indirect_pointer',$op,$operand,'zero-page pointer and indexed target range are page-sensitive'),"\n";
         }
         if ($unofficial{$op}) {
            my $purpose =
               $op eq 'DCP' ? 'decrement vertical object counter and compare in one five-cycle instruction' :
               $op eq 'SBX' ? 'advance the zero-based playfield byte offset by four in two cycles' :
               $op eq 'ASR' ? 'shift/mask score nibble while preserving the retained pointer-setup timing' :
               $operand =~ /^\(/ ? 'load score glyph byte into A and X in one indexed instruction' :
               'load score byte into A and X for glyph-pointer setup';
            print join("\t",$file,$line_no,'unofficial_opcode',$op,$operand,$purpose),"\n";
         }
         if ($op eq 'NOP' && $suffix eq 'z') {
            print join("\t",$file,$line_no,'unofficial_opcode','NOP.z',$operand,'three-cycle zero-page delay NOP used by odd SLEEP durations'),"\n";
         } elsif ($op eq 'NOP') {
            print join("\t",$file,$line_no,'padding','NOP',$operand,'explicit legal one-byte two-cycle padding'),"\n";
         }
      }
   }
   close($fh) or die "could not close $path: $!\n";
}
