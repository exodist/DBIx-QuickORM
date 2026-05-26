use Test2::V0;
use DBIx::QuickORM::Schema::Table;
use DBIx::QuickORM::Schema::Table::Column;

# Simulate the autofill merge: an introspected table (columns keyed by database
# name, name == db_name) merged with a user table that aliases those columns
# (columns keyed by ORM name with a db_name pointing at the database column).
# The database is canonical, so introspected metadata fills gaps while the
# user's ORM names and overrides win, and the result is uniformly ORM-keyed.

my $C = 'DBIx::QuickORM::Schema::Table::Column';

my $introspected = DBIx::QuickORM::Schema::Table->new(
    name    => 'example',
    db_name => 'example',
    columns => {
        id   => $C->new(name => 'id',   db_name => 'id',   order => 1, identity => 1, nullable => 0, affinity => 'numeric'),
        uuid => $C->new(name => 'uuid', db_name => 'uuid', order => 2,                nullable => 0, affinity => 'binary'),
    },
    primary_key => ['id'],
);

my $user = DBIx::QuickORM::Schema::Table->new(
    name    => 'example',
    columns => {
        my_id   => $C->new(name => 'my_id',   db_name => 'id',   order => 1, affinity => 'numeric'),
        my_uuid => $C->new(name => 'my_uuid', db_name => 'uuid', order => 2, affinity => 'binary'),
    },
    primary_key => ['my_id'],
);

my $merged = $introspected->merge($user);

is([sort $merged->column_names], ['my_id', 'my_uuid'], "merged columns are keyed by ORM name");
is($merged->primary_key, ['my_id'], "primary key translated to ORM name");

my $my_id = $merged->column('my_id');
is($my_id->db_name, 'id', "aliased column keeps its database name");
ok($my_id->identity, "identity metadata filled in from introspection");
is($my_id->nullable, 0, "nullable metadata filled in from introspection");

is($merged->field_db_name('my_id'),  'id',    "field_db_name maps ORM name to database name");
is($merged->field_db_name('id'),     'id',    "field_db_name is idempotent on database name");
is($merged->field_orm_name('id'),    'my_id', "field_orm_name maps database name to ORM name");
is($merged->field_orm_name('my_id'), 'my_id', "field_orm_name is idempotent on ORM name");

ok($merged->has_field('id'),    "has_field accepts the database name");
ok($merged->has_field('my_id'), "has_field accepts the ORM name");

done_testing;
