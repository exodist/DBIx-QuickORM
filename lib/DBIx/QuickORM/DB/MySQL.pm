package DBIx::QuickORM::DB::MySQL;
use strict;
use warnings;

use parent 'DBIx::QuickORM::DB';

sub default_dbd { 'DBD::mysql' };

1;
