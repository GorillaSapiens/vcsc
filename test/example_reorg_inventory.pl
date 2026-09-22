#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: example reorg inventory ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Find qw(find);
use File::Spec;

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO\n");
die "usage: $0 REPO\n" if @ARGV;

my $examples=File::Spec->catdir($repo,'examples');
my $inventory=File::Spec->catfile($repo,qw(test fixtures example_reorg_inventory.tsv));
my $refs_fixture=File::Spec->catfile($repo,qw(test fixtures example_reorg_path_refs.tsv));

sub slurp {
   my($path)=@_;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/;
   my $text=<$fh>;
   close($fh);
   return defined($text) ? $text : '';
}

sub rel_path {
   my($path)=@_;
   my $rel=File::Spec->abs2rel($path,$repo);
   $rel =~ s{\\}{/}g;
   return $rel;
}

my(%ids,%targets,%old_markers,%active_leaves,%retired_top);
my($existing_count,$new_count)=(0,0);
for my $line (split /\n/,slurp($inventory)) {
   next if $line eq '' || $line =~ /^#/;
   my($kind,$id,$old,$target,$marker)=split /\t/,$line,5;
   defined($marker) or die "malformed example reorg inventory line: $line\n";
   ($kind eq 'existing' || $kind eq 'new')
      or die "invalid example reorg inventory kind '$kind' for $id\n";
   $id =~ /^[A-Za-z0-9_]+$/ or die "invalid example reorg logical id '$id'\n";
   !$ids{$id}++ or die "duplicate example reorg logical id '$id'\n";
   $target =~ m{^(?:01_basics|02_components|03_controllers|04_renderers|05_video_standards|06_games|07_diagnostics)/}
      or die "invalid target example leaf '$target' for $id\n";
   !$targets{$target}++ or die "duplicate target example leaf '$target'\n";
   $target !~ m{(?:^|/)_common(?:/|$)}
      or die "runnable target incorrectly placed under _common: $target\n";
   $marker ne '' && $marker !~ m{/}
      or die "invalid marker '$marker' for $id\n";

   my $target_marker=File::Spec->catfile($examples,split(m{/},$target),$marker);
   if ($kind eq 'new') {
      ++$new_count;
      $old eq '-' or die "new example $id unexpectedly has old leaf '$old'\n";
      $active_leaves{$target}=1 if -f $target_marker;
      next;
   }

   ++$existing_count;
   $old ne '-' or die "existing example $id lacks old leaf\n";
   $old =~ m{^([^/]+)/} or die "invalid old example leaf '$old' for $id\n";
   $retired_top{$1}=1;
   my $old_marker=File::Spec->catfile($examples,split(m{/},$old),$marker);
   my $old_present=-f $old_marker;
   my $target_present=-f $target_marker;
   $old_present || $target_present
      or die "mapped example $id is missing from both '$old' and '$target'\n";
   !($old_present && $target_present)
      or die "mapped example $id is duplicated at both '$old' and '$target'\n";
   my $where=$old_present ? $old : $target;
   $active_leaves{$where}=1;
   my $old_key="$old\t$marker";
   !$old_markers{$old_key}++
      or die "duplicate old-leaf marker '$old/$marker' in inventory\n";
}
$existing_count==85 or die "existing example inventory count changed: $existing_count != 85\n";
$new_count==7 or die "planned-new example inventory count changed: $new_count != 7\n";

my %actual_leaves;
find({
   no_chdir=>1,
   wanted=>sub {
      return unless -f $_ && $File::Find::name =~ m{(?:^|/)Makefile\z};
      my $dir=$File::Find::dir;
      my $rel=File::Spec->abs2rel($dir,$examples);
      $rel =~ s{\\}{/}g;
      if ($rel =~ m{(?:^|/)(?:common|_common)(?:/|$)}) {
         die "shared example support directory contains runnable Makefile: examples/$rel/Makefile\n";
      }
      $actual_leaves{$rel}=1;
   },
},$examples);

for my $leaf (sort keys %actual_leaves) {
   $active_leaves{$leaf}
      or die "unmapped runnable example leaf appeared: examples/$leaf\n";
}
for my $leaf (sort keys %active_leaves) {
   $actual_leaves{$leaf}
      or die "inventory expects runnable example leaf without Makefile: examples/$leaf\n";
}

