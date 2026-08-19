#!/usr/bin/env perl
# Optional Stella 7.0 pixel-level regression for enhanced_multisprite.
# This test judges actual TIA pixels.  The CPU-only regression proves frame
# timing/fair arbitration; this one protects horizontal phase, lane symmetry,
# equal-Y overlap, and top-edge placement from emulator-visible regressions.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path remove_tree);
use File::Spec;
use IPC::Open3;
use POSIX qw(:sys_wait_h);
use Symbol qw(gensym);
use Compress::Zlib qw(uncompress);

sub slurp_fh { my($f)=@_; local $/; return <$f>//''; }
sub capture { my(@c)=@_; my$e=gensym; my$p=open3(my$i,my$o,$e,@c); close$i; my$so=slurp_fh($o); my$se=slurp_fh($e); waitpid($p,0); return($?>>8,$?&127,$so,$se); }
sub ok { my($label,@c)=@_; my($r,$s,$o,$e)=capture(@c); $r==0&&!$s or die "$label failed rc=$r sig=$s\n@c\n$o$e"; return($o,$e); }
sub findexe { my($n)=@_; return abs_path($n) if $n=~m{/}&&-x$n; for(split(/:/,$ENV{PATH}//'')){my$p="$_/$n";return abs_path($p)if-x$p} return undef; }
sub terminate { my($p)=@_; return unless$p; kill 'TERM',$p; for(1..20){my$d=waitpid($p,WNOHANG);return if$d==$p||$d==-1;select undef,undef,undef,.05} kill 'KILL',$p;waitpid($p,0); }
sub read_file { my($p)=@_; open(my$f,'<:raw',$p) or die "read $p: $!\n"; local$/; my$d=<$f>; close$f; return$d//''; }
sub write_file { my($p,$d)=@_; open(my$f,'>:raw',$p) or die "write $p: $!\n"; print {$f}$d; close$f or die "close $p: $!\n"; }
sub paeth { my($a,$b,$c)=@_; my$p=$a+$b-$c; my($pa,$pb,$pc)=(abs($p-$a),abs($p-$b),abs($p-$c)); return$a if$pa<=$pb&&$pa<=$pc; return$b if$pb<=$pc; return$c; }

sub decode_png_rgb {
   my($path)=@_; my$png=read_file($path); substr($png,0,8) eq "\x89PNG\r\n\x1a\n" or die "$path is not PNG\n";
   my($w,$h,$depth,$ct,$interlace,$palette,$idat); ($palette,$idat)=('',''); my$o=8;
   while($o<length($png)) { my$n=unpack('N',substr($png,$o,4)); my$type=substr($png,$o+4,4); $o+=8; my$d=substr($png,$o,$n); $o+=$n+4;
      if($type eq 'IHDR'){($w,$h,$depth,$ct,undef,undef,$interlace)=unpack('NNCCCCC',$d)} elsif($type eq 'PLTE'){$palette=$d} elsif($type eq 'IDAT'){$idat.=$d} elsif($type eq 'IEND'){last} }
   defined($w)&&$depth==8&&$interlace==0 or die "$path uses unsupported PNG encoding\n";
   my%ch=(0=>1,2=>3,3=>1,4=>2,6=>4); exists$ch{$ct} or die "$path uses unsupported PNG color type $ct\n";
   my$c=$ch{$ct}; my$rowbytes=$w*$c; my$raw=uncompress($idat); defined$raw or die "$path has invalid compressed data\n";
   length($raw)==($rowbytes+1)*$h or die "$path has unexpected scanline bytes\n";
   my@prev=(0)x$rowbytes; my$pos=0; my$rgb='';
   for my$y(0..$h-1){ my$filter=ord(substr($raw,$pos++,1)); my@row=unpack('C*',substr($raw,$pos,$rowbytes)); $pos+=$rowbytes;
      for my$x(0..$#row){my$left=$x>=$c?$row[$x-$c]:0;my$up=$prev[$x];my$ul=$x>=$c?$prev[$x-$c]:0;
         if($filter==1){$row[$x]=($row[$x]+$left)&255}elsif($filter==2){$row[$x]=($row[$x]+$up)&255}elsif($filter==3){$row[$x]=($row[$x]+int(($left+$up)/2))&255}elsif($filter==4){$row[$x]=($row[$x]+paeth($left,$up,$ul))&255}elsif($filter!=0){die "$path uses unknown PNG filter $filter\n"}}
      for my$x(0..$w-1){my$i=$x*$c;if($ct==0||$ct==4){$rgb.=pack('C3',($row[$i])x3)}elsif($ct==3){$rgb.=substr($palette,$row[$i]*3,3)}else{$rgb.=pack('C3',@row[$i,$i+1,$i+2])}}
      @prev=@row;
   }
   return($w,$h,$rgb);
}
sub color_extent {
   my($png,$want)=@_; my($w,$h,$rgb)=decode_png_rgb($png); $w==320 or die "$png unexpected Stella width $w\n";
   my(%x,%y); for my$yy(0..$h-1){for my$xx(0..$w-1){my$i=3*($yy*$w+$xx);next unless substr($rgb,$i,3) eq $want;$x{int($xx/2)}=1;$y{$yy}=1}}
   return([sort{$a<=>$b}keys%x],[sort{$a<=>$b}keys%y]);
}
sub expect_x { my($label,$actual,@want)=@_; my$a=join(',',@$actual); my$w=join(',',@want); $a eq $w or die "$label X pixels [$a], expected [$w]\n"; }
sub expect_y { my($label,$actual,$lo,$hi)=@_; @$actual or die "$label has no pixels\n"; ($actual->[0]==$lo && $actual->[-1]==$hi && @$actual==$hi-$lo+1) or die "$label Y extent $actual->[0]..$actual->[-1] (".scalar(@$actual)." lines), expected $lo..$hi\n"; }
sub expect_same_full_y { my($label,$a,$b)=@_; @$a==16 && @$b==16 or die "$label expected 16 physical rows on both lanes\n"; join(',',@$a) eq join(',',@$b) or die "$label lanes disagree in Y: [".join(',',@$a)."] vs [".join(',',@$b)."]\n"; for my$i(1..15){$a->[$i]==$a->[0]+$i or die "$label has a Y gap\n";} }
sub expect_glyph_exact {
   my($label,$png,$want,$origin_x,$rows)=@_;
   my($w,$h,$rgb)=decode_png_rgb($png);
   my%seen;
   for my$yy(0..$h-1){for my$xx(0..$w-1){my$i=3*($yy*$w+$xx);next unless substr($rgb,$i,3) eq $want;$seen{int($xx/2).','.$yy}=1}}
   my@actual=map{my($x,$y)=split(/,/);[$x+0,$y+0]} sort { my($ax,$ay)=split(/,/,$a); my($bx,$by)=split(/,/,$b); $ay<=>$by || $ax<=>$bx } keys%seen;
   @actual or die "$label has no pixels\n";
   my$top=$actual[0][1];
   my@expected;
   for my$r(0..7){
      for my$dy(0,1){for my$dx(@{$rows->[$r]}){push @expected,[$origin_x+$dx,$top+$r*2+$dy]}}
   }
   my$a=join(';',map{"$_->[0],$_->[1]"}@actual);
   my$e=join(';',map{"$_->[0],$_->[1]"}@expected);
   $a eq $e or die "$label glyph/color pixels differ from the exact eight-row contract\n";
}

my@p0_rows=(
   [1,2,3,4],[0,1,4,5],[-1,0,5,6],[-1,0,2,3,5,6],
   [-1,0,2,3,5,6],[-1,0,5,6],[0,1,4,5],[1,2,3,4],
);

@ARGV==2 or die "usage: $0 REPO TMP\n";
my$repo=abs_path($ARGV[0]) or die "resolve repo\n"; my$tmp=$ARGV[1]; make_path($tmp); $tmp=abs_path($tmp);
my$stella=$ENV{VCSC_STELLA}||$ENV{STELLA}||findexe('stella') or die "set STELLA or VCSC_STELLA\n";
my$xvfb=findexe('Xvfb') or die "Xvfb required\n"; my$perl=findexe('perl') or die "perl required\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc)); my$vcs=File::Spec->catdir($repo,qw(libraries vcs));
my$keys=File::Spec->catfile($repo,qw(test stella_snapshot_keys.pl));
my$source=File::Spec->catfile($repo,qw(examples 18_enhanced_multisprite 01_192 01_interactive enhanced_multisprite_192_interactive.c26));
my$needle="   initialize_enhanced_scene();\n";
my%rgb=(p0=>pack('C3',234,234,233),p1=>pack('C3',253,134,133),p2=>pack('C3',134,253,133),p3=>pack('C3',121,221,251),p4=>pack('C3',234,130,220),p5=>pack('C3',121,253,207));

my$display=320+($$%30); $display++ while -e "/tmp/.X11-unix/X$display"; my$d=":$display";
my$xpid=fork(); defined$xpid or die "fork Xvfb\n"; if(!$xpid){open(STDOUT,'>:raw',"$tmp/xvfb.log");open(STDERR,'>&STDOUT');exec($xvfb,$d,'-ac','-screen','0','1024x768x24');die$!}
select undef,undef,undef,.2; local$ENV{DISPLAY}=$d; local$ENV{XAUTHORITY}='/dev/null'; local$ENV{HOME}=$tmp; local$ENV{SDL_AUDIODRIVER}='dummy';

sub snapshot_text {
   my($name,$src_text)=@_;
   my($vol,$dirs,$file)=File::Spec->splitpath($source); my$case_src=File::Spec->catfile($dirs,"__stella_enhanced_$name.c26"); write_file($case_src,$src_text);
   my$rom=File::Spec->catfile($tmp,"$name.bin"); eval { ok("build $name",$driver,'-I',$vcs,'-Wa,--illegals',$case_src,'-o',$rom); 1 } or do { my$e=$@; unlink$case_src; die$e; }; unlink$case_src;
   my$work=File::Spec->catdir($tmp,$name); remove_tree($work); make_path(File::Spec->catdir($work,'snap'),File::Spec->catdir($work,'user'));
   my$snap=File::Spec->catdir($work,'snap'); my$user=File::Spec->catdir($work,'user');
   my@cmd=($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','4K','-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1','-exitlauncher','0','-confirmexit','0','-userdir',$user,$rom);
   my$pid=fork(); defined$pid or die "fork Stella\n"; if(!$pid){open(STDOUT,'>:raw',"$work/stella.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
   select undef,undef,undef,.25; ok("snapshot $name",$perl,$keys); my@png; for(1..40){@png=grep{-s$_}glob("$snap/*.png");last if@png==1;select undef,undef,undef,.04}
   terminate($pid); @png==1 or die "$name produced ".scalar(@png)." snapshots\n"; return$png[0];
}

sub snapshot_case {
   my($name,@assign)=@_; my$src_text=read_file($source); index($src_text,$needle)>=0 or die "insertion point missing\n";
   my$insert=$needle.join('',map{"   $_;\n"}@assign); $src_text =~ s/\Q$needle\E/$insert/;
   return snapshot_text($name,$src_text);
}

sub snapshot_case_loop {
   my($name,$loop,@assign)=@_; my$src_text=read_file($source); index($src_text,$needle)>=0 or die "insertion point missing\n";
   my$insert=$needle.join('',map{"   $_;\n"}@assign); $src_text =~ s/\Q$needle\E/$insert/;
   $src_text =~ s/   while \(1\) \{\n/   while (1) {\n$loop/ or die "loop insertion point missing\n";
   return snapshot_text($name,$src_text);
}

sub overlap_case {
   my($name,$first,$second,$x1,$x2)=@_;
   my$png=snapshot_case($name,
      'game_PLAYER0_Y := 35','game_PLAYER1_Y := 50','game_PLAYER2_Y := 50','game_PLAYER3_Y := 89','game_PLAYER4_Y := 25','game_PLAYER5_Y := 10',
      "game_PLAYER1_X := $x1","game_PLAYER2_X := $x2",
      "game_priority[0] := $first","game_priority[1] := $second",'game_priority[2] := 0','game_priority[3] := 3','game_priority[4] := 4','game_priority[5] := 5');
   my($xred,$yred)=color_extent($png,$rgb{p1}); my($xgreen,$ygreen)=color_extent($png,$rgb{p2});
   my@r=$x1==159?(0,1,2,3,4,159):($x1..$x1+5); @r=sort{$a<=>$b}@r;
   my@g=$x2==159?(0,1,2,3,4,159):($x2..$x2+5); @g=sort{$a<=>$b}@g;
   expect_x("$name P1",$xred,@r); expect_x("$name P2",$xgreen,@g);
   expect_same_full_y("$name equal-Y overlap",$yred,$ygreen);
}

# Keep the two same-Y sprites horizontally disjoint so TIA object priority
# cannot hide pixels from the oracle.  Repeat each edge with the priority order
# reversed; that moves the same logical sprite from P0 to P1 without changing X.
overlap_case('left_on_p0',1,2,0,100);
overlap_case('left_on_p1',2,1,0,100);
overlap_case('right_on_p0',1,2,159,100);
overlap_case('right_on_p1',2,1,159,100);

# Exact vertical handoff/color regression. These were the interactive Y positions
# that previously duplicated, dropped, or recolored rows while sprite 0 moved
# through stationary sprites. Reset priority every frame so P0 is always
# accepted first and the snapshot is deterministic; omissions elsewhere do not
# affect this exact gray-glyph oracle.
my$identity_priority="      game_priority[0] := 0; game_priority[1] := 1; game_priority[2] := 2; game_priority[3] := 3; game_priority[4] := 4; game_priority[5] := 5;\n";
for my$y(64,52,44,28,25){
   my$png=snapshot_case_loop("handoff_y$y",$identity_priority,"game_PLAYER0_Y := $y");
   expect_glyph_exact("handoff Y=$y P0",$png,$rgb{p0},18,\@p0_rows);
}

# Force logical sprite 0 onto P1 in a clean two-way pile and certify that its
# special PLAYER0_GLYPH layout survives the symmetric hardware-lane path too.
my$p0_on_p1="      game_priority[0] := 5; game_priority[1] := 0; game_priority[2] := 1; game_priority[3] := 2; game_priority[4] := 3; game_priority[5] := 4;\n";
my$p1lane=snapshot_case_loop('p0_on_p1',$p0_on_p1,'game_PLAYER0_Y := 25','game_PLAYER5_Y := 25');
expect_glyph_exact('logical P0 on hardware P1',$p1lane,$rgb{p0},18,\@p0_rows);

# Top legal Y must remain a full eight logical rows (16 physical scanlines).
my$top=snapshot_case('top_y89','game_PLAYER1_X := 80','game_PLAYER1_Y := 89','game_priority[0] := 1','game_priority[1] := 0','game_PLAYER0_Y := 60','game_PLAYER2_Y := 40','game_PLAYER3_Y := 25','game_PLAYER4_Y := 12','game_PLAYER5_Y := 0');
my($tx,$ty)=color_extent($top,$rgb{p1}); expect_x('top Y=89 P1',$tx,80..85); @$ty==16 or die "top Y=89 P1 is clipped\n"; ($ty->[0]==27 || $ty->[0]==28) or die "top Y=89 P1 starts at unexpected Stella row $ty->[0]\n"; for my$i(1..15){$ty->[$i]==$ty->[0]+$i or die "top Y=89 P1 has a Y gap\n";}

terminate($xpid);
print "Stella enhanced multisprite pixels passed: calibrated X edges, symmetric lanes, exact setup-handoff glyph/color rows, solid overlap, and top reach\n";
