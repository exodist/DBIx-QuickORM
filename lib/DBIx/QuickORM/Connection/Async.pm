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

    +dialect
    +ready
    +fetched
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

    delete $self->{+FETCHED};
}

sub ready { $_[0]->{+READY} ||= $_[0]->dialect->async_ready($_[0]) }

sub cancel {
    my $self = shift;

    return if $self->{+DONE};

    $self->dialect->async_cancel($self);

    $self->{+CONNECTION}->clear_async($self);
    $self->{+DONE} = 1;
}

sub fetch {
    my $self = shift;

    return $self->{+FETCHED} if exists $self->{+FETCHED};

    $self->dialect->async_result($self);
    $self->{+FETCHED} = $self->sth->fetchall_arrayref({});

    $self->{+CONNECTION}->clear_async($self);
    $self->{+DONE} = 1;

    return $self->{+FETCHED};
}

sub DESTROY {
    my $self = shift;

    return if $self->{+DONE};

    if ($self->dialect->async_cancel_supported) {
        $self->cancel;
    }
    else {
        sleep 0.1 until $self->ready;
        $self->dialect->async_result($self);
    }

    $self->{+DONE} = 1;
}

1;
