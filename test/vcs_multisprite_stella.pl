#!/usr/bin/perl
# Optional Stella 7.0 pixel-level regression for the modern multisprite renderer.
# Unlike vcs_multisprite_profiles.cpp, this deliberately judges rendered pixels,
# not a formula inferred from RESP/HMP write cycles.
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
   my($png,$want,$ymin,$ymax)=@_; my($w,$h,$rgb)=decode_png_rgb($png); $w==320 or die "$png unexpected Stella width $w\n";
   $ymin=0 if !defined$ymin; $ymax=$h-1 if !defined$ymax || $ymax>=$h;
   my(%x,%y);
   for my$yy($ymin..$ymax){for my$xx(0..$w-1){my$i=3*($yy*$w+$xx);next unless substr($rgb,$i,3) eq $want;$x{int($xx/2)}=1;$y{$yy}=1}}
   my@x=sort{$a<=>$b}keys%x; my@y=sort{$a<=>$b}keys%y; return(\@x,\@y);
}
sub expect_x { my($label,$actual,@want)=@_; my$a=join(',',@$actual); my$w=join(',',@want); $a eq $w or die "$label X pixels [$a], expected [$w]\n"; }
sub expect_y_extent { my($label,$ys,$lo,$hi)=@_; @$ys or die "$label has no pixels\n"; ($ys->[0]==$lo && $ys->[-1]==$hi) or die "$label Y extent $ys->[0]..$ys->[-1], expected $lo..$hi\n"; }

@ARGV==2 or die "usage: $0 REPO TMP\n";
my$repo=abs_path($ARGV[0]) or die "resolve repo\n"; my$tmp=$ARGV[1]; make_path($tmp); $tmp=abs_path($tmp);
my$stella=$ENV{VCSC_STELLA}||$ENV{STELLA}||findexe('stella') or die "set STELLA or VCSC_STELLA\n";
my$xvfb=findexe('Xvfb') or die "Xvfb required\n"; my$perl=findexe('perl') or die "perl required\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc)); my$vcs=File::Spec->catdir($repo,qw(libraries vcs)); my$keys=File::Spec->catfile($repo,qw(test stella_snapshot_keys.pl));
my%profile=(
   '192'=>[File::Spec->catfile($repo,qw(examples 14_multisprite 01_192 01_interactive multisprite_192_interactive.c26)),"   initialize_192_scene();\n"],
   'above'=>[File::Spec->catfile($repo,qw(examples 14_multisprite 02_181_score_above 01_interactive multisprite_181_score_above_interactive.c26)),"   initialize_multisprite_scene();\n"],
   'below'=>[File::Spec->catfile($repo,qw(examples 14_multisprite 03_181_score_below 01_interactive multisprite_181_score_below_interactive.c26)),"   initialize_multisprite_scene();\n"],
);

my$display=280+($$%30); $display++ while -e "/tmp/.X11-unix/X$display"; my$d=":$display";
my$xpid=fork(); defined$xpid or die "fork Xvfb\n"; if(!$xpid){open(STDOUT,'>:raw',"$tmp/xvfb.log");open(STDERR,'>&STDOUT');exec($xvfb,$d,'-ac','-screen','0','1024x768x24');die$!}
select undef,undef,undef,.2; local$ENV{DISPLAY}=$d; local$ENV{XAUTHORITY}='/dev/null'; local$ENV{HOME}=$tmp; local$ENV{SDL_AUDIODRIVER}='dummy';

