#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(basename);
use File::Glob qw(bsd_glob);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP [--family FIXTURE [--mixed]]\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub read_file {
   my($path)=@_; open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $d=<$fh>; close($fh); return defined($d)?$d:'';
}
sub write_file {
   my($path,$text)=@_; open(my $fh,'>:raw',$path) or die "write $path: $!\n";
   print {$fh} $text; close($fh) or die "close $path: $!\n";
}
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }
sub map_zp {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n";
   my $value=hex($1); $value<=0xff or die "$name is not in zero page\n";
   return sprintf('0x%02x',$value);
}
sub transform_score {
   my($text,$kind)=@_;
   return $text if $kind eq 'center';
   if ($kind eq 'left' || $kind eq 'right') {
      my $component=$kind eq 'left' ? 'six_glyph_left_component.c26' : 'six_glyph_right_component.c26';
      $text =~ s/instantiate "six_glyph_component\.c26" as score/instantiate "$component" as score/
         or die "could not install $kind score component\n";
      $text =~ s/^(\s*score_score := 123456;\n)/$1   score_color := 0x0e;\n/m
         or die "could not initialize $kind score color\n";
      return $text;
   }
   if ($kind eq 'two-plus-two') {
      $text =~ s/(include "fonts\/default_decimal\.c26"\n)/$1include "two_plus_two_score_support.c26"\n/
         or die "could not add two-plus-two support\n";
      $text =~ s/instantiate "six_glyph_component\.c26" as score/instantiate "two_plus_two_score_component.c26" as score/
         or die "could not install two-plus-two component\n";
      $text =~ s/^\s*score_score := 123456;\n/   score_left_score := 12;\n   score_right_score := 34;\n   score_left_color := 0x0e;\n   score_right_color := 0x2e;\n   score_left_x := 16;\n   score_right_x := 104;\n/m
         or die "could not initialize two-plus-two component\n";
      return $text;
   }
   if ($kind eq 'poison') {
      $text =~ s/instantiate "six_glyph_component\.c26" as score/instantiate "renderers\/poison_debug_score\/poison_debug_score.c26" as score/
         or die "could not install poison component\n";
      $text =~ s/^\s*score_score := 123456;\n/   score_exit_background := 0x84;\n/m
         or die "could not initialize poison component\n";
      return $text;
   }
   die "unknown score kind $kind\n";
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
my $family_filter;
my $run_mixed=1;
if (@ARGV) {
   shift @ARGV eq '--family' or usage();
   $family_filter=shift @ARGV // usage();
   $run_mixed=0;
   if (@ARGV && $ARGV[0] eq '--mixed') {
      shift @ARGV;
      $run_mixed=1;
   }
}
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve tmp\n";

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $cfg=File::Spec->catfile($vcs,qw(renderers standard_4k_ntsc vcs_standard_4k_ntsc.cfg));
my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));

my @families=(
   {fixture=>'player_color_181',            example=>'04_player_color_181',            class=>'player',   illegals=>0},
   {fixture=>'all_five_181',                example=>'06_all_five_181',                class=>'all_five', illegals=>0},
   {fixture=>'player_color_181_unofficial', example=>'07_player_color_181_unofficial', class=>'player',   illegals=>1},
   {fixture=>'all_five_181_unofficial',     example=>'08_all_five_181_unofficial',     class=>'all_five', illegals=>1},
);
my @scores=(
   {kind=>'center',       above=>'01_score_above',                 below=>'02_score_below',                 component=>'six_glyph_component.c26'},
   {kind=>'left',         above=>'03_left_justified_score_above',  below=>'04_left_justified_score_below',  component=>'six_glyph_left_component.c26'},
   {kind=>'right',        above=>'05_right_justified_score_above', below=>'06_right_justified_score_below', component=>'six_glyph_right_component.c26'},
   {kind=>'two-plus-two', above=>'07_two_plus_two_score_above',    below=>'08_two_plus_two_score_below',    component=>'two_plus_two_score_component.c26'},
   {kind=>'poison',       above=>'09_poison_score_above',          below=>'10_poison_score_below',          component=>'renderers/poison_debug_score/poison_debug_score.c26'},
);

my @active_families=defined($family_filter)
   ? grep { $_->{fixture} eq $family_filter } @families
   : @families;
@active_families or die "unknown score-composition family $family_filter\n";

my %harness_sources=(
   raster=>[qw(test vcs_score_matrix_raster.cpp)],
   player=>[qw(test vcs_player_color_181.cpp)],
   all_five=>[qw(test vcs_all_five_composition.cpp)],
   phase=>[qw(test vcs_playfield_phase.cpp)],
);
my %needed=(raster=>1);
if (@active_families) {
   $needed{phase}=1;
   $needed{player}=1 if grep { $_->{class} eq 'player' } @active_families;
   $needed{all_five}=1 if grep { $_->{class} eq 'all_five' } @active_families;
}
my %executables;
for my $name (sort keys %needed) {
   my $src=File::Spec->catfile($repo,@{$harness_sources{$name}});
   my $exe=File::Spec->catfile($tmp,"score_matrix_$name");
   my @warnings=$name eq 'raster' ? ('-Wall','-Wextra','-Werror','-pedantic') : ();
   my($rc,$sig,$out,$err)=capture($cxx,'-std=c++17',@warnings,'-O2',
      '-DILLEGAL_OPCODES','-I',$mos,$src,@mos_input,'-o',$exe);
   $rc==0 && !$sig or die "$name harness build failed\n$out$err";
   $out eq '' && $err eq '' or die "$name harness build wrote output\n$out$err";
   $executables{$name}=$exe;
}

