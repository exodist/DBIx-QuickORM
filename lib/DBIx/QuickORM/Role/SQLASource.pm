package DBIx::QuickORM::Role::SQLASource;
use strict;
use warnings;

use Carp qw/croak confess/;

use Role::Tiny;

requires qw{
    name
    sqla_source
    sqla_fields
    sqla_all_fields
    rename_db_to_orm_map
    rename_orm_to_db_map
    row_class
    primary_key
    column
    column_db_names
    column_orm_names
};

sub column_can_conflate {
    my $self = shift;
    my ($col) = @_;
    my $spec = $self->column($col) or return;
    my $type = $spec->type or return;
    return if ref($type) eq 'SCALAR';
    return $type;
}

sub column_affinity {
    my $self = shift;
    my ($col, $dialect) = @_;
    my $spec = $self->column($col) or return 'string';
    return $spec->affinity($dialect);
}

sub column_type {
    my $self = shift;
    my ($col) = @_;
    my $spec = $self->column($col) or return;
    my $type = $spec->type or return;
    return if ref($type);
    return $type;
}

sub column_db_name {
    my $self = shift;
    my ($name) = @_;
    my $col = $self->column($name) or confess "unknown orm column '$name'";
    return $col->db_name;
}

sub column_orm_name {
    my $self = shift;
    my ($name) = @_;
    my $col = $self->db_column($name) or confess "unknown db column '$name'";
    return $col->name;
}

sub remap_db_to_orm {
    my $self = shift;
    my ($hash) = @_;

    my $map = $self->rename_db_to_orm_map;

    # In case orm and db keys conflict, we put all keeps into an array, then squash it to a hash later.
    my @keep;
    for my $db (keys %$hash, keys %$map) {
        my $orm = $map->{$db} // $db;
        push @keep => ($orm => $hash->{$db}) if exists $hash->{$db};
    }

    return { @keep };
}

sub remap_orm_to_db {
    my $self = shift;
    my ($hash) = @_;

    my $map = $self->rename_orm_to_db_map;

    # In case orm and db keys conflict, we put all keeps into an array, then squash it to a hash later.
    my @keep;
    for my $orm (keys %$hash, keys %$map) {
        my $db = $map->{$orm} // $orm;
        push @keep => ($db => $hash->{$orm}) if exists $hash->{$orm};
    }

    return { @keep };
}


1;
