#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: vcs_three_plus_three_score ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use Compress::Zlib qw(uncompress);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($?>>8,$?&127,$so,$se);
}
sub read_file { my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return $d // ''; }
sub png_rgb {
   my($path)=@_;
   my $png=read_file($path);
   substr($png,0,8) eq "\x89PNG\r\n\x1a\n" or die "$path is not PNG\n";
   my($w,$h,$depth,$ct,$interlace,$palette,$idat); ($palette,$idat)=('','');
   my $o=8;
   while ($o<length($png)) {
      my $n=unpack('N',substr($png,$o,4)); my $type=substr($png,$o+4,4); $o+=8;
      my $d=substr($png,$o,$n); $o+=$n+4;
      if ($type eq 'IHDR') { ($w,$h,$depth,$ct,undef,undef,$interlace)=unpack('NNCCCCC',$d); }
      elsif ($type eq 'PLTE') { $palette=$d; }
      elsif ($type eq 'IDAT') { $idat.=$d; }
      elsif ($type eq 'IEND') { last; }
   }
   defined($w) && $depth==8 && $interlace==0 or die "$path uses unsupported PNG encoding\n";
   my %ch=(0=>1,2=>3,3=>1,4=>2,6=>4); exists($ch{$ct}) or die "$path uses unsupported PNG color type $ct\n";
   my $c=$ch{$ct}; my $rowbytes=$w*$c; my $raw=uncompress($idat); defined($raw) or die "$path has invalid compressed data\n";
   length($raw)==($rowbytes+1)*$h or die "$path has unexpected scanline bytes\n";
   my @prev=(0)x$rowbytes; my $pos=0; my $rgb='';
   for my $y (0..$h-1) {
      my $filter=ord(substr($raw,$pos++,1)); my @row=unpack('C*',substr($raw,$pos,$rowbytes)); $pos+=$rowbytes;
      for my $x (0..$#row) {
         my $left=$x >= $c ? $row[$x-$c] : 0; my $up=$prev[$x]; my $ul=$x >= $c ? $prev[$x-$c] : 0;
         if($filter==1){$row[$x]=($row[$x]+$left)&255} elsif($filter==2){$row[$x]=($row[$x]+$up)&255}
         elsif($filter==3){$row[$x]=($row[$x]+int(($left+$up)/2))&255} elsif($filter==4){$row[$x]=($row[$x]+png_paeth($left,$up,$ul))&255}
         elsif($filter!=0){die "$path uses unknown PNG filter $filter\n"}
      }
      for my $x (0..$w-1) {
         my $i=$x*$c;
         if($ct==0 || $ct==4){$rgb.=pack('C3',($row[$i])x3)}
         elsif($ct==3){my $q=$row[$i]*3; $rgb.=substr($palette,$q,3)}
         else{$rgb.=pack('C3',@row[$i,$i+1,$i+2])}
      }
      @prev=@row;
   }
   return ($w,$h,$rgb);
}
sub png_paeth { my($a,$b,$c)=@_; my $p=$a+$b-$c; my($pa,$pb,$pc)=(abs($p-$a),abs($p-$b),abs($p-$c)); return $a if $pa<=$pb && $pa<=$pc; return $b if $pb<=$pc; return $c; }
sub pixel_rgb { my($rgb,$w,$x,$y)=@_; return substr($rgb,3*($y*$w+$x),3); }
sub verify_reference_glyphs {
   my($path)=@_;
   my($w,$h,$rgb)=png_rgb($path);
   $w==320 && $h==228 or die "three-plus-three Stella reference is ${w}x${h}, expected 320x228\n";
   my $background=pixel_rgb($rgb,$w,0,0);
   my $left_color=pixel_rgb($rgb,$w,48,107);  # set pixel in digit 1, row 0
   my $right_color=pixel_rgb($rgb,$w,208,107); # set pixel in digit 4, row 0
   $left_color ne $background && $right_color ne $background && $left_color ne $right_color
      or die "three-plus-three Stella reference lost independent foreground colors\n";
   my @font=(
      [0x08,0x18,0x38,0x18,0x18,0x18,0x18,0x7e],
      [0x3c,0x46,0x06,0x06,0x3c,0x60,0x60,0x7e],
      [0x3c,0x46,0x06,0x1c,0x06,0x06,0x46,0x3c],
      [0x0c,0x1c,0x2c,0x4c,0x4c,0x7e,0x0c,0x0c],
      [0x7e,0x60,0x60,0x3c,0x06,0x06,0x46,0x3c],
      [0x3c,0x62,0x60,0x7c,0x66,0x66,0x66,0x3c],
   );
   my @fields=(
      [$left_color, [40,72,104], [0,1,2]],
      [$right_color,[200,232,264],[3,4,5]],
   );
   for my $field (@fields) {
      my($color,$origins,$digits)=@$field;
      for my $g (0..2) {
         for my $row (0..7) {
            my $bits=$font[$digits->[$g]][$row];
            for my $bit (0..7) {
               my $want=($bits & (0x80>>$bit)) ? $color : $background;
               for my $scale (0,1) {
                  my $x=$origins->[$g]+2*$bit+$scale; my $y=107+$row;
                  pixel_rgb($rgb,$w,$x,$y) eq $want or die sprintf(
                     "three-plus-three Stella reference glyph %d row %d pixel %d is not exact at (%d,%d)\n",
                     $digits->[$g]+1,$row,$bit,$x,$y);
               }
            }
         }
      }
   }
}
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }
sub symbol_addr {
   my($map,$name)=@_;
   return hex($1) if $map =~ /\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/;
   return hex($1) if $map =~ /\b\Q$name\E\b.*?run=\$([0-9A-Fa-f]{4})/;
   die "map is missing $name\n";
}

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n"; $tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $component=File::Spec->catfile($vcs,'three_plus_three_score_component.c26');
my $fixture=File::Spec->catfile($repo,qw(test fixtures three_plus_three_score boundary_carries.c26));
my $reference=File::Spec->catfile($repo,qw(test fixtures three_plus_three_score reference_stella_7.0.png));
my $public=File::Spec->catfile($repo,qw(examples 01_basic 08_dual_score dual_score.c26));
my $bin=File::Spec->catfile($tmp,'three_plus_three_score.bin');
my $mapfile=File::Spec->catfile($tmp,'three_plus_three_score.map');
my $public_bin=File::Spec->catfile($tmp,'dual_score.bin');
my $public_map=File::Spec->catfile($tmp,'dual_score.map');

