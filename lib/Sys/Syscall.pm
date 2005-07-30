# LICENSE: You're free to distribute this under the same terms as Perl itself.

package Sys::Syscall;
use strict;
use POSIX qw(ENOSYS);

require Exporter;
use vars qw(@ISA @EXPORT_OK %EXPORT_TAGS $VERSION);

$VERSION     = "0.1";
@ISA         = qw(Exporter);
@EXPORT_OK   = qw(sendfile epoll_ctl epoll_create epoll_wait EPOLLIN EPOLLOUT EPOLLERR EPOLLHUP
                  EPOLL_CTL_ADD EPOLL_CTL_DEL EPOLL_CTL_MOD);
%EXPORT_TAGS = (epoll => [qw(epoll_ctl epoll_create epoll_wait EPOLLIN EPOLLOUT EPOLLERR EPOLLHUP
                             EPOLL_CTL_ADD EPOLL_CTL_DEL EPOLL_CTL_MOD)],
                sendfile => [qw(sendfile)],
                );

use constant EPOLLIN       => 1;
use constant EPOLLOUT      => 4;
use constant EPOLLERR      => 8;
use constant EPOLLHUP      => 16;
use constant EPOLL_CTL_ADD => 1;
use constant EPOLL_CTL_DEL => 2;
use constant EPOLL_CTL_MOD => 3;

our $loaded_syscall = 0;

sub _load_syscall {
    return if $loaded_syscall++;
    my $clean = sub {
        delete @INC{qw<syscall.ph asm/unistd.ph bits/syscall.ph
                        _h2ph_pre.ph sys/syscall.ph>};
    };
    $clean->(); # don't trust modules before us
    my $rv = eval { require 'syscall.ph'; 1 } || eval { require 'sys/syscall.ph'; 1 };
    $clean->(); # don't require modules after us trust us
    return $rv;
}

our ($sysname, $nodename, $release, $version, $machine) = POSIX::uname();

our (
     $SYS_epoll_create,
     $SYS_epoll_ctl,
     $SYS_epoll_wait,
     $SYS_sendfile,
     $SYS_readahead,
     );

if ($^O eq "linux") {
    # whether the machine requires 64-bit numbers to be on 8-byte
    # boundaries.
    my $u64_mod_8 = 0;

    if ($machine =~ m/^i[3456]86$/) {
        $SYS_epoll_create = 254;
        $SYS_epoll_ctl    = 255;
        $SYS_epoll_wait   = 256;
        $SYS_sendfile     = 187;  # or 64: 239
        $SYS_readahead    = 225;
    } elsif ($machine eq "x86_64") {
        $SYS_epoll_create = 213;
        $SYS_epoll_ctl    = 233;
        $SYS_epoll_wait   = 232;
        $SYS_sendfile     = 187;  # or 64: 239
        $SYS_readahead    = 225;
    } elsif ($machine eq "ppc64") {
        $SYS_epoll_create = 236;
        $SYS_epoll_ctl    = 237;
        $SYS_epoll_wait   = 238;
        $SYS_sendfile     = 186;  # (sys32_sendfile).  sys32_sendfile64=226  (64 bit processes: sys_sendfile64=186)
        $SYS_readahead    = 191;  # both 32-bit and 64-bit vesions
        $u64_mod_8        = 1;
    } elsif ($machine eq "ppc") {
        $SYS_epoll_create = 236;
        $SYS_epoll_ctl    = 237;
        $SYS_epoll_wait   = 238;
        $SYS_sendfile     = 186;  # sys_sendfile64=226
        $SYS_readahead    = 191;
        $u64_mod_8        = 1;
    } elsif ($machine eq "ia64") {
        $SYS_epoll_create = 1243;
        $SYS_epoll_ctl    = 1244;
        $SYS_epoll_wait   = 1245;
        $SYS_sendfile     = 1187;
        $SYS_readahead    = 1216;
        $u64_mod_8        = 1;
    } elsif ($machine eq "alpha") {
        # natural alignment, ints are 32-bits
        $SYS_sendfile     = 370;  # (sys_sendfile64)
        $SYS_epoll_create = 407;
        $SYS_epoll_ctl    = 408;
        $SYS_epoll_wait   = 409;
        $SYS_readahead    = 379;
        $u64_mod_8        = 1;
    } else {
        # as a last resort, try using the *.ph files which may not
        # exist or may be wrong
        _load_syscall();
        $SYS_epoll_create = eval { &SYS_epoll_create; } || 0;
        $SYS_epoll_ctl    = eval { &SYS_epoll_ctl;    } || 0;
        $SYS_epoll_wait   = eval { &SYS_epoll_wait;   } || 0;
        $SYS_readahead    = eval { &SYS_readahead;    } || 0;
    }

    if ($u64_mod_8) {
        *epoll_wait = \&epoll_wait_mod8;
        *epoll_ctl = \&epoll_ctl_mod8;
    } else {
        *epoll_wait = \&epoll_wait_mod4;
        *epoll_ctl = \&epoll_ctl_mod4;
    }
}

