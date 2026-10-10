# Shared deterministic Stella test configuration.
# Required directly by maintained Stella certification scripts.
use strict;
use warnings;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use Fcntl qw(O_CREAT O_EXCL O_WRONLY);
use Socket qw(PF_UNIX SOCK_STREAM sockaddr_un);
use Digest::SHA qw(sha256_hex);

sub vcsc_stella_private_env {
   my($basedir)=@_;
   defined($basedir) or die "vcsc_stella_private_env requires BASEDIR\n";
   make_path($basedir);
   my$xdg=File::Spec->catdir($basedir,'.xdg');
   my$config=File::Spec->catdir($xdg,'config');
   my$data=File::Spec->catdir($xdg,'data');
   my$state=File::Spec->catdir($xdg,'state');
   my$cache=File::Spec->catdir($xdg,'cache');
   make_path($config,$data,$state,$cache);
   $ENV{HOME}=$basedir;
   $ENV{XDG_CONFIG_HOME}=$config;
   $ENV{XDG_DATA_HOME}=$data;
   $ENV{XDG_STATE_HOME}=$state;
   $ENV{XDG_CACHE_HOME}=$cache;
}

sub vcsc_stella_palette_args {
   my($repo,$basedir)=@_;
   defined($repo)&&defined($basedir) or die "vcsc_stella_palette_args requires REPO and BASEDIR\n";
   vcsc_stella_private_env($basedir);
   my$palette=File::Spec->catfile($repo,qw(test fixtures stella stella.pal));
   -f$palette or die "missing pinned Stella palette $palette\n";
   -s$palette==792 or die "pinned Stella palette must be exactly 792 bytes\n";
   open(my$fh,'<:raw',$palette) or die "open $palette: $!\n"; local$/; my$data=<$fh>; close$fh;
   sha256_hex($data) eq '912ce47e7c53e0e61a861bc0ff889d187644ac53d762f0c0091484c70a3bf8bd'
      or die "pinned Stella palette digest changed\n";
   make_path($basedir);
   my$dest=File::Spec->catfile($basedir,'stella.pal');
   copy($palette,$dest) or die "copy $palette -> $dest: $!\n";
   return (
      '-basedir',$basedir,
      '-palette','user',
      '-pal.hue','0',
      '-pal.saturation','0',
      '-pal.contrast','0',
      '-pal.brightness','0',
      '-pal.gamma','0',
      '-detectpal60','0',
      '-detectntsc50','0',
      '-plr.colorloss','0',
      '-dev.colorloss','0',
      '-tv.filter','0',
      '-tv.phosblend','0',
      '-tia.inter','0',
   );
}

# --- X display allocation ------------------------------------------------------
#
# Concurrent runs in separate checkouts are normal for this project, and they share
# /tmp, so a display number has to be reserved ATOMICALLY.  The pattern this
# replaces was:
#
#     my$n=250+($$%20); $n++ while -e "/tmp/.X11-unix/X$n";
#
# which is check-then-create.  Two processes can both see a number free and both try
# to start an X server on it; the loser exits 1 and, because nothing verified that
# Xvfb came up, the test carried on against a dead display and failed somewhere
# unrelated.  Measured: with the PID bucket forced to collide, two of three Xvfb
# instances died that way.  The PID modulo is a second problem -- any two PIDs a
# multiple of the span apart start probing at the same number.
#
# The reservation is a file created with O_CREAT|O_EXCL, because that is the one
# primitive here that is atomic.  A display already carrying an X socket is skipped
# outright, which is what covers another user's X server and an interactive session.
# A reservation whose owner has gone is reclaimed, so a killed run leaks a display
# only until the next one notices.
#
# These are deliberately NOT keyed by user: two accounts share /tmp, so a private
# per-user key would defeat the coordination entirely.  The file records the owning
# account so a reservation is never stolen from a live run, and never from a
# different account whose PIDs cannot be tested with kill(0).
my @vcsc_x_reservations;      # [ display number, reservation path ]
my @vcsc_x_servers;          # Xvfb pids registered by vcsc_xvfb_assert_ready

sub vcsc_x_socket_path {
   return File::Spec->catfile(File::Spec->tmpdir(), '.X11-unix', "X$_[0]");
}

sub vcsc_x_reserve_path {
   return File::Spec->catfile(File::Spec->tmpdir(), ".vcsc-xvfb-reserve.$_[0]");
}

# Is the process that took a reservation still running?
#
# Within this account the answer is exact: kill(0) on our own pid.  Across accounts
# it is NOT -- kill(0) answers only for our own processes, so testing another
# account's pid would report it dead and we would steal a live reservation.  A
# reservation owned by a different account is therefore treated as live, and only
# reclaimed once it is older than VCSC_X_RESERVATION_TTL, which bounds how long a
# killed run can hide a display from someone else.
sub vcsc_x_reservation_live {
   my ($path) = @_;
   my $ttl = $ENV{VCSC_X_RESERVATION_TTL};
   $ttl = defined($ttl) && $ttl =~ /^[0-9]+$/ ? $ttl : 3600;
   my @st = stat($path);
   return 0 unless @st;                       # already gone; the caller's -e was stale
   my $age_by_mtime = time() - $st[9];

   open(my $fh, '<', $path) or return $age_by_mtime < $ttl ? 1 : 0;
   my $line = <$fh>;
   close($fh);

   # A file that exists but does not yet parse is NOT evidence of a dead owner.  The
   # claim is created with O_EXCL and the owner record is written afterwards and
   # flushed at close, so between those two instants a peer can legitimately read an
   # empty or half-written file.  Reading that as "owner gone" would let the peer
   # unlink a live reservation and take the same display, which is precisely the race
   # this whole mechanism exists to remove.  Only the file's age can retire it.
   return $age_by_mtime < $ttl ? 1 : 0
      unless defined($line) && $line =~ /\A\s*(\S+)\s+([0-9]+)\s+([0-9]+)\s*\z/;
   my ($user, $pid, $when) = ($1, $2, $3);

   my $self = scalar getpwuid($<);
   return 1 unless defined($self);
   if ($user ne $self) {
      # Someone else's: a pid cannot be tested across accounts, so age is the only
      # evidence available.
      my $age = time() - $when;
      $age = $age_by_mtime if $age < 0;
      return $age < $ttl ? 1 : 0;
   }
   # Within this account the answer is exact.
   return kill(0, $pid) ? 1 : 0;
}

