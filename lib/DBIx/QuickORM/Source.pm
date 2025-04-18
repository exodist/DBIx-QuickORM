package DBIx::QuickORM::Source;
use strict;
use warnings;
use feature qw/state/;

use Carp qw/confess/;
use Sub::Util qw/set_subname/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Util::HashBase qw{
    <connection
    <sqla_source
};

sub init {
    my $self = shift;

    my $con = $self->connection or confess "'connection' is a required attribute";
    confess "Connection '$con' is not an instance of 'DBIx::QuickORM::Connection'"
        unless blessed($con) && $con->isa('DBIx::QuickORM::Connection');

    my $sqla_source = $self->sqla_source or confess "'sqla_source' is a required attribute";
    confess "Source '$sqla_source' does not implement the role 'DBIx::QuickORM::Role::SQLASource'"
        unless blessed($sqla_source) && $sqla_source->DOES('DBIx::QuickORM::Role::SQLASource');
}

BEGIN {
    my @METHODS = qw{
        all      data_all
        iterator data_iterator
        iterate  data_iterate
        any      data_any
        first    data_first
        one      data_one

        by_id
        by_ids
        insert
        vivify
        search
        count
        delete
        update
        find_or_insert
        update_or_insert

        select
        async
        aside
        forked
    };

    for my $meth (@METHODS) {
        my $name = $meth;
        no strict 'refs';
        *$name = set_subname $name => sub { my $self = shift; $self->{+CONNECTION}->$name($self->{+SQLA_SOURCE}, @_) };
    }
}

1;
