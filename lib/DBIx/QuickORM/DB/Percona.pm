package DBIx::QuickORM::DB::Percona;
use strict;
use warnings;

use parent 'DBIx::QuickORM::DB::MySQL';
use DBIx::QuickORM::Util::HashBase;

sub sql_spec_keys { qw/percona mysql/ }

1;
