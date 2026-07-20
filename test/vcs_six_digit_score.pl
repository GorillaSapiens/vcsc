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
   $text =~ /const\s+uint8_t\s+score_font\s*\[\s*80\s*\]\s*:=\s*\{(.*?)\}\s*;/s
      or die "font does not define const uint8_t score_font[80]\n";
   my $body=$1;
   my @visual=$body =~ /^\s*0b([01.xX_]{8,})[,]?\s*$/mg;
   @visual==80 or die "font has ".scalar(@visual)." one-byte visual rows, expected 80\n";

   my @rows;
   for my $digits (@visual) {
      $digits =~ s/_//g;
      length($digits)==8 or die "visual font row '$digits' is not eight pixels wide\n";
      $digits =~ tr/.xX/011/;
      push @rows, oct("0b$digits");
   }

   # SCORE_GLYPH accepts source rows top-to-bottom and reverses each glyph for
   # the kernel's row-7-through-row-0 traversal.
   my @out;
   for (my $i=0; $i<@rows; $i+=8) {
      push @out, reverse @rows[$i..$i+7];
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
my $font=File::Spec->catfile($ex,'fonts','clean.vcsc');
my $alternate_font=File::Spec->catfile($ex,'fonts','classic.vcsc');
my $bin=File::Spec->catfile($tmp,'six_digit_score.bin');
my $map=File::Spec->catfile($tmp,'six_digit_score.map');
my $asm=File::Spec->catfile($tmp,'six_digit_score.s');
my $timing_source=File::Spec->catfile($repo,'test','vcs_frame_timing.cpp');
my $timing_exe=File::Spec->catfile($tmp,'vcs_frame_timing_score');
my $mos_dir=File::Spec->catdir($repo,'simulator','mos6502');
my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp');

my ($exit,$sig,$out,$err)=run_capture(
   $driver,'-I',$vcs,'-I',$ex,'-Map',$map,$src,'-o',$bin);
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
require_re($map_text,qr/\$0090\s+score_pointers|score_pointers\s+.*\$0090/,
           'score pointer table is not in zero page');
my $font_addr;
if ($map_text =~ /\$([Ff][0-9A-Fa-f]{3})\s+score_font/) { $font_addr=hex($1); }
elsif ($map_text =~ /score_font\s+\$([Ff][0-9A-Fa-f]{3})/) { $font_addr=hex($1); }
else { die "score map is missing score_font\n"; }

my @font=parse_font(read_file($font));
@font==80 or die "active font has ".scalar(@font)." bytes, expected 80\n";
my @alternate=parse_font(read_file($alternate_font));
@alternate==80 or die "alternate font has ".scalar(@alternate)." bytes, expected 80\n";
my @rom_font=unpack('C80',substr($rom,$font_addr-0xf000,80));
for my $i (0..79) {
   $rom_font[$i]==$font[$i]
      or die sprintf("font byte %d is %02x, expected %02x\n",$i,$rom_font[$i],$font[$i]);
}

my $s=read_file($src);
require_re($s,qr/include\s+"fonts\/clean\.vcsc"/,
           'example no longer includes the VCSC clean font');
require_re(read_file($font),qr/0b[.Xx01]{8}/,
           'active font no longer uses visual binary rows');
require_re(read_file($alternate_font),qr/Adapted from retained CC0/,
           'classic alternate font lost its legacy BASIC CC0 lineage note');
require_re($s,qr/bcd24_t\s+score\s*:=\s*123456\s*;/,
           'example no longer starts from bcd24_t 123456');
require_re($s,qr/alias\s+SCORE_PERIOD\s+20/,
           'example no longer declares a 20-frame period');
require_re($s,qr/frame_counter\s*==\s*SCORE_PERIOD.*?score\+\+.*?prepare_score_pointers\(\)/s,
           'example no longer increments packed BCD every 20 frames');
require_re($s,qr/alias\s+BACKGROUND_COLOR\s+0x84/,
           'example background is no longer medium blue');
require_re($s,qr/alias\s+SCORE_COLOR\s+0x0e/,
           'example score is no longer bright white');
require_re($s,qr/void\s+wait_scanlines\s*\(uint8_t\s+lines\).*?while\s*\(lines\).*?WSYNC\s*:=\s*0.*?lines--/s,
           'scanline waiting is no longer expressed in VCSC');
require_re($s,qr/while\s*\(1\).*?wait_scanlines\(3\).*?wait_scanlines\(37\).*?wait_scanlines\(89\).*?draw_score\(\).*?wait_scanlines\(89\)/s,
           'frame structure is no longer expressed in VCSC');

# Packed BCD is little-endian. The display pipeline consumes pointer slots
# 0,4,3,2,1,5, so 123456 must map byte2 high/low, byte1 high/low, byte0 high/low
# to slots 0,4,3,2,1,5 respectively.
require_re($s,qr/asm lda score\+2;.*?asm sta score_pointers;.*?asm sta score_pointers\+1;.*?asm txa;.*?asm sta score_pointers\+8;.*?asm sta score_pointers\+9;/s,
           'most-significant BCD byte is not mapped to display digits 1 and 2');
require_re($s,qr/asm lda score\+1;.*?asm sta score_pointers\+6;.*?asm sta score_pointers\+7;.*?asm txa;.*?asm sta score_pointers\+4;.*?asm sta score_pointers\+5;/s,
           'middle BCD byte is not mapped to display digits 3 and 4');
require_re($s,qr/asm lda score;.*?asm sta score_pointers\+2;.*?asm sta score_pointers\+3;.*?asm txa;.*?asm sta score_pointers\+10;.*?asm sta score_pointers\+11;/s,
           'least-significant BCD byte is not mapped to display digits 5 and 6');

-f File::Spec->catfile($ex,'score_font.s')
   and die "obsolete assembly font wrapper still exists\n";
-f File::Spec->catfile($ex,'fonts','clean.inc')
   and die "obsolete assembly clean-font include still exists\n";
-f File::Spec->catfile($ex,'fonts','default.inc')
   and die "obsolete assembly classic-font include still exists\n";

my $generated=read_file($asm);
require_re($generated,qr/lda #\$84\s+sta\s+\$09/s,
           'generated code lost blue COLUBK setup');
require_re($generated,qr/lda #\$0e\s+sta\s+\$06\s+sta\s+\$07/s,
           'generated code lost white player colors');
require_re($generated,qr/cmp #\$14/,
           'generated code lost the 20-frame cadence');
require_re($generated,qr/sed\s+clc.*?cld/s,
           'generated code lost packed-BCD increment');
require_re($generated,qr/jsr wait_scanlines.*?jsr draw_score/s,
           'example no longer uses ordinary VCSC helper functions');
my $carry_count=()=$generated =~ /adc #0/g;
$carry_count==6 or die "glyph pointer setup has $carry_count carry propagations, expected 6\n";
my ($draw)=$generated =~ /(\.proc draw_score.*?\.endproc)/s;
defined($draw) or die "generated assembly is missing draw_score\n";
$draw !~ /\bjsr\b/ or die "draw_score contains a nested call in the timed kernel\n";
$draw !~ /\b(?:lax|tsx|txs)\b/ or die "score kernel uses an unofficial or stack-pointer opcode\n";
$generated !~ /saved_stack_pointer/ or die "obsolete saved-stack variable remains\n";
require_re($draw,
   qr/lda \(score_pointers\+\$2\),y\s+sta delayed_glyph\s+lda \(score_pointers\+\$4\),y\s+tax\s+bit score\s+nop\s+lda \(score_pointers\+\$a\),y\s+stx \$1C\s+ldx delayed_glyph\s+stx \$1B/s,
   'score kernel lost the cycle-exact official-opcode delayed-glyph sequence');

my $cxx=$ENV{CXX} || 'c++';
($exit,$sig,$out,$err)=run_capture(
   $cxx,'-std=c++17','-O0','-I',$mos_dir,$timing_source,$mos_source,'-o',$timing_exe,
);
die "timing harness build exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err"
   if $exit || $sig;
die "timing harness build wrote unexpected stdout:\n$out" if $out ne '';

($exit,$sig,$out,$err)=run_capture($timing_exe,$bin,'45','--no-audio');
die "timing verification exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err"
   if $exit || $sig;
$out =~ /^vcs_frame_timing ok: 42 frames at 262 lines, 0 AUDV0 writes\n$/
   or die "unexpected timing-verifier output:\n$out";
die "timing verifier wrote unexpected stderr:\n$err" if $err ne '';

print "vcs_six_digit_score ok\n";
