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

    plugin plugins

    autofill mixer orm

    include schema

    sql_spec
    table
};

sub _schema {
    table person => sub {
        column person_id => sub {
            primary_key;
            serial;
            sql_spec(
                mysql      => {type => 'INTEGER'},
                postgresql => {type => 'SERIAL'},
                sqlite     => {type => 'INTEGER'},

                type => 'INTEGER',    # Fallback
            );
        };

        column name => sub {
            unique;
            sql_spec(type => 'VARCHAR(128)');
        };
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
    };
}

orm postgresql => sub {
    db_class 'PostgreSQL';
    db_name 'quickdb';
    db_connect sub { $psql->connect };

    _schema();
} if $psql;

orm mariadb => sub {
    db_class 'MariaDB';
    db_name 'quickdb';
    db_connect sub { $mariadb->connect };

    _schema();
} if $mariadb;

orm mysql => sub {
    db_class 'MySQL';
    db_name 'quickdb';
    db_connect sub { $mysql->connect };

    _schema();
} if $mysql;

orm percona => sub {
    db_class 'Percona';
    db_name 'quickdb';
    db_connect sub { $percona->connect };

    _schema();
} if $percona;

orm sqlite => sub {
    db_class 'SQLite';
    db_name 'quickdb';
    db_connect sub { $sqlite->connect };

    _schema();
} if $sqlite;

for my $name (qw/postgresql mariadb mysql percona sqlite/) {
    subtest $name => sub {
        skip_all "Could not find PostgreSQL" unless __PACKAGE__->can($name);

        my $orm = __PACKAGE__->$name();
        isa_ok($orm, ['DBIx::QuickORM::ORM'], "Got correct ORM type");

        my $pdb = $orm->db;
        isa_ok($pdb, ['DBIx::QuickORM::DB'], "Got a database instance");

        ok(lives { $orm->generate_and_load_schema() }, "Generate and insert schema");

        is([sort $orm->connection->tables], [qw/aliases person/], "Loaded both tables");
    };
}

done_testing;
