use Test2::V0;
use Test2::Tools::QuickDB;
use DBIx::QuickORM;
use Data::Dumper;

BEGIN {
    $ENV{PATH} = "/home/exodist/percona/bin:$ENV{PATH}" if -d "/home/exodist/percona/bin";
}

my $psql_file   = __FILE__;
my $mysql_file  = __FILE__;
my $sqlite_file = __FILE__;

$psql_file   =~ s/\.t$/_postgresql.sql/;
$mysql_file  =~ s/\.t$/_mysql.sql/;
$sqlite_file =~ s/\.t$/_sqlite.sql/;

my $psql    = eval { get_db({driver => 'PostgreSQL', load_sql => [quickdb => $psql_file]}) }   or diag(clean_err( $@ ));
my $mariadb = eval { get_db({driver => 'MariaDB',    load_sql => [quickdb => $mysql_file]}) }  or diag(clean_err( $@ ));
my $mysql   = eval { get_db({driver => 'MySQL',      load_sql => [quickdb => $mysql_file]}) }  or diag(clean_err( $@ ));
my $percona = eval { get_db({driver => 'Percona',    load_sql => [quickdb => $mysql_file]}) }  or diag(clean_err( $@ ));
my $sqlite  = eval { get_db({driver => 'SQLite',     load_sql => [quickdb => $sqlite_file]}) } or diag(clean_err( $@ ));

sub clean_err {
    my $err = shift;

    my @lines = split /\n/, $err;

    my $out = "";
    while (@lines) {
        my $line = shift @lines;
        next unless $line;
        last if $out && $line =~ m{^Aborting at.*DBIx/QuickDB\.pm};

        $out = $out ? "$out\n$line" : $line;
    }

    return $out;
}

mixer test_mix => sub {
    db postgresql => sub {
        db_class 'PostgreSQL';
        connect sub { $psql->connect };
        db_name 'quickdb';
    } if $psql;

    db mariadb => sub {
        db_class 'MariaDB';
        connect sub { $mariadb->connect };
        db_name 'quickdb';
    } if $mariadb;

    db mysql => sub {
        db_class 'MySQL';
        connect sub { $mysql->connect };
        db_name 'quickdb';
    } if $mysql;

    db percona => sub {
        db_class 'Percona';
        connect sub { $percona->connect };
        db_name 'quickdb';
    } if $percona;

    db sqlite => sub {
        db_class 'SQLite';
        connect sub { $sqlite->connect };
        db_name 'quickdb';
    } if $sqlite;
};

my $keys = {
    lights => {
        pk     => ['light_id'],
        unique => [['light_id']],
    },
    aliases => {
        pk     => ['alias_id'],
        fk     => [{columns => ['light_id'], foreign_columns => ['light_id'], foreign_table => 'lights'}],
        unique => bag { item ['alias_id']; item ['name']; end },
    },
    light_by_name => {},
    complex_keys  => {
        pk     => bag { item 'name_a'; item 'name_b'; end },
        unique => bag { item bag { item 'name_a'; item 'name_b'; end }; item bag { item 'name_a'; item 'name_b'; item 'name_c'; end }; end },
    },
    complex_ref => {
        fk     => [{columns => bag { item 'name_a'; item 'name_b'; end }, foreign_columns => bag { item 'name_a'; item 'name_b'; end }, foreign_table => 'complex_keys'}],
        pk     => bag { item 'name_a'; item 'name_b'; end },
        unique => [ bag { item 'name_a'; item 'name_b'; end }],
    },
};

my ($pg_schema, $mariadb_schema, $sqlite_schema, $mysql_schema, $percona_schema);
subtest PostgreSQL => sub {
    skip_all "Could not find PostgreSQL" unless $psql;
    my $pdb = test_mix()->database('postgresql');
    isa_ok($pdb, ['DBIx::QuickORM::DB', 'DBIx::QuickORM::DB::PostgreSQL'], "Got a database instance");

    my $dbh = $pdb->dbh;
    is($pdb->dbh, $dbh, "Got the same dbh, it was cached");
    ref_is_not($pdb->connect, $dbh, "Got a second connection");

    is($pdb->keys($_), $keys->{$_}, "Got expected data structure for table '$_' keys") for keys %$keys;

    $pg_schema = $pdb->generate_schema;
};

subtest MariaDB => sub {
    skip_all "Could not find MariaDB" unless $mariadb;
    my $pdb = test_mix()->database('mariadb');
    isa_ok($pdb, ['DBIx::QuickORM::DB', 'DBIx::QuickORM::DB::MariaDB'], "Got a database instance");

    my $dbh = $pdb->dbh;
    is($pdb->dbh, $dbh, "Got the same dbh, it was cached");
    ref_is_not($pdb->connect, $dbh, "Got a second connection");

    is($pdb->keys($_), $keys->{$_}, "Got expected data structure for table '$_' keys") for keys %$keys;

    $mariadb_schema = $pdb->generate_schema;
};