# Lock the complete public 4 x 5 x 2 inventory and its legal draw order.
my $public=0;
for my $family (@active_families) {
   for my $score (@scores) {
      for my $order (qw(above below)) {
         my $leaf=File::Spec->catdir($repo,'examples',$family->{example},$score->{$order},'01_interactive');
         -d $leaf or die "missing public matrix leaf $leaf\n";
         my @sources=bsd_glob(File::Spec->catfile($leaf,'*.c26'));
         @sources==1 or die "$leaf has ".scalar(@sources)." editable sources, expected one\n";
         my $text=read_file($sources[0]);
         $text =~ /instantiate\s+"\Q$score->{component}\E"\s+as\s+score\b/
            or die "$sources[0] does not use $score->{component}\n";
         if ($family->{class} eq 'all_five') {
            my $renderer=$family->{illegals}
               ? 'renderers/all_five_unofficial/all_five_unofficial.c26'
               : 'renderers/all_five/all_five.c26';
            $text =~ /instantiate\s+"\Q$renderer\E"\s+as\s+game\s*\(\s*lines\s*:=\s*181\s*\)/
               or die "$sources[0] does not use $renderer lines:=181\n";
         } else {
            if ($family->{illegals}) {
               $text =~ /instantiate\s+"renderers\/player_color_181_unofficial\/player_color_181_unofficial\.c26"\s+as\s+game\b/
                  or die "$sources[0] does not use player_color_181_unofficial\n";
            } else {
               $text =~ /instantiate\s+"renderers\/player_color\/player_color\.c26"\s+as\s+game\s*\(\s*lines\s*:=\s*181\s*\)/
                  or die "$sources[0] does not use player_color lines:=181\n";
            }
         }
         my $expected=$order eq 'above'
            ? qr/score_draw\(\);.*vcs_ntsc_component_handoff\(\);.*game_draw\(\);/s
            : qr/game_draw\(\);.*vcs_ntsc_component_handoff\(\);.*score_draw\(\);/s;
         $text =~ $expected or die "$sources[0] has the wrong $order draw order\n";
         ++$public;
      }
   }
}
my $expected_public=10 * scalar(@active_families);
$public==$expected_public or die "public matrix has $public entries, expected $expected_public\n";

# Build and raster-check every real public production cartridge.  The smaller
# generated composition fixtures cannot expose page-sensitive branch timing
# changes caused by the final public link layout.
my $public_production_checked=0;
for my $family (@active_families) {
   for my $score (grep { $_->{kind} ne 'poison' } @scores) {
      for my $order (qw(above below)) {
         my $leaf=File::Spec->catdir($repo,'examples',$family->{example},$score->{$order},'01_interactive');
         my @sources=bsd_glob(File::Spec->catfile($leaf,'*.c26'));
         my $tag=join('_','public',$family->{fixture},$score->{kind},$order);
         $tag =~ s/-/_/g;
         my $bin=File::Spec->catfile($tmp,"$tag.bin");
         my @extra=$family->{illegals} ? ('-Wa,--illegals') : ();
         my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-I',$leaf,@extra,$sources[0],'-o',$bin);
         $rc==0 && !$sig or die "$tag build failed\n$out$err";
         without_usage($out) eq '' && $err eq '' or die "$tag build wrote output\n$out$err";
         -s $bin==4096 or die "$tag is not a 4K cartridge\n";

         my($first_row,$profile);
         if ($family->{class} eq 'player') {
            $first_row=$order eq 'above' ? 55 : 44;
            $profile='diagonal';
         }
         else {
            # With console inputs released, every public all-five score
            # composition reaches the first complete gameplay row at the same
            # frame-relative line.  Do not calibrate this against a held Reset;
            # startup/BSS clearing cost is unrelated to visible scheduling.
            $first_row=$order eq 'above' ? 55 : 44;
            $profile='all-five-diagonal';
         }
         ($rc,$sig,$out,$err)=capture($executables{phase},$bin,'11','11',$first_row,$profile);
         $rc==0 && !$sig or die "$tag public playfield raster failed\n$out$err";
         $out eq "vcs_playfield_raster ok: 11 rows x 16 lines x 160 pixels\n"
            or die "unexpected $tag public playfield output: $out";
         $err eq '' or die "$tag public playfield stderr: $err";
         ++$public_production_checked;
      }
   }
}
my $expected_production=8 * scalar(@active_families);
$public_production_checked==$expected_production or die "checked $public_production_checked public production cartridges, expected $expected_production\n";

