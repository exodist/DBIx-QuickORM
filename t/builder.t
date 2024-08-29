use Test2::V0;
use Test2::Tools::QuickDB;
use DBIx::QuickORM;
use Data::Dumper;
use Carp::Always;

BEGIN {
    $ENV{PATH} = "/home/exodist/percona/bin:$ENV{PATH}" if -d "/home/exodist/percona/bin";
}

my $psql    = eval { get_db({driver => 'PostgreSQL'}) } or diag(clean_err($@));
my $mysql   = eval { get_db({driver => 'MySQL'}) }      or diag(clean_err($@));
my $mariadb = eval { get_db({driver => 'MariaDB'}) }    or diag(clean_err($@));
my $percona = eval { get_db({driver => 'Percona'}) }    or diag(clean_err($@));
my $sqlite  = eval { get_db({driver => 'SQLite'}) }     or diag(clean_err($@));

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

imported_ok qw{
    db db_attributes db_class db_connect db_dsn db_host db_name db_password
    db_port db_socket db_user

    column column_class columns conflate default index is_temp is_view omit
    primary_key row_base_class source_class table_class unique

    column columns member member_class relation relation_class

    plugin plugins ordered_plugins

    autofill mixer orm

    include schema

    sql_spec
    table
};

mixer mymix => sub {
    db postgresql => sub {
        db_class 'PostgreSQL';
        db_name 'quickdb';
        db_connect sub { $psql->connect };
        sql_spec(
            extensions => [qw/citext uuid-ossp/],
            types => [
                [qw/choice enum foo bar baz/],
            ],
        );
    } if $psql;

    db mariadb => sub {
        db_class 'MariaDB';
        db_name 'quickdb';
        db_connect sub { $mariadb->connect };
    } if $mariadb;

    db mysql => sub {
        db_class 'MySQL';
        db_name 'quickdb';
        db_connect sub { $mysql->connect };
    } if $mysql;

    db percona => sub {
        db_class 'Percona';
        db_name 'quickdb';
        db_connect sub { $percona->connect };
    } if $percona;

    db sqlite => sub {
        db_class 'SQLite';
        db_name 'quickdb';
        db_connect sub { $sqlite->connect };
    } if $sqlite;

    schema simple => sub {
        table person => sub {
            column person_id => sub {
                primary_key;
                serial;
                sql_spec(
                    mysql      => {type => 'INTEGER'},
                    postgresql => {type => 'SERIAL'},
                    sqlite     => {type => 'INTEGER'},

                    type => 'INTEGER', # Fallback
                );
            };

            column name => sub {
                unique;
                sql_spec(type => 'VARCHAR(128)');
            };

            column height => {type => 'SMALLINT'};

            column birthdate => sub {
                sql_spec type => 'DATE',
            };

            index happy_bday => qw/birthdate/;
        };

        table aliases => sub {
            column alias_id => sub {
                primary_key;
                serial;
                sql_spec type => 'INTEGER';
            };

            column person_id => sub {
                sql_spec type => 'INTEGER';

                # 4 ways to do it
                references person => ['person_id'], {on_delete => 'cascade'};
                relation {accessor => 'person_way2', reference => 1, on_delete => 'cascade'}, {table => 'person', accessor => 'aliases_way2', columns => ['person_id']};
                relation {accessor => 'person_way3', reference => 1}, sub {
                    references;
                    on_delete 'cascade';
                    member {table => 'person', accessor => 'aliases_way3', columns => ['person_id']};
                };
                relation sub {
                    accessor 'person_way4';
                    on_delete 'cascade';
                    references {table => 'person', accessor => 'aliases_way4', columns => ['person_id']};
                };
            };

            column alias => sub {
                sql_spec(type => 'VARCHAR(128)');
            };

            unique(qw/person_id alias/);

            index unnecessary_index => qw/person_id alias/;
        };
    };
};

ok(mymix(), "Added mymix");
isa_ok(mymix(), ['DBIx::QuickORM::Mixer'], "Mixer is the right type of object");

