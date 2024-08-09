package DBIx::QuickORM::DB::PostgreSQL;
use strict;
use warnings;

use parent 'DBIx::QuickORM::DB';

sub default_dbd { 'DBD::Pg' };

1;
