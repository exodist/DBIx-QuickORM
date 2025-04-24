package DBIx::QuickORM::Connection::Async;
use strict;
use warnings;

use Carp qw/croak/;
use Time::HiRes qw/sleep/;

use DBIx::QuickORM::Util::HashBase qw{
    <connection
    <dbh
    <sth
    <sqla_source

    only_one

    +dialect
    +ready
    +got_result
    <done
};

sub dialect { $_[0]->{+DIALECT} //= $_[0]->{+CONNECTION}->dialect }

sub init {
    my $self = shift;

    croak "'connection' is a required attribute" unless $self->{+CONNECTION};
    croak "'sqla_source' us a required attribute" unless $self->{+SQLA_SOURCE};

    # Fix this for non dbh/sth ones like aside and forked
    croak "'sth' and 'dbh' are required attributes"
        unless $self->{+DBH} && $self->{+STH};
}

sub ready { $_[0]->{+READY} ||= $_[0]->dialect->async_ready($_[0]) }

sub cancel {
    my $self = shift;

    return if $self->{+DONE};

    $self->dialect->async_cancel($self);

    $self->{+CONNECTION}->clear_async($self);
    $self->{+DONE} = 1;
}

sub next {
    my $self = shift;
    my $row = $self->_next;

    if ($self->{+ONLY_ONE}) {
        croak "Expected only 1 row, but got more than one" if $self->_next;
        $self->set_done;
    }

    return $row;
}

sub _next {
    my $self = shift;

    return if $self->{+DONE};

    $self->{+GOT_RESULT} //= $self->dialect->async_result($self);

    my $row = $self->sth->fetchrow_hashref();

    return $row if $row;

    $self->set_done;

    return;
}

sub set_done {
    my $self = shift;

    return if $self->{+DONE};

    $self->{+CONNECTION}->clear_async($self);
    $self->{+DONE} = 1;
}

sub DESTROY {
    my $self = shift;

    return if $self->{+DONE};

    unless ($self->{+GOT_RESULT}) {
        if ($self->dialect->async_cancel_supported) {
            $self->cancel;
        }
        else {
            sleep 0.1 until $self->ready;
            $self->dialect->async_result($self);
        }
    }

    $self->{+DONE} = 1;
}

1;
