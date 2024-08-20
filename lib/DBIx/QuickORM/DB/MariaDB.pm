package DBIx::QuickORM::DB::MariaDB;
use strict;
use warnings;

use DBD::MariaDB;

use parent 'DBIx::QuickORM::DB::MySQL';
use DBIx::QuickORM::Util::HashBase;

sub dbi_driver { 'DBD::MariaDB' }

1;
