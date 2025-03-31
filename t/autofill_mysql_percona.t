use Test2::V0 -target => 'DBIx::QuickORM', '!meta', '!pass';
use DBIx::QuickORM;

BEGIN {
    $ENV{PATH}="$ENV{HOME}/dbs/percona8/bin:$ENV{PATH}" if -d "$ENV{HOME}/dbs/percona8/bin";
}

use Test2::Tools::QuickDB;
skipall_unless_can_db(driver => 'Percona');

use lib 't/lib';
use DBIx::QuickORM::Test;

my $percona_file = __FILE__;
$percona_file =~ s/\.t/.sql/;
my $mysql = mysql(load_sql => [quickdb => $percona_file]);

db mysql => sub {
    dialect 'MySQL::Percona';
    db_name 'quickdb';
    connect sub { $mysql->connect };
};

orm myorm => sub {
    db 'mysql';
    autofill sub {
        autotype 'UUID';
    };
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
                    alias_id => {affinity => 'numeric', db_name => 'alias_id', name => 'alias_id', nullable => F(), order => 1, type => \'int', identity => T()},
                    light_id => {affinity => 'numeric', db_name => 'light_id', name => 'light_id', nullable => F(), order => 2, type => \'int'},
                    name     => {affinity => 'string',  db_name => 'name',     name => 'name',     nullable => F(), order => 3, type => \'varchar'},
                },
                links => {
                    lights => {
                        light_id => {aliases => [], created => 'unknown', key => 'light_id', local_columns => ['light_id'], other_columns => ['light_id'], table => 'lights', unique => T()},
                    },
                },
                indexes => [
                    {columns => ['alias_id'], name => 'PRIMARY',  type => 'BTREE', unique => T()},
                    {columns => ['light_id'], name => 'light_id', type => 'BTREE', unique => F()},
                    {columns => ['name'],     name => 'name',     type => 'BTREE', unique => T()},
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
                    name_a => {affinity => 'string', db_name => 'name_a', name => 'name_a', nullable => F(), order => 1, type => \'char'},
                    name_b => {affinity => 'string', db_name => 'name_b', name => 'name_b', nullable => F(), order => 2, type => \'char'},
                    name_c => {affinity => 'string', db_name => 'name_c', name => 'name_c', nullable => T(), order => 3, type => \'char'},
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
                    {columns => ['name_a', 'name_b'],           name => 'PRIMARY', type => 'BTREE', unique => T()},
                    {columns => ['name_a', 'name_b', 'name_c'], name => 'name_a',  type => 'BTREE', unique => T()},
                ],
            },
            complex_ref => {
                name           => 'complex_ref',
                db_name        => 'complex_ref',
                primary_key    => ['name_a', 'name_b'],
                is_temp        => F(),
                links_by_alias => {},

                columns => {
                    name_a => {affinity => 'string', db_name => 'name_a', name => 'name_a', nullable => F(), order => 1, type => \'char'},
                    name_b => {affinity => 'string', db_name => 'name_b', name => 'name_b', nullable => F(), order => 2, type => \'char'},
                    extras => {affinity => 'string', db_name => 'extras', name => 'extras', nullable => T(), order => 3, type => \'char'},
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
                    {columns => ['name_a', 'name_b'], name => 'PRIMARY', type => 'BTREE', unique => T()},
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
                    name       => {affinity => 'string',  db_name => 'name',       name => 'name',       nullable => F(), order => 1, type => \'varchar'},
                    alias_id   => {affinity => 'numeric', db_name => 'alias_id',   name => 'alias_id',   nullable => F(), order => 2, type => \'int'},
                    light_id   => {affinity => 'numeric', db_name => 'light_id',   name => 'light_id',   nullable => F(), order => 3, type => \'int'},
                    light_uuid => {affinity => 'binary',  db_name => 'light_uuid', name => 'light_uuid', nullable => F(), order => 4, type => 'DBIx::QuickORM::Type::UUID'},
                    stamp      => {affinity => 'string',  db_name => 'stamp',      name => 'stamp',      nullable => T(), order => 5, type => \'timestamp'},
                    color      => {affinity => 'string',  db_name => 'color',      name => 'color',      nullable => F(), order => 6, type => \'enum'},
                },
            },
            lights => {
                name           => 'lights',
                db_name        => 'lights',
                primary_key    => ['light_id',],
                is_temp        => F(),
                links_by_alias => {},

                columns => {
                    light_id   => {affinity => 'numeric', db_name => 'light_id',   name => 'light_id',   nullable => F(), order => 1, type => \'int', identity => T()},
                    light_uuid => {affinity => 'binary',  db_name => 'light_uuid', name => 'light_uuid', nullable => F(), order => 2, type => 'DBIx::QuickORM::Type::UUID'},
                    stamp      => {affinity => 'string',  db_name => 'stamp',      name => 'stamp',      nullable => T(), order => 3, type => \'timestamp'},
                    color      => {affinity => 'string',  db_name => 'color',      name => 'color',      nullable => F(), order => 4, type => \'enum'},
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
                    {columns => ['light_id'], name => 'PRIMARY', type => 'BTREE', unique => T()},
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
