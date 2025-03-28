use Test2::V0 -target => 'DBIx::QuickORM', '!meta', '!pass';
use DBIx::QuickORM;

use Test2::Tools::QuickDB;
skipall_unless_can_db(driver => 'PostgreSQL');

use lib 't/lib';
use DBIx::QuickORM::Test;

my $psql_file = __FILE__;
$psql_file =~ s/\.t/.sql/;
my $psql = psql(load_sql => [quickdb => $psql_file]);

db postgresql => sub {
    dialect 'PostgreSQL';
    db_name 'quickdb';
    connect sub { $psql->connect };
};

orm myorm => sub {
    db 'postgresql';
    autofill;
};

my $con = orm('myorm')->connect;
diag "Using dialect '" . $con->dialect->dialect_name . "'";

my $schema = $con->schema;
is(
    $schema,
    {
        row_class => 'DBIx::QuickORM::Row',
        tables    => {
            aliases => {
                name           => 'aliases',
                db_name        => 'aliases',
                primary_key    => ['alias_id'],
                is_temp        => F(),
                links_by_alias => {},

                columns => {
                    alias_id => {affinity => 'numeric', db_name => 'alias_id', name => 'alias_id', nullable => F(), order => 1, type => \'int4'},
                    light_id => {affinity => 'numeric', db_name => 'light_id', name => 'light_id', nullable => F(), order => 2, type => \'int4'},
                    name     => {affinity => 'string',  db_name => 'name',     name => 'name',     nullable => F(), order => 3, type => \'varchar'},
                },
                links => {
                    lights => {
                        light_id => {aliases => [], created => 'unknown', key => 'light_id', local_columns => ['light_id'], other_columns => ['light_id'], table => 'lights', unique => T()},
                    },
                },
                indexes => [
                    {columns => ['name'],     name => 'aliases_name_key', type => 'btree', unique => 1},
                    {columns => ['alias_id'], name => 'aliases_pkey',     type => 'btree', unique => 1},
                ],
                unique => {
                    alias_id => ['alias_id'],
                    name     => ['name'],
                },
            },
            complex_keys => {
                name           => 'complex_keys',
                db_name        => 'complex_keys',
                primary_key    => ['name_a', 'name_b'],
                is_temp        => F(),
                links_by_alias => {},

                columns => {
                    name_a => {affinity => 'string', db_name => 'name_a', name => 'name_a', nullable => F(), order => 1, type => \'bpchar'},
                    name_b => {affinity => 'string', db_name => 'name_b', name => 'name_b', nullable => F(), order => 2, type => \'bpchar'},
                    name_c => {affinity => 'string', db_name => 'name_c', name => 'name_c', nullable => T(), order => 3, type => \'bpchar'},
                },
                links => {
                    complex_ref => {
                        'name_a, name_b' => {aliases => [], created => 'unknown', key => 'name_a, name_b', local_columns => ['name_a', 'name_b'], other_columns => ['name_a', 'name_b'], table => 'complex_ref', unique => T()},
                    },
                },
                unique => {
                    'name_a, name_b'         => ['name_a', 'name_b'],
                    'name_a, name_b, name_c' => ['name_a', 'name_b', 'name_c'],
                },
                indexes => [
                    {columns => ['name_a', 'name_b', 'name_c'], name => 'complex_keys_name_a_name_b_name_c_key', type => 'btree', unique => 1},
                    {columns => ['name_a', 'name_b'], name => 'complex_keys_pkey', type => 'btree', unique => 1},
                ],
            },
            complex_ref => {
                name           => 'complex_ref',
                db_name        => 'complex_ref',
                primary_key    => ['name_a', 'name_b'],
                is_temp        => F(),
                links_by_alias => {},

                columns => {
                    name_a => {affinity => 'string', db_name => 'name_a', name => 'name_a', nullable => F(), order => 1, type => \'bpchar'},
                    name_b => {affinity => 'string', db_name => 'name_b', name => 'name_b', nullable => F(), order => 2, type => \'bpchar'},
                    extras => {affinity => 'string', db_name => 'extras', name => 'extras', nullable => T(), order => 3, type => \'bpchar'},
                },
                links => {
                    complex_keys => {
                        'name_a, name_b' => {aliases => [], created => 'unknown', key => 'name_a, name_b', local_columns => ['name_a', 'name_b'], other_columns => ['name_a', 'name_b'], table => 'complex_keys', unique => T()},
                    },
                },
                unique => {
                    'name_a, name_b' => ['name_a', 'name_b',],
                },
                indexes => [
                    {columns => ['name_a', 'name_b'], name => 'complex_ref_pkey', type => 'btree', unique => 1},
                ],
            },
            light_by_name => {
                name           => 'light_by_name',
                db_name        => 'light_by_name',
                primary_key    => undef,
                is_temp        => F(),
                links          => {},
                links_by_alias => {},
                unique         => {},
                indexes        => [],

                columns => {
                    name       => {affinity => 'string',  db_name => 'name',       name => 'name',       nullable => T(), order => 1, type => \'varchar'},
                    alias_id   => {affinity => 'numeric', db_name => 'alias_id',   name => 'alias_id',   nullable => T(), order => 2, type => \'int4'},
                    light_id   => {affinity => 'numeric', db_name => 'light_id',   name => 'light_id',   nullable => T(), order => 3, type => \'int4'},
                    light_uuid => {affinity => 'string',  db_name => 'light_uuid', name => 'light_uuid', nullable => T(), order => 4, type => \'uuid'},
                    stamp      => {affinity => 'string',  db_name => 'stamp',      name => 'stamp',      nullable => T(), order => 5, type => \'timestamptz'},
                    color      => {affinity => 'string',  db_name => 'color',      name => 'color',      nullable => T(), order => 6, type => \'color'},
                },
            },
            lights => {
                name           => 'lights',
                db_name        => 'lights',
                primary_key    => ['light_id',],
                is_temp        => F(),
                links_by_alias => {},

                columns => {
                    light_id   => {affinity => 'numeric', db_name => 'light_id',   name => 'light_id',   nullable => F(), order => 1, type => \'int4'},
                    light_uuid => {affinity => 'string',  db_name => 'light_uuid', name => 'light_uuid', nullable => F(), order => 2, type => \'uuid'},
                    stamp      => {affinity => 'string',  db_name => 'stamp',      name => 'stamp',      nullable => T(), order => 3, type => \'timestamptz'},
                    color      => {affinity => 'string',  db_name => 'color',      name => 'color',      nullable => F(), order => 4, type => \'color'},
                },
                links => {
                    aliases => {
                        light_id => {aliases => [], created => 'unknown', key => 'light_id', local_columns => ['light_id'], other_columns => ['light_id'], table => 'aliases', unique => F()},
                    },
                },
                unique => {
                    light_id => ['light_id',],
                },
                indexes => [
                    {columns => ['light_id'], name => 'lights_pkey', type => 'btree', unique => 1},
                ],
            },
        },
    },
    "Generated a schema"
);

