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
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $cfg=File::Spec->catfile($vcs,'vcs_4k.cfg');
my $ex=File::Spec->catdir($repo,'examples','04_fingerprint');
my $src=File::Spec->catfile($ex,'fingerprint.vcsc');
my $shared=File::Spec->catfile($vcs,'six_glyph_display.vcsc');
my $example_makefile=File::Spec->catfile($ex,'Makefile');
my $font=File::Spec->catfile($vcs,'fonts','hexadecimal_hex.vcsc');
my $bin=File::Spec->catfile($tmp,'fingerprint.bin');
my $map=File::Spec->catfile($tmp,'fingerprint.map');
my $asm=File::Spec->catfile($tmp,'fingerprint.s');
my $selftest=File::Spec->catfile($tmp,'fingerprint_selftest.hex');
my $timing_source=File::Spec->catfile($repo,'test','vcs_frame_timing.cpp');
my $timing_exe=File::Spec->catfile($tmp,'vcs_frame_timing_fingerprint');
my $mos_dir=File::Spec->catdir($repo,'simulator','mos6502');
my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp');

my ($exit,$sig,$out,$err)=run_capture($driver,'-I',$vcs,'-Wa,--illegals','-Map',$map,$src,'-o',$bin);
die "fingerprint build exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
die "fingerprint build wrote output\nstdout:\n$out\nstderr:\n$err" if $out ne '' || $err ne '';

($exit,$sig,$out,$err)=run_capture($driver,'-I',$vcs,'-S',$src,'-o',$asm);
die "fingerprint compile exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;

my $rom=read_file($bin);
length($rom)==4096 or die "fingerprint cartridge size is ".length($rom).", expected 4096\n";
my ($nmi,$reset,$irq)=unpack('v3',substr($rom,0x0ffa,6));
$reset==0xf000 or die sprintf("fingerprint RESET vector is %04x, expected f000\n",$reset);
for my $v ($nmi,$irq) { $v>=0xf000 && $v<=0xffff or die "fingerprint vector outside ROM\n"; }

my $map_text=read_file($map);
require_re($map_text,qr/\bfingerprint\b/, 'map is missing fingerprint state');
require_re($map_text,qr/\bsix_glyph_pointers\b/, 'map is missing six glyph pointers');
require_re($map_text,qr/\bprobe_accumulator\b/, 'map is missing probe accumulator');
require_re($map_text,qr/\bprobe_flags\b/, 'map is missing probe flags');
my $font_addr;
if ($map_text =~ /\$([Ff][0-9A-Fa-f]{3})\s+score_font/) { $font_addr=hex($1); }
elsif ($map_text =~ /score_font\s+\$([Ff][0-9A-Fa-f]{3})/) { $font_addr=hex($1); }
else { die "map is missing score_font\n"; }
my @font=parse_font(read_file($font),'score_font',128);
my @rom_font=unpack('C128',substr($rom,$font_addr-0xf000,128));
for my $i (0..127) {
   $rom_font[$i]==$font[$i]
      or die sprintf("font byte %d is %02x, expected %02x\n",$i,$rom_font[$i],$font[$i]);
}

my $source=read_file($src);
my $shared_text=read_file($shared);
my $example_makefile_text=read_file($example_makefile);
require_re($example_makefile_text,qr/-Wa,--illegals/,
           'fingerprint Makefile does not explicitly enable unofficial mnemonics');
require_re($source,qr/include\s+"fonts\/hexadecimal_hex\.vcsc"/,
           'example does not select the hexadecimal hex font');
require_re($source,qr/include\s+"six_glyph_display\.vcsc"/,
           'fingerprint example no longer includes the shared six-glyph display module');
$source !~ /void\s+six_glyph_(?:setup|draw)\s*\(/
   or die "fingerprint example copied a shared timing function locally\n";
require_re($shared_text,qr/void\s+six_glyph_setup\s*\(/,
           'shared module is missing six_glyph_setup');
require_re($shared_text,qr/void\s+six_glyph_draw\s*\(/,
           'shared module is missing six_glyph_draw');
require_re($source,qr/uint24_t\s+fingerprint\s*;/,
           'fingerprint is not an ordinary VCSC uint24_t');
require_re($source,qr/alias\s+BACKGROUND_COLOR\s+0x84/,
           'background is no longer medium blue');
require_re($shared_text,qr/COLUP0\s*:=\s*0x0e.*?COLUP1\s*:=\s*0x0e/s,
           'shared display is no longer bright white');
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

my ($setup)=$generated =~ /(\.proc six_glyph_setup.*?\.endproc)/s;
defined($setup) or die "generated assembly is missing six_glyph_setup\n";
require_re($setup,qr/sta\s+\$02\s+lda #\$03\s+sta \$04\s+sta \$05\s+lda #\$0e\s+bit six_glyph_pointers\s+sta \$06\s+sta \$07\s+sta \$2B\s+lda #\$80\s+sta \$20\s+lda #\$90\s+sta \$21\s+nop\s+sta \$10\s+sta \$11\s+lda #\$00\s+sta\s+\$02\s+sta\s+\$2A/s,
           'shared horizontal positioning sequence changed');
my ($draw)=$generated =~ /(\.proc six_glyph_draw.*?\.endproc)/s;
defined($draw) or die "generated assembly is missing six_glyph_draw\n";
$draw !~ /\bjsr\b/ or die "timed fingerprint row loop contains a call\n";
$draw !~ /\b(?:lax|tsx|txs)\b/ or die "fingerprint display uses an unofficial or stack-pointer opcode\n";
my ($loop)=$draw =~ /(\@six_glyph_loop:.*?bpl \@six_glyph_loop)/s;
defined($loop) or die "generated assembly is missing glyph loop\n";
my @actual=map { s/^\s+|\s+$//gr } grep { length } split(/\n/,$loop);
my @expected=(
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
   or die "fingerprint glyph loop changed:\n".join("\n",@actual)."\n";

# Verify CRC VCSC independently of unstable-opcode modeling.
($exit,$sig,$out,$err)=run_capture(
   $driver,'-I',$vcs,'-Wa,--illegals','-D','FINGERPRINT_SELFTEST',$src,'-o',$selftest);
die "CRC selftest build exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
($exit,$sig,$out,$err)=run_capture($sim,'-T',$cfg,$selftest);
die "CRC selftest exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;

($exit,$sig,$out,$err)=run_capture(
   'g++','-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-DILLEGAL_OPCODES',
   '-I'.$mos_dir,$timing_source,$mos_source,'-o',$timing_exe);
die "timing harness compile exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
($exit,$sig,$out,$err)=run_capture($timing_exe,$bin,'80','--no-audio');
die "timing harness exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
require_re($out,qr/vcs_frame_timing ok: 77 frames at 262 lines/,
           'fingerprint cartridge lost stable 262-line timing');

print "vcs_fingerprint ok\n";
