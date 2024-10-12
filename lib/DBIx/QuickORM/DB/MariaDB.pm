package DBIx::QuickORM::DB::MariaDB;
use strict;
use warnings;

use DBD::MariaDB;

use parent 'DBIx::QuickORM::DB::MySQL';
use DBIx::QuickORM::Util::HashBase;

sub dbi_driver { 'DBD::MariaDB' }

sub sql_spec_keys { qw/mariadb mysql/ }
sub dsn_socket_field { 'mariadb_socket' };

sub insert_returning_supported { 1 }
sub update_returning_supported { 0 }

sub supports_uuid { 'UUID' }
sub supports_json { 'JSON' }

my %NORMALIZED_TYPES = (
    UUID => 'UUID',
);

sub normalize_sql_type {
    my $self = shift;
    my ($type, %params) = @_;

    $type = uc($type);
    return $NORMALIZED_TYPES{$type} // $self->SUPER::normalize_sql_type(@_);
}

1;
