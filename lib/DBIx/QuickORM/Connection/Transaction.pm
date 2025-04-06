package DBIx::QuickORM::Connection::Transaction;
use strict;
use warnings;

use Carp qw/croak/;

use DBIx::QuickORM::Util::HashBase qw{
    on_success
    on_fail
    on_completion
    <result
    started
    savepoint
    pid
    id
};

sub init {
    my $self = shift;

    croak "" unless $self->{+ID};
}

1;