my $checked=0;
for my $family (@active_families) {
   for my $score (@scores) {
      for my $order (qw(above below)) {
         my $entry=$order eq 'above' ? 40 : 221;
         for my $mode (qw(static motion)) {
            my $base=File::Spec->catfile($repo,'test','fixtures',$family->{fixture},"${mode}_score_${order}.c26");
            my $source=transform_score(read_file($base),$score->{kind});
            my $tag=join('_',$family->{fixture},$score->{kind},$order,$mode);
            $tag =~ s/-/_/g;
            my $src=File::Spec->catfile($tmp,"$tag.c26");
            my $bin=File::Spec->catfile($tmp,"$tag.bin");
            my $mapfile=File::Spec->catfile($tmp,"$tag.map");
            write_file($src,$source);
            my @extra=$family->{illegals} ? ('-Wa,--illegals') : ();
            my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,@extra,'-Map',$mapfile,$src,'-o',$bin);
            $rc==0 && !$sig or die "$tag build failed\n$out$err";
            without_usage($out) eq '' && $err eq '' or die "$tag build wrote output\n$out$err";
            -s $bin==4096 or die "$tag is not a 4K cartridge\n";

            ($rc,$sig,$out,$err)=capture($executables{raster},$bin,$score->{kind},$entry);
            $rc==0 && !$sig or die "$tag score raster failed\n$out$err";
            $out eq "vcs_score_matrix_raster $score->{kind} ok: exact score pixels, ownership schedule, and 262-line frames\n"
               or die "unexpected $tag score-raster output: $out";
            $err eq '' or die "$tag score-raster stderr: $err";

            my $map=read_file($mapfile);
            my @args;
            if ($family->{class} eq 'player') {
               @args=($executables{player},$mode,$bin,map { map_zp($map,$_) }
                  qw(game_object_x game_player0_y game_player1_y game_ball_y));
               push @args,map_zp($map,'motion_directions') if $mode eq 'motion';
               push @args,$score->{kind} eq 'poison' ? "poison-$order" : $order;
               ($rc,$sig,$out,$err)=capture(@args);
               my $label=$score->{kind} eq 'poison' ? "poison-$order" : $order;
               $rc==0 && !$sig or die "$tag gameplay raster failed\n$out$err";
               $out eq "vcs_player_color_181 composition $mode $label ok\n"
                  or die "unexpected $tag gameplay output: $out";
            }
            else {
               @args=($executables{all_five},$bin,$order,$mode);
               if ($mode eq 'motion') {
                  push @args,map { map_zp($map,$_) } qw(game_object_x game_player0_y game_player1_y game_missile0_y game_missile1_y game_ball_y motion_frame);
               }
               push @args,'poison' if $score->{kind} eq 'poison';
               ($rc,$sig,$out,$err)=capture(@args);
               $rc==0 && !$sig or die "$tag gameplay raster failed\n$out$err";
               $out eq "vcs_all_five_composition $mode $order ok\n"
                  or die "unexpected $tag gameplay output: $out";
            }
            $err eq '' or die "$tag gameplay stderr: $err";
            ++$checked;
         }
      }
   }
}
my $expected_compositions=20 * scalar(@active_families);
$checked==$expected_compositions or die "checked $checked static/motion compositions, expected $expected_compositions\n";

# A score-only cartridge proves arbitrary placement and four mixed instances;
# the existing centered and two-plus-two component tests separately cover
# multiple same-type instances and independent per-instance motion.
if ($run_mixed) {
   my $mixed_src=File::Spec->catfile($repo,qw(test fixtures score_composition_matrix mixed_instances.c26));
   my $mixed_bin=File::Spec->catfile($tmp,'score_matrix_mixed_instances.bin');
   my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,$mixed_src,'-o',$mixed_bin);
   $rc==0 && !$sig or die "mixed score-instance build failed\n$out$err";
   without_usage($out) eq '' && $err eq '' or die "mixed score-instance build wrote output\n$out$err";
   for my $case (['center',50],['left',80],['right',110],['two-plus-two',140]) {
      ($rc,$sig,$out,$err)=capture($executables{raster},$mixed_bin,@$case);
      $rc==0 && !$sig or die "mixed @$case raster failed\n$out$err";
      $out eq "vcs_score_matrix_raster $case->[0] ok: exact score pixels, ownership schedule, and 262-line frames\n"
         or die "unexpected mixed $case->[0] output: $out";
      $err eq '' or die "mixed $case->[0] stderr: $err";
   }

}

if (defined($family_filter)) {
   print "vcs_score_composition_raster family $family_filter ok: $expected_public public score/gameplay pairs, $expected_production production cartridges, and $expected_compositions static/motion compositions";
   print "; mixed score placement also passes" if $run_mixed;
   print "\n";
}
else {
   print "vcs_score_composition_raster ok: 40 public score/gameplay pairs have exact static and motion pixels; 32 public production cartridges preserve the diagonal playfield; mixed score placement also passes\n";
}
