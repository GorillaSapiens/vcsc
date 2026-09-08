#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: diagnostic non-beam C26 cleanup passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO\n");
die "usage: $0 REPO\n" if @ARGV;
my $src=File::Spec->catfile($repo,qw(examples 19_diagnostic 01_diagnostic vcsc_diagnostic.c26));
open(my $fh,'<',$src) or die "read $src: $!\n";
local $/; my $text=<$fh>; close($fh);

sub function_text {
   my($name)=@_;
   pos($text)=0;
   $text =~ /\b(?:inline\s+)?(?:bank\d+\s+)?void\s+\Q$name\E\s*\([^)]*\)\s*\{/g
      or die "missing $name\n";
   my $start=pos($text)-1;
   my $depth=0;
   for(my $i=$start;$i<length($text);++$i) {
      my $ch=substr($text,$i,1);
      ++$depth if $ch eq '{';
      if($ch eq '}') {
         --$depth;
         return substr($text,$start,$i-$start+1) if $depth==0;
      }
   }
   die "unterminated $name\n";
}

my @ordinary=qw(
   diagnostic_initialize_rows
   diagnostic_update_one_header_row
   diagnostic_update_numeric_detail0
   diagnostic_update_numeric_detail1
   diagnostic_crc24_feed
   diagnostic_audio_tick
);
for my $name (@ordinary) {
   my $body=function_text($name);
   $body !~ /\basm\b/ or die "$name regressed to inline assembly\n";
}

my $crc=function_text('diagnostic_crc24_feed');
$crc =~ /diagnostic_cpu_fingerprint\s*\^=/ &&
$crc =~ /diagnostic_cpu_fingerprint\s*<<=/ &&
$crc =~ /0x864cfb/i
   or die "diagnostic CRC-24 C26 structure changed\n";

my $audio=function_text('diagnostic_audio_tick');
$audio =~ /AUDV0\s*:=\s*diagnostic_audio0\[diagnostic_audio_phase\]/ &&
$audio =~ /AUDV1\s*:=\s*diagnostic_audio1\[diagnostic_audio_phase\]/
   or die "diagnostic audio C26 table cadence changed\n";

print "diagnostic non-beam C26 cleanup passed\n";
