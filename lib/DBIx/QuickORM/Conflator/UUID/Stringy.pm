package DBIx::QuickORM::Conflator::UUID::Stringy;
use strict;
use warnings;

use parent 'DBIx::QuickORM::Conflator::UUID';
use DBIx::QuickORM::Util::HashBase;

sub _qorm_sql_type { 'VARCHAR(36)' }

1;
