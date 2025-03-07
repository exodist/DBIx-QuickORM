package DBIx::QuickORM::Table::Column;
use strict;
use warnings;

our $VERSION = '0.000005';

use Carp qw/croak confess/;

use DBIx::QuickORM::Util::Affinity qw{
    validate_affinity
    affinity_from_type
};

use DBIx::QuickORM::Util::HashBase qw{
    <conflate
    <sql_default
    <perl_default
    <name
    <db_name
    <omit
    <order
    <nullable
    <identity
    <sql_type
    <affinity
    <created
};

sub init {
    my $self = shift;

    $self->{+NAME} //= $self->{+DB_NAME};
    $self->{+DB_NAME} //= $self->{+NAME};

    croak "At least one of the 'name' or 'db_name' fields are required" unless $self->{+NAME} && $self->{+DB_NAME};
    croak "Column must have an order number"                            unless $self->{+ORDER};

    if (my $type = $self->{+SQL_TYPE}) {
        $self->{+AFFINITY} //= affinity_from_type($type);
    }

    croak "'affinity' was not provided, and could not be derived from sql_type"
        unless $self->{+AFFINITY};

    croak "'$self->{+AFFINITY}' is not a valid affinity"
        unless validate_affinity($self->{+AFFINITY});

    if (my $conflate = $self->{+CONFLATE}) {
        if (ref($conflate) eq 'HASH') { # unblessed hash
            confess "No inflate callback was provided for conflation" unless $conflate->{inflate};
            confess "No deflate callback was provided for conflation" unless $conflate->{deflate};

            require DBIx::QuickORM::Conflator;
            $self->{+CONFLATE} = DBIx::QuickORM::Conflator->new(%$conflate);
        }
    }
}

sub merge {
    my $self = shift;
    my ($other, %params) = @_;

    return ref($self)->new(%$self, %params);
}

sub clone {
    my $self   = shift;
    my %params = @_;

    return ref($self)->new(%$self, %params);
}

1;
