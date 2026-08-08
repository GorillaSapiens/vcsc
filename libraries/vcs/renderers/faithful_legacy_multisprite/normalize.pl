#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.

use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Basename qw(dirname);
use File::Spec;
use Getopt::Long qw(GetOptions);

my $check=0;
GetOptions('check'=>\$check) or die "usage: $0 [--check]\n";
die "usage: $0 [--check]\n" if @ARGV;

my $script=abs_path($0) // die "resolve $0\n";
my $profile=dirname($script);
my $vcs=abs_path(File::Spec->catdir($profile,'..','..')) // die "resolve vcs\n";
my $legacy=File::Spec->catdir($vcs,'legacy-basic-renderers');
my $renderer_path=File::Spec->catfile($legacy,'multisprite','multisprite_renderer.asm');
my $score_path=File::Spec->catfile($legacy,'common','score_graphics.asm');
my $out_path=File::Spec->catfile($profile,'faithful_legacy_multisprite_renderer.s26');

sub slurp { my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $s=<$f>//''; close($f); $s=~s/\r\n?/\n/g; return $s; }
my $renderer=slurp($renderer_path);
my $score=slurp($score_path);

$renderer =~ /^multisprite_setup\b/m or die "retained multisprite_setup missing\n";
$renderer =~ /^drawscreen\b/m or die "retained drawscreen missing\n";
$renderer =~ /^RendererRoutine\b/m or die "retained RendererRoutine missing\n";
$renderer =~ /^SetupP1Subroutine\b/m or die "retained SetupP1Subroutine missing\n";
$renderer =~ /\btxs\b/i or die "retained stack-pointer renderer trick missing\n";
$renderer =~ /\bphp\b/i or die "retained PHP object-enable trick missing\n";
$score =~ /^scoretable\b/m or die "retained score table missing\n";

sub selected_lines {
   my($text)=@_;
   my @out;
   my @stack;
   my $active=1;
   my @lines=split(/\n/,$text,-1);
   for(my $i=0;$i<@lines;++$i){
      my $line=$lines[$i]; my $n=$i+1;
      my $trim=$line; $trim=~s/^\s+|\s+$//g;
      if($trim =~ /^ifconst\s+([A-Za-z_][A-Za-z0-9_]*)\b/i){
         my $cond=0; push @stack,{parent=>$active,cond=>$cond}; $active=$active&&$cond; next;
      }
      if($trim =~ /^ifnconst\s+([A-Za-z_][A-Za-z0-9_]*)\b/i){
         my $cond=1; push @stack,{parent=>$active,cond=>$cond}; $active=$active&&$cond; next;
      }
      if($trim =~ /^if\s+(.+)$/i){
         if($active){ die "$renderer_path:$n unexpected active retained conditional '$trim' in minimal profile\n"; }
         push @stack,{parent=>$active,cond=>0}; $active=0; next;
      }
      if($trim =~ /^else\b/i){
         @stack or die "$renderer_path:$n ELSE without IF\n";
         my $f=$stack[-1]; $active=$f->{parent}&&!$f->{cond}; next;
      }
      if($trim =~ /^endif\b/i){
         @stack or die "$renderer_path:$n ENDIF without IF\n";
         my $f=pop @stack; $active=$f->{parent}; next;
      }
      push @out,$line if $active;
   }
   @stack and die "$renderer_path: unterminated conditional\n";
   return @out;
}

sub translate_line {
   my($line)=@_;
   my($code,$comment)=$line =~ /\A([^;]*)(;.*)?\z/s;
   $comment='' if !defined $comment;
   # Retain comments untouched. Only active assembly is normalized.
   $code =~ s/\bSLEEP\b/SLEEP/ig;
   $code =~ s/\bRETURN\b/RETURN/ig;
   while($code =~ /\b([A-Za-z][A-Za-z0-9]*)\.w\b/){
      my $mn=$1;
      my $suffix=$code =~ /,\s*[Xx]\b/ ? '.ax' : $code =~ /,\s*[Yy]\b/ ? '.ay' : '.a';
      $code =~ s/\b\Q$mn\E\.w\b/$mn$suffix/;
   }
   $code=replace_ram_operands($code);
   if($code =~ /^(\s*)multisprite_setup\s*$/){ $code=$1.'vcs_multisprite_setup:'; }
   elsif($code =~ /^(\s*)drawscreen\s*$/){ $code=$1.'vcs_multisprite_drawscreen:'; }
   elsif($code =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*$/){ $code=$1.':'; }
   elsif($code =~ /^([A-Za-z_][A-Za-z0-9_]*)(\s+;.*)?$/){ $code=$1.':'; }
   return $code.$comment;
}

sub score_bytes {
   my @bytes; my $seen=0;
   for my $line(split(/\n/,$score)){
      if(!$seen){ $seen=1 if $line =~ /^scoretable\b/; next; }
      if($line =~ /^\s*\.byte\s+(%[01]+|\$[0-9A-Fa-f]+|\d+)\s*(?:;.*)?$/){
         push @bytes,$1; last if @bytes==88;
      }
   }
   @bytes==88 or die "$score_path: expected 88 score bytes, got ".scalar(@bytes)."\n";
   return @bytes;
}

# Exact retained $80-$F9 layout.  Do not emit these as assembler equates:
# vcs_multisprite_state is relocatable, and vcsc-as intentionally does not
# resolve aliases whose right hand side contains an imported symbol.  Instead
# substitute each legacy RAM name directly with symbol+offset in operands.
my @aliases=(
 ['missile0x',0],['missile1x',1],['ballx',2],['SpriteIndex',3],['player0x',4],['NewSpriteX',5],
 ['player1x',5],['player2x',6],['player3x',7],['player4x',8],['player5x',9],
 ['objecty',10],['missile0y',10],['missile1y',11],['bally',12],['player0y',13],['NewSpriteY',14],
 ['player1y',14],['player2y',15],['player3y',16],['player4y',17],['player5y',18],
 ['NewNUSIZ',19],['_NUSIZ1',19],['NUSIZ2',20],['NUSIZ3',21],['NUSIZ4',22],['NUSIZ5',23],
 ['NewCOLUP1',24],['_COLUP1',24],['COLUP2',25],['COLUP3',26],['COLUP4',27],['COLUP5',28],
 ['SpriteGfxIndex',29],['player0pointer',34],['player0pointerlo',34],['player0pointerhi',35],
 ['P0Top',79],['P0Bottom',36],['P1Bottom',37],['player1pointerlo',38],['player2pointerlo',39],
 ['player3pointerlo',40],['player4pointerlo',41],['player5pointerlo',42],['player1pointerhi',43],
 ['player2pointerhi',44],['player3pointerhi',45],['player4pointerhi',46],['player5pointerhi',47],
 ['player0height',48],['spriteheight',49],['player1height',49],['player2height',50],['player3height',51],
 ['player4height',52],['player5height',53],['PF1temp1',54],['PF1temp2',55],['PF2temp1',56],['PF2temp2',57],
 ['pfpixelheight',58],['playfield',59],['PF1pointer',59],['PF2pointer',61],['statusbarlength',63],['aux3',63],
 ['lifecolor',64],['pfscorecolor',64],['aux4',64],['P1display',76],['lifepointer',65],['lives',66],
 ['pfscore1',65],['pfscore2',66],['aux5',65],['aux6',66],['playfieldpos',67],['RepoLine',78],['pfheight',68],
 ['scorepointers',69],['temp1',75],['temp2',76],['temp3',77],['temp4',78],['temp5',79],['temp6',80],
 ['temp7',81],['score',82],['scorecolor',85],['rand',86],['spritesort',113],['spritesort2',114],
 ['spritesort3',115],['spritesort4',116],['spritesort5',117],['stack1',118],['stack2',119],['stack3',120],['stack4',121]
);
my %ram_offset=map { $_->[0] => $_->[1] } @aliases;
my @ram_names=sort { length($b)<=>length($a) || $a cmp $b } keys %ram_offset;

sub replace_ram_operands {
   my($code)=@_;
   for my $name(@ram_names){
      my $replacement='vcs_multisprite_state + '.$ram_offset{$name};
      $code =~ s/(?<![A-Za-z0-9_.\$\@])\Q$name\E(?![A-Za-z0-9_.\$])/$replacement/g;
   }
   return $code;
}

my @selected=selected_lines($renderer);
my @body=map { translate_line($_) } @selected;

my @out;
push @out, '; This file is covered under CC0-1.0. See libraries/LICENSE.txt.';
push @out, ';';
push @out, '; Generated by renderers/faithful_legacy_multisprite/normalize.pl.';
push @out, '; Selected profile: NTSC, unbanked 4K, non-Superchip, default 88-line';
push @out, '; gameplay height, integrated six-digit score, no optional status/PF-score/minirenderer.';
push @out, sprintf('; retained renderer SHA-256: %s',sha256_hex($renderer));
push @out, sprintf('; retained score SHA-256:    %s',sha256_hex($score));
push @out, '';
push @out, '.include "faithful_legacy_multisprite_macros.inc"';
push @out, '.segmentregion "RENDERER_CODE", startup';
push @out, '.segmentprivate "RENDERER_CODE"';
push @out, '.segmentregion "RENDERER_RODATA", startup';
push @out, '.segmentprivate "RENDERER_RODATA"';
# This profile tail-enters main from its private startup.  vcsc-ld's callgraph
# reserve still counts one root slot, so main -> drawscreen contributes four
# modeled source bytes (root + edge).  The retained renderer can be two hidden
# JSR levels deeper than drawscreen; two of those four hidden bytes overlap the
# modeled-but-not-physically-pushed root slot.  An extra two therefore gives
# the exact physical six-byte $FA-$FF maximum.
push @out, '.callstackextra 2';
push @out, '.importzp vcs_multisprite_state';
push @out,'';
push @out,'; Canonical TIA/RIOT addresses used by the selected source.';
my @hw=(
 ['VSYNC',0x00],['VBLANK',0x01],['WSYNC',0x02],['NUSIZ0',0x04],['NUSIZ1',0x05],['COLUP0',0x06],['COLUP1',0x07],
 ['COLUPF',0x08],['COLUBK',0x09],['PF0',0x0d],['PF1',0x0e],['PF2',0x0f],['RESP0',0x10],['RESP1',0x11],
 ['REFP0',0x0b],['REFP1',0x0c],
 ['RESM0',0x12],['RESM1',0x13],['RESBL',0x14],['GRP0',0x1b],['GRP1',0x1c],['ENAM0',0x1d],['ENAM1',0x1e],['ENABL',0x1f],
 ['HMP0',0x20],['HMP1',0x21],['HMM0',0x22],['HMM1',0x23],['HMBL',0x24],['VDELP0',0x25],['VDELP1',0x26],
 ['VDELBL',0x27],['HMOVE',0x2a],['HMCLR',0x2b],['CXCLR',0x2c],['INTIM',0x0284],['TIM64T',0x0296]
);
for my $h(@hw){ push @out,sprintf('%-8s = $%04X',$h->[0],$h->[1]); }
push @out,'';
for my $fn(qw(vcs_multisprite_setup vcs_multisprite_drawscreen)){
 push @out,".export $fn";
 push @out,'.export __abimeta$V1$function$definition$'.$fn.'$summary$paramsQ3D0$parametersQ3D0';
 push @out,'__abimeta$V1$function$definition$'.$fn.'$summary$paramsQ3D0$parametersQ3D0 = 0';
 push @out,'.export __abimeta$V1$function$definition$'.$fn.'$return$modeQ3Dreturn_voidQ3BvoidQ28szQ3D0Q29$return_voidQ20voidQ28sizeQ3D0Q29';
 push @out,'__abimeta$V1$function$definition$'.$fn.'$return$modeQ3Dreturn_voidQ3BvoidQ28szQ3D0Q29$return_voidQ20voidQ28sizeQ3D0Q29 = 0';
 push @out,'.export __sbpmeta$F$'.$fn;
 push @out,'__sbpmeta$F$'.$fn.' = 0';
}
push @out,'';
push @out,'.segment "RENDERER_CODE"';
push @out,@body;
push @out,'';
push @out,'.segment "RENDERER_RODATA"';
push @out,'.align 256';
push @out,'scoretable:';
my @score_bytes=score_bytes();
for my $g(0..10){ push @out, $g==10?'; blank glyph':"; digit $g"; push @out,map { '   .byte '.$_ } @score_bytes[$g*8..$g*8+7]; }
push @out,'';
my $result=join("\n",@out);

if($check){
   my $old=slurp($out_path);
   die "$out_path is stale; run normalize.pl\n" if $old ne $result;
   print "faithful_legacy_multisprite normalize ok\n";
}else{
   open(my $f,'>:raw',$out_path) or die "write $out_path: $!\n";
   print {$f} $result; close($f) or die "close $out_path: $!\n";
}
