#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: scalar operator Cartesian matrix passed: 896 legal runtime cells, 144 illegal compile cells, 1040 total
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub run_capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub require_ok {
   my($label,@cmd)=@_; my($rc,$sig,$out,$err)=run_capture(@cmd);
   $rc==0 && !$sig or die "$label failed rc=$rc sig=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return ($out,$err);
}
sub write_file {
   my($path,$text)=@_; open(my $fh,'>:raw',$path) or die "write $path: $!\n";
   print {$fh} $text; close($fh) or die "close $path: $!\n";
}
sub read_file {
   my($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/;
   my $d=<$fh>; close($fh); return $d // '';
}
sub map_symbol {
   my($map,$name)=@_; $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m
      or die "map missing $name\n"; return hex($1);
}
sub parse_hex_dump {
   my($text)=@_; my @mem=(0)x65536;
   for my $line (split /\n/,$text) {
      next unless $line =~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
      my($n,$a,$data)=(hex($1),hex($2),$3);
      length($data)==$n*2 or die "bad HEX dump record\n";
      for my $i (0..$n-1) { $mem[$a+$i]=hex(substr($data,$i*2,2)); }
   }
   return \@mem;
}
sub mask_for_bits { my($bits)=@_; return (1 << $bits) - 1 if $bits < 32; return 0xffffffff; }
sub signed_value {
   my($v,$bits)=@_; my $mod = 2 ** $bits; $v %= $mod; $v += $mod if $v < 0;
   return $v >= $mod/2 ? $v - $mod : $v;
}
sub typed_value {
   my($v,$t)=@_; my $mod=2 ** $t->{bits}; $v %= $mod; $v += $mod if $v < 0;
   return $t->{signed} ? signed_value($v,$t->{bits}) : $v;
}
sub add_case {
   my($state,$label,$body)=@_;
   my $code=++$state->{code};
   push @{$state->{labels}}, $label;
   $state->{src}.="   // matrix: $label\n$body";
   return $code;
}
sub value_check {
   my($state,$label,$setup,$expr,$expected,$x_expected)=@_;
   my $code=$state->{code}+1;
   my $check="   if ($state->{r} != $expected";
   $check.=" || $state->{x} != $x_expected" if defined $x_expected;
   $check.=") { failure := $code; return; }\n";
   add_case($state,$label,"$setup   $state->{r} := $expr;\n$check");
}
sub bool_check {
   my($state,$label,$setup,$expr,$want)=@_;
   my $code=$state->{code}+1;
   my $check=$want ? "if (!$state->{b})" : "if ($state->{b})";
   add_case($state,$label,"$setup   $state->{b} := $expr;\n   $check { failure := $code; return; }\n");
}
sub dual_bool_case {
   my($state,$label,$setup1,$expr1,$want1,$setup2,$expr2,$want2)=@_;
   my $code=$state->{code}+1;
   my $c1=$want1 ? "if (!$state->{b})" : "if ($state->{b})";
   my $c2=$want2 ? "if (!$state->{b})" : "if ($state->{b})";
   add_case($state,$label,
      "$setup1   $state->{b} := $expr1;\n   $c1 { failure := $code; return; }\n".
      "$setup2   $state->{b} := $expr2;\n   $c2 { failure := $code; return; }\n");
}

my @types=(
   { name=>'int8_t',   bits=>8,  signed=>1, bcd=>0, pattern=>0x2a, mask=>0x0f },
   { name=>'uint8_t',  bits=>8,  signed=>0, bcd=>0, pattern=>0x2a, mask=>0x0f },
   { name=>'int16_t',  bits=>16, signed=>1, bcd=>0, pattern=>0x1234, mask=>0x0f0f },
   { name=>'uint16_t', bits=>16, signed=>0, bcd=>0, pattern=>0x1234, mask=>0x0f0f },
   { name=>'int24_t',  bits=>24, signed=>1, bcd=>0, pattern=>0x123456, mask=>0x0f0f0f },
   { name=>'uint24_t', bits=>24, signed=>0, bcd=>0, pattern=>0x123456, mask=>0x0f0f0f },
   { name=>'int32_t',  bits=>32, signed=>1, bcd=>0, pattern=>0x12345678, mask=>0x0f0f0f0f },
   { name=>'uint32_t', bits=>32, signed=>0, bcd=>0, pattern=>0x12345678, mask=>0x0f0f0f0f },
   { name=>'bcd8_t',   bits=>8,  signed=>0, bcd=>1, digits=>2, pattern=>42 },
   { name=>'bcd16_t',  bits=>16, signed=>0, bcd=>1, digits=>4, pattern=>1234 },
   { name=>'bcd24_t',  bits=>24, signed=>0, bcd=>1, digits=>6, pattern=>123456 },
   { name=>'bcd32_t',  bits=>32, signed=>0, bcd=>1, digits=>8, pattern=>12345678 },
);
my @storage=(
   { name=>'ram', qualifier=>'', bank=>'bank0' },
   { name=>'cartram', qualifier=>'cartram ', bank=>'bank1' },
);
my @ordinary_ops=qw(:= cast sizeof unary+ unary- ! ~ + - * / % & | ^ << >> == != < <= > >= && || += -= *= /= %= &= |= ^= <<= >>= post++ pre++ post-- pre-- ?: comma);
my @bcd_legal_ops=(':=','cast','sizeof','unary+','!','+','-','*const-right','*const-left','/const','%const','==','!=','<','<=','>','>=','&&','||','+=','-=','*=const','/=const','%=const','post++','pre++','post--','pre--','?:','comma');
my @bcd_illegal_ops=('unary-','~','&','|','^','<<','>>','&=','|=','^=','<<=','>>=','*var','/var','%var','*=var','/=var','%=var');

sub emit_ordinary_body {
   my($t,$s,$prefix)=@_;
   my ($x,$y,$r,$b)=("${prefix}_x","${prefix}_y","${prefix}_r","${prefix}_b");
   my $p=$t->{pattern}; my $m=$t->{mask};
   my $st={src=>'',code=>0,labels=>[],x=>$x,y=>$y,r=>$r,b=>$b};
   my $v=sub { typed_value($_[0],$t) };
   my $setup=sub { my($a,$bb)=@_; return "   $x := ".$v->($a).";\n   $y := ".$v->($bb).";\n"; };

   value_check($st,"$prefix $t->{name} :=",$setup->(0,$p),"($x := $y)",$v->($p),$v->($p));
   value_check($st,"$prefix $t->{name} cast",$setup->($p,0),"($t->{name})$x",$v->($p),undef);
   my $size_code=$st->{code}+1;
   add_case($st,"$prefix $t->{name} sizeof",$setup->($p,0)."   $b := sizeof($x);\n   if ($b != ".($t->{bits}/8).") { failure := $size_code; return; }\n");
   value_check($st,"$prefix $t->{name} unary +",$setup->($p,0),"+$x",$v->($p),undef);
   value_check($st,"$prefix $t->{name} unary -",$setup->($p,0),"-$x",$v->(-$p),undef);
   dual_bool_case($st,"$prefix $t->{name} !",$setup->(0,0),"!$x",1,$setup->($p,0),"!$x",0);
   value_check($st,"$prefix $t->{name} ~",$setup->($p,0),"~$x",$v->((mask_for_bits($t->{bits}) ^ $p)),undef);

   for my $op ('+','-','*','/','%') {
      my($a,$bb)=($p,3); my $e = $op eq '+' ? $a+$bb : $op eq '-' ? $a-$bb : $op eq '*' ? $a*$bb : $op eq '/' ? int($a/$bb) : $a%$bb;
      value_check($st,"$prefix $t->{name} $op",$setup->($a,$bb),"$x $op $y",$v->($e),undef);
   }
   for my $op ('&','|','^') {
      my $e = $op eq '&' ? ($p & $m) : $op eq '|' ? ($p | $m) : ($p ^ $m);
      value_check($st,"$prefix $t->{name} $op",$setup->($p,$m),"$x $op $y",$v->($e),undef);
   }
   value_check($st,"$prefix $t->{name} <<",$setup->($p,1),"$x << $y",$v->($p<<1),undef);
   value_check($st,"$prefix $t->{name} >>",$setup->($p,1),"$x >> $y",$v->($p>>1),undef);

   dual_bool_case($st,"$prefix $t->{name} ==",$setup->(7,7),"$x == $y",1,$setup->(7,5),"$x == $y",0);
   dual_bool_case($st,"$prefix $t->{name} !=",$setup->(7,5),"$x != $y",1,$setup->(7,7),"$x != $y",0);
   dual_bool_case($st,"$prefix $t->{name} <", $setup->(5,7),"$x < $y",1,$setup->(7,5),"$x < $y",0);
   dual_bool_case($st,"$prefix $t->{name} <=",$setup->(5,7),"$x <= $y",1,$setup->(7,5),"$x <= $y",0);
   dual_bool_case($st,"$prefix $t->{name} >", $setup->(7,5),"$x > $y",1,$setup->(5,7),"$x > $y",0);
   dual_bool_case($st,"$prefix $t->{name} >=",$setup->(7,5),"$x >= $y",1,$setup->(5,7),"$x >= $y",0);
   dual_bool_case($st,"$prefix $t->{name} &&",$setup->(1,2),"$x && $y",1,$setup->(0,2),"$x && $y",0);
   dual_bool_case($st,"$prefix $t->{name} ||",$setup->(0,2),"$x || $y",1,$setup->(0,0),"$x || $y",0);

   my %compound=(
      '+='=>[$p,3,$p+3], '-='=>[$p,3,$p-3], '*='=>[$p,3,$p*3], '/='=>[$p,3,int($p/3)], '%='=>[$p,3,$p%3],
      '&='=>[$p,$m,$p&$m], '|='=>[$p,$m,$p|$m], '^='=>[$p,$m,$p^$m], '<<='=>[$p,1,$p<<1], '>>='=>[$p,1,$p>>1],
   );
   for my $op ('+=','-=','*=','/=','%=','&=','|=','^=','<<=','>>=') {
      my($a,$bb,$e)=@{$compound{$op}};
      value_check($st,"$prefix $t->{name} $op",$setup->($a,$bb),"($x $op $y)",$v->($e),$v->($e));
   }

   value_check($st,"$prefix $t->{name} post++",$setup->($p,0),"$x++",$v->($p),$v->($p+1));
   value_check($st,"$prefix $t->{name} pre++", $setup->($p,0),"++$x",$v->($p+1),$v->($p+1));
   value_check($st,"$prefix $t->{name} post--",$setup->($p,0),"$x--",$v->($p),$v->($p-1));
   value_check($st,"$prefix $t->{name} pre--", $setup->($p,0),"--$x",$v->($p-1),$v->($p-1));

   my $code=$st->{code}+1;
   add_case($st,"$prefix $t->{name} ?: static branches",
      $setup->(1,$p)."   $r := $x ? $y : 3;\n   if ($r != ".$v->($p).") { failure := $code; return; }\n".
      $setup->(0,$p)."   $r := $x ? 3 : $y;\n   if ($r != ".$v->($p).") { failure := $code; return; }\n");
   $code=$st->{code}+1;
   add_case($st,"$prefix $t->{name} comma",
      $setup->($p,7)."   $r := ($x++, $y);\n   if ($r != ".$v->(7)." || $x != ".$v->($p+1).") { failure := $code; return; }\n");

   scalar(@{$st->{labels}})==scalar(@ordinary_ops) or die "ordinary operator generator count drift for $t->{name}/$prefix\n";
   return ($st->{src},$st->{labels},$st->{code});
}

sub emit_bcd_body {
   my($t,$s,$prefix)=@_;
   my ($x,$y,$r,$b)=("${prefix}_x","${prefix}_y","${prefix}_r","${prefix}_b");
   my $mod=10 ** $t->{digits}; my $max=$mod-1; my $p=$t->{pattern};
   my $st={src=>'',code=>0,labels=>[],x=>$x,y=>$y,r=>$r,b=>$b};
   my $setup=sub { my($a,$bb)=@_; return "   $x := $a;\n   $y := $bb;\n"; };

   value_check($st,"$prefix $t->{name} :=",$setup->(0,$p),"($x := $y)",$p,$p);
   value_check($st,"$prefix $t->{name} cast",$setup->($p,0),"($t->{name})$x",$p,undef);
   my $size_code=$st->{code}+1;
   add_case($st,"$prefix $t->{name} sizeof",$setup->($p,0)."   $b := sizeof($x);\n   if ($b != ".($t->{bits}/8).") { failure := $size_code; return; }\n");
   value_check($st,"$prefix $t->{name} unary +",$setup->($p,0),"+$x",$p,undef);
   dual_bool_case($st,"$prefix $t->{name} !",$setup->(0,0),"!$x",1,$setup->($p,0),"!$x",0);
   value_check($st,"$prefix $t->{name} +",$setup->($max-4,7),"$x + $y",2,undef);
   value_check($st,"$prefix $t->{name} -",$setup->(3,5),"$x - $y",$max-1,undef);
   value_check($st,"$prefix $t->{name} * const-right",$setup->($p,0),"$x * 10",($p*10)%$mod,undef);
   value_check($st,"$prefix $t->{name} * const-left",$setup->($p,0),"10 * $x",($p*10)%$mod,undef);
   value_check($st,"$prefix $t->{name} / const",$setup->($p,0),"$x / 10",int($p/10),undef);
   value_check($st,"$prefix $t->{name} % const",$setup->($p,0),"$x % 10",$p%10,undef);

   dual_bool_case($st,"$prefix $t->{name} ==",$setup->(7,7),"$x == $y",1,$setup->(7,5),"$x == $y",0);
   dual_bool_case($st,"$prefix $t->{name} !=",$setup->(7,5),"$x != $y",1,$setup->(7,7),"$x != $y",0);
   dual_bool_case($st,"$prefix $t->{name} <", $setup->(5,7),"$x < $y",1,$setup->(7,5),"$x < $y",0);
   dual_bool_case($st,"$prefix $t->{name} <=",$setup->(5,7),"$x <= $y",1,$setup->(7,5),"$x <= $y",0);
   dual_bool_case($st,"$prefix $t->{name} >", $setup->(7,5),"$x > $y",1,$setup->(5,7),"$x > $y",0);
   dual_bool_case($st,"$prefix $t->{name} >=",$setup->(7,5),"$x >= $y",1,$setup->(5,7),"$x >= $y",0);
   dual_bool_case($st,"$prefix $t->{name} &&",$setup->(1,2),"$x && $y",1,$setup->(0,2),"$x && $y",0);
   dual_bool_case($st,"$prefix $t->{name} ||",$setup->(0,2),"$x || $y",1,$setup->(0,0),"$x || $y",0);

   value_check($st,"$prefix $t->{name} +=",$setup->($max-4,7),"($x += $y)",2,2);
   value_check($st,"$prefix $t->{name} -=",$setup->(3,5),"($x -= $y)",$max-1,$max-1);
   value_check($st,"$prefix $t->{name} *= const",$setup->($p,0),"($x *= 10)",($p*10)%$mod,($p*10)%$mod);
   value_check($st,"$prefix $t->{name} /= const",$setup->($p,0),"($x /= 10)",int($p/10),int($p/10));
   value_check($st,"$prefix $t->{name} %= const",$setup->($p,0),"($x %= 10)",$p%10,$p%10);

   value_check($st,"$prefix $t->{name} post++",$setup->($max,0),"$x++",$max,0);
   value_check($st,"$prefix $t->{name} pre++", $setup->($max-1,0),"++$x",$max,$max);
   value_check($st,"$prefix $t->{name} post--",$setup->(0,0),"$x--",0,$max);
   value_check($st,"$prefix $t->{name} pre--", $setup->(1,0),"--$x",0,0);

   my $code=$st->{code}+1;
   add_case($st,"$prefix $t->{name} ?: static branches",
      $setup->(1,$p)."   $r := 3;\n   $r := $x ? $y : $r;\n   if ($r != $p) { failure := $code; return; }\n".
      $setup->(0,$p)."   $r := 3;\n   $r := $x ? $y : $r;\n   if ($r != 3) { failure := $code; return; }\n");
   $code=$st->{code}+1;
   add_case($st,"$prefix $t->{name} comma",
      $setup->(12,34)."   $r := ($x++, $y);\n   if ($r != 34 || $x != 13) { failure := $code; return; }\n");

   scalar(@{$st->{labels}})==scalar(@bcd_legal_ops) or die "BCD legal operator generator count drift for $t->{name}/$prefix\n";
   return ($st->{src},$st->{labels},$st->{code});
}

sub split_body_cases {
   my($body,$parts)=@_;
   my @chunks=($body =~ /(^   \/\/ matrix:.*?)(?=^   \/\/ matrix:|\z)/msg);
   @chunks or die "cannot split generated matrix body\n";
   my @out;
   my $per=int((@chunks+$parts-1)/$parts);
   while (@chunks) {
      my @take=splice(@chunks,0,$per);
      push @out, join('',@take);
   }
   push @out, '' while @out < $parts;
   return @out;
}

sub generate_program {
   my($t)=@_;
   my $type=$t->{name};
   my($ram_body,$ram_labels,$ram_count)=$t->{bcd} ? emit_bcd_body($t,$storage[0],'ram') : emit_ordinary_body($t,$storage[0],'ram');
   my($cart_body,$cart_labels,$cart_count)=$t->{bcd} ? emit_bcd_body($t,$storage[1],'cart') : emit_ordinary_body($t,$storage[1],'cart');
   my($ram_a,$ram_b)=split_body_cases($ram_body,2);
   my($cart_a,$cart_b)=split_body_cases($cart_body,2);
   my $source=<<"SRC";
include "machine_6502.c26"
mem rom { \$start:0x4000 \$size:0xb000 \$ro \$priority:1 };
mem cartram { \$read_start:0xf080 \$write_start:0xf000 \$size:0x80 \$rw };

uint8_t failure;
$type ram_x;
$type ram_y;
$type ram_r;
uint8_t ram_b;
cartram $type cart_x;
cartram $type cart_y;
cartram $type cart_r;
cartram uint8_t cart_b;

void fail(void) {
   asm lda #\$ff;
   asm ldx failure;
   asm ldy #0;
   asm jsr \$ffff;
}
void pass(void) {
   asm lda #\$ff;
   asm ldx #0;
   asm ldy #0;
   asm jsr \$ffff;
}
void test_ram_a(void) {
$ram_a}
void test_ram_b(void) {
$ram_b}
void test_cart_a(void) {
$cart_a}
void test_cart_b(void) {
$cart_b}
void main(void) {
   failure := 0;
   test_ram_a();
   if (failure) { fail(); }
   test_ram_b();
   if (failure) { fail(); }
   test_cart_a();
   if (failure) { fail(); }
   test_cart_b();
   if (failure) { fail(); }
   pass();
}
SRC
   return ($source,$ram_labels,$cart_labels);
}

sub illegal_source {
   my($t,$storage_name,$op)=@_;
   my $type=$t->{name}; my $q=$storage_name eq 'cartram' ? 'cartram ' : '';
   my $mem=$storage_name eq 'cartram' ? "mem cartram { \$read_start:0xf080 \$write_start:0xf000 \$size:0x80 \$rw };\n" : '';
   my($stmt,$needle);
   if ($op eq 'unary-') { $stmt='z := -x;'; $needle="operator '-'"; }
   elsif ($op eq '~') { $stmt='z := ~x;'; $needle="operator '~'"; }
   elsif ($op =~ /^(\&|\||\^|<<|>>)$/) { $stmt="z := x $op y;"; $needle="operator '$op'"; }
   elsif ($op =~ /^(\&=|\|=|\^=|<<=|>>=)$/) { $stmt="x $op y;"; $needle="compound operator '$op'"; }
   elsif ($op =~ /^([*\/%])var$/) { my $o=$1; $stmt="z := x $o y;"; $needle="operator '$o'"; }
   elsif ($op =~ /^([*\/%]=)var$/) { my $o=$1; $stmt="x $o y;"; $needle="compound operator '$o'"; }
   else { die "unknown illegal op $op\n"; }
   return ("include \"machine_6502.c26\"\nmem rom { \$start:0x4000 \$size:0xb000 \$ro \$priority:1 };\n$mem${q}$type x;\n${q}$type y;\n$type z;\nvoid f(void) { $stmt }\n",$needle);
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $testdir=File::Spec->catdir($repo,'test');
my $cfg=File::Spec->catfile($repo,'test','scalar_operator_cartesian.cfg');

my($legal_cells,$illegal_cells)=(0,0);
for my $t (@types) {
   my($src,$ram_labels,$cart_labels)=generate_program($t);
   my $stem=$t->{name}; $stem =~ s/_t$//;
   my $source=File::Spec->catfile($tmp,"matrix-$stem.c26");
   my $hex=File::Spec->catfile($tmp,"matrix-$stem.hex");
   my $map=File::Spec->catfile($tmp,"matrix-$stem.map");
   write_file($source,$src);
   require_ok("build legal scalar operator matrix for $t->{name}",$driver,'-I',$testdir,
      '-DMACHINE_6502_NO_DEFAULT_ROM','-T',$cfg,'-Map',$map,$source,'-o',$hex);
   my $m=read_file($map);
   $m =~ /^\s*cartram\s+read_start=\$F080 write_start=\$F000 size=\$0080 type=rw shared=yes\b/m
      or die "$t->{name} matrix lost split-address cartram\n$m";
   for my $name (qw(cart_x cart_y cart_r cart_b)) {
      $m =~ /(?:BSS|DATA)\.cartram\.__vcsc_object\$\Q$name\E\b.*\bsplit=yes\b/m
         or die "$t->{name} $name is not actually split cartram\n$m";
   }
   for my $name (qw(ram_x ram_y ram_r ram_b)) {
      $m =~ /(?:BSS|DATA)\.__vcsc_object\$\Q$name\E\b/m
         or die "$t->{name} $name is not ordinary RAM\n$m";
   }
   my($out,$err)=require_ok("simulate legal scalar operator matrix for $t->{name}",$sim,
      '--split-fill=0xA7','-T',$cfg,$hex);
   $err eq '' or die "$t->{name} simulator wrote stderr:\n$err";
   $legal_cells += scalar(@$ram_labels)+scalar(@$cart_labels);
}

for my $t (grep { $_->{bcd} } @types) {
   for my $s (@storage) {
      for my $op (@bcd_illegal_ops) {
         my($src,$needle)=illegal_source($t,$s->{name},$op);
         my $stem=join('-', $t->{name},$s->{name},$op); $stem =~ s/[^A-Za-z0-9_.-]+/_/g;
         my $source=File::Spec->catfile($tmp,"illegal-$stem.c26");
         my $asm=File::Spec->catfile($tmp,"illegal-$stem.s26");
         write_file($source,$src);
         my($rc,$sig,$out,$err)=run_capture($driver,'-I',$testdir,'-DMACHINE_6502_NO_DEFAULT_ROM','-S',$source,'-o',$asm);
         ($rc != 0 || $sig) or die "illegal matrix unexpectedly accepted $t->{name}/$s->{name}/$op\n";
         index($err,$needle)>=0 && $err =~ /not supported for packed-BCD values/
            or die "illegal matrix rejected $t->{name}/$s->{name}/$op for wrong reason\nneedle=$needle\nstderr:\n$err";
         $illegal_cells++;
      }
   }
}

$legal_cells==896 or die "legal matrix count drift: $legal_cells != 896\n";
$illegal_cells==144 or die "illegal matrix count drift: $illegal_cells != 144\n";
print "scalar operator Cartesian matrix passed: $legal_cells legal runtime cells, $illegal_cells illegal compile cells, ".($legal_cells+$illegal_cells)." total\n";
