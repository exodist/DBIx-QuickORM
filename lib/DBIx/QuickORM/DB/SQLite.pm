package DBIx::QuickORM::DB::SQLite;
use strict;
use warnings;

use parent 'DBIx::QuickORM::DB';

sub default_dbd { 'DBD::SQLite' };

1;