my ($pg_sql, $mariadb_sql, $sqlite_sql, $mysql_sql, $percona_sql);
subtest PostgreSQL => sub {
    skip_all "Could not find PostgreSQL" unless $psql;
    my $pdb = mymix()->database('postgresql');
    isa_ok($pdb, ['DBIx::QuickORM::DB', 'DBIx::QuickORM::DB::PostgreSQL'], "Got a database instance");

    my $orm = mymix()->orm('simple_pg', schema => 'simple', db => 'postgresql');
    isa_ok($orm, ['DBIx::QuickORM::ORM'], "Got correct ORM type");
    ref_is(mymix()->orm('simple_pg'), $orm, "Instance cached");
    is($orm->db, $pdb, "Orm uses the postgresql database");

    $pg_sql = $orm->generate_schema_sql;
    ok(lives { $orm->load_schema($pg_sql) }, "loaded schema");

    is([sort $orm->connection->tables], [qw/aliases person/], "Loaded both tables");
};

subtest MySQL => sub {
    skip_all "Could not find MySQL" unless $mysql;
    my $pdb = mymix()->database('mysql');
    isa_ok($pdb, ['DBIx::QuickORM::DB', 'DBIx::QuickORM::DB::MySQL'], "Got a database instance");

    my $orm = mymix()->orm('simple_mysql', schema => 'simple', db => 'mysql');
    isa_ok($orm, ['DBIx::QuickORM::ORM'], "Got correct ORM type");
    ref_is(mymix()->orm('simple_mysql'), $orm, "Instance cached");
    is($orm->db, $pdb, "Orm uses the mysql database");

    $mysql_sql = $orm->generate_schema_sql;
    ok(lives { $orm->load_schema($mysql_sql) }, "loaded schema");

    is([sort $orm->connection->tables], [qw/aliases person/], "Loaded both tables");
};

subtest Percona => sub {
    skip_all "Could not find Percona" unless $percona;
    my $pdb = mymix()->database('percona');
    isa_ok($pdb, ['DBIx::QuickORM::DB', 'DBIx::QuickORM::DB::MySQL', 'DBIx::QuickORM::DB::Percona'], "Got a database instance");

    my $orm = mymix()->orm('simple_percona', schema => 'simple', db => 'percona');
    isa_ok($orm, ['DBIx::QuickORM::ORM'], "Got correct ORM type");
    ref_is(mymix()->orm('simple_percona'), $orm, "Instance cached");
    is($orm->db, $pdb, "Orm uses the percona database");

    $percona_sql = $orm->generate_schema_sql;
    ok(lives { $orm->load_schema($percona_sql) }, "loaded schema");

    is([sort $orm->connection->tables], [qw/aliases person/], "Loaded both tables");
};

subtest MariaDB => sub {
    skip_all "Could not find MariaDB" unless $mariadb;
    my $pdb = mymix()->database('mariadb');
    isa_ok($pdb, ['DBIx::QuickORM::DB', 'DBIx::QuickORM::DB::MySQL', 'DBIx::QuickORM::DB::MariaDB'], "Got a database instance");

    my $orm = mymix()->orm('simple_mariadb', schema => 'simple', db => 'mariadb');
    isa_ok($orm, ['DBIx::QuickORM::ORM'], "Got correct ORM type");
    ref_is(mymix()->orm('simple_mariadb'), $orm, "Instance cached");
    is($orm->db, $pdb, "Orm uses the mariadb database");

    $mariadb_sql = $orm->generate_schema_sql;
    ok(lives { $orm->load_schema($mariadb_sql) }, "loaded schema");

    is([sort $orm->connection->tables], [qw/aliases person/], "Loaded both tables");
};

subtest SQLite => sub {
    skip_all "Could not find SQLite" unless $sqlite;
    my $pdb = mymix()->database('sqlite');
    isa_ok($pdb, ['DBIx::QuickORM::DB', 'DBIx::QuickORM::DB::SQLite'], "Got a database instance");

    my $orm = mymix()->orm('simple_sqlite', schema => 'simple', db => 'sqlite');
    isa_ok($orm, ['DBIx::QuickORM::ORM'], "Got correct ORM type");
    ref_is(mymix()->orm('simple_sqlite'), $orm, "Instance cached");
    is($orm->db, $pdb, "Orm uses the sqlite database");

    $sqlite_sql = $orm->generate_schema_sql;
    ok(lives { $orm->load_schema($sqlite_sql) }, "loaded schema");

    is([sort $orm->connection->tables], [qw/aliases person/], "Loaded both tables");
};

done_testing;