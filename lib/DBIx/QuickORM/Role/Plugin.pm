package DBIx::QuickORM::Role::Plugin;
use strict;
use warnings;

use Role::Tiny;

with 'DBIx::QuickORM::Role::HasORM';

requires 'qorm_plugin_action';

1;
