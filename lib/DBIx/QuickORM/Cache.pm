package DBIx::QuickORM::Cache;
use strict;
use warnings;

use Scalar::Util qw/weaken/;

use DBIx::QuickORM::Util::HashBase qw{
    +data
};

sub init {
    my $self = shift;
    $self->{+DATA} //= {};
}

sub lookup {
    my $self = shift;
    my ($sqla_source, $data) = @_;

    my $key = $self->data_key($sqla_source, $data) or return;

    return $self->{+DATA}->{$sqla_source->sqla_orm_name}->{$key} // undef;
}

sub update {
    my $self = shift;
    my ($row, $row_data) = @_;

    my $source = $row->sqla_source->sqla_orm_name;

    my $old_key = $self->row_key($row)            or return;
    my $new_key = $self->new_key($row, $row_data) or return;

    return if $old_key eq $new_key;

    delete $self->{+DATA}->{$source}->{$old_key};
    $self->{+DATA}->{$source}->{$new_key} = $row;
    weaken($self->{+DATA}->{$source}->{$new_key});
    return $row;
}

sub remove {
    my $self = shift;
    my ($row) = @_;

    my $source = $row->sqla_source->sqla_orm_name;

    my $key = $self->row_key($row) or return 0;
    delete $self->{+DATA}->{$source}->{$key};
}

sub store {
    my $self = shift;
    my ($row) = @_;

    my $source = $row->sqla_source->sqla_orm_name;

    my $key = $self->row_key($row) or return 0;
    $self->{+DATA}->{$source}->{$key} = $row;
    weaken($self->{+DATA}->{$source}->{$key});
    return $row;
}

sub row_key {
    my $self = shift;
    my ($row) = @_;

    my $pk_fields = $row->sqla_source->primary_key or return;
    my $out = join ', ' => map { my $v = $row->stored_field($_) // return } @$pk_fields;
    return $out;
}

sub data_key {
    my $self = shift;
    my ($sqla_source, $data) = @_;

    my $pk_fields = $sqla_source->primary_key or return;
    return join ', ' => map { $data->{$_} // return } @$pk_fields;
}

sub new_key {
    my $self = shift;
    my ($row, $data) = @_;

    my $pk_fields = $row->sqla_source->primary_key or return;
    return join ', ' => map { $data->{$_} // $row->stored_field($_) // return } @$pk_fields;
}

1;
