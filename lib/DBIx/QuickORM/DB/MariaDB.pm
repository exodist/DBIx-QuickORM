package DBIx::QuickORM::DB::MariaDB;
use strict;
use warnings;

use DBD::MariaDB;

use parent 'DBIx::QuickORM::DB::MySQL';
use DBIx::QuickORM::Util::HashBase;

sub dbi_driver { 'DBD::MariaDB' }

sub sql_spec_keys { qw/mariadb mysql/ }

1;