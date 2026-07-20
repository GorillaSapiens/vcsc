#!/usr/bin/perl

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO_ROOT TMP_DIR\n"; }
sub slurp_fh { my ($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub run_capture {
   my (@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in);
   my $stdout=slurp_fh($out);
   my $stderr=slurp_fh($err);
   waitpid($pid,0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}
sub read_file {
   my ($path)=@_;
   open(my $fh,'<:raw',$path) or die "could not open $path: $!\n";
   local $/; my $d=<$fh>; close($fh) or die "could not close $path: $!\n";
   return defined($d)?$d:'';
}
sub require_re {
   my ($text,$re,$why)=@_;
   $text =~ $re or die "$why\n";
}
sub parse_font {
   my ($text)=@_;
   my @out;
   while ($text =~ /^\.byte\s+(.+)$/mg) {
      for my $tok (split /\s*,\s*/, $1) {
         $tok =~ s/\s*;.*$//;
         next if $tok eq '';
         if ($tok =~ /^%([01]{8})$/) { push @out, oct("0b$1"); }
         elsif ($tok =~ /^\$([0-9a-fA-F]{1,2})$/) { push @out, hex($1); }
         elsif ($tok =~ /^(\d+)$/) { push @out, int($1); }
         else { die "unrecognized font byte '$tok'\n"; }
      }
   }
   return @out;
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "could not resolve repo root\n";
$tmp=abs_path($tmp) // die "could not resolve temp dir\n";

my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $ex=File::Spec->catdir($repo,'examples','03_six_digit_score');
my $src=File::Spec->catfile($ex,'six_digit_score.vcsc');
my $font_s=File::Spec->catfile($ex,'score_font.s');
my $font_inc=File::Spec->catfile($ex,'fonts','default.inc');
my $bin=File::Spec->catfile($tmp,'six_digit_score.bin');
my $map=File::Spec->catfile($tmp,'six_digit_score.map');
my $asm=File::Spec->catfile($tmp,'six_digit_score.s');

my ($exit,$sig,$out,$err)=run_capture(
   $driver,'-I',$vcs,'-I',$ex,'-Wa,--illegals','-Map',$map,
   $src,$font_s,'-o',$bin);
die "score build exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
die "score build wrote stdout:\n$out" if $out ne '';
die "score build wrote stderr:\n$err" if $err ne '';

($exit,$sig,$out,$err)=run_capture($driver,'-I',$vcs,'-I',$ex,'-S',$src,'-o',$asm);
die "score compile exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;

my $rom=read_file($bin);
length($rom)==4096 or die "score cartridge size is ".length($rom).", expected 4096\n";
my ($nmi,$reset,$irq)=unpack('v3',substr($rom,0x0ffa,6));
$reset==0xf000 or die sprintf("score RESET vector is %04x, expected f000\n",$reset);
for my $v ($nmi,$irq) { $v>=0xf000 && $v<=0xffff or die "score vector outside ROM\n"; }

my $map_text=read_file($map);
require_re($map_text,qr/region=RAM\s+depth=2\s+bytes=\$0004\s+physical=\$00FC-\$00FF/,
           'score map lost the expected two-level source call reserve');
require_re($map_text,qr/score_pointers\s+.*\$0090|\$0090\s+score_pointers/,
           'score pointer table is not in zero page');
require_re($map_text,qr/score_font\s+.*\$([Ff][0-9A-Fa-f]{3})|\$([Ff][0-9A-Fa-f]{3})\s+score_font/,
           'score map is missing score_font');
my $font_addr;
if ($map_text =~ /\$([Ff][0-9A-Fa-f]{3})\s+score_font/) { $font_addr=hex($1); }
elsif ($map_text =~ /score_font\s+\$([Ff][0-9A-Fa-f]{3})/) { $font_addr=hex($1); }
else { die "could not parse score_font address\n"; }

my @font=parse_font(read_file($font_inc));
@font==80 or die "font has ".scalar(@font)." bytes, expected 80\n";
my @rom_font=unpack('C80',substr($rom,$font_addr-0xf000,80));
for my $i (0..79) {
   $rom_font[$i]==$font[$i]
      or die sprintf("font byte %d is %02x, expected %02x\n",$i,$rom_font[$i],$font[$i]);
}

my $s=read_file($src);
require_re($s,qr/bcd24_t\s+score\s*:=\s*123456\s*;/,
           'example no longer starts from bcd24_t 123456');
require_re($s,qr/frame_counter\s*==\s*20/,
           'example no longer increments every 20 frames');
require_re($s,qr/COLUBK\s*:=\s*0x84/,
           'example background is no longer medium blue');
require_re($s,qr/asm\s+lda\s+#\$0e;\s*\n\s*asm\s+sta\s+COLUP0;\s*\n\s*asm\s+sta\s+COLUP1;/,
           'example score is no longer bright white');
require_re($s,qr/asm\s+ldx\s+#90;/,
           'example lost the 90 explicit top blank lines');
require_re($s,qr/asm\s+ldx\s+#91;/,
           'example lost the 91 bottom blank lines');

my $generated=read_file($asm);
require_re($generated,qr/lda #\$84\s+sta\s+\$09/s,
           'generated code lost blue COLUBK setup');
require_re($generated,qr/lda #\$0e\s+sta \$06\s+sta \$07/s,
           'generated code lost white player colors');
require_re($generated,qr/cmp #\$14/,
           'generated code lost the 20-frame cadence');
require_re($generated,qr/sed\s+clc.*?cld/s,
           'generated code lost packed-BCD increment');
my $carry_count=()=$generated =~ /adc #0/g;
$carry_count==6 or die "glyph pointer setup has $carry_count carry propagations, expected 6\n";
my $lax_count=()=$generated =~ /^lax \(score_pointers\+\$[24]\),y$/mg;
$lax_count==2 or die "score kernel has $lax_count expected LAX instructions, expected 2\n";
my ($draw)=$generated =~ /(\.proc draw_score.*?\.endproc)/s;
defined($draw) or die "generated assembly is missing draw_score\n";
$draw !~ /\bjsr\b/ or die "draw_score calls code while the stack pointer may be borrowed\n";
require_re($draw,qr/tsx\s+stx saved_stack_pointer.*?ldx saved_stack_pointer\s+txs/s,
           'draw_score no longer brackets stack-pointer borrowing');

print "vcs_six_digit_score ok\n";
