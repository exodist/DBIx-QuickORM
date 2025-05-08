package DBIx::QuickORM::Source;
use strict;
use warnings;
use feature qw/state/;

use Carp qw/confess/;
use Sub::Util qw/set_subname/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Util::HashBase qw{
    <connection
    <query_source
};

sub init {
    my $self = shift;

    my $con = $self->connection or confess "'connection' is a required attribute";
    confess "Connection '$con' is not an instance of 'DBIx::QuickORM::Connection'"
        unless blessed($con) && $con->isa('DBIx::QuickORM::Connection');

    my $query_source = $self->query_source or confess "'query_source' is a required attribute";
    confess "Source '$query_source' does not implement the role 'DBIx::QuickORM::Role::QuerySource'"
        unless blessed($query_source) && $query_source->DOES('DBIx::QuickORM::Role::QuerySource');
}

BEGIN {
    my @METHODS = qw{
        all
        iterator
        iterate
        any
        first
        one

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
        query
        async
        aside
        forked
    };

    for my $meth (@METHODS) {
        my $name = $meth;
        no strict 'refs';
        *$name = set_subname $name => sub { my $self = shift; $self->{+CONNECTION}->$name($self->{+QUERY_SOURCE}, @_) };
    }
}

1;
