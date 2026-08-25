#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_half_ascii_font ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local$/; return <$fh> // ''; }
sub capture {
   my(@cmd)=@_; my$err=gensym; my$pid=open3(my$in,my$out,$err,@cmd); close($in);
   my$so=slurp_fh($out); my$se=slurp_fh($err); waitpid($pid,0);
   return($?>>8,$?&127,$so,$se);
}
sub read_file {
   my($p)=@_; open(my$fh,'<:raw',$p) or die "read $p: $!\n";
   local$/; my$d=<$fh>; close($fh); return $d // '';
}
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }

my$repo=abs_path(shift@ARGV // usage());
my$tmp=shift@ARGV // usage(); usage() if@ARGV;
make_path($tmp); $tmp=abs_path($tmp) // die "resolve tmp\n";
my$fonts=File::Spec->catdir($repo,qw(libraries vcs fonts));
my$font=File::Spec->catfile($fonts,'half_ascii.c26');
my$decimal=File::Spec->catfile($fonts,'half_decimal.c26');
my$hex=File::Spec->catfile($fonts,'half_hex.c26');
my$lhex=File::Spec->catfile($fonts,'half_lhex.c26');
my$helper=File::Spec->catfile($fonts,'make_pair_font.pl');
my$driver=File::Spec->catfile($repo,qw(driver vcsc));
my$vcs=File::Spec->catdir($repo,qw(libraries vcs));

-f$font or die "missing half_ascii.c26\n";
-f$helper or die "missing make_pair_font.pl\n";
-x$helper or die "make_pair_font.pl is not executable\n";
my$text=read_file($font);
$text =~ /CC0-1\.0/ or die "half_ascii.c26 lost CC0 provenance\n";
$text =~ /align\s*\(\s*256\s*\)\s+const\s+uint8_t\s+score_font\s*\[\s*570\s*\]\s*:=/
   or die "half_ascii.c26 is not one aligned 570-byte table\n";
my@rows=$text =~ /0b([.X]{4})/g;
@rows==95*6 or die "half_ascii.c26 has ".scalar(@rows)." rows, expected 570\n";
grep(substr($_,0,1) ne '.',@rows)==0
   or die "half_ascii.c26 lost its blank high source bit\n";
my@glyph_headers=$text =~ /^\s*\/\/\s+0x([0-9A-Fa-f]{2})\b/mg;
@glyph_headers==95 or die "half_ascii.c26 has ".scalar(@glyph_headers)." glyph headers, expected 95\n";
for my$i(0..94) {
   hex($glyph_headers[$i])==0x20+$i
      or die sprintf("half_ascii.c26 glyph order changed at 0x%02X\n",0x20+$i);
}

my@ascii_glyphs;
for my$i(0..94) {
   push @ascii_glyphs,join('/',@rows[$i*6..$i*6+5]);
}
for my$spec (
   [$decimal, [ '0'..'9' ], '0-9', 60],
   [$hex, [ '0'..'9','A'..'F' ], '0-9 and A-F', 96],
   [$lhex, [ '0'..'9','a'..'f' ], '0-9 and a-f', 96],
) {
   my($path,$chars,$desc,$size)=@$spec;
   -f$path or die "missing $path\n";
   my$subset=read_file($path);
   $subset =~ m{\A// 4x6 \(subset\)\n} or die "$path lost its subset title\n";
   $subset =~ /^\/\/ Characters: \Q$desc\E$/m or die "$path has the wrong Characters line\n";
   $subset =~ /^\/\/ Generated from half_ascii\.c26\.$/m or die "$path lost its source provenance\n";
   $subset =~ /page\s+const\s+uint8_t\s+score_font\s*\[\s*\Q$size\E\s*\]\s*:=/
      or die "$path is not a page-contained $size-byte table\n";
   my@subset_rows=$subset =~ /0b([.X]{4})/g;
   @subset_rows==@$chars*6 or die "$path has ".scalar(@subset_rows)." rows, expected ".(@$chars*6)."\n";
   for my$i(0..$#$chars) {
      my$key=join('/',@subset_rows[$i*6..$i*6+5]);
      $key eq $ascii_glyphs[ord($chars->[$i])-0x20]
         or die "$path glyph $chars->[$i] differs from half_ascii.c26\n";
   }
}

# The source font itself must compile and remain addressable through its last byte.
my$probe=File::Spec->catfile($tmp,'half_ascii_probe.c26');
my$bin=File::Spec->catfile($tmp,'half_ascii_probe.bin');
open(my$fh,'>',$probe) or die "write $probe: $!\n";
print {$fh} qq{include "vcs.c26"\ninclude "fonts/half_ascii.c26"\nuint8_t probe;\nvoid main(void) { probe := score_font[0] ^ score_font[569]; while (1) { } }\n};
close($fh) or die "close $probe: $!\n";
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,$probe,'-o',$bin);
$rc==0&&!$sig or die "half_ascii probe build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "half_ascii probe wrote output\n$out$err";

# Pairing must preserve left/right 4-bit rows and space-pad an odd message.
($rc,$sig,$out,$err)=capture($helper,$font,'AB!');
$rc==0&&!$sig or die "make_pair_font failed\n$out$err";
$err eq '' or die "make_pair_font stderr: $err";
$out =~ /const\s+uint8_t\s+message_font\s*\[\s*12\s*\]/
   or die "paired odd message did not produce two 8x6 glyphs\n";
$out =~ /\/\/\s+0:\s+"AB"\s+\(0x41 0x42\)/
   or die "paired first glyph annotation changed\n";
$out =~ /\/\/\s+1:\s+"! "\s+\(0x21 0x20\)/
   or die "paired odd glyph is not space padded\n";
my@paired=$out =~ /0b([.X]{8})/g;
@paired==12 or die "paired output has ".scalar(@paired)." rows, expected 12\n";

my$gen=File::Spec->catfile($tmp,'paired.c26');
open($fh,'>',$gen) or die "write $gen: $!\n"; print {$fh}$out; close($fh);
my$genprobe=File::Spec->catfile($tmp,'paired_probe.c26');
my$genbin=File::Spec->catfile($tmp,'paired_probe.bin');
open($fh,'>',$genprobe) or die "write $genprobe: $!\n";
print {$fh} qq{include "vcs.c26"\ninclude "$gen"\nuint8_t probe;\nvoid main(void) { probe := message_font[0] ^ message_font[11]; while (1) { } }\n};
close($fh);
($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,$genprobe,'-o',$genbin);
$rc==0&&!$sig or die "paired font probe build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "paired font probe wrote output\n$out$err";

print "vcs_half_ascii_font ok\n";
