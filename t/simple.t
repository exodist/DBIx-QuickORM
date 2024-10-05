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
            sql_spec(type => 'INTEGER');
        };

        column person_id => sub {
            sql_spec type => 'INTEGER';

            # 4 ways to do it
            references person => ['person_id'], {on_delete => 'cascade', precache => 1};
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
        skip_all "Could not find $name" unless __PACKAGE__->can($name);

        my $id = 1;

        my $orm = __PACKAGE__->$name();
        isa_ok($orm, ['DBIx::QuickORM::ORM'], "Got correct ORM type");

        my $pdb = $orm->db;
        isa_ok($pdb, ['DBIx::QuickORM::DB'], "Got a database instance");

        ok(lives { $orm->generate_and_load_schema() }, "Generate and load schema");

        is([sort $orm->connection->tables], [qw/aliases person/], "Loaded both tables");

        my $source = $orm->source('person');
        isa_ok($source, ['DBIx::QuickORM::Source'], "Got a source");

        my $bob_id = $id++;
        ok(my $bob = $source->insert(name => 'bob'), "Inserted bob");
        isa_ok($bob, ['DBIx::QuickORM::Row'], "Got a row back");
        is($bob->from_db->{person_id}, $bob_id, "First row inserted, got id");
        is($bob->from_db->{name}, 'bob', "Name was set correctly");
        ref_is($bob->source, $source, "Get original source when calling source");
        is(ref($bob->{source}), 'CODE', "Source is a coderef, not the actual source instance");

        # This failed insert will increment the sequence for all db's except sqlite
        $id++ unless $name eq 'sqlite';

        like(
            dies {
                local $SIG{__WARN__} = sub { 1 };
                $source->insert(name => 'bob');
            },
            in_set(
                qr/Duplicate entry 'bob' for key 'name'/,
                qr/UNIQUE constraint failed: person\.name/,
                qr/Duplicate entry 'bob' for key 'person\.name'/,
                qr/duplicate key value violates unique constraint "person_name_key"/,
            ),
            "Cannot insert the same row again due to unique contraint"
        );

        ref_is($source->find($bob_id), $bob, "Got cached copy using pk search");
        ref_is($source->find(name => 'bob'), $bob, "Got cached copy using name search");

        my $con = $source->connection;
        my $oldref = "$bob";
        $bob = undef;
        ok(!$con->{cache}->{$source}->{$bob_id}, "Object can be pruned from cache when there are no refs to it");

        $bob = $source->find($bob_id);
        ok("$bob" ne $oldref, "Did not get the same ref");
        is($bob->from_db, {name => 'bob', person_id => $bob_id}, "Got bob");
        ref_is($source->find($bob_id), $bob, "Got cached copy using pk search");

        my $data_ref = $bob->from_db;
        $bob->refresh();
        is($bob->from_db, $data_ref, "Identical data after fetch");
        ref_is_not($bob->from_db, $data_ref, "But the data hashref has been swapped out");

        $bob->from_db->{name} = 'foo';
        is($bob->column('name'), 'foo', "Got incorrect stored name");
        $bob->{dirty}->{name} = 'bar';
        is($bob->column('name'), 'bar', "Got dirty name");
        $bob->reload;
        is($bob->column('name'), 'bob', "Got correct name from db, and cleared dirty");

        is($source->fetch($bob_id), {name => 'bob', person_id => $bob_id}, "fetched bobs data");
        is($source->find($id), undef, "Could not find anything for id $id");

        my $ted = $source->vivify(name => 'ted');
        isa_ok($ted, ['DBIx::QuickORM::Row'], "Created row");
        ok(!$ted->from_db, "But did not insert");

        my $ted_id = $id++;
        $ted->save;

        is($ted->from_db, {name => 'ted', person_id => $ted_id}, "Inserted");
        ref_is($source->find($ted_id), $ted, "Got cached copy");

        $ted->update(name => 'theador');

        like(
            $ted,
            {
                from_db  => {name => 'theador', person_id => $ted_id},
                dirty    => DNE(),
                inflated => {name => DNE()},
            },
            "Got expected data and state",
        );

        ok($ted->in_db, "Ted is in the db");
        $ted->delete;
        ok(!$ted->in_db, "Not in the db");

        is($source->find($ted_id), undef, "No Ted");

        my $als = $orm->source('aliases');
        my $robert = $als->insert(person_id => $bob->column('person_id'), alias => 'robert');
        my $rob = $als->insert(person_id => $bob->column('person_id'), alias => 'rob');

        is($robert->relation('person'), $bob, "Got bob via relationship");
        is($rob->relation('person'), $bob, "Got bob via relationship");

        my $robert_id = $robert->column('alias_id');
        $robert = undef;
        ok(!$con->{cache}->{$als}->{$robert_id}, "Robert is not in cache");

        $robert = $als->find(alias => 'robert');
        is(
            $robert->cached_relations,
            {person => $bob},
            "prefetched person"
        );

        is($als->count_select({where => {person_id => $bob_id}}),             2, "Got proper count");
        is($als->count_select({where => {person_id => $bob_id}, limit => 1}), 1, "Got limit");
        is($als->count_select({where => {person_id => 9001}}),                0, "No rows");

        $robert = $als->find(where => {alias => 'robert'}, prefetch => 'person_way2');
        is(
            $robert->cached_relations,
            {person => $bob, person_way2 => $bob},
            "prefetched person and person_way2"
        );

        my $rows = $bob->relations('aliases', order_by => 'alias_id');
        is($rows->count, 2, "Got count");

        is([$rows->all], [exact_ref($robert), exact_ref($rob)], "Got both aliases, cached");
        is($rows->count, 2, "Got count");

        $rows = $bob->relations('aliases', order_by => 'alias_id', limit => 1);
        is($rows->count, 1, "Got count");
        is([$rows->all], [exact_ref($robert)], "Got aliases, limited");
        is($rows->count, 1, "Got count");
    };
}

done_testing;