# Claim one display out of BASE..BASE+SPAN-1.  Returns (number, ":number").
sub vcsc_reserve_x_display {
   my ($base, $span) = @_;
   defined($base) && defined($span) && $span > 0
      or die "vcsc_reserve_x_display requires BASE and a positive SPAN\n";
   for my $offset (0 .. $span - 1) {
      my $n = $base + $offset;
      next if -e vcsc_x_socket_path($n);
      my $path = vcsc_x_reserve_path($n);
      for my $attempt (1, 2) {
         if (sysopen(my $fh, $path, O_CREAT | O_EXCL | O_WRONLY, 0644)) {
            print {$fh} scalar(getpwuid($<)), " $$ ", time(), "\n";
            close($fh);
            push @vcsc_x_reservations, [$n, $path];
            return ($n, ":$n");
         }
         # Taken.  On the second pass only, reclaim it if the owner is gone; the
         # O_EXCL create above still decides the winner between reapers.
         last unless $attempt == 1;
         unlink $path if -e $path && !vcsc_x_reservation_live($path);
      }
   }
   die "no free X display in $base.." . ($base + $span - 1)
       . "; every number is either serving an X server or reserved by a live run\n";
}

# Give back everything this process claimed.  Safe to call more than once.
sub vcsc_release_x_displays {
   for my $r (@vcsc_x_reservations) {
      unlink $r->[1] if -e $r->[1];
   }
   @vcsc_x_reservations = ();
}

# Is the X server on this display actually accepting connections?  A socket FILE is
# not enough: Xvfb creates it slightly before it starts listening, so a file test
# can pass while a client would still be refused.  Connecting is the only check that
# matches what Stella is about to do.
sub vcsc_x_listening {
   my ($number) = @_;
   my $path = vcsc_x_socket_path($number);
   return 0 unless -e $path;
   socket(my $s, PF_UNIX, SOCK_STREAM, 0) or return 0;
   my $ok = connect($s, sockaddr_un($path));
   close($s);
   return $ok ? 1 : 0;
}

# Fail loudly if the server just forked for DISPLAY did not come up.
#
# This is the half of the fix that the reservation alone does not cover.  A
# reservation makes the display UNIQUE; it cannot make the X server START.  Without
# this check an Xvfb that dies -- out of memory, a display it still considers
# locked, an exec failure -- leaves the test running against a dead display, and the
# failure surfaces later as an opaque Stella error with nothing pointing at the
# cause.  That indirection is exactly how the original race stayed unnoticed.
#
# waitpid(WNOHANG) is used rather than kill(0): a dead child stays in the process
# table as a zombie until it is reaped, so kill(0) reports a dead Xvfb as alive.
sub vcsc_xvfb_assert_ready {
   my ($display, $pid) = @_;
   defined($display) && defined($pid)
      or die "vcsc_xvfb_assert_ready requires DISPLAY and PID\n";
   (my $number = $display) =~ s/^://;
   push @vcsc_x_servers, $pid;
   for my $try (1 .. 200) {
      if (waitpid($pid, 1) == $pid) {
         my $status = $?;
         pop @vcsc_x_servers;
         die "Xvfb exited on $display before serving it (exit " . ($status >> 8) . ")\n";
      }
      return 1 if vcsc_x_listening($number);
      select undef, undef, undef, 0.05;
   }
   die "Xvfb never began accepting connections on $display\n";
}

# Registered servers are reaped at exit so a test that dies mid-run cannot leave an
# Xvfb holding a display.  waitpid(WNOHANG) is consulted FIRST: a server the test
# already terminated has been reaped, and its pid may since have been handed to an
# unrelated process, so signalling without this check could kill a bystander.
# Returns 0 for a live child, $pid for one that exited, -1 for one already reaped.
# Registered servers are reaped at exit so a test that dies mid-run cannot leave an
# Xvfb holding a display.  Two traps here, both of which were live bugs:
#
#   - waitpid(WNOHANG) is consulted first.  A server the test already terminated has
#     been reaped, and its pid may since have been handed to an unrelated process, so
#     signalling without this check could kill a bystander.
#
#   - $? is saved and restored.  A waitpid that finds no such child returns -1 and
#     sets $? to -1, and a $? assigned inside an END block BECOMES the process exit
#     status, overriding even an explicit `exit 0`.  Leaving that in place made all
#     twenty-two converted runners report success on stdout and exit 255.
END {
   my $status = $?;
   for my $pid (@vcsc_x_servers) {
      # 0 means still running, $pid means it exited, -1 means it is not our child.
      my $reaped = waitpid($pid, 1);
      next unless $reaped == 0;
      kill 'TERM', $pid;
      waitpid($pid, 0);
   }
   @vcsc_x_servers = ();
   vcsc_release_x_displays();
   $? = $status;
}
1;
