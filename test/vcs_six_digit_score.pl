#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_six_digit_score ok
# expectexit: 0


use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub without_cartridge_usage {
   my ($out) = @_;
   $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//;
   return $out;
}
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
   my @visual=$1 =~ /^\s*0b([01.xX_]{8,})[,]?\s*$/mg;
   @visual==$count or die "font has ".scalar(@visual)." visual rows, expected $count\n";
   my @rows;
   for my $digits (@visual) {
      $digits =~ s/_//g;
      length($digits)==8 or die "font row '$digits' is not eight pixels wide\n";
      $digits =~ tr/.xX/011/;
      push @rows,oct("0b$digits");
   }
   my @out;
   for (my $i=0;$i<@rows;$i+=8) { push @out,reverse @rows[$i..$i+7]; }
   return @out;
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "could not resolve repo root\n";
$tmp=abs_path($tmp) // die "could not resolve temp dir\n";

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $src=File::Spec->catfile($repo,qw(test fixtures vcs_examples 03_six_digit_score golden.c26));
my $oldsrc=File::Spec->catfile($repo,qw(test fixtures six_glyph_component pre_template_one_score.c26));
my $oldinclude=File::Spec->catdir($repo,qw(test fixtures six_glyph_component));
my $component=File::Spec->catfile($vcs,'six_glyph_component.c26');
my $frame=File::Spec->catfile($vcs,'frame_ntsc.c26');
my $font=File::Spec->catfile($vcs,qw(fonts default_decimal.c26));
my $reference=File::Spec->catfile($repo,qw(test fixtures vcs_examples 03_six_digit_score reference_stella_7.0.png));
my $cfg=File::Spec->catfile($vcs,'vcs_4k.cfg');
my $bin=File::Spec->catfile($tmp,'six_digit_score.bin');
my $oldbin=File::Spec->catfile($tmp,'six_digit_score_pre_template.bin');
my $map=File::Spec->catfile($tmp,'six_digit_score.map');
my $asm=File::Spec->catfile($tmp,'six_digit_score.s26');

my ($exit,$sig,$out,$err)=run_capture($driver,'-I',$vcs,'-Map',$map,$src,'-o',$bin);
die "score build exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
die "score build wrote output\n$out$err" if without_cartridge_usage($out) ne '' || $err ne '';
($exit,$sig,$out,$err)=run_capture($driver,'-I',$vcs,'-S',$src,'-o',$asm);
die "score compile exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
die "score compile wrote output\n$out$err" if $out ne '' || $err ne '';
($exit,$sig,$out,$err)=run_capture($driver,'-I',$vcs,'-I',$oldinclude,$oldsrc,'-o',$oldbin);
die "pre-template score build exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
die "pre-template score build wrote output\n$out$err" if without_cartridge_usage($out) ne '' || $err ne '';

for my $rompath ($bin,$oldbin) {
   my $rom=read_file($rompath);
   length($rom)==4096 or die "$rompath is not 4096 bytes\n";
   my ($nmi,$reset,$irq)=unpack('v3',substr($rom,0x0ffa,6));
   $reset==0xf056 or die sprintf("%s RESET vector is %04x, expected f056\n",$rompath,$reset);
   for my $v ($nmi,$irq) { $v>=0xf000 && $v<=0xffff or die "$rompath vector outside ROM\n"; }
}

my $map_text=read_file($map);
require_re($map_text,qr/\$0084\s+score_offsets|score_offsets\s+.*\$0084/,
           'component compact offsets are not anchored at the first allocatable RAM byte');
for my $symbol (qw(score_score score_offsets score_pointers score_delayed)) {
   require_re($map_text,qr/\b\Q$symbol\E\b/,"score map is missing $symbol");
}
my $font_addr;
if ($map_text =~ /\$([Ff][0-9A-Fa-f]{3})\s+score_font/) { $font_addr=hex($1); }
elsif ($map_text =~ /score_font\s+\$([Ff][0-9A-Fa-f]{3})/) { $font_addr=hex($1); }
else { die "score map is missing score_font\n"; }
(($font_addr+79)>>8)==($font_addr>>8) or die "score font crosses a page boundary\n";
my @font=parse_font(read_file($font),'score_font',80);
my @rom_font=unpack('C80',substr(read_file($bin),$font_addr-0xf000,80));
for my $i (0..79) {
   $rom_font[$i]==$font[$i]
      or die sprintf("font byte %d is %02x, expected %02x\n",$i,$rom_font[$i],$font[$i]);
}

my $source=read_file($src);
sha256_hex(read_file($reference)) eq
   'ef34364b790e2ffe7dbf7ebec6cf9937d88f0b96e9a45d32aeba30a68a063333'
   or die "reviewed six-digit Stella reference PNG changed\n";
my $component_text=read_file($component);
my $frame_text=read_file($frame);
require_re($source,qr/include\s+"frame_ntsc\.c26"/,
           'score fixture no longer uses the shared NTSC scheduler');
require_re($source,qr/instantiate\s+"six_glyph_component\.c26"\s+as\s+score/,
           'score fixture no longer instantiates the reusable component');
$source !~ /six_glyph_display\.c26/ or die "score fixture still includes the legacy display module\n";
require_re($source,qr/score_score\s*:=\s*123456/,
           'score fixture no longer starts from packed BCD 123456');
