package DBIx::QuickORM::Role::SQLASource;
use strict;
use warnings;

use Role::Tiny;

requires qw{
    name
    sqla_source
    sqla_fields
    sqla_rename
    row_class
};

1;