############################################################################
# sendfile functions
############################################################################

unless ($SYS_sendfile) {
    _load_syscall();
    $SYS_sendfile = eval { &SYS_sendfile; } || 0;
}

sub sendfile_defined { return $SYS_sendfile ? 1 : 0; }

# C: ssize_t sendfile(int out_fd, int in_fd, off_t *offset, size_t count)
# Perl:  sendfile($write_fd, $read_fd, $max_count) --> $actually_sent
sub sendfile {
    unless ($SYS_sendfile) {
        $! = ENOSYS;
        return -1;
    }
    return syscall(
                   $SYS_sendfile,
                   $_[0] + 0,  # fd
                   $_[1] + 0,  # fd
                   0,          # don't keep track of offset.  callers can lseek and keep track.
                   $_[2] + 0   # count
                   );
}

############################################################################
# epoll functions
############################################################################

sub epoll_defined { return $SYS_epoll_create ? 1 : 0; }

# ARGS: (size) -- but in modern Linux 2.6, the
# size doesn't even matter (radix tree now, not hash)
sub epoll_create {
    return -1 unless defined $SYS_epoll_create;
    my $epfd = eval { syscall($SYS_epoll_create, ($_[0]||100)+0) };
    return -1 if $@;
    return $epfd;
}

# epoll_ctl wrapper
# ARGS: (epfd, op, fd, events_mask)
sub epoll_ctl_mod4 {
    syscall($SYS_epoll_ctl, $_[0]+0, $_[1]+0, $_[2]+0, pack("LLL", $_[3], $_[2], 0));
}
sub epoll_ctl_mod8 {
    syscall($SYS_epoll_ctl, $_[0]+0, $_[1]+0, $_[2]+0, pack("LLLL", $_[3], 0, $_[2], 0));
}

# epoll_wait wrapper
# ARGS: (epfd, maxevents, timeout (milliseconds), arrayref)
#  arrayref: values modified to be [$fd, $event]
our $epoll_wait_events;
our $epoll_wait_size = 0;
sub epoll_wait_mod4 {
    # resize our static buffer if requested size is bigger than we've ever done
    if ($_[1] > $epoll_wait_size) {
        $epoll_wait_size = $_[1];
        $epoll_wait_events = "\0" x 12 x $epoll_wait_size;
    }
    my $ct = syscall($SYS_epoll_wait, $_[0]+0, $epoll_wait_events, $_[1]+0, $_[2]+0);
    for ($_ = 0; $_ < $ct; $_++) {
        @{$_[3]->[$_]}[1,0] = unpack("LL", substr($epoll_wait_events, 12*$_, 8));
    }
    return $ct;
}

sub epoll_wait_mod8 {
    # resize our static buffer if requested size is bigger than we've ever done
    if ($_[1] > $epoll_wait_size) {
        $epoll_wait_size = $_[1];
        $epoll_wait_events = "\0" x 16 x $epoll_wait_size;
    }
    my $ct = syscall($SYS_epoll_wait, $_[0]+0, $epoll_wait_events, $_[1]+0, $_[2]+0);
    for ($_ = 0; $_ < $ct; $_++) {
        # 16 byte epoll_event structs, with format:
        #    4 byte mask [idx 1]
        #    4 byte padding (we put it into idx 2, useless)
        #    8 byte data (first 4 bytes are fd, into idx 0)
        @{$_[3]->[$_]}[1,2,0] = unpack("LLL", substr($epoll_wait_events, 16*$_, 12));
    }
    return $ct;
}


1;
__END__

=head1 NAME

Sys::Syscall - access system calls that Perl doesn't normally provide access to

=head1 SYNOPSIS

  use Sys::Syscall;

=head1 DESCRIPTION

Use epoll, sendfile, from Perl.  Future: more.

=head1 COPYRIGHT

This module is Copyright (c) 2005 Six Apart, Ltd.

All rights reserved.

You may distribute under the terms of either the GNU General Public
License or the Artistic License, as specified in the Perl README file.
If you need more liberal licensing terms, please contact the
maintainer.

=head1 WARRANTY

This is free software. IT COMES WITHOUT WARRANTY OF ANY KIND.

=head1 AUTHORS

Brad Fitzpatrick <brad@danga.com>

