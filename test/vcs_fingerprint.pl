#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_fingerprint ok
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
   my ($text,$symbol,$count,$height)=@_;
   $height //= 8;
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
   my @out;
   for (my $i=0; $i<@rows; $i+=$height) {
      push @out, reverse @rows[$i..$i+$height-1];
   }
   return @out;
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "could not resolve repo root\n";
$tmp=abs_path($tmp) // die "could not resolve temp dir\n";

my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $ex=File::Spec->catdir($repo,'test','fixtures','vcs_examples','04_fingerprint');
my $src=File::Spec->catfile($ex,'golden.c26');
my $reference=File::Spec->catfile($repo,qw(test fixtures vcs_examples 04_fingerprint reference_stella_7.0.png));
my $component=File::Spec->catfile($vcs,'six_glyph_big_wide_component.c26');
my $left_component=File::Spec->catfile($vcs,'six_glyph_left_component.c26');
my $right_component=File::Spec->catfile($vcs,'six_glyph_right_component.c26');
my $frame=File::Spec->catfile($vcs,'frame_ntsc.c26');
my $font=File::Spec->catfile($vcs,'fonts','big_hex.c26');
my $logo_font=File::Spec->catfile($vcs,'fonts','logo_font.c26');
my $bin=File::Spec->catfile($tmp,'fingerprint.bin');
my $map=File::Spec->catfile($tmp,'fingerprint.map');
my $asm=File::Spec->catfile($tmp,'fingerprint.s26');
my $selftest=File::Spec->catfile($tmp,'fingerprint_selftest.hex');
my $timing_source=File::Spec->catfile($repo,'test','vcs_frame_timing.cpp');
my $timing_exe=File::Spec->catfile($tmp,'vcs_frame_timing_fingerprint');
my $mos_dir=File::Spec->catdir($repo,'simulator','mos6502');
my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp');
my $mos_obj=File::Spec->catfile($mos_dir,'mos6502.o');

my ($exit,$sig,$out,$err)=run_capture($driver,'-I',$vcs,'-Wa,--illegals','-Map',$map,$src,'-o',$bin);
die "fingerprint build exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
die "fingerprint build wrote output\nstdout:\n$out\nstderr:\n$err" if without_cartridge_usage($out) ne '' || $err ne '';

($exit,$sig,$out,$err)=run_capture($driver,'-I',$vcs,'-S',$src,'-o',$asm);
die "fingerprint compile exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;

my $rom=read_file($bin);
length($rom)==4096 or die "fingerprint cartridge size is ".length($rom).", expected 4096\n";
my ($nmi,$reset,$irq)=unpack('v3',substr($rom,0x0ffa,6));
for my $entry ([NMI=>$nmi],[RESET=>$reset],[IRQ=>$irq]) {
   my ($name,$address)=@$entry;
   $address>=0xf000 && $address<=0xffff
      or die sprintf("fingerprint %s vector %04x is outside cartridge ROM\n",$name,$address);
}
for my $v ($nmi,$irq) { $v>=0xf000 && $v<=0xffff or die "fingerprint vector outside ROM\n"; }

my $map_text=read_file($map);
$map_text =~ /^\s+\$([0-9A-Fa-f]{4})\s+__reset\s+/m or die "fingerprint map is missing __reset\n";
hex($1)==$reset or die sprintf("fingerprint RESET vector %04x disagrees with map __reset %04x\n",$reset,hex($1));
require_re($map_text,qr/\bfingerprint\b/, 'map is missing fingerprint state');
for my $symbol (qw(display_score display_pointers display_row display_delayed display_color upper_logo_score upper_logo_pointers upper_logo_delayed lower_logo_score lower_logo_pointers lower_logo_delayed)) {
   require_re($map_text,qr/\b\Q$symbol\E\b/,"map is missing $symbol");
}
require_re($map_text,qr/\bprobe_accumulator\b/, 'map is missing probe accumulator');
require_re($map_text,qr/\bprobe_flags\b/, 'map is missing probe flags');
my $font_addr;
if ($map_text =~ /\$([Ff][0-9A-Fa-f]{3})\s+score_font/) { $font_addr=hex($1); }
elsif ($map_text =~ /score_font\s+\$([Ff][0-9A-Fa-f]{3})/) { $font_addr=hex($1); }
else { die "map is missing score_font\n"; }
my @font=parse_font(read_file($font),'score_font',256,16);
my @rom_font=unpack('C256',substr($rom,$font_addr-0xf000,256));
for my $i (0..255) {
   $rom_font[$i]==$font[$i]
      or die sprintf("font byte %d is %02x, expected %02x\n",$i,$rom_font[$i],$font[$i]);
}
my $logo_font_addr;
if ($map_text =~ /\$([Ff][0-9A-Fa-f]{3})\s+logo_font/) { $logo_font_addr=hex($1); }
elsif ($map_text =~ /logo_font\s+\$([Ff][0-9A-Fa-f]{3})/) { $logo_font_addr=hex($1); }
else { die "map is missing logo_font\n"; }
my @logo_font=parse_font(read_file($logo_font),'logo_font',48);
my @rom_logo_font=unpack('C48',substr($rom,$logo_font_addr-0xf000,48));
for my $i (0..47) {
   $rom_logo_font[$i]==$logo_font[$i]
      or die sprintf("logo font byte %d is %02x, expected %02x\n",$i,$rom_logo_font[$i],$logo_font[$i]);
}

