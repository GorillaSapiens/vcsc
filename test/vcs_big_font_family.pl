#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_big_font_family ok: decimal, upper hex, and lower hex are exact 16-row subsets of big ASCII and stay page-contained
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub read_file {
   my($path)=@_; open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $text=<$fh>; close($fh); return $text // '';
}
sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($?>>8,$?&127,$so,$se);
}
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }
sub rows {
   my($path,$glyphs)=@_;
   my $text=read_file($path);
   my @rows=($text =~ /0b([.Xx]{8})/g);
   @rows==$glyphs*16 or die "$path has ".scalar(@rows)." rows, expected ".($glyphs*16)."\n";
   return ($text,\@rows);
}
sub glyph_key {
   my($rows,$index)=@_;
   return join('/',map { uc($_) } @$rows[$index*16..$index*16+15]);
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve tmp\n";
my $fonts=File::Spec->catdir($repo,qw(libraries vcs fonts));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my($ascii_text,$ascii)=rows(File::Spec->catfile($fonts,'big_ascii.c26'),95);
my($dec_text,$dec)=rows(File::Spec->catfile($fonts,'big_decimal.c26'),10);
my($hex_text,$hex)=rows(File::Spec->catfile($fonts,'big_hex.c26'),16);
my($lhex_text,$lhex)=rows(File::Spec->catfile($fonts,'big_lhex.c26'),16);

$dec_text =~ m{\A// Big \(subset\)\n// Characters: 0-9\n// This font is covered under CC0-1\.0\. See libraries/LICENSE\.txt\.\n// Generated from big_ascii\.c26\.\n\n}
   or die "big_decimal.c26 has the wrong header\n";
$hex_text =~ m{\A// Big \(subset\)\n// Characters: 0-9 and A-F\n// This font is covered under CC0-1\.0\. See libraries/LICENSE\.txt\.\n// Generated from big_ascii\.c26\.\n\n}
   or die "big_hex.c26 has the wrong header\n";
$lhex_text =~ m{\A// Big \(subset\)\n// Characters: 0-9 and a-f\n// This font is covered under CC0-1\.0\. See libraries/LICENSE\.txt\.\n// Generated from big_ascii\.c26\.\n\n}
   or die "big_lhex.c26 has the wrong header\n";
for my $spec ([$dec_text,160,'decimal'],[$hex_text,256,'hex'],[$lhex_text,256,'lower hex']) {
   my($text,$size,$name)=@$spec;
   $text =~ /alias\s+VCS_FONT_GLYPH\s*\(a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p\)\s+p,o,n,m,l,k,j,i,h,g,f,e,d,c,b,a/
      or die "big $name lost the 16-row reversal alias\n";
   $text =~ /page\s+const\s+uint8_t\s+score_font\s*\[\s*\Q$size\E\s*\]\s*:=/
      or die "big $name is not a page-contained $size-byte table\n";
}
for my $digit (0..9) {
   glyph_key($dec,$digit) eq glyph_key($ascii,ord('0')-0x20+$digit)
      or die "big decimal digit $digit differs from big ASCII\n";
   glyph_key($hex,$digit) eq glyph_key($ascii,ord('0')-0x20+$digit)
      or die "big hex digit $digit differs from big ASCII\n";
   glyph_key($lhex,$digit) eq glyph_key($ascii,ord('0')-0x20+$digit)
      or die "big lower-hex digit $digit differs from big ASCII\n";
}
for my $letter (0..5) {
   glyph_key($hex,10+$letter) eq glyph_key($ascii,ord('A')-0x20+$letter)
      or die "big hex letter ".chr(ord('A')+$letter)." differs from big ASCII\n";
   glyph_key($lhex,10+$letter) eq glyph_key($ascii,ord('a')-0x20+$letter)
      or die "big lower-hex letter ".chr(ord('a')+$letter)." differs from big ASCII\n";
}

for my $variant (['decimal',160],['hex',256],['lhex',256]) {
   my($name,$size)=@$variant;
   my $src=File::Spec->catfile($tmp,"big_${name}_probe.c26");
   my $map=File::Spec->catfile($tmp,"big_${name}_probe.map");
   my $bin=File::Spec->catfile($tmp,"big_${name}_probe.bin");
   open(my $fh,'>',$src) or die "write $src: $!\n";
   print {$fh} qq{include "vcs.c26"\n};
   print {$fh} qq{include "fonts/big_${name}.c26"\n};
   print {$fh} qq{uint8_t probe;\n};
   print {$fh} "void main(void) {\n";
   print {$fh} "   probe := score_font[0] ^ score_font[".($size-1)."];\n";
   print {$fh} "   while (1) {\n   }\n}\n";
   close($fh) or die "close $src: $!\n";
   my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$map,$src,'-o',$bin);
   $rc==0 && !$sig or die "big $name probe failed\n$out$err";
   without_usage($out) eq '' && $err eq '' or die "big $name probe wrote output\n$out$err";
   my $map_text=read_file($map);
   my $hexsize=sprintf('%04X',$size);
   $map_text =~ /^\s+RODATA\.__vcsc_object\$score_font\s+load=\$([0-9A-Fa-f]{4})\s+size=\$\Q$hexsize\E\s+page=hard\b/m
      or die "big $name linked table does not have expected size/page containment\n";
   my $addr=hex($1);
   (($addr & 0xff)+$size-1)<=0xff or die "big $name table crosses a hardware page\n";
}

print "vcs_big_font_family ok: decimal, upper hex, and lower hex are exact 16-row subsets of big ASCII and stay page-contained\n";
