#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_rainbow_data ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
sub usage { die "usage: $0 REPO TMP\n"; }
my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo); $tmp=abs_path($tmp);
my $f=File::Spec->catfile($repo,qw(examples _common all_five_stripes32_rainbow_data.c26));
open my $fh,'<',$f or die "open $f: $!\n"; local $/; my $s=<$fh>; close $fh;
my($ct)=$s =~ /game_playfield_colors\[64\]\s*:=\s*\{(.*?)\};/s;
my($pt)=$s =~ /game_playfield_data\[192\]\s*:=\s*\{(.*?)\};/s;
defined $ct && defined $pt or die "stripes32 rainbow arrays missing\n";
my @c=map { hex($_) } ($ct =~ /0x([0-9a-fA-F]{2})/g);
my @p=map { hex($_) } ($pt =~ /0x([0-9a-fA-F]{2})/g);
@c==64 or die "expected 64 stripe colors, got ".scalar(@c)."\n";
@p==192 or die "expected 192 stripe PF bytes, got ".scalar(@p)."\n";
for my $i (0..31) {
   my($fg,$bg)=@c[2*$i,2*$i+1];
   ($bg&0x0f)==4 or die "stripe $i background luminance changed\n";
   ($fg&0x0f)==14 or die "stripe $i foreground luminance changed\n";
   my $want=((($bg>>4)+8)&15);
   ($fg>>4)==$want or die "stripe $i foreground hue is not complementary\n";
}
my @pat=(0xf0,0xaa,0x55,0xf0,0x55,0xaa);
for my $i (0..31) {
   for my $j (0..5) {
      $p[6*$i+$j]==$pat[$j] or die "stripe $i PF pattern changed at byte $j\n";
   }
}
print "vcs_all_five_stripes32_rainbow_data ok\n";
