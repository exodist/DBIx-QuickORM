package DBIx::QuickORM::Role::SQLBuilder;
use strict;
use warnings;

use Role::Tiny;

requires qw{
    qorm_select
    qorm_insert
    qorm_update
    qorm_delete
    qorm_where

    qorm_and
    qorm_or

    qorm_where_for_row
};

1;

__END__




lib/DBIx/QuickORM/Role/Handle.pm:17:sub sqla      { shift->connection->sqla(@_) }
lib/DBIx/QuickORM/SQLAbstract.pm:1:package DBIx::QuickORM::SQLAbstract;
lib/DBIx/QuickORM/Connection.pm:19:use DBIx::QuickORM::SQLAbstract;
lib/DBIx/QuickORM/Connection.pm:55:    +sqla
lib/DBIx/QuickORM/Connection.pm:171:sub sqla {
lib/DBIx/QuickORM/Connection.pm:173:    return $self->{+SQLA}->() if $self->{+SQLA};
lib/DBIx/QuickORM/Connection.pm:175:    my $sqla = DBIx::QuickORM::SQLAbstract->new(bindtype => 'columns');
lib/DBIx/QuickORM/Connection.pm:177:    $self->{+SQLA} = sub { $sqla };
lib/DBIx/QuickORM/Connection.pm:179:    return $sqla;
lib/DBIx/QuickORM/Connection.pm:619:    my ($stmt, $bind) = $self->sqla->qorm_select($query_source, $query->{+QUERY_FIELDS}, $query->{+QUERY_WHERE}, $query->{+QUERY_ORDER_BY});
lib/DBIx/QuickORM/Connection.pm:643:    my ($stmt, $bind) = $self->sqla->qorm_select($query_source, $pk_fields, $where);
lib/DBIx/QuickORM/Connection.pm:721:        my ($stmt, $bind) = $self->sqla->qorm_insert($query_source, $data, $ret ? {returning => $query_source->fields_to_fetch} : ());
lib/DBIx/QuickORM/Connection.pm:811:        my ($stmt, $bind) = $self->sqla->qorm_update($query_source, $changes, $query->{+QUERY_WHERE});
lib/DBIx/QuickORM/Connection.pm:821:        my ($stmt, $bind) = $self->sqla->qorm_update($query_source, $changes, $where, $ret ? {returning => $fields} : ());
lib/DBIx/QuickORM/Connection.pm:840:                my ($stmt, $bind) = $self->sqla->qorm_select($query_source, $fields, $where);
lib/DBIx/QuickORM/Connection.pm:889:        my ($stmt, $bind) = $self->sqla->qorm_delete($query_source, $where, $ret ? $pk_fields : ());
