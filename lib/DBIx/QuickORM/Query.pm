package DBIx::QuickORM::Query;
use strict;
use warnings;

use Carp qw/croak/;

use DBIx::QuickORM::Util::HashBase qw{
    sqla_source
    row
    where
    order_by
    limit
    fields
    omit
    async
    aside
    forked
};

use Role::Tiny::With qw/with/;
with 'DBIx::QuickORM::Role::Query';

sub init {
    my $self = shift;
    $self->normalize_query;
}

1;
