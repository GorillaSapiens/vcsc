#!/usr/bin/perl
# Focus the largest mapped X11 window, optionally send F2 to reset the console,
# then send F12 to make Stella save a snapshot.
# This intentionally speaks the small X11 protocol subset directly so the test
# suite does not depend on Python, python-xlib, xdotool, or a non-core Perl X11
# binding merely to press one key in its private Xvfb server.

use strict;
use warnings;
use IO::Socket::UNIX;
use Socket qw(SOCK_STREAM);
use Time::HiRes qw(sleep time);

sub read_exact {
   my($fh,$length)=@_;
   my $data='';
   while (length($data)<$length) {
      my $n=sysread($fh,my $chunk,$length-length($data));
      defined($n) or die "read X11 socket: $!\n";
      $n>0 or die "X11 server closed the connection\n";
      $data.=$chunk;
   }
   return $data;
}

sub send_request {
   my($fh,$opcode,$minor,$body,$reply_expected)=@_;
   $body //= '';
   $body.="\0" x ((4-length($body)%4)%4);
   my $request=pack('CCv',$opcode,$minor,(4+length($body))/4).$body;
   syswrite($fh,$request)==length($request) or die "write X11 request: $!\n";
   return undef unless $reply_expected;
   while (1) {
      my $head=read_exact($fh,32);
      my $type=ord(substr($head,0,1));
      if ($type==0) {
         my $code=ord(substr($head,1,1));
         my $major=ord(substr($head,10,1));
         die "X11 protocol error $code while processing opcode $major\n";
      }
      next if $type!=1; # Ignore asynchronous events.
      my $extra_length=unpack('V',substr($head,4,4))*4;
      return $head.($extra_length ? read_exact($fh,$extra_length) : '');
   }
}

sub x_connect {
   my $display=$ENV{DISPLAY} // die "DISPLAY is not set\n";
   $display =~ /(?:^|:)(\d+)(?:\.\d+)?$/
      or die "unsupported DISPLAY '$display'; expected a local X display\n";
   my $number=$1;
   my $socket=IO::Socket::UNIX->new(
      Type=>SOCK_STREAM,
      Peer=>"/tmp/.X11-unix/X$number",
   ) or die "connect to X display $display: $!\n";
   binmode($socket);

   my $hello=pack('CCvvvvv',ord('l'),0,11,0,0,0,0);
   syswrite($socket,$hello)==length($hello) or die "write X11 setup: $!\n";
   my $setup_head=read_exact($socket,8);
   my($status,$reason_length,undef,undef,$extra_units)=unpack('CCvvv',$setup_head);
   my $setup=read_exact($socket,$extra_units*4);
   if ($status!=1) {
      my $reason=substr($setup,0,$reason_length);
      die "X11 setup failed: $reason\n";
   }
   length($setup)>=32 or die "short X11 setup reply\n";
   my $vendor_length=unpack('v',substr($setup,16,2));
   my $root_count=ord(substr($setup,20,1));
   my $format_count=ord(substr($setup,21,1));
   my $min_keycode=ord(substr($setup,26,1));
   my $max_keycode=ord(substr($setup,27,1));
   $root_count>=1 or die "X11 display has no screens\n";
   my $root_offset=32+(($vendor_length+3)&~3)+$format_count*8;
   $root_offset+4<=length($setup) or die "short X11 screen description\n";
   my $root=unpack('V',substr($setup,$root_offset,4));
   return ($socket,$root,$min_keycode,$max_keycode);
}

sub query_tree {
   my($fh,$window)=@_;
   my $reply=send_request($fh,15,0,pack('V',$window),1);
   my $count=unpack('v',substr($reply,16,2));
   return $count ? unpack('V*',substr($reply,32,$count*4)) : ();
}

sub is_viewable {
   my($fh,$window)=@_;
   my $reply=eval { send_request($fh,3,0,pack('V',$window),1) };
   return 0 if !$reply;
   return ord(substr($reply,26,1))==2;
}

sub geometry_area {
   my($fh,$window)=@_;
   my $reply=eval { send_request($fh,14,0,pack('V',$window),1) };
   return 0 if !$reply;
   my $width=unpack('v',substr($reply,16,2));
   my $height=unpack('v',substr($reply,18,2));
   return $width*$height;
}