my $source=read_file($component);
for my $contract (
   'TEMPLATE_DRAW_ENTRY_CYCLE := 3',
   'TEMPLATE_DRAW_RETURN_CYCLE := 0', 'TEMPLATE_DRAW_TERMINAL_WSYNC := 1',
   'TEMPLATE_DRAW_HMOVE_COUNT := 1', 'TEMPLATE_DRAW_SUCCESSOR_ON_RETURN_LINE := 1',
   'TEMPLATE_LEFT_GLYPH_ORIGIN_0 := 20', 'TEMPLATE_LEFT_GLYPH_ORIGIN_1 := 36',
   'TEMPLATE_LEFT_GLYPH_ORIGIN_2 := 52', 'TEMPLATE_RIGHT_GLYPH_ORIGIN_0 := 100',
   'TEMPLATE_RIGHT_GLYPH_ORIGIN_1 := 116', 'TEMPLATE_RIGHT_GLYPH_ORIGIN_2 := 132',
   'TEMPLATE_GLYPH_WIDTH := 8', 'TEMPLATE_GLYPH_ORIGIN_PITCH := 16') {
   index($source,$contract)>=0 or die "three-plus-three component lost contract '$contract'\n";
}
$source =~ /parameter\s+glyph_rows\s*:=\s*8/ &&
$source =~ /#elif TEMPLATE_glyph_rows == 8\s*\nalias TEMPLATE_VISIBLE_SCANLINES_VALUE 11/ &&
$source =~ /TEMPLATE_VISIBLE_SCANLINES\s*:=\s*TEMPLATE_VISIBLE_SCANLINES_VALUE/ &&
$source =~ /TEMPLATE_DRAW_COMPLETE_SCANLINES\s*:=\s*TEMPLATE_VISIBLE_SCANLINES_VALUE/
   or die "three-plus-three component lost glyph_rows default-height contract\n";
$source =~ /recommend\s+bcd16_t\s+TEMPLATE_left_score\s*:=\s*0/ &&
$source =~ /recommend\s+bcd16_t\s+TEMPLATE_right_score\s*:=\s*0/ &&
$source =~ /recommend\s+uint8_t\s+TEMPLATE_left_color\s*:=\s*0x0e/ &&
$source =~ /recommend\s+uint8_t\s+TEMPLATE_right_color\s*:=\s*0x0e/
   or die "component lost independent score/color state\n";
$source =~ /asm lda #3;\s*asm sta NUSIZ0;\s*asm sta NUSIZ1;/s
   or die "component lost three-close-copy player setup\n";
