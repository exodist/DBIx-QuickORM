use Test2::V0;
use DBIx::QuickORM::Schema;
use DBIx::QuickORM::Schema::Table;
use DBIx::QuickORM::Schema::Table::Column;
use DBIx::QuickORM::Join;

# Joins do not yet translate aliased column names, so building a join over a
# table that has an aliased column must fail loudly rather than emit wrong SQL.

my $C = 'DBIx::QuickORM::Schema::Table::Column';

my $aliased = DBIx::QuickORM::Schema::Table->new(
    name        => 'example',
    columns     => {
        my_id => $C->new(name => 'my_id', db_name => 'id', order => 1, affinity => 'numeric'),
    },
    primary_key => ['my_id'],
);

my $plain = DBIx::QuickORM::Schema::Table->new(
    name        => 'plain',
    columns     => {
        id => $C->new(name => 'id', db_name => 'id', order => 1, affinity => 'numeric'),
    },
    primary_key => ['id'],
);

my $schema = DBIx::QuickORM::Schema->new(name => 's', tables => {example => $aliased, plain => $plain});

like(
    dies { DBIx::QuickORM::Join->new(schema => $schema, primary_source => $aliased) },
    qr/Joins over tables with aliased columns are not yet supported/,
    "join over an aliased table croaks",
);

ok(
    lives { DBIx::QuickORM::Join->new(schema => $schema, primary_source => $plain) },
    "join over a non-aliased table is fine",
);

done_testing;
