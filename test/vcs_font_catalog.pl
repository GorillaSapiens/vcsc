#!/usr/bin/perl

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub without_cartridge_usage {
   my ($out) = @_;
   $out =~ s/\ACARTRIDGE ROM USAGE\n(?:  [^\n]+\n)+//;
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
sub parse_rows {
   my ($path,$symbol,$count)=@_;
   my $text=read_file($path);
   $text =~ /const\s+uint8_t\s+\Q$symbol\E\s*\[\s*\Q$count\E\s*\]\s*:=\s*\{(.*?)\}\s*;/s
      or die "$path does not define $symbol\[$count\]\n";
   my $body=$1;
   my @visual=$body =~ /^\s*0b([01.xX_]+)[,]?\s*$/mg;
   @visual==$count
      or die "$path has ".scalar(@visual)." visual rows, expected $count\n";
   my @bytes;
   for my $digits (@visual) {
      $digits =~ s/_//g;
      length($digits)==8 or die "$path has non-eight-pixel row '$digits'\n";
      $digits =~ tr/.xX/011/;
      push @bytes,oct("0b$digits");
   }
   # Source rows are top-to-bottom; the module's alias reverses each glyph.
   my @out;
   for (my $i=0;$i<@bytes;$i+=8) {
      push @out,reverse @bytes[$i..$i+7];
   }
   $text =~ /CC0-1\.0/ or die "$path lost its CC0 provenance note\n";
   $text =~ /alias\s+VCS_FONT_GLYPH\s*\(/ or die "$path lost row-reversal alias\n";
   return @out;
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "could not resolve repo root\n";
$tmp=abs_path($tmp) // die "could not resolve temp dir\n";

my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $fonts=File::Spec->catdir($vcs,'fonts');
my $example=File::Spec->catfile($repo,'test','fixtures','vcs_examples','03_six_digit_score','golden.c26');
my @families=qw(default 21st_century alarm_clock handwritten interrupted retroputer whimsey tiny);
my $example_text=read_file($example);

-f File::Spec->catfile($fonts,'README.md') or die "font catalog README is missing\n";
-d File::Spec->catdir($repo,'examples','03_six_digit_score','fonts')
   and die "example 03 still owns a private font directory\n";

for my $family (@families) {
   my $dec_file=File::Spec->catfile($fonts,"${family}_decimal.c26");
   my $hex_file=File::Spec->catfile($fonts,"${family}_hex.c26");
   my $dec_symbol="score_font";
   my $hex_symbol="score_font";
   -f $dec_file or die "missing $dec_file\n";
   -f $hex_file or die "missing $hex_file\n";
   my @dec=parse_rows($dec_file,$dec_symbol,80);
   my @hex=parse_rows($hex_file,$hex_symbol,128);
   join(',',@dec) eq join(',',@hex[0..79])
      or die "$family hexadecimal variant does not preserve decimal glyphs\n";
}

-f File::Spec->catfile($fonts,'hexadecimal_decimal.c26')
   and die "removed hexadecimal decimal font remains\n";
-f File::Spec->catfile($fonts,'hexadecimal_hex.c26')
   and die "removed hexadecimal hex font remains\n";

# Every module must build in the real six-digit cartridge, not merely parse.
for my $family (@families) {
   for my $variant (qw(decimal hex)) {
      my $module="fonts/${family}_${variant}.c26";
      my $source=$example_text;
      $source =~ s/include\s+"fonts\/default_decimal\.c26"/include "$module"/
         or die "could not replace example font include\n";
      my $stem="font_${family}_${variant}";
      my $src=File::Spec->catfile($tmp,"$stem.c26");
      my $bin=File::Spec->catfile($tmp,"$stem.bin");
      open(my $fh,'>',$src) or die "could not create $src: $!\n";
      print {$fh} $source;
      close($fh) or die "could not close $src: $!\n";
      my ($exit,$sig,$out,$err)=run_capture($driver,'-I',$vcs,$src,'-o',$bin);
      die "$module build exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err"
         if $exit || $sig;
      die "$module build wrote stdout:\n$out" if without_cartridge_usage($out) ne '';
      die "$module build wrote stderr:\n$err" if $err ne '';
      -s $bin == 4096 or die "$module cartridge is not 4096 bytes\n";
   }
}

print "vcs_font_catalog ok\n";
