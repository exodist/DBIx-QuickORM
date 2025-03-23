package DBIx::QuickORM::Schema::Table;
use strict;
use warnings;

our $VERSION = '0.000005';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Util::HashBase qw{
    <name
    <columns
    <unique
    <primary_key
    <row_class
    <accessors
    <created
    <compiled
};

sub init {
    my $self = shift;

    croak "The 'name' attribute is required" unless $self->{+NAME};

    my $debug = $self->{+CREATED} ? " (defined in $self->{+CREATED})" : "";

    my $cols = $self->{+COLUMNS} //= {};
    croak "The 'columns' attribute must be a hashref${debug}" unless ref($cols) eq 'HASH';

    for my $cname (sort keys %$cols) {
        my $cval = $cols->{$cname} or croak "Column '$cname' is empty${debug}";
        croak "Columns '$cname' is not an instance of 'DBIx::QuickORM::Schema::Table::Column', got: '$cval'$debug" unless blessed($cval) && $cval->isa('DBIx::QuickORM::Schema::Table::Column');
    }
}

sub column_names { keys %{$_[0]->{+COLUMNS}} }

sub column {
    my $self = shift;
    my ($cname, $row) = @_;

    return $self->{+COLUMNS}->{$cname} // undef;
}

1;
