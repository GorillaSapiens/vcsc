#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_ascii_font_alignment ok: 9 contiguous 760-byte ASCII fonts start on 256-byte boundaries and no 8-byte glyph crosses a page
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub capture { my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in); my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0); return ($?>>8,$?&127,$so,$se); }
sub read_file { my($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$fh>; close($fh); return $d // ''; }
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my @fonts=qw(21st_century alarm_clock default handwritten interrupted retroputer tiny whimsey wonk);

for my $font (@fonts) {
   my $src=File::Spec->catfile($tmp,"${font}_ascii_probe.c26");
   my $map=File::Spec->catfile($tmp,"${font}_ascii_probe.map");
   my $bin=File::Spec->catfile($tmp,"${font}_ascii_probe.bin");
   open(my $fh,'>',$src) or die "write $src: $!\n";
   print {$fh} qq{include "vcs.c26"\ninclude "fonts/${font}_ascii.c26"\nuint8_t probe;\nvoid main(void) { probe := score_font[0] ^ score_font[759]; while (1) { } }\n};
   close($fh) or die "close $src: $!\n";
   my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$map,$src,'-o',$bin);
   $rc==0 && !$sig or die "$font ASCII probe build failed\n$out$err";
   without_usage($out) eq '' && $err eq '' or die "$font ASCII probe wrote output\n$out$err";
   my $m=read_file($map);
   $m =~ /^\s+RODATA\.__vcsc_object\$score_font\s+load=\$([0-9A-Fa-f]{4})\s+size=\$02F8\s+page=(?!hard)(\S+).*component-align=\$0100/m
      or die "$font ASCII font is not one aligned 760-byte object\n";
   my $addr=hex($1);
   ($addr & 0xff)==0 or die sprintf("%s ASCII font starts at %04X, not a page boundary\n",$font,$addr);
   for my $glyph (0..94) {
      my $start=$addr+$glyph*8;
      (($start & 0xff)+7)<256 or die sprintf("%s glyph 0x%02X crosses a hardware page\n",$font,0x20+$glyph);
   }
}
print "vcs_ascii_font_alignment ok: 9 contiguous 760-byte ASCII fonts start on 256-byte boundaries and no 8-byte glyph crosses a page\n";
