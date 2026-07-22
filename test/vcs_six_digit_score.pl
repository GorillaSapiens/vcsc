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
   my ($text,$symbol,$count)=@_;
   $text =~ /const\s+uint8_t\s+\Q$symbol\E\s*\[\s*\Q$count\E\s*\]\s*:=\s*\{(.*?)\}\s*;/s
      or die "font does not define const uint8_t $symbol\[$count\]\n";
   my $body=$1;
   my @visual=$body =~ /^\s*0b([01.xX_]{8,})[,]?\s*$/mg;
   @visual==$count or die "font has ".scalar(@visual)." one-byte visual rows, expected $count\n";

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
my $src=File::Spec->catfile($ex,'six_digit_score.c26');
my $font=File::Spec->catfile($vcs,'fonts','default_decimal.c26');
my $shared=File::Spec->catfile($vcs,'six_glyph_display.c26');
my $cfg=File::Spec->catfile($vcs,'vcs_4k.cfg');
my $font_symbol='score_font';
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
require_re($map_text,qr/\$0088\s+six_glyph_pointers|six_glyph_pointers\s+.*\$0088/,
           'score pointer table is not anchored at the first allocatable RAM byte');
require_re($map_text,qr/six_glyph_row/, 'score map is missing row counter');
require_re($map_text,qr/six_glyph_delayed/, 'score map is missing delayed glyph byte');
my $font_addr;
if ($map_text =~ /\$([Ff][0-9A-Fa-f]{3})\s+\Q$font_symbol\E/) { $font_addr=hex($1); }
elsif ($map_text =~ /\Q$font_symbol\E\s+\$([Ff][0-9A-Fa-f]{3})/) { $font_addr=hex($1); }
else { die "score map is missing $font_symbol\n"; }
($font_addr & 0xff)==0
   or die sprintf("score font starts at %04X instead of a page boundary\n",$font_addr);
(($font_addr + 79) >> 8)==($font_addr >> 8)
   or die "score font crosses a page boundary\n";
require_re(read_file($cfg),qr/^\s*RODATA:.*?align\s*=\s*\$0100\s*;/m,
           'stock 4K linker profile no longer page-aligns RODATA');

my @font=parse_font(read_file($font),$font_symbol,80);
@font==80 or die "active font has ".scalar(@font)." bytes, expected 80\n";
my @rom_font=unpack('C80',substr($rom,$font_addr-0xf000,80));
for my $i (0..79) {
   $rom_font[$i]==$font[$i]
      or die sprintf("font byte %d is %02x, expected %02x\n",$i,$rom_font[$i],$font[$i]);
}

my $s=read_file($src);
my $shared_text=read_file($shared);
require_re($s,qr/include\s+"fonts\/default_decimal\.c26"/,
           'example no longer includes the shared Default decimal font');
require_re($s,qr/include\s+"fonts\/default_decimal\.c26".*?bcd24_t\s+score/s,
           'font include no longer precedes score/data declarations');
require_re(read_file($font),qr/0b[.Xx01]{8}/,
           'active font no longer uses visual binary rows');
require_re(read_file($font),qr/CC0-1\.0/,
           'shared active font lost its CC0 lineage note');
require_re($s,qr/bcd24_t\s+score\s*:=\s*123456\s*;/,
           'example no longer starts from bcd24_t 123456');
require_re($s,qr/alias\s+SCORE_PERIOD\s+20/,
           'example no longer declares a 20-frame period');
require_re($shared_text,qr/uint8_t\s+six_glyph_pointers\s*\[\s*12\s*\]/,
           'shared module no longer provides six complete glyph pointers');
require_re($s,qr/frame_counter\s*==\s*SCORE_PERIOD.*?score\+\+.*?prepare_six_glyph_pointers\(\)/s,
           'example no longer increments packed BCD every 20 frames');
require_re($s,qr/alias\s+BACKGROUND_COLOR\s+0x84/,
           'example background is no longer medium blue');
require_re($shared_text,qr/COLUP0\s*:=\s*0x0e.*?COLUP1\s*:=\s*0x0e/s,
           'shared display is no longer bright white');
require_re($s,qr/void\s+wait_scanlines\s*\(uint8_t\s+lines\).*?while\s*\(lines\).*?WSYNC\s*:=\s*0.*?lines--/s,
           'scanline waiting is no longer expressed in VCSC');
