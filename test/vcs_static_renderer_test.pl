#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_static_renderer_test ok
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

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my ($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub run_capture {
   my (@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in);
   my $stdout=slurp_fh($out); my $stderr=slurp_fh($err);
   waitpid($pid,0);
   return ($? >> 8,$? & 127,$stdout,$stderr);
}
sub read_file {
   my ($path)=@_;
   open(my $fh,'<:raw',$path) or die "could not read $path: $!\n";
   local $/; my $d=<$fh>; close($fh); return defined($d)?$d:'';
}
sub require_re {
   my ($text,$re,$why)=@_;
   $text =~ $re or die "$why\n";
}
sub map_symbol {
   my ($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m
      or die "map is missing $name\n";
   return hex($1);
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "could not resolve repo root\n";
$tmp=abs_path($tmp) // die "could not resolve temp dir\n";

my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $profile=File::Spec->catdir($vcs,'renderers','standard_4k_ntsc');
my $example=File::Spec->catdir($repo,'test','fixtures','vcs_examples','05_static_renderer');
my $source=File::Spec->catfile($example,'golden.c26');
my $reference=File::Spec->catfile($example,'reference_stella_7.0.png');
my $renderer=File::Spec->catfile($profile,'standard_4k_ntsc_renderer.s26');
my $cfg=File::Spec->catfile($profile,'vcs_standard_4k_ntsc.cfg');
my $bin=File::Spec->catfile($tmp,'static_renderer_test.bin');
my $mapfile=File::Spec->catfile($tmp,'static_renderer_test.map');
my $phase_source=File::Spec->catfile($repo,'test','vcs_playfield_phase.cpp');
my $phase_exe=File::Spec->catfile($tmp,'vcs_playfield_phase');
my $objects_source=File::Spec->catfile($repo,'test','vcs_standard_objects.cpp');
my $objects_exe=File::Spec->catfile($tmp,'vcs_standard_objects');
my $mos_dir=File::Spec->catdir($repo,'simulator','mos6502');
my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp');

my ($exit,$sig,$out,$err)=run_capture(
   $driver,'-I',$vcs,'-T',$cfg,'-Map',$mapfile,
   $source,$renderer,'-o',$bin);
$exit == 0 && !$sig
   or die "static-renderer build failed: exit=$exit signal=$sig\nstdout:\n$out\nstderr:\n$err";
without_cartridge_usage($out) eq '' or die "static-renderer build wrote stdout:\n$out";
$err eq '' or die "static-renderer build wrote stderr:\n$err";

my $rom=read_file($bin);
length($rom)==4096 or die "static-renderer cartridge is not 4096 bytes\n";
my ($nmi,$reset,$irq)=unpack('v3',substr($rom,0x0ffa,6));
$reset>=0xf000 && $reset<=0xffff
   or die sprintf("RESET vector %04X lies outside cartridge ROM\n",$reset);
for my $v ($nmi,$irq) {
   $v>=0xf000 && $v<=0xffff or die sprintf("vector %04X lies outside cartridge ROM\n",$v);
}

my $map=read_file($mapfile);
map_symbol($map,'__reset')==$reset
   or die sprintf("RESET vector %04X disagrees with map __reset %04X\n",$reset,map_symbol($map,'__reset'));
$map =~ /^\s*RENDERER_CODE\s+load=\$([0-9A-Fa-f]{4})\s+size=\$0300\b/m
   or die "renderer code lost its three-page component window\n";
my $renderer_load=hex($1);
($renderer_load & 0xff)==0
   or die sprintf("renderer code is not page-aligned at %04X\n",$renderer_load);
$map =~ /^\s*RENDERER_RODATA\s+load=\$([0-9A-Fa-f]{4})\s+size=\$0058\b/m
   or die "score table lost its component window\n";
my $renderer_rodata_load=hex($1);
($renderer_rodata_load & 0xff)==0 && $renderer_rodata_load==$renderer_load+0x300
   or die sprintf("score table is not page-aligned immediately after renderer code at %04X\n",$renderer_rodata_load);
require_re($map,qr/region=ram\s+depth=3\s+bytes=\$000A\s+physical=\$00F6-\$00FF\s+extra=\$0004/,
   'map lost the standard renderer hook-aware stack allowance');
map_symbol($map,'vcs_standard_renderer_drawscreen')==$renderer_load
   or die "standard renderer entry does not match its component load address\n";
map_symbol($map,'vcs_standard_score_table')==$renderer_rodata_load
   or die "score table does not match its component load address\n";
my $playfield=map_symbol($map,'vcs_standard_playfield');
(($playfield & 0xff) <= 0xd0 && ($playfield >> 8)==(($playfield+47) >> 8))
   or die sprintf("ROM playfield crosses a page at %04X\n",$playfield);
$playfield>=0xf000 && $playfield+47<=0xfff9
   or die "ROM playfield lies outside cartridge data space\n";
my $paddle=map_symbol($map,'paddle_graphics');
my $target=map_symbol($map,'target_graphics');
($paddle & 0xff)<=0xf8 && ($paddle >> 8)==(($paddle+7) >> 8)
   or die "paddle graphics cross a page boundary\n";
($target & 0xff)<=0xf8 && ($target >> 8)==(($target+7) >> 8)
   or die "target graphics cross a page boundary\n";

my $src=read_file($source);
sha256_hex(read_file($reference)) eq
   '91e212989d0c09fa233139150c25eab95dec8d7ad0f8659fbed8e38d647b4321'
   or die "reviewed Stella reference PNG changed without updating its contract\n";
require_re($src,qr/^page\s+const\s+uint8_t\s+vcs_standard_playfield\s*\[48\]\s*:=/m,
   'test playfield is not a page-contained immutable VCSC object');
$src !~ /alignment_pad|\[97\]/
   or die "dummy source padding array returned\n";
require_re($src,qr/vcs_standard_score\s*:=\s*123456\s*;/,
   'static score is no longer 123456');
require_re($src,qr/COLUBK\s*:=\s*0x84\s*;/,
   'static scene lost its medium-blue background');
require_re($src,qr/COLUPF\s*:=\s*0x2e\s*;/,
   'static scene lost its gold playfield');
require_re($src,qr/CTRLPF\s*:=\s*0x21\s*;/,
   'static scene no longer selects reflected playfield plus four-clock ball width');
require_re($src,qr/NUSIZ0\s*:=\s*0x25\s*;/,
   'static scene no longer makes P0 double-width and M0 four clocks wide');
require_re($src,qr/NUSIZ1\s*:=\s*0x20\s*;/,
   'static scene no longer makes M1 four clocks wide');
require_re($src,qr/vcs_standard_score_color\s*:=\s*0x0e\s*;/,
   'static scene lost its white score');
require_re($src,qr/VCS_STANDARD_SPRITE_GLYPH\s*\(/,
   'static scene no longer stores player art through the top-to-bottom reversal helper');
require_re(read_file(File::Spec->catfile($profile,'standard_4k_ntsc.c26')),
   qr/alias\s+VCS_STANDARD_SPRITE_GLYPH\s*\([^)]*\)\s+h,g,f,e,d,c,b,a/,
   'public sprite reversal helper changed');
for my $name (qw(PLAYER0 PLAYER1 MISSILE0 MISSILE1 BALL)) {
   require_re($src,qr/VCS_STANDARD_\Q$name\E_X\s*:=/,
      "static scene no longer positions $name");
}
for my $locked (
   [qr/VCS_STANDARD_PLAYER0_X\s*:=\s*76\s*;/, 'P0 X'],
   [qr/VCS_STANDARD_PLAYER1_X\s*:=\s*108\s*;/, 'P1 X'],
   [qr/VCS_STANDARD_MISSILE0_X\s*:=\s*64\s*;/, 'M0 X'],
   [qr/VCS_STANDARD_MISSILE1_X\s*:=\s*132\s*;/, 'M1 X'],
   [qr/VCS_STANDARD_BALL_X\s*:=\s*84\s*;/, 'ball X'],
   [qr/vcs_standard_player0_y\s*:=\s*78\s*;/, 'P0 Y'],
   [qr/vcs_standard_player1_y\s*:=\s*42\s*;/, 'P1 Y'],
   [qr/vcs_standard_missile0_y\s*:=\s*30\s*;/, 'M0 Y'],
   [qr/vcs_standard_missile1_y\s*:=\s*60\s*;/, 'M1 Y'],
   [qr/vcs_standard_ball_y\s*:=\s*45\s*;/, 'ball Y'],
   [qr/vcs_standard_player0_height\s*:=\s*7\s*;/, 'P0 height'],
   [qr/vcs_standard_player1_height\s*:=\s*7\s*;/, 'P1 height'],
   [qr/vcs_standard_missile0_height\s*:=\s*5\s*;/, 'M0 height'],
   [qr/vcs_standard_missile1_height\s*:=\s*7\s*;/, 'M1 height'],
   [qr/vcs_standard_ball_height\s*:=\s*3\s*;/, 'ball height'],
) {
   require_re($src,$locked->[0],"static reference changed $locked->[1]");
}
require_re($src,
   qr/while\s*\(1\)\s*\{\s*configure_static_frame\(\);\s*vcs_standard_renderer_drawscreen\(\);\s*\}/s,
   'static scene no longer reapplies volatile TIA geometry before each deterministic draw');

# Lock the imported zero-page addends used by the six-digit score pipeline.
my $renderer_bytes=substr($rom,$renderer_load-0xf000,0x300);
for my $pattern (
   "\xB1\x9B", "\xB1\x9D", "\xB1\x9F",
   "\xB1\xA1", "\xB1\xA3", "\xB1\xA5") {
   index($renderer_bytes,$pattern)>=0
      or die sprintf("renderer is missing score-pointer opcode bytes %s\n",unpack('H*',$pattern));
}
index($renderer_bytes,"\x29\xF0\x4A")>=0
   or die "renderer lost legal AND/LSR score-nibble sequence\n";
index($renderer_bytes,"\x8A\x69\x04\xAA\xE0\x2C")>=0
   or die "renderer lost legal TXA/ADC/TAX/CPX row advance\n";

my $renderer_text=read_file($renderer);
$renderer_text !~ /^\s*lax\b/im or die "normalized renderer still contains LAX\n";
require_re($renderer_text,
   qr/lda \(vcs_standard_pointer_workspace\+\$2\),y[^\n]*\n\s+tax\s+txs\s+lda \(vcs_standard_pointer_workspace\+\$4\),y[^\n]*\n\s+tax\s+SLEEP 5/s,
   'legal visible-score load path or its cycle compensation changed');
my $old_score_path_cycles=5+2+5+3+6;
my $legal_score_path_cycles=5+2+2+5+2+5;
$legal_score_path_cycles==$old_score_path_cycles
   or die "legal visible-score path no longer preserves the original 21-cycle interval\n";
require_re($renderer_text,qr/^\s*lda\s+#37\+128\s*$/m,
   'renderer no longer contains the Stella-verified 262-line timer value');
require_re($renderer_text,qr/\.align 256\s+\@kerloop:/s,
   'hot playfield loop is not pinned to a page boundary');

my $cxx=$ENV{CXX} || 'c++';
($exit,$sig,$out,$err)=run_capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos_dir,$phase_source,$mos_source,'-o',$phase_exe);
$exit == 0 && !$sig
   or die "playfield-phase harness build failed: exit=$exit signal=$sig\nstdout:\n$out\nstderr:\n$err";
without_cartridge_usage($out) eq '' or die "playfield-phase harness build wrote stdout:\n$out";
($exit,$sig,$out,$err)=run_capture($phase_exe,$bin);
$exit == 0 && !$sig
   or die "playfield-phase verification failed: exit=$exit signal=$sig\nstdout:\n$out\nstderr:\n$err";
$out =~ /^vcs_playfield_phase ok: \d+ scanlines at cycles 24\/31, 25\/32, or 27\/34,41,48\n$/
   or die "unexpected playfield-phase output:\n$out";
$err eq '' or die "playfield-phase verifier wrote stderr:\n$err";

($exit,$sig,$out,$err)=run_capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos_dir,$objects_source,$mos_source,'-o',$objects_exe);
$exit == 0 && !$sig
   or die "object harness build failed: exit=$exit signal=$sig\nstdout:\n$out\nstderr:\n$err";
without_cartridge_usage($out) eq '' or die "object harness build wrote stdout:\n$out";
($exit,$sig,$out,$err)=run_capture($objects_exe,$bin);
$exit == 0 && !$sig
   or die "object verification failed: exit=$exit signal=$sig\nstdout:\n$out\nstderr:\n$err";
$out =~ /^vcs_standard_objects ok: P0=\d+ P1=\d+ M0=\d+ M1=\d+ BL=\d+\n$/
   or die "unexpected object-verifier output:\n$out";
$err eq '' or die "object verifier wrote stderr:\n$err";

print "vcs_static_renderer_test ok\n";