my $source=read_file($src);
sha256_hex(read_file($reference)) eq
   '4459e650e68d9c5e214de2d253726374298e627bae8377da7cfab4d4b7fc9440'
   or die "reviewed fingerprint Stella reference PNG changed\n";
my $component_text=read_file($component);
my $frame_text=read_file($frame);
require_re($source,qr/include\s+"fonts\/big_hex\.c26"/,
           'fingerprint fixture does not select the Big hex font');
require_re($source,qr/include\s+"fonts\/logo_font\.c26"/,
           'fingerprint fixture does not include the logo font');
require_re($source,qr/include\s+"frame_ntsc\.c26"/,
           'fingerprint fixture no longer uses the shared NTSC scheduler');
require_re($source,qr/instantiate\s+"six_glyph_big_wide_component\.c26"\s+as\s+display/,
           'fingerprint fixture no longer instantiates the big-wide fingerprint component');
require_re($source,qr/instantiate\s+"six_glyph_right_component\.c26"\s+as\s+upper_logo/,
           'fingerprint fixture no longer instantiates the right-justified upper logo');
require_re($source,qr/instantiate\s+"six_glyph_left_component\.c26"\s+as\s+lower_logo/,
           'fingerprint fixture no longer instantiates the left-justified lower logo');
$source !~ /six_glyph_display\.c26/
   or die "fingerprint fixture still includes the legacy display module\n";
require_re($source,qr/display_score\s*:=\s*0.*?asm lda fingerprint;.*?asm sta display_score;.*?asm lda fingerprint\+1;.*?asm sta display_score\+1;.*?asm lda fingerprint\+2;.*?asm sta display_score\+2;/s,
           'fingerprint bytes are no longer copied raw into the component score storage');
require_re($source,qr/upper_logo_score\s*:=\s*12345\s*;.*?lower_logo_score\s*:=\s*12345\s*;/s,
           'both logos are no longer driven by the fixed six-glyph value 012345');
require_re($source,qr/inline\s+void\s+load_logo_pointers\s*\(void\).*?lda #<logo_font;.*?sta upper_logo_pointers;.*?sta lower_logo_pointers;.*?adc #\$08;.*?sta upper_logo_pointers\+10;.*?sta lower_logo_pointers\+10;.*?lda #>logo_font;.*?sta upper_logo_pointers\+11;.*?sta lower_logo_pointers\+11;/s,
           'both logo pointer sets are no longer redirected to the six logo-font slices');
