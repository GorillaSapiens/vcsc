#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: vcs font contracts ok: 8 ASCII families, distinct glyphs, matched source styles, and unchanged logo pixels
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Spec;

sub read_file {
   my($path)=@_;
   open(my $fh,'<',$path) or die "read $path: $!\n";
   local $/;
   my $text=<$fh>;
   close($fh);
   return $text // '';
}

sub glyphs {
   my($path,$expected)=@_;
   my $text=read_file($path);
   my @rows=($text =~ /0b([.Xx]{8})/g);
   @rows==$expected*8
      or die "$path has ".scalar(@rows)." visual rows, expected ".($expected*8)."\n";
   my @glyphs;
   while (@rows) {
      my @one=splice(@rows,0,8);
      tr/x/X/ for @one;
      push @glyphs,\@one;
   }
   return ($text,\@glyphs);
}

sub key {
   my($glyph)=@_;
   return join('/',@$glyph);
}

sub same_glyph {
   my($left,$right,$label)=@_;
   key($left) eq key($right) or die "$label does not match its source-family glyph\n";
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO\n");
my $fonts=File::Spec->catdir($repo,qw(libraries vcs fonts));
my @families=(
   ['21st_century','21st Century'],
   ['alarm_clock','Alarm Clock'],
   ['default','Default'],
   ['handwritten','Handwritten'],
   ['interrupted','Interrupted'],
   ['retroputer','Retroputer'],
   ['tiny','Tiny'],
   ['whimsey','Whimsey'],
);
my $license_line='// This font is covered under CC0-1.0. See libraries/LICENSE.txt.';

my $license=read_file(File::Spec->catfile($repo,qw(libraries LICENSE.txt)));
$license =~ /\ACC0 1\.0 Universal License\s*\n/
   or die "libraries/LICENSE.txt is not the CC0-1.0 text\n";
$license =~ /4\. Limitations and Disclaimers\./ && $license =~ /use of the Work\.\s*\z/
   or die "libraries/LICENSE.txt is incomplete\n";

for my $family (@families) {
   my($base,$display)=@$family;
   my $ascii_path=File::Spec->catfile($fonts,"${base}_ascii.c26");
   my $decimal_path=File::Spec->catfile($fonts,"${base}_decimal.c26");
   my $hex_path=File::Spec->catfile($fonts,"${base}_hex.c26");
   my($ascii_text,$ascii)=glyphs($ascii_path,95);
   my($decimal_text,$decimal)=glyphs($decimal_path,10);
   my($hex_text,$hex)=glyphs($hex_path,16);

   my @headers=(
      [$ascii_text,"// $display\n// Characters: printable ASCII from space (0x20) through tilde (0x7E)\n$license_line\n\n"],
      [$decimal_text,"// $display\n// Characters: 0-9\n$license_line\n\n"],
      [$hex_text,"// $display\n// Characters: 0-9 and A-F\n$license_line\n\n"],
   );
   for my $header (@headers) {
      index($header->[0],$header->[1])==0
         or die "$base font has the wrong leading comment\n";
   }

   my %seen;
   for my $i (0..$#$ascii) {
      my $k=key($ascii->[$i]);
      if (exists $seen{$k}) {
         my $a=chr(0x20+$seen{$k});
         my $b=chr(0x20+$i);
         die "$ascii_path has identical glyphs '$a' and '$b'\n";
      }
      $seen{$k}=$i;
   }

   for my $digit (0..9) {
      same_glyph($ascii->[ord('0')-0x20+$digit],$decimal->[$digit],
         "$base ASCII digit $digit");
      same_glyph($ascii->[ord('0')-0x20+$digit],$hex->[$digit],
         "$base ASCII/hex digit $digit");
   }
   for my $letter (0..5) {
      same_glyph($ascii->[ord('A')-0x20+$letter],$hex->[10+$letter],
         "$base ASCII letter ".chr(ord('A')+$letter));
   }

   my @reference=(@$decimal,@$hex);
   my @empty_rows=grep {
      my $row=$_;
      !grep { $_->[$row] ne '........' } @reference;
   } 0..7;
   my @empty_columns=grep {
      my $column=$_;
      !grep {
         my $glyph=$_;
         grep { substr($_,$column,1) ne '.' } @$glyph;
      } @reference;
   } 0..7;

   for my $index (0..$#$ascii) {
      my $glyph=$ascii->[$index];
      my $char=chr(0x20+$index);
      for my $row (@empty_rows) {
         $glyph->[$row] eq '........'
            or die "$ascii_path glyph '$char' violates blank row $row\n";
      }
      for my $column (@empty_columns) {
         !grep { substr($_,$column,1) ne '.' } @$glyph
            or die "$ascii_path glyph '$char' violates blank column $column\n";
      }
   }
}

my $logo_path=File::Spec->catfile($fonts,'logo_font.c26');
my($logo_text,$logo)=glyphs($logo_path,6);
my $logo_header="// VCSC logo\n// Characters: six consecutive logo slices numbered 0-5\n$license_line\n\n";
index($logo_text,$logo_header)==0 or die "logo font has the wrong leading comment\n";
my $logo_rows=join("\n",map {@$_} @$logo);
sha256_hex($logo_rows) eq 'eb79c068605cc8e84250651de1067b579c6b673af7265120098790e070c40e6a'
   or die "logo_font.c26 glyph pixels changed\n";

print "vcs font contracts ok: 8 ASCII families, distinct glyphs, matched source styles, and unchanged logo pixels\n";
