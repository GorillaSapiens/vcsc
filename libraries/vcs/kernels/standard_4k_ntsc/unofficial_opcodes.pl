#!/usr/bin/perl
use strict;
use warnings;
use File::Basename qw(basename);

@ARGV=('standard_4k_ntsc_macros.inc','standard_4k_ntsc_kernel.s') if !@ARGV;

my %forms=(
   'ASR:imm' => [ '$4B', 2, 2, 'none',          'stable/common' ],
   'DCP:zp'  => [ '$C7', 2, 5, 'none',          'stable/common' ],
   'LAX:zp'  => [ '$A7', 2, 3, 'none',          'stable/common' ],
   'LAX:indy'=> [ '$B3', 2, 5, '+1 on crossing','stable/common' ],
   'SBX:imm' => [ '$CB', 2, 2, 'none',          'stable/common' ],
   'NOP.z:zp'=> [ '$04', 2, 3, 'none',          'stable/common' ],
);

print "file\tline\tmnemonic\tmode\topcode\tbytes\tbase_cycles\tpage_penalty\tclassification\tpurpose\n";
for my $path (@ARGV) {
   open(my $fh,'<',$path) or die "could not open $path: $!\n";
   my $file=basename($path);
   my $line=0;
   while (my $raw=<$fh>) {
      ++$line;
      my $code=$raw;
      $code =~ s/;.*$//;
      $code =~ s/^\s+|\s+$//g;
      next if $code eq '';
      next unless $code =~ /^(ASR|DCP|LAX|SBX|NOP\.z)\b(?:\s+(.*))?$/i;
      my $mn=uc($1);
      $mn='NOP.z' if $mn eq 'NOP.Z';
      my $operand=defined($2)?$2:'';
      $operand =~ s/^\s+|\s+$//g;
      my $mode = $mn eq 'LAX' && $operand =~ /^\([^)]*\)\s*,\s*Y$/i ? 'indy' :
                 $mn eq 'ASR' || $mn eq 'SBX' ? 'imm' : 'zp';
      my $key="$mn:$mode";
      exists($forms{$key}) or die "$file:$line: unclassified unofficial form $key ($operand)\n";
      my ($opcode,$bytes,$cycles,$penalty,$class)=@{$forms{$key}};
      my $purpose =
         $mn eq 'DCP' ? 'decrement vertical object counter and compare in one read-modify-write instruction' :
         $mn eq 'SBX' ? 'advance the zero-based playfield byte offset by four' :
         $mn eq 'ASR' ? 'mask and shift the upper score nibble' :
         $mn eq 'NOP.z' ? 'provide an exact three-cycle zero-page delay for odd SLEEP durations' :
         $mode eq 'indy' ? 'load a score glyph byte into A and X' :
         'load a packed score byte into A and X for pointer setup';
      print join("\t",$file,$line,$mn,$mode,$opcode,$bytes,$cycles,$penalty,$class,$purpose),"\n";
   }
   close($fh) or die "could not close $path: $!\n";
}