sub snapshot_case {
   my($mode,$name,@assign)=@_; my($source,$needle)=@{$profile{$mode}}; my$src_text=read_file($source); index($src_text,$needle)>=0 or die "$mode insertion point missing\n";
   my$insert=$needle.join('',map{"   $_;\n"}@assign); $src_text =~ s/\Q$needle\E/$insert/;
   my($vol,$dirs,$file)=File::Spec->splitpath($source); my$case_src=File::Spec->catfile($dirs,"__stella_multisprite_$name.c26"); write_file($case_src,$src_text);
   my$rom=File::Spec->catfile($tmp,"$name.bin"); eval { ok("build $name",$driver,'-I',$vcs,'-Wa,--illegals',$case_src,'-o',$rom); 1 } or do { my$e=$@; unlink$case_src; die$e; }; unlink$case_src;
   my$work=File::Spec->catdir($tmp,$name); remove_tree($work); make_path(File::Spec->catdir($work,'snap'),File::Spec->catdir($work,'user'));
   my$snap=File::Spec->catdir($work,'snap'); my$user=File::Spec->catdir($work,'user');
   my@cmd=($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','4K','-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1','-exitlauncher','0','-confirmexit','0','-userdir',$user,$rom);
   my$pid=fork(); defined$pid or die "fork Stella\n"; if(!$pid){open(STDOUT,'>:raw',"$work/stella.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
   select undef,undef,undef,.25; ok("snapshot $name",$perl,$keys); my@png; for(1..40){@png=grep{-s$_}glob("$snap/*.png");last if@png==1;select undef,undef,undef,.04}
   terminate($pid); @png==1 or die "$name produced ".scalar(@png)." snapshots\n"; return$png[0];
}

my%rgb=(p0=>pack('C3',234,234,233),p1=>pack('C3',253,134,133),p2=>pack('C3',134,253,133),p3=>pack('C3',121,221,251),p4=>pack('C3',234,130,220),p5=>pack('C3',121,253,207));
for my$mode(qw(192 above below)) {
   my$top=$mode eq '192'?92:86;
   my$png=snapshot_case($mode,"edge_$mode",
      'game_PLAYER0_X := 100','game_PLAYER1_X := 0','game_PLAYER2_X := 20','game_PLAYER3_X := 100','game_PLAYER4_X := 152','game_PLAYER5_X := 159',"game_PLAYER5_Y := $top");
   my($x1,$y1)=color_extent($png,$rgb{p1}); expect_x("$mode P1 X=0",$x1,0..5);
   my($x2,$y2)=color_extent($png,$rgb{p2}); expect_x("$mode P2 X=20",$x2,20..25);
   my($x3,$y3)=color_extent($png,$rgb{p3}); expect_x("$mode P3 X=100",$x3,100..105);
   my($x4,$y4)=color_extent($png,$rgb{p4}); expect_x("$mode P4 X=152",$x4,151..157);
   my($x5,$y5)=color_extent($png,$rgb{p5}); expect_x("$mode P5 X=159",$x5,0,1,2,3,4,159);
   expect_y_extent("$mode top-edge P5",$y5,$mode eq '192'?20:$mode eq 'above'?33:22,$mode eq '192'?35:$mode eq 'above'?48:37);
   my($x0,$y0)=color_extent($png,$rgb{p0},30,190); expect_x("$mode P0 X=100",$x0,$mode eq '192'?(97..104):(100..107));
}
for my$mode(qw(above below)) {
   my$png=snapshot_case($mode,"sort_$mode",'game_PLAYER0_X := 100','game_PLAYER1_Y := 80','game_PLAYER2_Y := 20','game_PLAYER3_Y := 30','game_PLAYER4_Y := 40','game_PLAYER5_Y := 50');
   my($x,$y)=color_extent($png,$rgb{p0},40,190); expect_x("$mode P0 sort-invariant X=100",$x,100..107);
}
my$bottom=snapshot_case('above','p0_bottom','game_PLAYER0_Y := 0'); my($bx,$by)=color_extent($bottom,$rgb{p0},30,220); @$bx==0 or die "181 P0 Y=0 rendered gameplay pixels (broad-stripe regression)\n";
terminate($xpid);
print "Stella modern multisprite pixels passed: full-rank edge placement, 181 P0 sort invariance, top reach, and clipped P0 bottom\n";
