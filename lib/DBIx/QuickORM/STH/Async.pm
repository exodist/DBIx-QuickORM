package DBIx::QuickORM::STH::Async;
use strict;
use warnings;

use Role::Tiny::With qw/with/;
with 'DBIx::QuickORM::Role::STH';
with 'DBIx::QuickORM::Role::Async';

use Carp qw/croak/;
use Time::HiRes qw/sleep/;

use parent 'DBIx::QuickORM::STH';
use DBIx::QuickORM::Util::HashBase qw{
    <got_result
};

sub cancel_supported { $_[0]->dialect->async_cancel_supported }

sub clear { $_[0]->{+CONNECTION}->clear_async($_[0]) }

sub cancel {
    my $self = shift;

    return if $self->{+DONE};

    $self->dialect->async_cancel($self);

    $self->clear;
    $self->set_done;
    $self->{+DONE} = 1;
}

sub result {
    my $self = shift;
    return $self->{+GOT_RESULT} //= $self->dialect->async_result(sth => $self->{+STH}, dbh => $self->{+DBH});
}

sub ready {
    my $self = shift;
    return $self->{+READY} ||= $self->dialect->async_ready(dbh => $self->{+DBH}, sth => $self->{+STH});
}

1;
