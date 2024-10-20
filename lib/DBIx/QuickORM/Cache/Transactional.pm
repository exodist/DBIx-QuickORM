package DBIx::QuickORM::Cache::Transactional;
use strict;
use warnings;

use parent 'DBIx::QuickORM::Cache::Naive';

require DBIx::QuickORM::RowState::Transactional;
sub row_state_class() { 'DBIx::QuickORM::RowState::Transactional' }

1;
