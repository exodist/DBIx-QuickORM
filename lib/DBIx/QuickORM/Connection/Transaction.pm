package DBIx::QuickORM::Connection::Transaction;
use strict;
use warnings;

use Scalar::Util qw/weaken/;

use DBIx::QuickORM::Util::HashBase qw{
    on_success
    on_fail
    on_completion
    <result
    started
    savepoint
    pid
    connection
    id
};

sub init {
    my $self = shift;

    croak "" unless $self->{+ID};

    weaken($self->{+CONNECTION});
}

1;
