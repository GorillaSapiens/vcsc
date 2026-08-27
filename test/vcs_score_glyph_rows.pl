#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: vcs_score_glyph_rows ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
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
sub read_file {
   my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n";
   local $/; my $d=<$f>; close($f); return $d // '';
}
sub write_file {
   my($p,$d)=@_; open(my $f,'>:raw',$p) or die "write $p: $!\n";
   print {$f} $d or die "write $p: $!\n"; close($f) or die "close $p: $!\n";
}
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }

my $repo=abs_path(shift @ARGV // usage());
my $tmp=shift @ARGV // usage();
@ARGV and usage();
make_path($tmp); $tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));

my @components=(
   ['six_glyph_component.c26',             'score', 8,  5, 'score_score := 123456;'],
   ['six_glyph_left_component.c26',        'score', 8,  5, 'score_score := 123456; score_color := 0x0e;'],
   ['six_glyph_right_component.c26',       'score', 8,  5, 'score_score := 123456; score_color := 0x0e;'],
   ['six_glyph_wide_component.c26',        'score', 8,  5, 'score_score := 123456; score_color := 0x0e;'],
   ['six_glyph_big_wide_component.c26',    'score', 16, 5, 'score_score := 123456; score_color := 0x0e;'],
   ['three_plus_three_score_component.c26','score', 8,  5, 'score_left_score := 123; score_right_score := 456; score_left_color := 0x0e; score_right_color := 0x1e;'],
   ['two_plus_two_score_component.c26',    'score', 8,  5, 'score_left_score := 12; score_right_score := 34; score_left_color := 0x0e; score_right_color := 0x1e; score_left_x := 32; score_right_x := 96;'],
);

for my $spec (@components) {
   my($file,$inst,$default,$probe,$uses)=@$spec;
   my $path=File::Spec->catfile($vcs,$file);
   my $text=read_file($path);
   $text =~ /parameter\s+glyph_rows\s*:=\s*\Q$default\E\b/
      or die "$file has no glyph_rows default $default\n";
   my $default_visible=$default+3;
   $text =~ /(?:#if|#elif)\s+TEMPLATE_glyph_rows\s*==\s*\Q$default\E\s*\n\s*alias\s+TEMPLATE_VISIBLE_SCANLINES_VALUE\s+\Q$default_visible\E\b/
      or die "$file has no default glyph_rows visible-height mapping\n";
   $text =~ /TEMPLATE_VISIBLE_SCANLINES\s*:=\s*TEMPLATE_VISIBLE_SCANLINES_VALUE/ &&
   $text =~ /TEMPLATE_DRAW_COMPLETE_SCANLINES\s*:=\s*TEMPLATE_VISIBLE_SCANLINES_VALUE/
      or die "$file does not publish glyph_rows through its visible contract\n";
   $text =~ /TEMPLATE_glyph_rows_must_be_1_through_\Q$default\E/
      or die "$file does not reject unsupported glyph_rows values\n";

   my $src=File::Spec->catfile($tmp,$file); $src =~ s/\.c26\z/_rows$probe.c26/;
   my $bin=$src; $bin =~ s/\.c26\z/.bin/;
   my $map=$src; $map =~ s/\.c26\z/.map/;
   my $body="include \"vcs.c26\"\n";
   if ($file eq 'two_plus_two_score_component.c26') {
      $body .= "include \"two_plus_two_score_support.c26\"\n";
   } else {
      my $bytes=10*$probe;
      my @v=(0..$bytes-1);
      $body .= "align(256) const uint8_t score_font[$bytes] := { ".join(',',@v)." };\n";
   }
   $body .= qq{instantiate "$file" as $inst (glyph_rows:=$probe)\n};
   $body .= "void main(void) { $uses ${inst}_init(); ${inst}_vblank(); ${inst}_draw(); ${inst}_overscan(); }\n";
   write_file($src,$body);
   my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$map,$src,'-o',$bin);
   $rc==0 && !$sig or die "$file glyph_rows=$probe build failed\n$out$err";
   without_usage($out) eq '' && $err eq '' or die "$file glyph_rows=$probe build wrote output\n$out$err";
   -s $bin==4096 or die "$file glyph_rows=$probe probe is not 4096 bytes\n";
   my $map_text=read_file($map);
   if ($file ne 'two_plus_two_score_component.c26') {
      $map_text =~ /\b${inst}_glyph_offsets\b.*?size=\$000A/
         or die "$file glyph_rows=$probe did not use packed glyph stride offsets\n";
   }
}

print "vcs_score_glyph_rows ok\n";
