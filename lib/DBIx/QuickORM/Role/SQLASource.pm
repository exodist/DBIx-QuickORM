package DBIx::QuickORM::Role::SQLASource;
use strict;
use warnings;

use Carp qw/croak/;

use Role::Tiny;

requires qw{
    name
    sqla_source
    sqla_fields
    sqla_rename
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
    my $col = $self->column($name) or return $name;
    return $col->db_name // $name;
}

sub column_orm_name {
    my $self = shift;
    my ($name) = @_;
    my $col = $self->db_column($name) or return $name;
    return $col->name // $name;
}

sub remap_columns {
    my $self = shift;
    my ($data) = @_;

    for my $field (keys %$data) {
        my $col = $self->column($field) // $self->db_column($field) // croak "Could not find column for field '$field'";
        my $name = $col->name;
        next if $name eq $field;
        $data->{$name} = delete $data->{$field};
    }

    return $data;
}

1;
