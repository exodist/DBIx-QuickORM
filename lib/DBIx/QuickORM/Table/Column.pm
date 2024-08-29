package DBIx::QuickORM::Table::Column;
use strict;
use warnings;

use Carp qw/croak/;

use DBIx::QuickORM::Util::Has qw/Plugins Created SQLSpec/;

use DBIx::QuickORM::Util::HashBase qw{
    <conflate
    <default
    <name
    <omit
    <primary_key
    <unique
    <order
    <nullable
    <serial
};



sub init {
    my $self = shift;

    croak "The 'name' field is required" unless $self->{+NAME};
    croak "Column must have an order number" unless $self->{+ORDER};
}

1;
