package DBIx::QuickORM::Role::SQLASource;
use strict;
use warnings;

use Role::Tiny;

requires qw{
    name
    sqla_source
    sqla_fields
    sqla_rename
    row_class
    primary_key
    column
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

1;
