package DBIx::QuickORM::STH::Fork;
use strict;
use warnings;

our $VERSION = '0.000020';

use Role::Tiny::With qw/with/;
with 'DBIx::QuickORM::Role::STH';
with 'DBIx::QuickORM::Role::Async';

use Carp qw/croak/;
use POSIX qw/WNOHANG/;
use Time::HiRes qw/sleep/;
use Cpanel::JSON::XS qw/decode_json/;

use DBIx::QuickORM::Util::HashBase qw{
    <connection
    <source

    only_one

    +dialect
    +ready
    <got_result
    <done
    <pid
    <pipe
};

sub cancel_supported { 1 }

sub dialect { $_[0]->{+DIALECT} //= $_[0]->{+CONNECTION}->dialect }
sub clear   { $_[0]->{+CONNECTION}->clear_fork($_[0]) }

sub init {
    my $self = shift;

    croak "'pid' is a required attribute"         unless $self->{+PID};
    croak "'pipe' is a required attribute"        unless $self->{+PIPE};
    croak "'connection' is a required attribute"  unless $self->{+CONNECTION};
    croak "'source' is a required attribute" unless $self->{+SOURCE};
}

sub ready {
    my $self = shift;
    return 1 if $self->{+READY};
    return 1 if exists $self->{+GOT_RESULT};

    my $msg = $self->_read_message(0);    # non-blocking peek for the result message
    return 0 unless defined $msg;

    $self->{+GOT_RESULT} = $self->_decode_result($msg);
    return $self->{+READY} = 1;
}

sub result {
    my $self = shift;
    return $self->{+GOT_RESULT} if exists $self->{+GOT_RESULT};

    my $msg = $self->_read_message(1);    # blocking
    $self->{+READY} //= 1;
    return $self->{+GOT_RESULT} = $self->_decode_result($msg);
}

sub cancel {
    my $self = shift;

    return if $self->{+DONE};

    delete $self->{+PIPE};

    if (waitpid($self->{+PID}, WNOHANG) <= 0) {
        kill('TERM', $self->{+PID});
        waitpid($self->{+PID}, 0);
    }

    $self->clear;
    $self->{+DONE} = 1;
}

sub next {
    my $self = shift;
    my $row = $self->_next;

    if ($self->{+ONLY_ONE}) {
        # Finalize before throwing so the child is reaped and the connection's
        # fork slot is released even on the error path.
        if ($self->_next) {
            $self->set_done;
            croak "Expected only 1 row, but got more than one";
        }
        $self->set_done;
    }

    return $row;
}

sub _next {
    my $self = shift;

    return if $self->{+DONE};

    $self->result unless exists $self->{+GOT_RESULT};

    my $msg = $self->_read_message(1);    # blocking
    if (defined $msg) {
        my $row = decode_json($msg);
        return $row if $row;
    }

    $self->set_done;

    return;
}

sub _read_message {
    my $self = shift;
    my ($blocking) = @_;

    my $pipe = $self->{+PIPE} or return undef;
    $pipe->read_blocking($blocking ? 1 : 0);
    return $pipe->read_message;
}

sub _decode_result {
    my $self = shift;
    my ($msg) = @_;

    my $data = defined($msg) ? decode_json($msg) : undef;
    return $data->{result} if $data && exists $data->{result};

    croak "Got invalid data from pipe: " . (defined($msg) ? $msg : '<eof>');
}

sub set_done {
    my $self = shift;

    return if $self->{+DONE};

    delete $self->{+PIPE};
    waitpid($self->{+PID}, 0) if $self->{+PID};
    $self->clear;
    $self->{+DONE} = 1;
}

1;