sub largest_mapped_descendant {
   my($fh,$root)=@_;
   my($best,$best_area);
   my @pending=query_tree($fh,$root);
   while (@pending) {
      my $window=shift @pending;
      if (is_viewable($fh,$window)) {
         my $area=geometry_area($fh,$window);
         ($best,$best_area)=($window,$area)
            if !defined($best) || $area>$best_area;
      }
      push @pending,eval { query_tree($fh,$window) };
   }
   return $best;
}

sub find_executable {
   my($name)=@_;
   return $name if $name =~ m{/} && -x $name;
   for my $dir (split(/:/,$ENV{PATH} // '')) {
      my $path="$dir/$name";
      return $path if -x $path;
   }
   return undef;
}

sub function_keycode {
   my($key)=@_;
   $key =~ /^F(\d{1,2})$/ or die "unsupported function key '$key'\n";
   my $symbol=sprintf('FK%02d',$1);
   my $xkbcomp=find_executable('xkbcomp')
      or die "xkbcomp is required to discover the $key keycode\n";
   my $display=$ENV{DISPLAY} // die "DISPLAY is not set\n";
   open(my $fh,'-|',$xkbcomp,$display,'-')
      or die "run xkbcomp: $!\n";
   my $keycode;
   while (my $line=<$fh>) {
      $keycode=$1 if $line =~ /<\Q$symbol\E>\s*=\s*(\d+)\s*;/;
   }
   close($fh) or die "xkbcomp failed while reading the X11 keymap\n";
   defined($keycode) or die "X11 keyboard mapping has no $key key\n";
   return $keycode;
}

sub key_event {
   my($type,$keycode,$root,$window)=@_;
   return pack('CCvVVVVssssvCC',
      $type,$keycode,0,0,$root,$window,0,
      1,1,1,1,0,1,0);
}

my $reset=0;
my $fast=0;
my $every_frame=0;
my $reset_sequence=0;
my $duration=1.00;
my $snapshot_dir;
my $snapshot_count;
my $snapshot_timeout=30.0;
while (@ARGV) {
   my $arg=shift @ARGV;
   if ($arg eq '--reset') { $reset=1; }
   elsif ($arg eq '--fast') { $fast=1; }
   elsif ($arg eq '--every-frame') { $every_frame=1; }
   elsif ($arg eq '--reset-sequence') { $reset_sequence=1; }
   elsif ($arg eq '--duration') {
      @ARGV or die "--duration requires seconds\n";
      $duration=shift @ARGV;
      $duration =~ /^\d+(?:\.\d+)?$/ && $duration > 0
         or die "invalid --duration '$duration'\n";
   }
   elsif ($arg eq '--snapshot-dir') {
      @ARGV or die "--snapshot-dir requires a directory\n";
      $snapshot_dir=shift @ARGV;
   }
   elsif ($arg eq '--snapshot-count') {
      @ARGV or die "--snapshot-count requires a positive integer\n";
      $snapshot_count=shift @ARGV;
      $snapshot_count =~ /^\d+$/ && $snapshot_count > 0
         or die "invalid --snapshot-count '$snapshot_count'\n";
   }
   elsif ($arg eq '--snapshot-timeout') {
      @ARGV or die "--snapshot-timeout requires seconds\n";
      $snapshot_timeout=shift @ARGV;
      $snapshot_timeout =~ /^\d+(?:\.\d+)?$/ && $snapshot_timeout > 0
         or die "invalid --snapshot-timeout '$snapshot_timeout'\n";
   }
   else { die "usage: $0 [--reset] [--fast] [--every-frame] [--reset-sequence] [--duration seconds | --snapshot-dir DIR --snapshot-count N [--snapshot-timeout seconds]]\n"; }
}

$reset_sequence && !$every_frame and die "--reset-sequence requires --every-frame\n";
(defined($snapshot_dir) xor defined($snapshot_count))
   and die "--snapshot-dir and --snapshot-count must be used together\n";
defined($snapshot_count) && !$every_frame
   and die "--snapshot-count requires --every-frame\n";
my($x,$root)=x_connect();
my $window;
for (1..100) {
   $window=largest_mapped_descendant($x,$root);
   last if defined($window);
   sleep(0.05);
}
defined($window) or die "no mapped Stella window appeared\n";
# The heart raster test owns a fresh stock Xvfb; --fast avoids spawning
# xkbcomp for every capture by using its standard F2/F12 core keycodes.
my $f12=$fast ? 96 : function_keycode('F12');
my $f2=$reset ? ($fast ? 68 : function_keycode('F2')) : undef;

sub x_test_opcode {
   my($fh)=@_;
   my $name='XTEST';
   my $reply=send_request($fh,98,0,pack('vCC',length($name),0,0).$name,1);
   ord(substr($reply,8,1)) or die "XTEST extension is unavailable\n";
   return ord(substr($reply,9,1));
}

sub x_test_key {
   my($fh,$opcode,$type,$keycode,$root_window)=@_;
   my $body=pack('CCvVVVVssVvCC',
      $type,$keycode,0,0,$root_window,0,0,0,0,0,0,0,0);
   send_request($fh,$opcode,2,$body,0);
}

sub toggle_every_frame_snapshots {
   my($fh,$root_window)=@_;
   $fast or die "--every-frame currently requires --fast on the private stock Xvfb display\n";
   my $xtest=x_test_opcode($fh);
   # Stock Xvfb keycodes: left Shift=50, left Control=37, left Alt=64, S=39.
   # Stella binds Shift-Control-Alt-S to one PNG snapshot after every complete
   # emulated frame.  XTEST is required here because SendEvent does not update
   # the server modifier state that Stella/SDL observes for this chord.
   for my $pair ([2,50],[2,37],[2,64],[2,39],[3,39],[3,64],[3,37],[3,50]) {
      x_test_key($fh,$xtest,$pair->[0],$pair->[1],$root_window);
      sleep(0.01);
   }
}

# SetInputFocus: RevertToParent=2, CurrentTime=0.
send_request($x,42,2,pack('VV',$window,0),0);
# Complete-matrix bank diagnostics can execute for several video frames
# before settling on their PASS/FAIL display, especially in F4/F4SC.
sleep($fast ? 0.10 : 1.00);
if ($every_frame) {
   if ($reset_sequence) {
      # Pause first so capture can be armed before a deterministic console-reset
      # release.  Keep F2 physically down while resuming for several frames,
      # then release it and record the resulting complete-frame sequence.
      my $xtest=x_test_opcode($x);
      x_test_key($x,$xtest,2,127,$root); # Pause down
      x_test_key($x,$xtest,3,127,$root); # Pause up
      sleep(0.10);
      toggle_every_frame_snapshots($x,$root);
      x_test_key($x,$xtest,2,68,$root);  # F2/reset down
      x_test_key($x,$xtest,2,127,$root); # resume
      x_test_key($x,$xtest,3,127,$root);
      sleep(0.10);
      x_test_key($x,$xtest,3,68,$root);  # release reset
   } else {
      toggle_every_frame_snapshots($x,$root);
   }
   if (defined($snapshot_count)) {
      my $deadline=time()+$snapshot_timeout;
      while (1) {
         my @png=grep { -s $_ } glob("$snapshot_dir/*.png");
         last if @png >= $snapshot_count;
         time() < $deadline
            or die "timed out waiting for $snapshot_count complete-frame snapshots in $snapshot_dir; got ".scalar(@png)."\n";
         sleep(0.02);
      }
   }
   else {
      sleep($duration);
   }
   toggle_every_frame_snapshots($x,$root);
   sleep(0.20);
   exit 0;
}
if ($reset) {
   for my $type (2,3) { # KeyPress, KeyRelease
      my $event=key_event($type,$f2,$root,$window);
      send_request($x,25,1,pack('VV',$window,0).$event,0);
   }
   # Superchip diagnostics poison their RAM after the first result frame.  The
   # second PASS/FAIL frame therefore certifies startup reinitialization after
   # Stella's real console-reset path.
   # Stella may expose one or more partial frames while a reset asserted from a
   # randomized physical bank traverses the vector bridge and the diagnostic
   # rebuilds its status frame. Wait well beyond that transient before F12.
   sleep(2.00);
}
for my $type (2,3) { # KeyPress, KeyRelease
   my $event=key_event($type,$f12,$root,$window);
   send_request($x,25,1,pack('VV',$window,0).$event,0);
}
sleep($fast ? 0.15 : 0.35);