for my $pair ([$component,'big-wide',16,19],[$left_component,'left',8,11],[$right_component,'right',8,11]) {
   my ($path,$name,$rows,$lines)=@$pair;
   my $text=read_file($path);
   for my $phase (qw(init vblank draw overscan)) {
      require_re($text,qr/require\s+inline\s+void\s+TEMPLATE_\Q$phase\E\s*\(/,
                 "$name component is missing required $phase lifecycle");
   }
   require_re($text,qr/parameter\s+glyph_rows\s*:=\s*\Q$rows\E\s*;/,
              "$name component lost its $rows-row default");
   require_re($text,qr/#(?:if|elif)\s+TEMPLATE_glyph_rows\s*==\s*\Q$rows\E\s*
\s*alias\s+TEMPLATE_VISIBLE_SCANLINES_VALUE\s+\Q$lines\E\b/,
              "$name component no longer maps its default height to $lines visible scanlines");
   require_re($text,qr/TEMPLATE_VISIBLE_SCANLINES\s*:=\s*TEMPLATE_VISIBLE_SCANLINES_VALUE/,
              "$name component no longer publishes parameterized visible scanlines");
}
require_re($source,qr/vcs_ntsc_begin_vblank\(\).*?display_vblank\(\).*?upper_logo_vblank\(\).*?lower_logo_vblank\(\).*?load_logo_pointers\(\).*?vcs_ntsc_end_vblank\(\)/s,
           'all three display vblank lifecycles are not inside the scheduler-owned budget');
require_re($source,qr/upper_logo_draw\(\).*?vcs_ntsc_wait_component_scanlines\(76\).*?display_draw\(\).*?vcs_ntsc_wait_component_scanlines\(75\).*?lower_logo_draw\(\)/s,
           'upper logo, big-wide fingerprint, or lower logo visible placement changed');
require_re($source,qr/vcs_ntsc_begin_overscan\(\).*?display_overscan\(\).*?upper_logo_overscan\(\).*?lower_logo_overscan\(\).*?vcs_ntsc_end_overscan\(\)/s,
           'all three display overscan lifecycles are not inside the scheduler-owned budget');
require_re($frame_text,qr/VCS_NTSC_FRAME_SCANLINES\s*:=\s*262/,
           'scheduler no longer declares a 262-line NTSC frame');
require_re($source,qr/uint24_t\s+fingerprint\s*;/,
           'fingerprint is not an ordinary VCSC uint24_t');
require_re($source,qr/alias\s+BACKGROUND_COLOR\s+0x84/,
           'background is no longer medium blue');
require_re($source,qr/display_color\s*:=\s*0x0e/,
           'big-wide fingerprint is no longer bright white');
require_re($component_text,qr/parameter\s+initial_color\s*:=\s*0x0e/,
           'big-wide component initial-color parameter no longer defaults to bright white');
require_re($component_text,qr/recommend\s+uint8_t\s+TEMPLATE_color\s*:=\s*TEMPLATE_initial_color/,
           'big-wide component color no longer follows its initial-color parameter');
require_re($source,qr/fingerprint\s*\^=\s*\(uint24_t\)value\s*<<\s*16/,
           'CRC input byte is no longer XORed into the high CRC byte in VCSC');
require_re($source,qr/fingerprint\s*\^=\s*0x864cfb/,
           'CRC polynomial is no longer 0x864cfb');
require_re($source,qr/fingerprint\s*:=\s*0xb704ce/,
           'CRC initial value is no longer 0xb704ce');
require_re($source,qr/probe1\(\).*?crc24_feed\(probe_accumulator\).*?crc24_feed\(probe_flags\).*?
\s*probe2\(\).*?crc24_feed\(probe_accumulator\).*?crc24_feed\(probe_flags\).*?
\s*probe3\(\).*?crc24_feed\(probe_accumulator\).*?crc24_feed\(probe_flags\).*?
\s*probe4\(\).*?crc24_feed\(probe_accumulator\).*?crc24_feed\(probe_flags\)/s,
           'probe result/flag feed order changed');
my @probe_specs=(
   ['probe1','cld','sec','e5','b8'],
   ['probe2','cld','sec','36','6b'],
   ['probe3','sed','clc','f6','6b'],
   ['probe4','cld','clc','06','6b'],
);
for my $spec (@probe_specs) {
   my ($name,$decimal,$carry,$a,$m)=@$spec;
   require_re($source,qr/void\s+\Q$name\E\s*\(void\).*?asm \Q$decimal\E;.*?asm \Q$carry\E;.*?asm lda #\$\Q$a\E;.*?asm ARR #\$\Q$m\E;\s*\/\/\s*Unstable unofficial ARR; emits bytes \$6B,\$\Q$m\E\..*?asm sta probe_accumulator;.*?asm php;.*?asm pla;.*?asm and #\$c3;.*?asm sta probe_flags;/si,
              "$name no longer implements or documents the specified ARR probe");
}

my $generated=read_file($asm);
my @generated_specs=(
   ['probe1','cld','sec','e5','b8'],
   ['probe2','cld','sec','36','6b'],
   ['probe3','sed','clc','f6','6b'],
   ['probe4','cld','clc','06','6b'],
);
for my $spec (@generated_specs) {
   my ($name,$decimal,$carry,$a,$m)=@$spec;
   my ($body)=$generated =~ /(\.proc \Q$name\E.*?\.endproc)/s;
   defined($body) or die "generated assembly is missing $name\n";
   require_re($body,qr/\Q$decimal\E\s+\Q$carry\E\s+lda #\$\Q$a\E\s+ARR #\$\Q$m\E\s+sta probe_accumulator\s+php\s+pla\s+and #\$c3\s+sta probe_flags/is,
              "$name generated opcode/flag sequence changed");
}
my $arr_count=()=$generated =~ /^ARR #\$/img;
$arr_count==4 or die "generated assembly has $arr_count named ARR probes, expected 4\n";

$generated !~ /\bjsr\s+(?:display|upper_logo|lower_logo)_(?:init|vblank|draw|overscan)\b/
   or die "display lifecycle unexpectedly emitted callable boundaries
";
require_re($generated,qr/ldy #11\s+\@inline_\d+_asm_delay:\s+dey\s+bne\.same \@inline_\d+_asm_delay\s+nop\s+nop\s+nop\s+bit\.z \$00.*?begin inline expansion display_draw.*?lda #\$06\s+sta \$04\s+sta \$05/s,
           'calibrated blank-gap tail is missing before the big-wide draw entry');
require_re($generated,qr/begin inline expansion upper_logo_draw.*?lda #\$c0\s+sta \$20\s+lda #\$d0\s+sta \$21(?:\s+nop){11}\s+sta \$10\s+sta \$11/s,
           'right-justified component positioning sequence changed');
require_re($generated,qr/begin inline expansion display_draw.*?lda #\$06\s+sta \$04\s+sta \$05(?:\s+nop){10}\s+sta \$10\s+sta \$11.*?lda #\$30\s+sta \$20\s+lda #\$c0\s+sta \$21/s,
           'big-wide fingerprint positioning sequence changed');
require_re($generated,qr/begin inline expansion lower_logo_draw.*?nop\s+nop\s+sta \$10\s+sta \$11.*?lda #\$30\s+sta \$20\s+lda #\$b0\s+sta \$21/s,
           'left-justified component positioning sequence changed');
my ($loop)=$generated =~ /(\@inline_\d+_asm_display_draw_loop:.*?bpl\.same \@inline_\d+_asm_display_draw_loop)/s;
defined($loop) or die "generated assembly is missing the instantiated display row loop\n";
$loop !~ /\bjsr\b/ or die "timed fingerprint row loop contains a call\n";
$loop !~ /\b(?:lax|tsx|txs)\b/ or die "fingerprint display uses an unofficial or stack-pointer opcode\n";
my @actual=map { s/^\s+|\s+$//gr } grep { length } split(/\n/,$loop);
$actual[0] =~ s/^\@inline_\d+_asm_display_draw_loop:/\@loop:/;
$actual[-1] =~ s/bpl\.same \@inline_\d+_asm_display_draw_loop/bpl.same \@loop/;
my @expected=(
   '@loop:', 'ldy display_row', 'lda (display_pointers),y', 'sta $1B',
   'sta $02', 'lda (display_pointers+$2),y', 'sta $1C',
   'lda (display_pointers+$4),y', 'sta $1B',
   'lda (display_pointers+$6),y', 'sta display_delayed',
   'lda (display_pointers+$8),y', 'tax',
   'lda (display_pointers+$a),y', 'tay', 'lda display_delayed',
   'sta $1C', 'stx $1B', 'sty $1C', 'sta $1B',
   'dec display_row', 'bpl.same @loop',
);
join("\n",@actual) eq join("\n",@expected)
   or die "instantiated fingerprint row loop changed:\n".join("\n",@actual)."\n";

# Verify CRC VCSC independently of unstable-opcode modeling.
($exit,$sig,$out,$err)=run_capture(
   $driver,'-I',$vcs,'-Wa,--illegals','-D','FINGERPRINT_SELFTEST',$src,'-o',$selftest);
die "CRC selftest build exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
($exit,$sig,$out,$err)=run_capture($sim,$selftest);
die "CRC selftest exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;

($exit,$sig,$out,$err)=run_capture(
   'g++','-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-DILLEGAL_OPCODES',
   '-I'.$mos_dir,$timing_source,(-f $mos_obj ? $mos_obj : $mos_source),'-o',$timing_exe);
die "timing harness compile exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
($exit,$sig,$out,$err)=run_capture($timing_exe,$bin,'80','--no-audio','--raw-lines','264');
die "timing harness exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
require_re($out,qr/vcs_frame_timing ok: 77 frames at 262 lines/,
           'fingerprint cartridge lost stable 262-line timing');
my $entry_source=File::Spec->catfile($repo,qw(test vcs_six_glyph_standalone_entry.cpp));
my $entry_exe=File::Spec->catfile($tmp,'vcs_six_glyph_standalone_entry');
($exit,$sig,$out,$err)=run_capture(
   'g++','-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2',
   '-I'.$mos_dir,$entry_source,(-f $mos_obj ? $mos_obj : $mos_source),'-o',$entry_exe);
die "standalone-entry harness build failed\n$out$err" if $exit || $sig;
die "standalone-entry harness build wrote output\n$out$err" if $out ne '' || $err ne '';
($exit,$sig,$out,$err)=run_capture($entry_exe,$bin,'fingerprint');
die "standalone-entry runtime contract failed\n$out$err" if $exit || $sig;
require_re($out,
   qr/^vcs_six_glyph_standalone_entry ok: right 40, big-wide 127, left 221 entries and 262-line frames\n$/,
   'big-wide fingerprint and both logos did not enter at their calibrated phases');
$err eq '' or die "standalone-entry harness stderr: $err";

print "vcs_fingerprint ok\n";