$source =~ /asm ldy #\$b2;.*asm sta RESP0;/s && $source =~ /asm ldy #\$58;.*asm sta RESP1;/s
   or die "component lost calibrated half-screen positioning\n";
for my $phase (qw(init vblank draw overscan)) {
   $source =~ /require\s+inline\s+void\s+TEMPLATE_\Q$phase\E\s*\(/
      or die "component is missing required TEMPLATE_$phase lifecycle declaration\n";
}
$source !~ /\b(?:VSYNC|VBLANK|TIM1T|TIM8T|TIM64T|T1024T|INTIM|TIMINT|AUDC0|AUDC1|AUDF0|AUDF1|AUDV0|AUDV1)\b\s*:=/
   or die "component takes ownership of scheduler or audio hardware\n";
$source =~ /asm sta HMM0;\s*asm sta HMM1;.*?#if TEMPLATE_paddle_samples == 0.*?asm sta HMBL;/s &&
$source =~ /asm sta RESP0;.*?#if TEMPLATE_paddle_samples >= 2.*?asm lda #0;\s*asm sta HMBL;/s
   or die "component does not neutralize hostile missile/Ball motion on both sampling paths\n";

my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$mapfile,$fixture,'-o',$bin);
$rc==0 && !$sig or die "boundary fixture build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "boundary fixture build wrote output\n$out$err";
-s $bin==4096 or die "boundary fixture is not 4096 bytes\n";
my $map=read_file($mapfile);
$map =~ /score_pointers\s+run=\$[0-9A-Fa-f]+ size=\$000C/ or die "component pointer allocation changed\n";
$map =~ /score_scratch\s+run=\$[0-9A-Fa-f]+ size=\$0002/ or die "component scratch allocation changed\n";
$map =~ /score_left_hundreds_rows\s+run=\$[0-9A-Fa-f]+ size=\$0008/ or die "component left-hundreds row cache changed\n";
$map =~ /BSS\.__vcsc_object\$score_left_score\s+run=\$[0-9A-Fa-f]+ size=\$0002/ or die "left score allocation changed\n";
$map =~ /BSS\.__vcsc_object\$score_right_score\s+run=\$[0-9A-Fa-f]+ size=\$0002/ or die "right score allocation changed\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my $oracle_src=File::Spec->catfile($repo,qw(test vcs_three_plus_three_score.cpp));
my $oracle=File::Spec->catfile($tmp,'vcs_three_plus_three_score_oracle');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2',
   '-DILLEGAL_OPCODES','-I',$mos,$oracle_src,@mos_input,'-o',$oracle);
$rc==0 && !$sig or die "three-plus-three oracle build failed\n$out$err";
$out eq '' && $err eq '' or die "three-plus-three oracle build wrote output\n$out$err";
my $left=sprintf('0x%02x',symbol_addr($map,'score_left_score'));
my $right=sprintf('0x%02x',symbol_addr($map,'score_right_score'));
($rc,$sig,$out,$err)=capture($oracle,$bin,$left,$right);
$rc==0 && !$sig or die "three-plus-three exact raster failed\n$out$err";
$out eq "vcs_three_plus_three_score ok: exact 3+3 raster, independent colors, BCD carries, and 262-line frames\n"
   or die "unexpected three-plus-three oracle output: $out";
$err eq '' or die "three-plus-three oracle stderr: $err";

($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$public_map,$public,'-o',$public_bin);
$rc==0 && !$sig or die "public dual-score example build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "public dual-score example wrote output\n$out$err";
-s $public_bin==2048 or die "public dual-score example is not 2048 bytes\n";
my $public_map_text=read_file($public_map);
$public_map_text =~ /rom\s+used=1538 bytes/ or die "public dual-score ROM accounting changed\n";
$public_map_text =~ /ram\s+used=45 bytes.*objects=41 bytes hardware-stack=4 bytes/ or die "public dual-score RAM accounting changed\n";

my $digest=File::Spec->catfile($repo,qw(test stella_png_rgb_digest.pl));
($rc,$sig,$out,$err)=capture($^X,$digest,$reference);
$rc==0 && !$sig or die "three-plus-three Stella reference digest failed\n$out$err";
$out eq "320 x 228 9fb7a8bb7d5a0917a329343273b9a1035b6d1728a5654b0e0c6ab5463bbbb560\n"
   or die "three-plus-three reviewed Stella reference changed: $out";
$err eq '' or die "three-plus-three reference digest stderr: $err";
verify_reference_glyphs($reference);

print "vcs_three_plus_three_score ok\n";
