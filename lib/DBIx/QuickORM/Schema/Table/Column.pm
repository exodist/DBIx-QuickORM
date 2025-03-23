package DBIx::QuickORM::Schema::Table::Column;
use strict;
use warnings;

our $VERSION = '0.000005';

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Affinity qw{
    validate_affinity
    affinity_from_type
};

use DBIx::QuickORM::Util::HashBase qw{
    <name
    <sql_default
    <perl_default
    <omit
    <order
    <nullable
    <identity
    +affinity
    <type
    <created
    <compiled
};

sub init {
    my $self = shift;

    my $debug = $self->{+CREATED} ? " (defined in $self->{+CREATED})" : "";

    croak "A 'name' is a required${debug}"           unless $self->{+NAME};
    croak "Column must have an order number${debug}" unless $self->{+ORDER};

    if (my $type = $self->{+TYPE}) {
        if (ref($type) eq 'SCALAR') {
            $self->{+AFFINITY} //= affinity_from_type($$type);

            croak "'affinity' was not provided, and could not be derived from type '$$type'${debug}"
                unless $self->{+AFFINITY};

            croak "'$self->{+AFFINITY}' is not a valid affinity${debug}"
                unless validate_affinity($self->{+AFFINITY});
        }
    }
}

sub affinity {
    my $self = shift;
    return $self->{+AFFINITY} if $self->{+AFFINITY};

    my $debug = $self->{+CREATED} ? " (defined in $self->{+CREATED})" : "";
    my $type = $self->{+TYPE} or croak "No affinity specified, and no type provided${debug}";

    croak "'$type' is not a valid type${debug}" unless blessed($type) && $type->isa('DBIx::QuickORM::Type');

    return $self->{+AFFINITY} = $type->affinity($self, @_);
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
