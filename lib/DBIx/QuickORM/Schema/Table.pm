package DBIx::QuickORM::Schema::Table;
use strict;
use warnings;

our $VERSION = '0.000005';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use DBIx::QuickORM::Util qw/column_key/;

use DBIx::QuickORM::Util::HashBase qw{
    <name
    +columns
    <unique
    <primary_key
    <row_class
    <accessors
    <created
    <compiled
    <is_temp
    +_links
    +links
    <links_by_alias
    <indexes
};

sub is_view { 0 }

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

    $self->{+UNIQUE} //= {};
    $self->{+LINKS} //= {};
    $self->{+LINKS_BY_ALIAS} //= {};
    $self->{+INDEXES} //= [];
}

sub _links { delete $_[0]->{+_LINKS} }

sub links_by_table { $_[0]->{+LINKS} }

sub links {
    my $self = shift;
    my ($table) = @_;

    my @tables = $table ? ($table) : keys %{ $self->{+LINKS} };

    return map { values %{ $self->{+LINKS}->{$_} // {}} } @tables;
}

sub link {
    my $self = shift;
    my %params = @_;

    if (my $table = $params{table}) {
        my $links = $self->{+LINKS}->{$table} or return undef;

        if (my $cols = $params{columns} // $params{cols}) {
            my $key = column_key(@$cols);
            return $links->{$key} // undef;
        }

        for my $key (sort keys %$links) {
            return $links->{$key} // undef;
        }

        return undef;
    }
    elsif (my $alias = $params{name}) {
        return $self->{+LINKS_BY_ALIAS}->{$alias} // undef;
    }

    croak "Need a link name or table";
}

sub columns { values %{$_[0]->{+COLUMNS}} }
sub column_names { keys %{$_[0]->{+COLUMNS}} }

sub column {
    my $self = shift;
    my ($cname, $row) = @_;

    return $self->{+COLUMNS}->{$cname} // undef;
}

1;
