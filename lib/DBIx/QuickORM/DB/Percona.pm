package DBIx::QuickORM::DB::Percona;
use strict;
use warnings;

use parent 'DBIx::QuickORM::DB';

sub default_dbd { 'DBD::mysql' };

1;
