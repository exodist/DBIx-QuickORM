package DBIx::QuickORM::Connection::Async;
use strict;
use warnings;

use Role::Tiny::With qw/with/;
with 'DBIx::QuickORM::Role::Async';

use Carp qw/croak/;
use Time::HiRes qw/sleep/;

use DBIx::QuickORM::Util::HashBase qw{
    <connection
    <dbh
    <sth
    <query_source

    only_one

    +dialect
    +ready
    <got_result
    <done
};

sub dialect { $_[0]->{+DIALECT}    //= $_[0]->{+CONNECTION}->dialect }
sub result  { $_[0]->{+GOT_RESULT} //= $_[0]->dialect->async_result($_[0]) }
sub ready   { $_[0]->{+READY} ||= $_[0]->dialect->async_ready($_[0]) }

sub cancel_supported { $_[0]->dialect->async_cancel_supported }

sub clear { $_[0]->{+CONNECTION}->clear_async($_[0]) }

sub init {
    my $self = shift;

    croak "'connection' is a required attribute" unless $self->{+CONNECTION};
    croak "'query_source' is a required attribute" unless $self->{+QUERY_SOURCE};

    # Fix this for non dbh/sth ones like aside and forked
    croak "'sth' and 'dbh' are required attributes"
        unless $self->{+DBH} && $self->{+STH};
}

sub cancel {
    my $self = shift;

    return if $self->{+DONE};

    $self->dialect->async_cancel($self);

    $self->clear;
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

    $self->result;

    my $row = $self->sth->fetchrow_hashref();

    return $row if $row;

    $self->set_done;

    return;
}

sub set_done {
    my $self = shift;

    return if $self->{+DONE};

    $self->clear;
    $self->{+DONE} = 1;
}

1;
