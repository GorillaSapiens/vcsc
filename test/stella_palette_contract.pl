#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: unit
# expectexit: 0
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Spec;
use File::Path qw(make_path);

@ARGV==2 or die "usage: $0 REPO TMP\n";
my($repo,$tmp)=@ARGV;
my$src=File::Spec->catfile($repo,qw(compiler builtin_rgb.c));
my$pal=File::Spec->catfile($repo,qw(test fixtures stella stella.pal));
open(my$sf,'<',$src) or die "open $src: $!\n"; local$/; my$text=<$sf>; close$sf;
open(my$pf,'<:raw',$pal) or die "open $pal: $!\n"; my$data=<$pf>; close$pf;
length($data)==792 or die "stella.pal size is ".length($data).", expected 792\n";
my$out='';
for my$spec (['ntsc_palette',128],['pal_palette',128],['secam_palette',8]) {
   my($name,$want)=@$spec;
   $text =~ /static const BuiltinRgbColor\s+\Q$name\E\[\]\s*=\s*\{(.*?)\n\};/s
      or die "missing $name in compiler/builtin_rgb.c\n";
   my$body=$1;
   my@rows=($body =~ /\{\s*0x([0-9a-fA-F]{2})\s*,\s*0x([0-9a-fA-F]{2})\s*,\s*0x([0-9a-fA-F]{2})\s*,\s*0x([0-9a-fA-F]{2})\s*\}/g);
   @rows==$want*4 or die "$name has ".(@rows/4)." entries, expected $want\n";
   for(my$i=0;$i<@rows;$i+=4) { $out.=pack('C3',map{hex$_}@rows[$i+1..$i+3]); }
}
$out eq $data or die "stella.pal no longer matches compiler NTSC/PAL/SECAM RGB tables\n";
sha256_hex(substr($data,0,384)) eq '1f4da6eea41b163402792852fdacaa2390256c14bbfdc8de91cbf8575bd91e25' or die "NTSC palette digest changed\n";
sha256_hex(substr($data,384,384)) eq 'ce6d0524c3cd587f6cae6468cf9d20e0cc21b2fda454844806128f76e192a7c4' or die "PAL palette digest changed\n";
sha256_hex(substr($data,768,24)) eq 'f12927872ffbe877977d75e72aa24e10161bb9c1cf9867a64ca0d8b3e9e55ffe' or die "SECAM palette digest changed\n";
sha256_hex($data) eq '912ce47e7c53e0e61a861bc0ff889d187644ac53d762f0c0091484c70a3bf8bd' or die "combined Stella palette digest changed\n";

my$helper=File::Spec->rel2abs(File::Spec->catfile($repo,qw(test stella_test_lib.pl)));
require $helper;
my$basedir=File::Spec->catdir($tmp,'stella-private-basedir');
make_path($basedir);
my@args=vcsc_stella_palette_args($repo,$basedir);
my@expected=(
   '-basedir',$basedir,'-palette','user',
   '-pal.hue','0','-pal.saturation','0','-pal.contrast','0',
   '-pal.brightness','0','-pal.gamma','0',
   '-detectpal60','0','-detectntsc50','0',
   '-plr.colorloss','0','-dev.colorloss','0',
   '-tv.filter','0','-tv.phosblend','0','-tia.inter','0',
);
join("\0",@args) eq join("\0",@expected)
   or die "Stella pinned-palette launch arguments changed\n";
my$copy=File::Spec->catfile($basedir,'stella.pal');
open(my$cf,'<:raw',$copy) or die "open copied palette $copy: $!\n";
my$copied=<$cf>; close$cf;
$copied eq $data or die "private Stella basedir palette copy differs\n";

print "pinned Stella NTSC/PAL/SECAM palette contract passed\n";