require_re($s,qr/VBLANK\s*:=\s*2;\s*six_glyph_setup\(\);\s*prepare_six_glyph_pointers\(\);/s,
           'one-time player positioning is no longer performed under vertical blank');
require_re($s,qr/while\s*\(1\).*?wait_scanlines\(3\).*?wait_scanlines\(37\).*?wait_scanlines\(89\).*?six_glyph_draw\(\).*?wait_scanlines\(89\)/s,
           'frame structure is no longer expressed in VCSC');
require_re($s,qr/include\s+"six_glyph_display\.c26"/,
           'example no longer includes the shared six-glyph display module');
$s !~ /void\s+six_glyph_(?:setup|draw)\s*\(/ 
   or die "example copied a shared six-glyph timing function locally\n";
require_re($shared_text,qr/void\s+six_glyph_setup\s*\(/,
           'shared module is missing six_glyph_setup');
require_re($shared_text,qr/void\s+six_glyph_draw\s*\(/,
           'shared module is missing six_glyph_draw');

# Packed BCD is little-endian. Pointers must be constructed in human display
# order, including carry into the font address high byte for each glyph.
require_re($s,qr/asm lda score\+2;.*?asm sta six_glyph_pointers;.*?asm sta six_glyph_pointers\+1;.*?asm txa;.*?asm sta six_glyph_pointers\+2;.*?asm sta six_glyph_pointers\+3;/s,
           'packed BCD byte score+2 is not mapped to digits 1 and 2');
require_re($s,qr/asm lda score\+1;.*?asm sta six_glyph_pointers\+4;.*?asm sta six_glyph_pointers\+5;.*?asm txa;.*?asm sta six_glyph_pointers\+6;.*?asm sta six_glyph_pointers\+7;/s,
           'packed BCD byte score+1 is not mapped to digits 3 and 4');
require_re($s,qr/asm lda score;.*?asm sta six_glyph_pointers\+8;.*?asm sta six_glyph_pointers\+9;.*?asm txa;.*?asm sta six_glyph_pointers\+10;.*?asm sta six_glyph_pointers\+11;/s,
           'packed BCD byte score is not mapped to digits 5 and 6');
my $carry_count=()=$s =~ /asm adc #0;/g;
$carry_count==6 or die "glyph pointer setup has $carry_count carry propagations, expected 6\n";

-d File::Spec->catdir($ex,'fonts')
   and die "example-private font directory still exists\n";

my $generated=read_file($asm);
my ($setup)=$generated =~ /(\.proc six_glyph_setup.*?\.endproc)/s;
defined($setup) or die "generated assembly is missing six_glyph_setup\n";
require_re($setup,qr/sta\s+\$02\s+lda #\$03\s+sta \$04\s+sta \$05\s+lda #\$0e\s+bit six_glyph_pointers\s+sta \$06\s+sta \$07\s+sta \$2B\s+lda #\$80\s+sta \$20\s+lda #\$90\s+sta \$21\s+nop\s+sta \$10\s+sta \$11\s+lda #\$00\s+sta\s+\$02\s+sta\s+\$2A/s,
           'shared horizontal positioning sequence changed');
require_re($generated,qr/lda #\$84\s+sta\s+\$09/s,
           'generated code lost blue COLUBK setup');
require_re($generated,qr/lda #\$0e\s+sta\s+\$06\s+sta\s+\$07/s,
           'generated code lost white player colors');
require_re($generated,qr/cmp #\$14/,
           'generated code lost the 20-frame cadence');
require_re($generated,qr/sed\s+clc.*?cld/s,
           'generated code lost packed-BCD increment');
require_re($generated,qr/jsr wait_scanlines.*?jsr six_glyph_draw/s,
           'example no longer uses ordinary VCSC helper functions');
my ($draw)=$generated =~ /(\.proc six_glyph_draw.*?\.endproc)/s;
defined($draw) or die "generated assembly is missing six_glyph_draw\n";
$draw !~ /\bjsr\b/ or die "six_glyph_draw contains a nested call in the timed kernel\n";
$draw !~ /\b(?:lax|tsx|txs)\b/ or die "score kernel uses an unofficial or stack-pointer opcode\n";
$generated !~ /saved_stack_pointer/ or die "obsolete saved-stack variable remains\n";
require_re($draw,qr/lda\s+#\$00\s+sta\s+\$02\s+sta\s+\$1B\s+sta\s+\$1C\s+sta\s+\$1B\s+lda\s+#\$0e\s+sta\s+\$06\s+sta\s+\$07\s+lda\s+#\$01\s+sta\s+\$25\s+sta\s+\$26/s,
           'score setup is not fresh-scanline anchored with latch clearing before color/VDEL setup');
require_re($draw,qr/lda\s+#\$00\s+sta\s+\$1B\s+sta\s+\$1C\s+sta\s+\$1B\s+sta\s+\$25\s+sta\s+\$26/s,
           'score cleanup does not flush delayed GRP latches before disabling VDEL');

my ($loop)=$draw =~ /(\@six_glyph_loop:.*?bpl \@six_glyph_loop)/s;
defined($loop) or die "generated assembly is missing the score row loop\n";
my @actual = map { s/^\s+|\s+$//gr } grep { length } split(/\n/, $loop);
my @expected = (
   '@six_glyph_loop:', 'ldy six_glyph_row', 'lda (six_glyph_pointers),y', 'sta $1B',
   'sta $02', 'lda (six_glyph_pointers+$2),y', 'sta $1C',
   'lda (six_glyph_pointers+$4),y', 'sta $1B',
   'lda (six_glyph_pointers+$6),y', 'sta six_glyph_delayed',
   'lda (six_glyph_pointers+$8),y', 'tax',
   'lda (six_glyph_pointers+$a),y', 'tay', 'lda six_glyph_delayed',
   'sta $1C', 'stx $1B', 'sty $1C', 'sta $1B',
   'dec six_glyph_row', 'bpl @six_glyph_loop',
);
join("\n",@actual) eq join("\n",@expected)
   or die "score row loop changed:\n".join("\n",@actual)."\n";

# After WSYNC, the six remaining GRP writes complete at the documented
# official-kernel deadlines. The D1 write immediately before WSYNC preloads it.
my %cycles=(
   'lda (six_glyph_pointers+$2),y'=>5, 'sta $1C'=>3,
   'lda (six_glyph_pointers+$4),y'=>5, 'sta $1B'=>3,
   'lda (six_glyph_pointers+$6),y'=>5, 'sta six_glyph_delayed'=>3,
   'lda (six_glyph_pointers+$8),y'=>5, 'tax'=>2,
   'lda (six_glyph_pointers+$a),y'=>5, 'tay'=>2,
   'lda six_glyph_delayed'=>3, 'stx $1B'=>3, 'sty $1C'=>3,
);
my $cycle=0; my @writes; my $after_wsync=0;
for my $line (@actual) {
   if ($line eq 'sta $02') { $cycle=0; $after_wsync=1; next; }
   next unless $after_wsync;
   last if $line eq 'dec six_glyph_row';
   exists $cycles{$line} or die "no cycle count for timed instruction '$line'\n";
   $cycle += $cycles{$line};
   push @writes,$cycle if $line =~ /^(?:sta \$1[BC]|stx \$1B|sty \$1C)$/;
}
my @expected_writes=(8,16,44,47,50,53);
join(',',@writes) eq join(',',@expected_writes)
   or die "post-WSYNC GRP writes complete at @writes, expected @expected_writes\n";

my $cxx=$ENV{CXX} || 'c++';
($exit,$sig,$out,$err)=run_capture(
   $cxx,'-std=c++17','-O0','-I',$mos_dir,$timing_source,$mos_source,'-o',$timing_exe,
);
die "timing harness build exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err"
   if $exit || $sig;
die "timing harness build wrote unexpected stdout:\n$out" if $out ne '';

($exit,$sig,$out,$err)=run_capture($timing_exe,$bin,'45','--no-audio','--raw-lines','263');
die "timing verification exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err"
   if $exit || $sig;
$out =~ /^vcs_frame_timing ok: 42 frames at 262 lines, 0 AUDV0 writes\n$/
   or die "unexpected timing-verifier output:\n$out";
die "timing verifier wrote unexpected stderr:\n$err" if $err ne '';

print "vcs_six_digit_score ok\n";
