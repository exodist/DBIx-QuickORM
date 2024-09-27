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

    croak "The 'name' field is required"     unless $self->{+NAME};
    croak "Column must have an order number" unless $self->{+ORDER};
}

sub merge {
    my $self = shift;
    my ($other, %params) = @_;

    $params{+SQL_SPEC} //= $self->{+SQL_SPEC}->merge($other->{+SQL_SPEC});
    $params{+PLUGINS}  //= $self->{+PLUGINS}->merge($other->{+PLUGINS});

    return ref($self)->new(%$self, %params);
}

sub clone {
    my $self   = shift;
    my %params = @_;

    $params{+SQL_SPEC} //= $self->{+SQL_SPEC}->clone();
    $params{+PLUGINS}  //= $self->{+PLUGINS}->clone();

    return ref($self)->new(%$self, %params);
}

1;
