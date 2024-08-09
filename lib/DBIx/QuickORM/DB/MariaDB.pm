package DBIx::QuickORM::DB::MariaDB;
use strict;
use warnings;

use parent 'DBIx::QuickORM::DB';

sub default_dbd { 'DBD::MariaDB' };

1;