# ER25 final-tree invariants.  The seven purpose categories are the only
# runnable top-level groups; _common is shared source and must stay non-runnable.
my @expected_top=qw(01_basics 02_components 03_controllers 04_renderers 05_video_standards 06_games 07_diagnostics _common);
opendir(my $examples_dh,$examples) or die "opendir $examples: $!\n";
my @actual_top=sort grep {
   $_ ne '.' && $_ ne '..' && -d File::Spec->catdir($examples,$_)
} readdir($examples_dh);
closedir($examples_dh);
join("\n",@actual_top) eq join("\n",sort @expected_top)
   or die "final example top-level groups changed: actual [".join(', ',@actual_top)."] expected [".join(', ',sort @expected_top)."]\n";
for my $name (sort keys %retired_top) {
   !-d File::Spec->catdir($examples,$name)
      or die "retired top-level example group still exists: examples/$name\n";
}
my @interactive_shells;
find({
   no_chdir=>1,
   wanted=>sub {
      return unless -d $File::Find::name;
      push @interactive_shells,rel_path($File::Find::name)
         if $_ eq '01_interactive';
   },
},$examples);
!@interactive_shells
   or die "redundant 01_interactive directory remains: ".join(', ',sort @interactive_shells)."\n";
my $common=File::Spec->catdir($examples,'_common');
my @common_makefiles;
find({
   no_chdir=>1,
   wanted=>sub {
      push @common_makefiles,rel_path($File::Find::name)
         if -f $_ && $_ eq 'Makefile';
   },
},$common);
!@common_makefiles
   or die "shared _common support became runnable: ".join(', ',sort @common_makefiles)."\n";

# The path-reference fixture is deliberately a migration checklist.  It tracks
# text files that still mention a retired top-level example family, including
# tests which synthesize paths from the family name rather than spelling an
# examples/... path.  The mapping specification itself and cold history are
# intentional archival references and are not checklist entries.
my %expected_refs;
for my $line (split /\n/,slurp($refs_fixture)) {
   next if $line eq '' || $line =~ /^#/;
   my($path,$names)=split /\t/,$line,2;
   defined($names) && $path ne '' or die "malformed path-reference inventory line: $line\n";
   my @names=split /,/,$names;
   @names or die "empty retired-name list for $path\n";
   my %seen;
   for my $name (@names) {
      $retired_top{$name} or die "unknown retired example family '$name' for $path\n";
      !$seen{$name}++ or die "duplicate retired family '$name' for $path\n";
   }
   !$expected_refs{$path}
      or die "duplicate path-reference inventory file '$path'\n";
   $expected_refs{$path}=join(',',sort @names);
}

my %allowed_suffix=map { $_=>1 } qw(.md .txt .dox .pl .test .cpp .c .h .c26 .tsv .json .yml .yaml .sh .mk);
my %allowed_name=map { $_=>1 } qw(Makefile .gitignore);
my %excluded=(
   '.../example_reorg.txt'=>1,
   'test/fixtures/example_reorg_inventory.tsv'=>1,
   'test/fixtures/example_reorg_path_refs.tsv'=>1,
);
my @retired=sort { length($b)<=>length($a) || $a cmp $b } keys %retired_top;
my $retired_re=join('|',map { quotemeta($_) } @retired);
my %actual_refs;
find({
   no_chdir=>1,
   wanted=>sub {
      return unless -f $_;
      my $rel=rel_path($File::Find::name);
      return if $rel =~ m{^\.\.\./context-history/};
      return if $excluded{$rel};
      my($suffix)=$rel =~ /(\.[^\/.]+)\z/;
      return unless $allowed_name{(File::Spec->splitpath($rel))[2]} ||
                    (defined($suffix) && $allowed_suffix{$suffix});
      my $text=slurp($File::Find::name);
      my %hits;
      while ($text =~ /(?<![A-Za-z0-9_])($retired_re)(?![A-Za-z0-9_])/g) {
         $hits{$1}=1;
      }
      $actual_refs{$rel}=join(',',sort keys %hits) if %hits;
   },
},$repo);

for my $path (sort keys %actual_refs) {
   exists($expected_refs{$path})
      or die "untracked retired example path reference in $path: $actual_refs{$path}\n";
   $actual_refs{$path} eq $expected_refs{$path}
      or die "retired example path-reference set changed in $path: actual '$actual_refs{$path}' expected '$expected_refs{$path}'\n";
}
for my $path (sort keys %expected_refs) {
   exists($actual_refs{$path})
      or die "stale retired example path-reference inventory entry: $path\n";
}

print "example reorg inventory ok\n";
