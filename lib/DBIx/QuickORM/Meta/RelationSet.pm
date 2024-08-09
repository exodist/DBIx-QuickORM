package DBIx::QuickORM::Meta::RelationSet;
use strict;
use warnings;

use Carp qw/confess/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::HashBase qw{
    <by_index
    <by_table_and_name
    <by_ref
};

sub init {
    my $self = shift;

    $self->{+BY_INDEX}          //= {};
    $self->{+BY_TABLE_AND_NAME} //= {};
}

sub relation {
    my $self = shift;
    my ($table, $name) = @_;

    return $self->{+BY_TABLE_AND_NAME}->{$table}->{$name};
}

sub has_equivelent {
    my $self = shift;
    my ($rel) = @_;

    return $self->{+BY_INDEX}->{$rel->index} ? 1 : 0;
}

sub add_relation {
    my $self = shift;
    my ($rel) = @_;

    my $index = $rel->index;

    my $missing = 0;
    for my $m (@{$rel->members}) {
        my $table = $m->{table};
        my $name  = $m->{name};

        if (my $x = $self->{+BY_TABLE_AND_NAME}->{$table}->{$name}) {
            # If this is true then they are duplicates
            next if $x->index eq $index;

            confess "Table '$table' already has a relation named '$name'";
        }
        else {
            $missing++;
        }
    }

    return unless $missing;

    $rel = $rel->clone;

    push @{$self->{+BY_INDEX}->{$index} //= []} => $rel;
    $self->{+BY_TABLE_AND_NAME}->{$_->{table}}->{$_->{name}} = $rel for @{$rel->members};
}

sub all {
    my $self = shift;
    return map { @{$_} } values %{$self->{+BY_INDEX}};
}

sub for_table {
    my $self = shift;
    my ($table) = @_;
    return keys %{$self->{+BY_TABLE_AND_NAME}->{$table} // {}};
}

sub merge_in {
    my $self = shift;
    my ($merge) = @_;

    return if $merge == $self;

    $self->add_relation($_) for $merge->all;
}

sub merge_missing_in {
    my $self = shift;
    my ($merge) = @_;

    return if $merge == $self;

    for my $rel ($merge->all) {
        next if $self->has_equivelent($rel);
        $self->add_relation($rel);
    }
}

sub clone {
    my $self = shift;

    my $new = blessed($self)->new;

    $new->merge_in($self);

    return $new;
}

1;