subtest MySQL => sub {
    skip_all "Could not find MySQL" unless $mysql;
    my $pdb = test_mix()->database('mysql');
    isa_ok($pdb, ['DBIx::QuickORM::DB', 'DBIx::QuickORM::DB::MySQL'], "Got a database instance");

    my $dbh = $pdb->dbh;
    is($pdb->dbh, $dbh, "Got the same dbh, it was cached");
    ref_is_not($pdb->connect, $dbh, "Got a second connection");

    is($pdb->keys($_), $keys->{$_}, "Got expected data structure for table '$_' keys") for keys %$keys;

    $mysql_schema = $pdb->generate_schema;
};

subtest Percona => sub {
    skip_all "Could not find Percona" unless $percona;
    my $pdb = test_mix()->database('percona');
    isa_ok($pdb, ['DBIx::QuickORM::DB', 'DBIx::QuickORM::DB::Percona'], "Got a database instance");

    my $dbh = $pdb->dbh;
    is($pdb->dbh, $dbh, "Got the same dbh, it was cached");
    ref_is_not($pdb->connect, $dbh, "Got a second connection");

    is($pdb->keys($_), $keys->{$_}, "Got expected data structure for table '$_' keys") for keys %$keys;

    $percona_schema = $pdb->generate_schema;
};

subtest SQLite => sub {
    skip_all "Could not find SQLite" unless $sqlite;
    my $pdb = test_mix()->database('sqlite');
    isa_ok($pdb, ['DBIx::QuickORM::DB', 'DBIx::QuickORM::DB::SQLite'], "Got a database instance");

    my $dbh = $pdb->dbh;
    is($pdb->dbh, $dbh, "Got the same dbh, it was cached");
    ref_is_not($pdb->connect, $dbh, "Got a second connection");

    is($pdb->keys($_), $keys->{$_}, "Got expected data structure for table '$_' keys") for keys %$keys;

    $sqlite_schema = $pdb->generate_schema;
};

my $plugins = {__ORDER__ => []};

my $rel_al = {
    index    => 'aliases(light_id) lights(light_id)',
    plugins  => $plugins,
    created  => T(),
    sql_spec => T(),
    members  => [
        {
            columns  => ['light_id'],
            name     => 'lights',
            plugins  => $plugins,
            table    => 'aliases',
            created  => T(),
            sql_spec => T(),
        },
        {
            columns  => ['light_id'],
            name     => 'aliases',
            plugins  => $plugins,
            table    => 'lights',
            created  => T(),
            sql_spec => T(),
        },
    ],
};

my $rel_cc = {
    index    => 'complex_keys(name_a,name_b) complex_ref(name_a,name_b)',
    plugins  => $plugins,
    created  => T(),
    sql_spec => T(),
    members  => [
        {
            columns  => ['name_a', 'name_b'],
            name     => 'complex_keys',
            table    => 'complex_ref',
            plugins  => $plugins,
            created  => T(),
            sql_spec => T(),
        },
        {
            columns  => ['name_a', 'name_b'],
            name     => 'complex_ref',
            table    => 'complex_keys',
            plugins  => $plugins,
            created  => T(),
            sql_spec => T(),
        },

    ],
};

my $relations = {
    by_index => {
        'aliases(light_id) lights(light_id)'                     => $rel_al,
        'complex_keys(name_a,name_b) complex_ref(name_a,name_b)' => $rel_cc,
    },
    by_table_and_name => {
        aliases      => {lights       => $rel_al},
        lights       => {aliases      => $rel_al},
        complex_keys => {complex_ref  => $rel_cc},
        complex_ref  => {complex_keys => $rel_cc},
    }
};

my $aliases = {
    name        => 'aliases',
    primary_key => ['alias_id'],
    plugins     => $plugins,
    is_temp     => F(),
    is_view     => F(),
    created     => T(),
    sql_spec    => T(),

    unique => {
        alias_id => ['alias_id'],
        name     => ['name'],
    },

    columns => {
        alias_id => {
            name        => 'alias_id',
            plugins     => $plugins,
            primary_key => T(),
            unique      => T(),
            created     => T(),
            sql_spec    => {type => T()},
        },
        light_id => {
            name     => 'light_id',
            plugins  => $plugins,
            created  => T(),
            sql_spec => {type => T()},
        },
        name => {
            name     => 'name',
            plugins  => $plugins,
            unique   => T(),
            created  => T(),
            sql_spec => {type => T()},
        },
    },
};