require_re($source,qr/frame_counter\s*==\s*SCORE_PERIOD.*?score_score\+\+/s,
           'score fixture no longer increments packed BCD every 20 frames');
require_re($source,qr/vcs_ntsc_begin_vblank\(\).*?score_vblank\(\).*?vcs_ntsc_end_vblank\(\)/s,
           'score vblank lifecycle is not inside the scheduler-owned budget');
require_re($source,qr/vcs_ntsc_wait_component_scanlines\(91\).*?score_draw\(\).*?vcs_ntsc_wait_visible_tail_scanlines\(90\)/s,
           'score fixture lost legacy absolute visible-line placement');
require_re($source,qr/vcs_ntsc_begin_overscan\(\).*?score_overscan\(\).*?vcs_ntsc_end_overscan\(\)/s,
           'score overscan lifecycle is not inside the scheduler-owned budget');
for my $phase (qw(init vblank draw overscan)) {
   require_re($component_text,qr/require\s+inline\s+void\s+TEMPLATE_\Q$phase\E\s*\(/,
              "component is missing required $phase lifecycle");
}
require_re($component_text,qr/TEMPLATE_VISIBLE_SCANLINES\s*:=\s*11/,
           'component visible contract is no longer eleven scanlines');
require_re($component_text,qr/parameter\s+compact_font\s*:=\s*1/,
           'component compact mode is no longer the default');
require_re($component_text,qr/#if TEMPLATE_compact_font.*?uint8_t\s+TEMPLATE_offsets\[2\].*?uint16_t\s+TEMPLATE_pointers\[4\].*?#else/s,
           'component compact pointer/offset layout changed');
require_re($component_text,qr/(?:COLUP0\s*:=\s*0x0e.*?COLUP1\s*:=\s*0x0e|asm\s+lda\s+#\$0e;.*?asm\s+sta\s+COLUP0;.*?asm\s+sta\s+COLUP1;)/s,
           'component is no longer bright white');
require_re($frame_text,qr/VCS_NTSC_FRAME_SCANLINES\s*:=\s*262/,
           'scheduler no longer declares a 262-line NTSC frame');

my $generated=read_file($asm);
$generated !~ /\bjsr\s+score_(?:init|vblank|draw|overscan)\b/
   or die "score lifecycle unexpectedly emitted callable boundaries\n";
require_re($generated,qr/ldy #11\s+\@inline_\d+_asm_delay:\s+dey\s+bne\.same \@inline_\d+_asm_delay\s+nop\s+nop\s+nop\s+bit\.z \$30.*?begin inline expansion (?:score|display)_draw.*?lda #\$03\s+sta \$04\s+sta \$05/s,
           'calibrated blank-gap tail is missing before the six-glyph draw entry');
require_re($generated,qr/lda #\$03\s+sta \$04\s+sta \$05\s+lda #\$0e\s+sta \$06\s+sta \$07\s+sta \$2B\s+lda #\$80\s+sta \$20\s+lda #\$90\s+sta \$21\s+nop\s+sta \$10\s+sta \$11\s+ldy score_offsets\+1\s+sta \$02\s+sta \$2A/s,
           'component fixed-color positioning/offset preload sequence changed');
require_re($generated,qr/cmp #\$14/,'generated code lost the 20-frame cadence');
require_re($generated,qr/sed\s+clc.*?cld/s,'generated code lost packed-BCD increment');
$generated !~ /\bscore_row\b/
   or die "compact centered score unexpectedly allocates or uses a row byte\n";
require_re($generated,qr/lda score_font\+7,y.*?lda score_font\+0,y/s,
           'compact centered score no longer contains the unrolled eight-row font schedule');

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my $trace_source=File::Spec->catfile($repo,qw(test vcs_visible_trace_compare.cpp));
my $trace_exe=File::Spec->catfile($tmp,'vcs_visible_trace_compare');
($exit,$sig,$out,$err)=run_capture(
   $cxx,'-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2',
   '-I',$mos,$trace_source,@mos_input,'-o',$trace_exe);
die "visible trace/timing harness build failed\n$out$err" if $exit || $sig;
($exit,$sig,$out,$err)=run_capture($trace_exe,$oldbin,$bin,'261','264','--timing-only');
die "visible trace/timing comparison failed\n$out$err" if $exit || $sig;
require_re($out,
   qr/^vcs_visible_trace_compare timing ok: 42 stable frames per ROM\n$/,
   'pre-template and component frame timing did not match their measured contracts');
my $entry_source=File::Spec->catfile($repo,qw(test vcs_six_glyph_standalone_entry.cpp));
my $entry_exe=File::Spec->catfile($tmp,'vcs_six_glyph_standalone_entry');
($exit,$sig,$out,$err)=run_capture(
   $cxx,'-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2',
   '-I',$mos,$entry_source,@mos_input,'-o',$entry_exe);
die "standalone-entry harness build failed\n$out$err" if $exit || $sig;
die "standalone-entry harness build wrote output\n$out$err" if $out ne '' || $err ne '';
($exit,$sig,$out,$err)=run_capture($entry_exe,$bin);
die "standalone-entry runtime contract failed\n$out$err" if $exit || $sig;
require_re($out,
   qr/^vcs_six_glyph_standalone_entry ok: calibrated line 131 entry and 262-line frames\n$/,
   'standalone score did not enter the six-glyph component at its calibrated phase');
$err eq '' or die "standalone-entry harness stderr: $err";

print "vcs_six_digit_score ok\n";
