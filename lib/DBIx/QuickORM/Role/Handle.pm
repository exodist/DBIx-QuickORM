package DBIx::QuickORM::Role::Handle;
use strict;
use warnings;

use Carp qw/confess/;
use Scalar::Util qw/blessed/;

use Role::Tiny;

sub cache     { shift->connection->cache(@_) }
sub check_pid { shift->connection->check_pid(@_) }
sub dbh       { shift->connection->dbh(@_) }
sub dialect   { shift->connection->dialect(@_) }
sub orm       { shift->connection->orm(@_) }
sub pid       { shift->connection->pid(@_) }
sub schema    { shift->connection->schema(@_) }
sub sqla      { shift->connection->sqla(@_) }
sub db        { shift->orm->db(@_) }

sub init {
    my $self = shift;

    my $con = $self->connection or confess "'connection' is a required attribute";
    confess "Connection '$con' is not an instance of 'DBIx::QuickORM::Connection'"
        unless blessed($con) && $con->isa('DBIx::QuickORM::Connection');

    my $query_source = $self->query_source or confess "'query_source' is a required attribute";
    confess "Source '$query_source' does not implement the role 'DBIx::QuickORM::Role::QuerySource'"
        unless blessed($query_source) && $query_source->DOES('DBIx::QuickORM::Role::QuerySource');
}

sub build_row {
    my $self = shift;
    my ($data, $row, %params) = @_;

    $self->connection->build_row(
        %params,
        row_class   => $self->row_class,
        query_source => $self->query_source,
        row_data    => $data,
        row         => $row,
    );
}

sub row_class {
    my $self = shift;
    return $self->query_source->row_class // $self->schema->row_class;
}

requires qw{
    connection
    query_source
    all
    iterator
    iterate
    any
    count
    first
    one
    delete
    update
};

1;