my $complex_keys = {
    name        => 'complex_keys',
    primary_key => ['name_a', 'name_b'],
    plugins     => $plugins,
    is_temp     => F(),
    is_view     => F(),
    created     => T(),
    sql_spec    => T(),

    unique => {
        'name_a, name_b'         => ['name_a', 'name_b'],
        'name_a, name_b, name_c' => ['name_a', 'name_b', 'name_c'],
    },

    columns => {
        name_a => {
            created     => T(),
            name        => 'name_a',
            plugins     => $plugins,
            primary_key => T(),
            sql_spec    => {type => T()},
        },
        name_b => {
            name        => 'name_b',
            plugins     => $plugins,
            primary_key => T(),
            created     => T(),
            sql_spec    => {type => T()},
        },
        name_c => {
            name     => 'name_c',
            plugins  => $plugins,
            created  => T(),
            sql_spec => {type => T()},
        },
    },
};

my $complex_ref = {
    name        => 'complex_ref',
    primary_key => ['name_a', 'name_b'],
    plugins     => $plugins,
    is_temp     => F(),
    is_view     => F(),
    created     => T(),
    sql_spec    => T(),

    unique => {
        'name_a, name_b' => ['name_a', 'name_b'],
    },

    columns => {
        extras => {
            name     => 'extras',
            plugins  => $plugins,
            created  => T(),
            sql_spec => {type => T()},
        },
        name_a => {
            name        => 'name_a',
            plugins     => $plugins,
            primary_key => T(),
            created     => T(),
            sql_spec    => {type => T()},
        },
        name_b => {
            name        => 'name_b',
            plugins     => $plugins,
            primary_key => T(),
            created     => T(),
            sql_spec    => {type => T()},
        },
    },
};

my $light_by_name = {
    name     => 'light_by_name',
    plugins  => $plugins,
    is_temp  => F(),
    is_view  => T(),
    created  => T(),
    sql_spec => T(),

    columns => {
        alias_id => {
            name     => 'alias_id',
            plugins  => $plugins,
            created  => T(),
            sql_spec => {type => T()},
        },
        color => {
            name     => 'color',
            plugins  => $plugins,
            created  => T(),
            sql_spec => {type => T()},
        },
        light_id => {
            name     => 'light_id',
            plugins  => $plugins,
            created  => T(),
            sql_spec => {type => T()},
        },
        light_uuid => {
            name     => 'light_uuid',
            conflate => 'DBIx::QuickORM::Conflator::UUID',
            plugins  => $plugins,
            created  => T(),
            sql_spec => {type => T()},
        },
        name => {
            name     => 'name',
            plugins  => $plugins,
            created  => T(),
            sql_spec => {type => T()},
        },
        stamp => {
            name     => 'stamp',
            conflate => 'DBIx::QuickORM::Conflator::DateTime',
            plugins  => $plugins,
            created  => T(),
            sql_spec => {type => T()},
        },
    },
};

my $lights = {
    name        => 'lights',
    plugins     => $plugins,
    primary_key => ['light_id'],
    is_temp     => F(),
    is_view     => F(),
    created     => T(),
    sql_spec    => T(),

    unique => {light_id => ['light_id']},

    columns => {
        color => {
            name     => 'color',
            plugins  => $plugins,
            created  => T(),
            sql_spec => {type => T()},
        },
        light_id => {
            name        => 'light_id',
            plugins     => $plugins,
            primary_key => T(),
            unique      => T(),
            created     => T(),
            sql_spec    => {type => T()},
        },
        light_uuid => {
            name     => 'light_uuid',
            conflate => 'DBIx::QuickORM::Conflator::UUID',
            plugins  => $plugins,
            created  => T(),
            sql_spec => {type => T()},
        },
        stamp => {
            name     => 'stamp',
            conflate => 'DBIx::QuickORM::Conflator::DateTime',
            plugins  => $plugins,
            created  => T(),
            sql_spec => {type => T()},
        },
    },
};

my $tables = {
    aliases       => $aliases,
    complex_keys  => $complex_keys,
    complex_ref   => $complex_ref,
    light_by_name => $light_by_name,
    lights        => $lights,
};

is($pg_schema,      {name => 'postgresql', plugins => $plugins, relations => $relations, tables => $tables, created => T()}, "Got PG Schema")      if $psql;
is($mariadb_schema, {name => 'mariadb',    plugins => $plugins, relations => $relations, tables => $tables, created => T()}, "Got MariaDB Schema") if $mariadb;
is($mysql_schema,   {name => 'mysql',      plugins => $plugins, relations => $relations, tables => $tables, created => T()}, "Got MySQL Schema")   if $mysql;
is($percona_schema, {name => 'percona',    plugins => $plugins, relations => $relations, tables => $tables, created => T()}, "Got Percona Schema") if $percona;
is($sqlite_schema,  {name => 'sqlite',     plugins => $plugins, relations => $relations, tables => $tables, created => T()}, "Got SQLite Schema")  if $sqlite;

#system($mariadb->shell_command('quickdb'));

done_testing;
