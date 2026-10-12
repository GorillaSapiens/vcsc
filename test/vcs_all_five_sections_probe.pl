#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 300
# expectstdout: vcs_all_five_sections_probe ok
# expectexit: 0
# Experimental baked-in sections, not a new public renderer ABI.
# Reuse the certified cached all-five pipeline and compare moving objects against
# an exact-RGB composite of two ordinary, independently coloured golden rasters.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path remove_tree);
use File::Spec;
use IPC::Open3;
use POSIX qw(:sys_wait_h);
use Symbol qw(gensym);

sub slurp_file {
   my($path)=@_; open(my$f,'<:raw',$path) or die "read $path: $!\n";
   local$/; return <$f>//'';
}
sub write_file {
   my($path,$text)=@_; open(my$f,'>:raw',$path) or die "write $path: $!\n";
   print{$f}$text; close($f) or die "close $path: $!\n";
}
sub capture {
   my(@cmd)=@_; my$e=gensym; my$p=open3(my$i,my$o,$e,@cmd); close$i;
   local$/; my$out=<$o>//''; my$err=<$e>//''; waitpid($p,0);
   return($?>>8,$?&127,$out,$err);
}
sub ok {
   my($label,@cmd)=@_; my($r,$s,$o,$e)=capture(@cmd);
   !$r&&!$s or die "$label failed rc=$r sig=$s\n@cmd\n$o$e";
   return $o;
}
sub findexe {
   my($n)=@_; return abs_path($n) if$n=~m{/}&&-x$n;
   for(split(/:/,$ENV{PATH}//'')){my$p="$_/$n";return abs_path($p)if-x$p}
   die "required executable not found: $n\n";
}
my%children;
sub terminate {
   my($p)=@_; return unless delete$children{$p};
   my$done=waitpid($p,WNOHANG); return if$done==$p||$done==-1;
   kill 'TERM',$p;
   for(1..40){my$d=waitpid($p,WNOHANG);return if$d==$p||$d==-1;select undef,undef,undef,.025}
   kill 'KILL',$p; waitpid($p,0);
}
END { terminate($_) for keys%children; }
sub replace_once {
   my($text,$old,$new,$label)=@_;
   $$text =~ s/\Q$old\E/$new/ or die "probe source marker missing: $label\n";
}

(@ARGV==2||@ARGV==3) or die "usage: $0 REPO TMP [alternating|split_32|split_48|split_96]\n";
my$profile=$ARGV[2]//'alternating';
my%boundaries=(alternating=>undef,split_32=>32,split_48=>48,split_96=>96);
exists$boundaries{$profile} or die "unknown section profile: $profile\n";
my$repo=abs_path($ARGV[0]) or die "resolve repo\n";
make_path($ARGV[1]); my$tmp=abs_path($ARGV[1]);
require File::Spec->catfile($repo,qw(test stella_test_lib.pl));
# Load the existing PNG decoder without that command-line utility's main body.
my$png_helpers=slurp_file(File::Spec->catfile($repo,qw(test stella_png_sequence.pl)));
$png_helpers =~ s/\n\@ARGV>=2.*\z//s or die "PNG helper boundary missing\n";
eval $png_helpers; die $@ if$@;
my$driver=File::Spec->catfile($repo,qw(driver vcsc));
my$vcs=File::Spec->catdir($repo,qw(libraries vcs));
my$base=File::Spec->catfile($vcs,qw(renderers all_five_player_color_192 all_five_player_color_192.c26));
my$probe=slurp_file($base);
# The probe changes only the visible schedule. The stock mask builder, geometry,
# positioning, delayed-object latches and overscan restoration remain intact.
$probe =~ s{//[^\n]*}{}g;
my$pad7="   asm bit.z \$00;\n   asm nop;\n   asm nop;";
for my$cache(qw(A B)) {
   for my$pair(1..7) {
      replace_once(\$probe,"   asm \@TEMPLATE_${cache}_u$pair:;\n   asm lda.ay TEMPLATE_player0_colors,y;\n   asm sta COLUP0;",
         "   asm \@TEMPLATE_${cache}_u$pair:;\n$pad7","$cache pair $pair P0 slot");
   }
   # Pair-7 P0 selection: 11 cycles including GRP0 on either path, seven
   # fewer than the coloured selector. Use those seven to prepare P1's index
   # before the boundary, retaining the original boundary entry phase.
   my$old="   asm bcc.same \@TEMPLATE_${cache}_u7_p0_active;\n   asm lda #0;\n   asm tay;\n   asm bit.a CXM0P;\n   asm nop;\n   asm bcs.same \@TEMPLATE_${cache}_u7_p0_ready;\n   asm \@TEMPLATE_${cache}_u7_p0_active:;\n   asm lda.ay TEMPLATE_player0_colors,y;\n   asm sta COLUP0;\n   asm lda.iy (TEMPLATE_player0_graphics),y;\n   asm \@TEMPLATE_${cache}_u7_p0_ready:;\n   asm sta GRP0;";
   my$new="   asm bcc.same \@TEMPLATE_${cache}_u7_p0_active;\n   asm ldy #0;\n   asm sty.a GRP0;\n   asm jmp \@TEMPLATE_${cache}_u7_p0_ready;\n   asm \@TEMPLATE_${cache}_u7_p0_active:;\n   asm lda.iy (TEMPLATE_player0_graphics),y;\n   asm sta GRP0;\n   asm \@TEMPLATE_${cache}_u7_p0_ready:;\n   asm ldy.z TEMPLATE_object_masks + 1;\n   asm dey;\n   asm nop;";
   replace_once(\$probe,$old,$new,"$cache pair-7 preparation");

   my($ball,$m1,$left,$right,$pf,$bk)=$cache eq'A'?(11,12,7,9,0x46,0xc2):(4,5,0,2,0x2e,0x84);
   my$prep=$cache eq'A'
      ?"   asm lsr.z TEMPLATE_row_cache + $ball;\n   asm nop;\n   asm bit.z \$00;"
      :"   asm lsr.a TEMPLATE_row_cache + $ball;";
   $old="$prep\n   asm ldy.z TEMPLATE_object_masks + 1;\n   asm dey;\n   asm sty.z TEMPLATE_object_masks + 1;";
   $new=$cache eq'A'
      ?"   asm lsr.z TEMPLATE_row_cache + $ball;\n   asm sty.z TEMPLATE_object_masks + 1;\n   asm cpy.z TEMPLATE_player1_height;\n   asm bit.z \$00;\n   asm nop;\n   asm nop;"
      :"   asm lsr.a TEMPLATE_row_cache + $ball;\n   asm sty.z TEMPLATE_object_masks + 1;\n   asm cpy.z TEMPLATE_player1_height;\n   asm nop;";
   replace_once(\$probe,$old,$new,"$cache boundary prepared P1");

   $old="   asm cpy.z TEMPLATE_player1_height;\n   asm bcs.same \@TEMPLATE_${cache}_boundary_p1_zero;\n   asm lda.ay TEMPLATE_player1_colors,y;\n   asm sta COLUP1;\n   asm lda.iy (TEMPLATE_player1_graphics),y;\n   asm jmp \@TEMPLATE_${cache}_boundary_p1_ready;\n   asm \@TEMPLATE_${cache}_boundary_p1_zero:;\n   asm ldy #0;\n   asm lda.ay TEMPLATE_player1_colors,y;\n   asm sta COLUP1;\n   asm lda #0;\n   asm bit.z \$00;\n   asm \@TEMPLATE_${cache}_boundary_p1_ready:;";
   $new="   asm bcs.same \@TEMPLATE_${cache}_boundary_p1_zero;\n   asm lda.iy (TEMPLATE_player1_graphics),y;\n   asm jmp \@TEMPLATE_${cache}_boundary_p1_ready;\n   asm \@TEMPLATE_${cache}_boundary_p1_zero:;\n   asm lda #0;\n   asm tay;\n   asm bit.z \$00;\n   asm \@TEMPLATE_${cache}_boundary_p1_ready:;\n   asm ldy.z TEMPLATE_object_masks + 0;\n   asm dey;\n   asm sty.z TEMPLATE_object_masks + 0;\n   asm nop;";
   replace_once(\$probe,$old,$new,"$cache boundary prepares P0");

   # GRP1 stays at cycle 2. Palette stores finish at cycles 7/12, M1 at
   # 18 and left PF1/PF2 at 24/30. Move the M1 shift and one INX later;
   # CPY follows the shift, preserving the P0 selector's carry.
   $old="   asm sta GRP1;\n   asm lda.z TEMPLATE_row_cache + $m1;\n   asm sta ENAM1;\n   asm lsr.z TEMPLATE_row_cache + $m1;\n   asm lda.z TEMPLATE_row_cache + $left;\n   asm sta PF1;\n   asm lda.z TEMPLATE_row_cache + ".($left+1).";\n   asm sta PF2;\n   asm ldy.z TEMPLATE_object_masks + 0;\n   asm dey;\n   asm sty.z TEMPLATE_object_masks + 0;\n   asm cpy.z TEMPLATE_player0_height;\n   asm inx;\n   asm inx;\n   asm inx;";
   $new=sprintf("   asm sta GRP1;\n   asm lda #\$%02x;\n   asm sta COLUPF;\n   asm lda #\$%02x;\n   asm sta COLUBK;\n   asm lda.z TEMPLATE_row_cache + $m1;\n   asm sta ENAM1;\n   asm lda.z TEMPLATE_row_cache + $left;\n   asm sta PF1;\n   asm lda.z TEMPLATE_row_cache + %d;\n   asm sta PF2;\n   asm lsr.z TEMPLATE_row_cache + $m1;\n   asm cpy.z TEMPLATE_player0_height;\n   asm inx;\n   asm inx;",$pf,$bk,$left+1);
   replace_once(\$probe,$old,$new,"$cache boundary immediate palette");
   my$next=$cache eq'A'?'B':'A';
   $old="   asm \@TEMPLATE_${cache}_first${next}_p0_ready:;\n   asm sta GRP0;\n   asm inx;\n   asm nop;";
   $new="   asm \@TEMPLATE_${cache}_first${next}_p0_ready:;\n   asm sta GRP0;\n   asm inx;\n   asm inx;";
   replace_once(\$probe,$old,$new,"$cache boundary final index step");
}
# Solid colours only in this proof. Every remaining visible player-colour slot
# becomes the same seven-cycle padding; there is no section table or selector.
$probe =~ s/   asm lda\.ay TEMPLATE_player1_colors,y;\n   asm sta COLUP1;/$pad7/g;
# The preceding replacement also pads the untimed VBLANK slot; main sets COLUP1.
$probe !~ /asm lda\.ay TEMPLATE_player[01]_colors/ or die "colour lookup remains\n";
# An equal-time, one-byte-longer pad keeps the changed pair selectors within
# their asserted pages. Keep all .same contracts: a crossing adds a real cycle.
replace_once(\$probe,"   asm \@TEMPLATE_A_u4:;\n$pad7",
   "   asm \@TEMPLATE_A_u4:;\n   asm nop;\n   asm nop;\n   asm jmp \@TEMPLATE_A_u4_pad_done;\n   asm \@TEMPLATE_A_u4_pad_done:;",'page-safe seven-cycle pad');
# A's fall-through three-cycle pad becomes a three-cycle jump over B's page
# anchor. B's outgoing boundary already jumps to A's existing page anchor.
replace_once(\$probe,"   asm sta GRP0;\n   asm inx;\n   asm inx;\n   asm bit.z \$00;\n   \n   asm \@TEMPLATE_B_u1:;",
   "   asm sta GRP0;\n   asm inx;\n   asm inx;\n   asm jmp \@TEMPLATE_B_u1;\n   asm .align 256, \$90;\n   asm \@TEMPLATE_B_u1:;",'B row page anchor');
replace_once(\$probe,"   asm \@TEMPLATE_B_u4:;\n$pad7",
   "   asm \@TEMPLATE_B_u4:;\n   asm nop;\n   asm nop;\n   asm jmp \@TEMPLATE_B_u4_pad_done;\n   asm \@TEMPLATE_B_u4_pad_done:;",'B page-safe seven-cycle pad');
write_file("$tmp/sections_probe.c26",$probe);

sub boundary_palette {
   my($text,$pf,$bk)=@_;
   my$n=$$text =~ s/   asm lda #\$[0-9a-f]{2};\n   asm sta COLUPF;\n   asm lda #\$[0-9a-f]{2};\n   asm sta COLUBK;/sprintf("   asm lda #\$%02x;\n   asm sta COLUPF;\n   asm lda #\$%02x;\n   asm sta COLUBK;",$pf,$bk)/ge;
   $n or die "missing boundary palette\n";
}
sub two_sections {
   my($source,$lines)=@_;
   $lines>0&&$lines<192&&$lines%16==0 or die "two-section proof requires an interior packed-row boundary\n";
   my($a)=$source =~ /   asm \@TEMPLATE_A_u7:;\n\Q$pad7\E\n(.*?)   asm \.align 256, \$90;\n   asm \@TEMPLATE_B_u1:;/s;
   my($b)=$source =~ /   asm \@TEMPLATE_B_u7:;\n\Q$pad7\E\n(.*?)\n}\n\nrequire inline void TEMPLATE_overscan/s;
   defined$a&&defined$b or die "missing packed-row tails\n";
   boundary_palette(\$source,0x2e,0x84);
   my$copies='';
   for my$cache(qw(A B)) {
      my$body=$cache eq'A'?$a:$b;
      boundary_palette(\$body,0x46,0xc2);
      $body =~ s/\@TEMPLATE_(?!(?:A|B)_u1\b)(\w+)/\@TEMPLATE_split_$1/g;
      if($cache eq'B') {
         replace_once(\$body,'   asm sta WSYNC;','   asm jmp @TEMPLATE_sections_last_wsync;','shared terminal WSYNC');
      }
      $copies.="   asm .align 256, \$90;\n   asm \@TEMPLATE_split_${cache}_u7:;\n$body\n";
      # Spend the existing seven-cycle pad on a balanced row-end dispatch.
      # The cutoff is baked into code; no palette/section lookup table is used.
      my$dispatch=sprintf("   asm \@TEMPLATE_${cache}_u7:;\n   asm cpx #%d;\n   asm bcc.same \@TEMPLATE_${cache}_u7_top;\n   asm jmp \@TEMPLATE_split_${cache}_u7;\n   asm \@TEMPLATE_${cache}_u7_top:;\n   asm nop;",($lines/16-1)*4);
      replace_once(\$source,"   asm \@TEMPLATE_${cache}_u7:;\n$pad7",$dispatch,"$cache fixed section dispatch");
   }
   # Copies are off the raster's fall-through path. Both paths rejoin the
   # original cached pair loops; no object state is reinitialised at the seam.
   $source =~ s/(   asm jmp \@TEMPLATE_A_u1;\n)(\s*asm \.align 256, \$90;)/$1$copies$2/
      or die "missing off-path copy anchor\n";
   replace_once(\$source,"   asm sta WSYNC;\n}\n\nrequire inline void TEMPLATE_overscan",
      "   asm \@TEMPLATE_sections_last_wsync:;\n   asm sta WSYNC;\n}\n\nrequire inline void TEMPLATE_overscan",'terminal handoff');
   return$source;
}

my$fixture=slurp_file(File::Spec->catfile($repo,qw(test fixtures all_five_player_color_192 all_five_match.c26)));
# Distinct halves and neighbouring rows make early/late PF rewrites observable;
# a symmetric pattern alone can hide a broken mid-scanline schedule.
my@pf;
push@pf, $_&1?(0x36,0x81,0x18,0xa5):(0x81,0x18,0x42,0x24) for 0..11;
my$pf_source=join(',',map{sprintf('0x%02x',$_)}@pf);
$fixture =~ s/(page const uint8_t game_playfield\[48\] := )\{.*?\};/$1\{$pf_source\};/s
   or die "fixture playfield marker missing\n";
$fixture =~ s/game_PLAYER1_X := 130;/game_PLAYER1_X := 60;/;
$fixture =~ s/game_MISSILE0_X := 50;/game_MISSILE0_X := 85;/;
$fixture =~ s/game_BALL_X := 80;/game_BALL_X := 148;/;
$fixture =~ s/game_missile0_height := 5;/game_missile0_height := 7;/;
$fixture =~ s/game_ball_height := 3;/game_ball_height := 7;/;
$fixture =~ s/void main\(void\)/uint8_t motion;\nvoid main(void)/;
$fixture =~ s/game_vblank\(\);/motion := (motion + 1) \& 15;\n      game_player0_y := 8 + motion;\n      game_player1_y := 8 + motion;\n      game_missile0_y := 8 + motion;\n      game_missile1_y := 8 + motion;\n      game_ball_y := 8 + motion;\n      COLUPF := 0x2e;\n      COLUBK := 0x84;\n      game_vblank();/;
my@cases=(['together',undef,undef]);
push@cases, ["${_}_left",$_,0],["${_}_right",$_,159] for qw(P0 P1 M0 M1 BL);
my$moving_fixture=$fixture;
my$work_tmp=$tmp;
my$profile_boundary=$boundaries{$profile};
for my$layout([$profile,$profile_boundary,defined$profile_boundary?two_sections($probe,$profile_boundary):$probe]) {
my($layout_name,$boundary,$layout_source)=@$layout;
$tmp=$layout_name eq'alternating'?$work_tmp:File::Spec->catdir($work_tmp,$layout_name);
make_path($tmp); write_file("$tmp/sections_probe.c26",$layout_source);
for my$case(@cases) {
my($case_name,$isolated,$endpoint)=@$case;
my$case_tmp=File::Spec->catdir($tmp,$case_name); make_path($case_tmp);
my$root_tmp=$tmp; $tmp=$case_tmp;
$fixture=$moving_fixture;
my$motion_base=($boundary//16)/2;
$fixture =~ s/ := 8 \+ motion;/ := $motion_base + motion;/g;
if(defined$isolated) {
   my%names=(P0=>'PLAYER0',P1=>'PLAYER1',M0=>'MISSILE0',M1=>'MISSILE1',BL=>'BALL');
   my%ys=(P0=>'player0',P1=>'player1',M0=>'missile0',M1=>'missile1',BL=>'ball');
   $fixture =~ s/game_$names{$isolated}_X := \d+;/game_$names{$isolated}_X := $endpoint;/
      or die "missing $isolated X assignment\n";
   for my$obj(qw(P0 P1 M0 M1 BL)) {
      next if$obj eq$isolated;
      if($obj eq'P0'||$obj eq'P1') {
         my$gfx=$obj eq'P0'?'p0_graphics':'p1_graphics';
         $fixture =~ s/(page const uint8_t $gfx\[8\] := )\{.*?\};/$1\{0,0,0,0,0,0,0,0\};/s
            or die "missing $obj graphics\n";
      } else {
         my$y=$ys{$obj};
         $fixture =~ s/game_${y}_y := $motion_base \+ motion;/game_${y}_y := 255;/
            or die "missing $obj moving Y\n";
      }
   }
}
my%rom;
for my$name(qw(top bottom sections)) {
   my$source=$fixture;
   if($name eq'sections') {
      $source =~ s#renderers/all_five_player_color_192/all_five_player_color_192\.c26#sections_probe.c26# or die "fixture renderer marker missing\n";
   } elsif($name eq'bottom') {
      $source =~ s/COLUPF := 0x2e;/COLUPF := 0x46;/g;
      $source =~ s/COLUBK := 0x84;/COLUBK := 0xc2;/g;
   }
   write_file("$tmp/$name.c26",$source); $rom{$name}="$tmp/$name.bin";
   ok("build $case_name $name",$driver,'-I',$vcs,'-I',$root_tmp,'-Map',"$tmp/$name.map","$tmp/$name.c26",'-o',$rom{$name});
   -s$rom{$name}==4096 or die "$name exceeds the 4K proof budget\n";
}
my$mos=File::Spec->catdir($repo,qw(simulator mos6502));
my$mos_obj=File::Spec->catfile($mos,'mos6502.o');
my@mos_input=-f$mos_obj?($mos_obj):(File::Spec->catfile($mos,'mos6502.cpp'));
my$timing="$root_tmp/frame_timing";
unless(-x$timing) {
ok('build timing',$ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp)),@mos_input,'-o',$timing);
}
ok('section frame timing',$timing,$rom{sections},'50','--no-audio','--raw-lines','264');

my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella');
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb');
my(undef,$display)=vcsc_reserve_x_display(250,40);
my$xpid=fork(); defined$xpid or die "fork Xvfb\n";
if(!$xpid){open(STDOUT,'>:raw',"$tmp/xvfb.log");open(STDERR,'>&STDOUT');exec($xvfb,$display,'-ac','-screen','0','1024x768x24');die$!}
$children{$xpid}=1; vcsc_xvfb_assert_ready($display,$xpid);
local$ENV{DISPLAY}=$display; local$ENV{XAUTHORITY}='/dev/null'; local$ENV{SDL_AUDIODRIVER}='dummy';
my%frames;
for my$name(qw(top bottom sections)) {
   my$snap="$tmp/snap_$name"; my$user="$tmp/user_$name";
   remove_tree($snap,$user); make_path($snap,$user);
   my@cmd=($stella,vcsc_stella_palette_args($repo,$user),
      '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
      '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
      '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0',
      '-bs','4K','-framesnap','200-215','-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
      '-exitlauncher','0','-confirmexit','0','-userdir',$user,$rom{$name});
   my$pid=fork(); defined$pid or die "fork Stella\n";
   if(!$pid){open(STDOUT,'>:raw',"$tmp/stella_$name.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
   $children{$pid}=1;
   my@png; for(1..1200){@png=grep{-s$_}glob("$snap/*.png");last if@png==16;select undef,undef,undef,.025}
   terminate($pid); @png==16 or die "$name captured ".scalar(@png)." frames, expected 16\n";
   for my$path(@png) {
      $path =~ /_([0-9A-F]{8})\.png$/ or die "unrecognised framesnap filename: $path\n";
      my$f=hex($1); $f>=200&&$f<=215 or die "wrong capture frame $f\n";
      $frames{$name}{$f}=[decode_rgb($path)];
   }
}
my%motion_rasters;
my%crossed;
my@objects=(
   ['P0',26,62,'e8e8e6'], ['P1',100,142,'46ab44'],
   ['M0',160,190,'e8e8e6'], ['M1',208,242,'46ab44'],
   ['BL',288,319,'e8bc48'],
);
if(defined$isolated) {
   @objects=grep{$_->[0]eq$isolated}@objects;
   $objects[0][1]=$endpoint==0?0:310;
   $objects[0][2]=$endpoint==0?18:319;
}
for my$f(200..215) {
   my($w,$h,$gold)=@{$frames{top}{$f}};
   my($bw,$bh,$other)=@{$frames{bottom}{$f}};
   my($cw,$ch,$actual)=@{$frames{sections}{$f}};
   $w==$bw&&$h==$bh&&$w==$cw&&$h==$ch or die "frame $f image geometry differs\n";
   # The PF0 margin has no objects. Its modal golden RGB identifies the visible
   # area without assuming how Stella transforms the pinned palette internally.
   # Pixel comparisons below remain exact RGB, not colour-normalised digests.
   my%margin; $margin{substr($gold,($_*$w+20)*3,3)}++ for 0..$h-1;
   my($background)=sort{$margin{$b}<=>$margin{$a}}keys%margin;
   my@visible=grep{substr($gold,($_*$w+20)*3,3)eq$background}0..$h-1;
   @visible==192 or die "frame $f has ".scalar(@visible)." visible rows, expected 192\n";
   my$first=$visible[0]; my$expected=$gold;
   # Require an actual straddling pose for each of the five objects, not just
   # changing whole-frame digests. The golden fixture isolates their X windows;
   # BL is in the zero PF0 margin so its shared playfield colour is distinguishable.
   for my$obj(@objects) {
      my($name,$lo,$hi,$hex)=@$obj; my$colour=pack('H6',$hex); my@halves;
      my$seam=$first+($boundary//16);
      for my$range([$seam-8,$seam-1],[$seam,$seam+7]) {
         my$found=0;
         for my$y($range->[0]..$range->[1]) {
            for my$x($lo..$hi) {
               $found=1 if substr($gold,($y*$w+$x)*3,3)eq$colour;
            }
         }
         push@halves,$found;
      }
      $crossed{$name}=1 if$halves[0]&&$halves[1];
   }
   for my$y($first..$first+191) {
      next unless defined$boundary ? $y-$first>=$boundary : int(($y-$first)/16)&1;
      substr($expected,$y*$w*3,$w*3)=substr($other,$y*$w*3,$w*3);
   }
   if($actual ne$expected) {
      for(my$i=0;$i<length($actual);$i+=3) {
         next if substr($actual,$i,3)eq substr($expected,$i,3);
         my$pixel=$i/3; die sprintf("%s/%s frame %d pixel (%d,%d) differs: actual=%s expected=%s\n",
            $layout_name,$case_name,$f,$pixel%$w,int($pixel/$w),unpack('H6',substr($actual,$i,3)),unpack('H6',substr($expected,$i,3)));
      }
   }
   $motion_rasters{$gold}=1;
}
keys(%motion_rasters)==16 or die "motion proof did not exercise all sixteen positions\n";
$crossed{$_->[0]} or die "$_->[0] never straddled the section seam\n" for@objects;
terminate($xpid); vcsc_release_x_displays();
$tmp=$root_tmp;
}
}
print "vcs_all_five_sections_probe ok\n";
