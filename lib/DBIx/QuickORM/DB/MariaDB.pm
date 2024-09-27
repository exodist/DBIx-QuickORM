package DBIx::QuickORM::DB::MariaDB;
use strict;
use warnings;

use DBD::MariaDB;

use parent 'DBIx::QuickORM::DB::MySQL';
use DBIx::QuickORM::Util::HashBase;

sub dbi_driver { 'DBD::MariaDB' }

sub sql_spec_keys { qw/mariadb mysql/ }

sub insert_returning_supported { 1 }
sub update_returning_supported { 0 }

1;