isa_ok($schema, ['DBIx::QuickORM::Schema'], "Schema is the correct type");
for my $table ($schema->tables) {
    isa_ok($table, ['DBIx::QuickORM::Schema::Table'], "Table $table->{name} is correct type");
    isa_ok($table, ['DBIx::QuickORM::Schema::View'], "View $table->{name} is a view") if $table->name eq 'light_by_name';

    for my $col ($table->columns) {
        isa_ok($col, ['DBIx::QuickORM::Schema::Table::Column'], "Column $table->{name}.$col->{name} is correct type");
    }

    for my $link ($table->links) {
        isa_ok($link, ['DBIx::QuickORM::Schema::Link'], "Link $table->{name}->$link->{table} is correct type");
    }
}

isa_ok($schema->maybe_table('aliases'), ['DBIx::QuickORM::Schema::Table'], "Can get table by name");
isa_ok($schema->maybe_table('aliases')->column('alias_id'), ['DBIx::QuickORM::Schema::Table::Column'], "Can get column by name");
isa_ok($schema->maybe_table('aliases')->link(table => 'lights'), ['DBIx::QuickORM::Schema::Link'], "Can get link by table");
isa_ok($schema->maybe_table('aliases')->link(table => 'lights', cols => ['light_id']), ['DBIx::QuickORM::Schema::Link'], "Can get link by table + cols");

done_testing;
