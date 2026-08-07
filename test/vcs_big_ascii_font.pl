#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_big_ascii_font ok: 95 distinct 8x16 ASCII glyphs link as one 1520-byte non-page-contained ROM table
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($?>>8,$?&127,$so,$se);
}
sub read_file {
   my($path)=@_; open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $text=<$fh>; close($fh); return $text // '';
}
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";
my $font=File::Spec->catfile($repo,qw(libraries vcs fonts big_ascii.c26));
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $text=read_file($font);
$text =~ m{\A// Big\n// Characters: printable ASCII from space \(0x20\) through tilde \(0x7E\)\n// This font is covered under CC0-1\.0\. See libraries/LICENSE\.txt\.\n\n}
   or die "big_ascii.c26 has the wrong header\n";
$text =~ /alias\s+VCS_FONT_GLYPH\s*\(a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p\)\s+p,o,n,m,l,k,j,i,h,g,f,e,d,c,b,a/
   or die "big_ascii.c26 does not reverse all sixteen rows correctly\n";
$text =~ /const\s+uint8_t\s+score_font\s*\[\s*1520\s*\]\s*:=/ &&
$text !~ /page\s+const\s+uint8_t\s+score_font/
   or die "big_ascii.c26 must be a 1520-byte non-page-contained table\n";
my @rows=($text =~ /0b([.Xx]{8})/g);
@rows==95*16 or die "big_ascii.c26 has ".scalar(@rows)." visual rows, expected 1520\n";
my(%seen,@bytes);
for my $glyph (0..94) {
   my @g=@rows[$glyph*16..$glyph*16+15];
   my $key=join('/',map { uc($_) } @g);
   exists $seen{$key} and die sprintf("big_ascii.c26 duplicates glyphs 0x%02X and 0x%02X\n",0x20+$seen{$key},0x20+$glyph);
   $seen{$key}=$glyph;
   for my $row (reverse @g) {
      $row =~ tr/.xX/011/;
      push @bytes,oct("0b$row");
   }
}
# Descenders prove row 'o' is data, not a hard-coded zero in the reversal alias.
for my $ch (qw(g j p q y)) {
   my $index=ord($ch)-0x20;
   $rows[$index*16+14] ne '........'
      or die "big_ascii.c26 lost the lower descender row for '$ch'\n";
}
my $src=File::Spec->catfile($tmp,'big_ascii_probe.c26');
my $map=File::Spec->catfile($tmp,'big_ascii_probe.map');
my $bin=File::Spec->catfile($tmp,'big_ascii_probe.bin');
open(my $fh,'>',$src) or die "write $src: $!\n";
print {$fh} <<'C26';
include "vcs.c26"
include "fonts/big_ascii.c26"
uint8_t probe;
void main(void) {
   probe := score_font[0] ^ score_font[1519];
   while (1) {
   }
}
C26
close($fh) or die "close $src: $!\n";
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$map,$src,'-o',$bin);
$rc==0 && !$sig or die "big ASCII probe build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "big ASCII probe wrote output\n$out$err";
-s $bin==4096 or die "big ASCII probe is not a 4K cartridge\n";
my $map_text=read_file($map);
$map_text =~ /^\s+RODATA\.__vcsc_object\$score_font\s+load=\$([0-9A-Fa-f]{4})\s+size=\$05F0\s+page=(?!hard)(\S+)/m
   or die "big ASCII table is not a 1520-byte ordinary ROM object\n";
my $addr=hex($1);
my $rom=read_file($bin);
$addr>=0xF000 && $addr+1520<=0x10000 or die "big ASCII table is outside the 4K image\n";
my @linked=unpack('C1520',substr($rom,$addr-0xF000,1520));
join(',',@linked) eq join(',',@bytes)
   or die "linked big ASCII bytes do not match the sixteen-row source reversal\n";
print "vcs_big_ascii_font ok: 95 distinct 8x16 ASCII glyphs link as one 1520-byte non-page-contained ROM table\n";
