use Test2::V0 -target => 'DBIx::QuickORM';
use lib 't/lib';
use DBIx::QuickORM::Tester qw/dbs_do all_dbs/;
use Carp::Always;

BEGIN {
    no strict 'refs';
    $CLASS->import(@{"$CLASS\::EXPORT_OK"});
    imported_ok(@{"$CLASS\::EXPORT_OK"});

    package DBIx::QuickORM;
    *main::STATE = \*DBIx::QuickORM::STATE;
}

sub db_common {
    my $dbname = shift;

    db_class $dbname;
    db_name 'quickdb';
    sql_spec foo => 'bar';
    db_user '';
    db_password '';
}

dbs_do db => sub {
    my ($dbname, $dbc, $st) = @_;
    imported_ok('db');

    my $dba = db 'dba' => sub {
        db_common($dbname);

        db_attributes foo => 'bar';
        db_attributes {baz => 'bat', apple => 'orange'};
        db_connect sub { $dbc->connect };
    };

    unless ($dbname eq 'SQLite') {
        my $dbb = db 'dbb' => sub {
            db_common($dbname);

            db_host "127.0.0.1";
            db_port 123;
        };

        like($dbb->dsn, qr/dbname=quickdb;host=127\.0\.0\.1;port=123;/, "host+port");
    }

    is(
        $dba->attributes,
        {
            AutoCommit          => T(),
            AutoInactiveDestroy => T(),
            PrintError          => T(),
            RaiseError          => T(),
            apple               => 'orange',
            baz                 => 'bat',
            foo                 => 'bar',
        },
        "All attributes set"
    );

    my %dbs;
    $dbs{'connect'} = db 'connect' => sub {
        db_common($dbname);
        db_connect sub { $dbc->connect };
    };

    $dbs{'dsn'} = db 'dsn' => sub {
        db_common($dbname);
        db_dsn $dbc->connect_string('quickdb');
    };

    unless ($dbname eq 'SQLite') {
        $dbs{'socket'} = db 'socket' => sub {
            db_common($dbname);

            if ($dbname eq 'PostgreSQL') {
                db_socket $dbc->dir; # Bug in DBIx::QuickDB?
            }
            else {
                db_socket $dbc->socket;
            }
        };
    }

    for my $id (keys %dbs) {
        my $db = $dbs{$id};

        isa_ok(
            $db,
            ["DBIx::QuickORM::DB", "DBIx::QuickORM::DB::$dbname"],
            "Got the database instance ($id)",
        );

        my $con = $db->connect;
        isa_ok($con, ['DBIx::QuickORM::Connection'], "Can get database connection");
        isa_ok($con->dbh, ['DBI::db'], "Can get a dbh");

        is($db->db_name, 'quickdb', "Set the db name");

        isa_ok($db->sql_spec, ['DBIx::QuickORM::SQLSpec'], "Specs object");
        is(
            $db->sql_spec,
            {'overrides' => {}, 'global' => {'foo' => 'bar'}},
            "Specs are set"
        );

        is($db->user, '', "User is set to empty string");
        is($db->password, '', "Password is set to empty string");
    }
};

dbs_do orm => sub {
    my ($dbname, $dbc, $st) = @_;
    imported_ok('orm');

    my $sth = $dbc->connect->do(<<"    EOT");
    CREATE TABLE orm_test(
        orm_test_id     INTEGER     PRIMARY KEY
    );
    EOT

    my $foo = orm foo => sub {
        db foo => sub {
            db_common($dbname);
            db_connect sub { $dbc->connect };
        };

        schema foo => sub {
            autofill 0;

            table foo => sub {
                column foo_id => sub {
                    primary_key;
                    serial;
                    sql_spec(
                        mysql      => {type => 'INTEGER'},
                        postgresql => {type => 'SERIAL'},
                        sqlite     => {type => 'INTEGER'},
                        type       => 'INTEGER',    # Fallback
                    );
                };

                column name => sub {
                    unique;
                    sql_spec(type => 'VARCHAR(128)');
                };
            };
        };
    };

    isa_ok($foo,             ['DBIx::QuickORM::ORM'],        "Got an orm instance");
    isa_ok($foo->db,         ['DBIx::QuickORM::DB'],         "Can get the db");
    isa_ok($foo->schema,     ['DBIx::QuickORM::Schema'],     "Can get the schema");
    isa_ok($foo->connection, ['DBIx::QuickORM::Connection'], "Can get the connection");

    if(ok(my $source = $foo->source('foo'), "Can get source for table")) {
        isa_ok($source, ['DBIx::QuickORM::Source'],  "Can get a table source");
    }

    like(
        dies { $foo->source('orm_test') },
        qr{'orm_test' is not defined in the schema as a table/view, or temporary table/view},
        "Cannot get source for orm_test because we did not specify it in the schema, and autofill was turned off"
    );

    my $bar = orm bar => sub {
        db foo => sub {
            db_common($dbname);
            db_connect sub { $dbc->connect };
        };

        schema foo => sub {
            autofill 1;
        };
    };

    isa_ok($bar,             ['DBIx::QuickORM::ORM'],        "Got an orm instance");
    isa_ok($bar->db,         ['DBIx::QuickORM::DB'],         "Can get the db");
    isa_ok($bar->schema,     ['DBIx::QuickORM::Schema'],     "Can get the schema");
    isa_ok($bar->connection, ['DBIx::QuickORM::Connection'], "Can get the connection");

    if(ok(my $source = $bar->source('orm_test'), "Can get source for table")) {
        isa_ok($source, ['DBIx::QuickORM::Source'],  "Can get a table source");

        ok(my $table = $source->table, "Got table");
        isa_ok($table, ['DBIx::QuickORM::Table'], "Table is the correct type");

        ok(!$table->is_temp, "Not a temporary table");
        ok(!$table->is_view, "Not a view");
        is($table->primary_key, ['orm_test_id'], "Got primary key columns");
        is($table->name, 'orm_test', "Got correct table name");
        isa_ok($table->column('orm_test_id'), ['DBIx::QuickORM::Table::Column'], "Can get column definition");
    }

    like(
        dies { orm 'xxx', "foo", "bar"; },
        qr/The `orm\(name, db, schema\)` form can only be used under a mixer builder/,
        "orm(name, db, schema) outside of mixer"
    );

    local %STATE = (MIXER => { dbs => {}, schemas => {} });

    like(
        dies { orm 'xxx', "foo", "bar"; },
        qr/The 'foo' database is not defined/,
        "Invalid db",
    );

    $STATE{MIXER}{dbs}{foo} = 1;

    like(
        dies { orm 'xxx', "foo", "bar"; },
        qr/The 'bar' schema is not defined/,
        "Invalid schema",
    );

    local %STATE;

    like(
        dies {
            my $orm = orm sub {
                db xyz => sub { db_common(); db_class 'SQLite'; db_connect sub {} };
                $STATE{DB} = {class => 'SQLite'};
            },
        },
        qr/orm was given more than 1 database/,
        "Cannot provide multiple DBs"
    );

    local %STATE;

    like(
        dies {
            my $orm = orm sub {
                db xyz => sub { db_common(); db_class 'SQLite'; db_connect sub {} };
                my %s;
                schema yyy => sub { %s = %{$STATE{SCHEMA}} };
                $STATE{SCHEMA} = \%s;
            },
        },
        qr/orm was given more than 1 schema/,
        "Cannot provide multiple schemas"
    );

};

#sub orm {
#    my $cb       = ref($_[-1]) eq 'CODE' ? pop : undef;
#    my $new_args = ref($_[-1]) eq 'HASH' ? pop : {};
#    my ($name, $db, $schema) = @_;
#
#    my @caller = caller;
#
#    my %params = (
#        name    => $name // 'orm',
#        created => "$caller[1] line $caller[2]",
#        plugins => _push_plugins(),
#    );
#
#    if ($db || $schema) {
#        my $mixer = $STATE{MIXER} or croak "The `orm(name, db, schema)` form can only be used under a mixer builder";
#
#        if ($db) {
#            $params{db} = $mixer->{dbs}->{$db} or croak "The '$db' database is not defined";
#        }
#        if ($schema) {
#            $params{schema} = $mixer->{schemas}->{$schema} or croak "The '$schema' schema is not defined";
#        }
#    }
#
#    local $STATE{PLUGINS} = $params{plugins};
#    local $STATE{ORM}    = \%params;
#    local $STATE{STACK}   = ['ORM', @{$STATE{STACK} // []}];
#
#    local $STATE{DB}        = undef;
#    local $STATE{RELATIONS} = undef;
#    local $STATE{SCHEMA}    = undef;
#
#    set_subname('orm_callback', $cb) if subname($cb) ne '__ANON__';
#    $cb->(%STATE);
#
#    if (my $db = delete $STATE{DB}) {
#        $db = _build_db($db);
#        croak "orm was given more than 1 database" if $params{db};
#        $params{db} = $db;
#    }
#
#    if (my $schema = delete $STATE{SCHEMA}) {
#        $schema = _build_schema($schema);
#        croak "orm was given more than 1 schema" if $params{schema};
#        $params{schema} = $schema;
#    }
#
#    require DBIx::QuickORM::ORM;
#    my $orm = DBIx::QuickORM::ORM->new(%params, %$new_args);
#
#    if (my $mixer = $STATE{MIXER}) {
#        $mixer->{orms}->{$name} = $orm;
#    }
#    else {
#        croak "Cannot be called in void context outside of a mixer without a symbol name"
#            unless defined($name) || defined(wantarray);
#
#        if ($name && !defined(wantarray)) {
#            no strict 'refs';
#            *{"$caller[0]\::$name"} = set_subname $name => sub { $orm };
#        }
#    }
#
#    return $orm;
#}


subtest mixer => sub {
    my @dbs = all_dbs();
    my @orms;
    my $mixer = mixer sub {
        schema empty => sub {};

        schema manual => sub {
            table mixer_test => sub {
                column 'mixer_test_id';
                primary_key 'mixer_test_id';
            };
        };

        for my $dbs (@dbs) {
            my ($dbname, $dbc) = @$dbs;

            my $sth = $dbc->connect->do(<<"            EOT");
            CREATE TABLE mixer_test(
                mixer_test_id     INTEGER     PRIMARY KEY
            );
            EOT

            db $dbname => sub {
                db_common($dbname);
                db_connect sub { $dbc->connect };
            };

            for my $schema (qw/empty manual/) {
                push @orms => "$schema + $dbname";
                orm "$schema + $dbname" => sub {
                    db $dbname;
                    schema $schema;
                };
            }
        }
    };

    isa_ok($mixer->database($_->[0]), ['DBIx::QuickORM::DB'], "Got db '$_->[0]'") for @dbs;

    isa_ok($mixer->schema('empty'), ['DBIx::QuickORM::Schema'], "Got empty schema");
    isa_ok($mixer->schema('manual'), ['DBIx::QuickORM::Schema'], "Got manual schema");

    ok(@orms, "Got some orms");

    for my $orm_name (@orms) {
        ok(my $orm = $mixer->orm($orm_name), "Can get orm '$orm_name'");
        isa_ok($orm, ['DBIx::QuickORM::ORM'], "orm '$orm_name' is the right type");
    }

    {
        local *my_mixer;
        not_imported_ok('my_mixer');
        mixer my_mixer => sub {};
        imported_ok('my_mixer');
        isa_ok(my_mixer(), ['DBIx::QuickORM::Mixer'], "Got the mixer via injected sub");
    }
    ok(!__PACKAGE__->can('my_mixer'), "Removed symbol when done with it");

    like(
        dies { mixer sub { } },
        qr/Cannot be called in void context without a symbol name/,
        "Need non-void or a symbol name"
    );
};

subtest accessor => sub {
    my $s = schema s => sub {
        table table_a => sub { columns 'foo' };
        table table_b => sub { columns 'foo' };

        relation sub {
            member 'table_a' => sub {
                accessor 'tb';
                columns 'foo';
            };

            member 'table_b' => sub {
                accessor 'ta';
                columns 'foo';
            };
        };
    };

    like(
        [$s->relations],
        [{
            tables    => [{accessor => 'tb'}, {accessor => 'ta'}],
            accessors => {table_a => {tb => T()}, table_b => {ta => T()}},
        }],
        "Added accessors correctly"
    );
};

done_testing;

__END__

sub plugins { $STATE{PLUGINS} // do { require DBIx::QuickORM::PluginSet; DBIx::QuickORM::PluginSet->new } }

sub add_plugin {
    my ($in, %params) = @_;

    my $before = delete $params{before_parent};
    my $after  = delete $params{after_parent};

    croak "Cannot add a plugin both before AND after the parent" if $before && $after;

    my $plugins = $STATE{PLUGINS} or croak "Must be used under a supported builder, no builder that accepts plugins found";

    if ($before) {
        $plugins->unshift_plugin($in, %params);
    }
    else {
        $plugins->push_plugin($in, %params);
    }
}

sub _push_plugins {
    require DBIx::QuickORM::PluginSet;

    if (my $parent = $STATE{PLUGINS}) {
        return DBIx::QuickORM::PluginSet->new(parent => $parent);
    }

    return DBIx::QuickORM::PluginSet->new;
}

sub autofill {
    my ($val) = @_;
    $val //= 1;

    my $orm = $STATE{ORM} or croak "This can only be used inside a orm builder";

    $orm->{autofill} = $val;
}

sub _new_db_params {
    my ($name, $caller) = @_;

    return (
        name       => $name,
        created    => "$caller->[1] line $caller->[2]",
        db_name    => $name,
        attributes => {},
        plugins    => _push_plugins(),
    );
}

sub _build_db {
    my $params = shift;

    my $class  = delete($params->{class}) or croak "You must specify a db class such as: PostgreSQL, MariaDB, Percona, MySQL, or SQLite";
    $class = "DBIx::QuickORM::DB::$class" unless $class =~ s/^\+// || $class =~ m/^DBIx::QuickORM::DB::/;

    eval { require(mod2file($class)); 1 } or croak "Could not load $class: $@";
    return $class->new(%$params);
}

sub db {
    my ($name, $cb) = @_;

    my $orm   = $STATE{ORM};
    my $mixer = $STATE{MIXER};

    my $db;

    if ($cb) {
        my @caller = caller;

        my %params = _new_db_params($name => \@caller);

        local $STATE{PLUGINS} = $params{plugins};
        local $STATE{DB}      = \%params;
        local $STATE{STACK}   = ['DB', @{$STATE{STACK} // []}];

        set_subname('db_callback', $cb) if subname($cb) ne '__ANON__';
        $cb->(%STATE);

        $db = _build_db(\%params);

        if ($mixer) {
            croak "Quick ORM mixer already has a db named '$name'" if $mixer->{dbs}->{$name};
            $mixer->{dbs}->{$name} = $db;
        }
    }
    else {
        croak "db() requires a builder block unless it is called under both a 'mixer' and 'orm' block" unless $orm && $mixer;

        $db = $mixer->{dbs}->{$name} or croak "the '$name' database is not defined under the current mixer";
    }

    if ($orm) {
        croak "Quick ORM instance already has a db" if $orm->{db};
        $orm->{db} = $db;
    }

    return $db;
}

sub _get_db {
    return $STATE{DB} if $STATE{DB};
    return unless $STATE{ORM};

    croak "Attempt to use db builder tools outside of a db builder in an orm that already has a db defined"
        if $STATE{ORM}->{db};

    my %params = _new_db_params(default => [caller(1)]);

    $STATE{DB} = \%params;
}

sub db_attributes {
    my %attrs = @_ == 1 ? (%{$_[0]}) : (@_);

    my $db = _get_db() or croak "attributes() must be called inside of a db or ORM builer";
    %{$db->{attributes} //= {}} = (%{$db->{attributes} // {}}, %attrs);

    return $db->{attributes};
}

sub db_connect {
    my ($in) = @_;

    my $db = _get_db() or croak "connect() must be called inside of a db or ORM builer";

    if (ref($in) eq 'CODE') {
        return $db->{connect} = $in;
    }

    my $code = do { no strict 'refs'; \&{$in} };
    croak "'$in' does not appear to be a defined subroutine" unless defined(&$code);
    return $db->{connect} = $code;
}

BEGIN {
    for my $db_field (qw/db_class db_name db_dsn db_host db_socket db_port db_user db_password/) {
        my $name = $db_field;
        my $attr = $name;
        $attr =~ s/^db_// unless $attr eq 'db_name';
        my $sub  = sub {
            my $db = _get_db() or croak "$name() must be called inside of a db builer";
            $db->{$attr} = $_[0];
        };

        no strict 'refs';
        *{$name} = set_subname $name => $sub;
    }
}

sub _new_schema_params {
    my ($name, $caller) = @_;

    return (
        name      => $name,
        created   => "$caller->[1] line $caller->[2]",
        relations => [],
        includes  => [],
        plugins   => _push_plugins(),
    );
}

sub _build_schema {
    my $params = shift;

    require DBIx::QuickORM::Schema::RelationSet;
    $params->{relations} = DBIx::QuickORM::Schema::RelationSet->new(@{$params->{relations} // []});

    my $includes = delete $params->{includes};
    my $class    = delete($params->{schema_class}) // first { $_ } (map { $_->schema_class(%$params, %STATE) } @{$params->{plugins}->all}), 'DBIx::QuickORM::Schema';
    eval { require(mod2file($class)); 1 } or croak "Could not load class $class: $@";
    my $schema = $class->new(%$params);
    $schema = $schema->merge($_) for @$includes;

    return $schema;
}

sub schema {
    my ($name, $cb) = @_;

    my $orm   = $STATE{ORM};
    my $mixer = $STATE{MIXER};

    my $schema;

    if ($cb) {
        my @caller = caller;

        my %params = _new_schema_params($name => \@caller);

        local $STATE{STACK}     = ['SCHEMA', @{$STATE{STACK} // []}];
        local $STATE{SCHEMA}    = \%params;
        local $STATE{SOURCES}   = {};
        local $STATE{PLUGINS}   = $params{plugins};
        local $STATE{RELATIONS} = $params{relations};

        local $STATE{COLUMN};
        local $STATE{RELATION};
        local $STATE{MEMBER};
        local $STATE{TABLE};

        set_subname('schema_callback', $cb) if subname($cb) ne '__ANON__';
        $cb->(%STATE);

        $schema = _build_schema(\%params);

        if ($mixer) {
            croak "A schema with name '$name' is already defined" if $mixer->{schemas}->{$name};

            $mixer->{schemas}->{$name} = $schema;
        }
    }
    else {
        croak "schema() requires a builder block unless it is called under both a 'mixer' and 'orm' block" unless $orm && $mixer;

        $schema = $mixer->{schemas}->{$name} or croak "the '$name' schema is not defined under the current mixer";
    }

    if ($orm) {
        croak "This orm instance already has a schema" if $orm->{schema};
        $orm->{schema} = $schema;
    }

    return $schema;
}

sub _get_schema {
    return $STATE{SCHEMA} if $STATE{SCHEMA};
    return unless $STATE{ORM};

    croak "Attempt to use schema builder tools outside of a schema builder in an orm that already has a schema defined"
        if $STATE{ORM}->{schema};

    my %params = _new_schema_params(default => [caller(1)]);

    $STATE{RELATIONS} = $params{relations};
    $STATE{SCHEMA}    = \%params;

    return $STATE{SCHEMA};
}

sub include {
    my @schemas = @_;

    my $schema = _get_schema() or croak "'include()' can only be used inside a 'schema' builder";

    my $mixer = $STATE{MIXER};

    for my $item (@schemas) {
        my $it;
        if ($mixer) {
            $it = blessed($item) ? $item : $mixer->{schemas}->{$item};
            croak "'$item' is not a defined schema inside the current mixer" unless $it;
        }
        else {
            $it = $item;
        }

        croak "'" . ($it // $item) . "' is not an instance of 'DBIx::QuickORM::Schema'" unless $it && blessed($it) && $it->isa('DBIx::QuickORM::Schema');

        push @{$schema->{include} //= []} => $it;
    }

    return;
}

sub tables {
    my ($prefix) = @_;

    die "TODO";

    # Iterate all $prefix::NAME classes, load them, and add their tables/relations
}

sub rogue_table {
    my ($name, $cb) = @_;

    # Must localize and assign seperately.
    local $STATE{PLUGINS};
    $STATE{PLUGINS} = _push_plugins();

    local $STATE{STACK}     = [];
    local $STATE{SCHEMA}    = undef;
    local $STATE{MIXER}     = undef;
    local $STATE{SOURCES}   = undef;
    local $STATE{RELATIONS} = undef;
    local $STATE{COLUMN}    = undef;
    local $STATE{RELATION}  = undef;
    local $STATE{MEMBER}    = undef;
    local $STATE{TABLE}     = undef;

    return _table($name, $cb);
}

sub _table {
    my ($name, $cb, %params) = @_;

    my @caller = caller(1);
    $params{name} = $name;
    $params{created} //= "$caller[1] line $caller[2]";
    $params{indexes} //= {};
    $params{plugins} = _push_plugins();

    local $STATE{PLUGINS} = $params{plugins};
    local $STATE{TABLE}   = \%params;
    local $STATE{STACK}   = ['TABLE', @{$STATE{STACK} // []}];

    set_subname('table_callback', $cb) if subname($cb) ne '__ANON__';
    $cb->(%STATE);

    for my $cname (keys %{$params{columns}}) {
        my $spec = $params{columns}{$cname};
        my $class = delete($spec->{column_class}) || $params{column_class} || ($STATE{SCHEMA} ? $STATE{SCHEMA}->{column_class} : undef ) || 'DBIx::QuickORM::Table::Column';
        eval { require(mod2file($class)); 1 } or die "Could not load column class '$class': $@";
        $params{columns}{$cname} = $class->new(%$spec);
    }

    my $class = delete($params{table_class}) // first { $_ } (map { $_->table_class(%params, %STATE) } @{$params{plugins}->all}), 'DBIx::QuickORM::Table';
    eval { require(mod2file($class)); 1 } or croak "Could not load class $class: $@";
    return $class->new(%params);
}

sub table {
    return _member_table(@_) if $STATE{MEMBER};

    my $schema = _get_schema() or croak "table() can only be used inside a schema, orm, or member builder";

    my ($name, $cb) = @_;

    my %params;

    local $STATE{COLUMN};
    local $STATE{RELATION};
    local $STATE{MEMBER};

    my $table = _table($name, $cb, %params);

    if (my $names = $STATE{NAMES}) {
        if (my $have = $names->{$name}) {
            croak "There is already a source named '$name' ($have) from " . ($have->created // '');
        }

        $names->{$name} = $table;
    }

    croak "Table '$table' is already defined" if $schema->{tables}->{$name};
    $schema->{tables}->{$name} = $table;

    return $table;
}

sub meta_table {
    my ($name, $cb) = @_;

    my $caller = caller;

    local %STATE;

    my @relations;
    local $STATE{RELATIONS} = \@relations;
    my $table = _table($name, $cb, row_base_class => $caller);

    my $relations = DBIx::QuickORM::Schema::RelationSet->new(@relations);

    {
        no strict 'refs';
        *{"$caller\::orm_table"}     = set_subname orm_table     => sub { $table };
        *{"$caller\::orm_relations"} = set_subname orm_relations => sub { $relations };
        push @{"$caller\::ISA"} => 'DBIx::QuickORM::Row';
    }

    return $table;
}

BEGIN {
    my @CLASS_SELECTORS = (
        ['column_class',   'COLUMN',   'TABLE',    'SCHEMA'],
        ['relation_class', 'RELATION', 'SCHEMA'],
        ['row_base_class', 'TABLE',    'SCHEMA'],
        ['table_class',    'TABLE',    'SCHEMA'],
        ['source_class',   'TABLE'],
    );

    for my $cs (@CLASS_SELECTORS) {
        my ($name, @states) = @$cs;

        my $code = sub {
            my ($class) = @_;
            eval { require(mod2file($class)); 1 } or croak "Could not load class $class: $@";

            for my $state (@states) {
                my $params = $STATE{$state} or next;
                return $params->{$name} = $class;
            }

            croak "$name() must be called inside one of the following builders: " . join(', ' => map { lc($_) } @states);
        };

        no strict 'refs';
        *{$name} = set_subname $name => $code;
    }
}

sub sql_spec {
    my %hash = @_ == 1 ? %{$_[0]} : (@_);

    my ($state) = @{$STATE{STACK} // []};
    croak "Must be called inside a builder" unless $state;

    my $params = $STATE{$state} or croak "Must be called inside a builder";

    my $specs = $params->{sql_spec} //= {};

    %$specs = (%$specs, %hash);

    return $specs;
}

# relation(table => \@cols);
# relation(table1 => \@cols, table2 => \@cols);
# relation({name => TABLE, columns => \@cols, accessor => FOO})
# relation({name => TABLE, columns => \@cols, accessor => FOO} ...)
# relation(table_1 => {accessor => foo, cols => \@cols);
# relation(table_1 => {accessor => foo}, \@cols
# relation(sub { ... })
#
# table foo => sub {
#   relation(\@cols, $table2 => \@cols);
#
#   relation => sub {
#       member \@cols;
#       member table_2 => \@cols;
#   };
# };
#
# table foo => sub {
#   column foo => sub {
#       relation(second_table => \@cols)
#   };
# };

sub relation {
    my $relations = $STATE{RELATIONS} or croak "No 'relations' store found, must be nested under a schema or meta_table builder";

    my @caller = caller;
    my %params = (
        created => "$caller[1] line $caller[2]",
        tables => [],
        plugins => _push_plugins(),
    );

    local $STATE{PLUGINS}  = $params{plugins};
    local $STATE{RELATION} = \%params;
    local $STATE{STACK}    = ['RELATION', @{$STATE{STACK} // []}];
    local $STATE{MEMBER};

    my %added;

    my $add = set_subname 'relation_add' => sub {
        my $m = shift;
        return if $added{$m};

        use Data::Dumper;
        print Dumper($m);

        confess "Member incomplete, no table name" unless $m->{table};
        confess "Member incomplete, no columns"    unless $m->{columns};

        push @{$params{tables}} => $m;
        $added{$m} = 1;
        return $m;
    };

    if (my $table = $STATE{TABLE}) {
        if (my $col = $STATE{COLUMN}) {
            $STATE{MEMBER} = {table => $table->{name}, columns => [$col->{name}], created => $params{created}};
        }
        else {
            $STATE{MEMBER} = {table => $table->{name}, created => $params{created}};
        }
    }

    while (my $arg = shift @_) {
        my $type = ref($arg);

        if ($type eq 'CODE') {
            local $STATE{MEMBER} = $STATE{MEMBER};
            set_subname('relation_callback', $arg) if subname($arg) ne '__ANON__';
            $arg->(%STATE);
            next;
        }

        if (!$type) { # Table name
            $add->(delete $STATE{MEMBER}) if $STATE{MEMBER};

            $STATE{MEMBER} = {table => $arg, created => $params{created}};
            croak "Too many members for relation" if @{$params{tables}} > 2;
            next;
        }

        if ($type eq 'HASH') {
            my $member = $STATE{MEMBER} //= {created => $params{created}};

            if ($member->{table} && $arg->{table}) {
                $add->($member);
                $member = $STATE{MEMBER} = {created => $params{created}};
            }

            croak "Hashref argument must include the 'table' key, or come after a table name argument"
                unless $member->{table} || $arg->{table};

            for my $field (qw/table accessor columns created reference on_delete precache/) {
                next unless $arg->{$field};
                croak "Member already has '$field' set" if $member->{$field} && $field ne 'created';
                $member->{$field} = delete $arg->{$field};
            }

            my @bad = sort keys %$arg;
            next unless @bad;
            croak "Invalid member keys: " . join(', ' => @bad);
        }

        if ($type eq 'ARRAY') {
            my $member = $STATE{MEMBER} or croak "Arrayref arg must come after a table name is specified";
            croak "Tried to specify member columns multiple times" if $member->{columns};
            $member->{columns} = $arg;
            next;
        }

        croak "Invalid arg to relartion: $arg";
    }

    $add->(delete $STATE{MEMBER}) if $STATE{MEMBER};

    my $class = delete($params{relation_class}) // first { $_ } (map { $_->relation_class(%params, %STATE) } @{$params{plugins}->all}), 'DBIx::QuickORM::Relation';
    eval { require(mod2file($class)); 1 } or croak "Could not load class $class: $@";
    my $rel = $class->new(%params);
    push @$relations => $rel;

    return $rel;
}

sub member {
    my (@specs) = @_;

    my $relation = $STATE{RELATION} or croak "member() must be nested under a relation builder";

    my @caller = caller;
    my %params = (
        created => "$caller[1] line $caller[2]",
    );
    local $STATE{MEMBER} = \%params;

    my $c = 0;
    while (my $arg = shift @_) {
        $c++;
        my $type = ref($arg);

        if ($type eq 'CODE') {
            set_subname('member_callback', $arg) if subname($arg) ne '__ANON__';
            $arg->(%STATE);
            next;
        }

        if (!$type) { # Table name
            if ($c == 1) {
                croak "Member name already set" if $params{table};
                $params{table} = $arg;
                next;
            }
            else {
                croak "Accessor name already set" if $params{accessor};
                $params{accessor} = $arg;
                next;
            }
        }

        if ($type eq 'HASH') {
            for my $field (qw/table accessor columns reference created on_delete precache/) {
                next unless $arg->{$field};
                croak "Member '$field' already set" if $params{$field} && $field ne 'created';
                $params{$field} = delete $arg->{$field};
            }

            my @bad = sort keys %$arg;
            next unless @bad;
            croak "Invalid member keys: " . join(', ' => @bad);
        }

        if ($type eq 'ARRAY') {
            croak "Tried to specify member columns multiple times" if $params{columns};
            $params{columns} = $arg;
            next;
        }

        croak "Invalid arg to relation: $arg";
    }

    if (my $table = $STATE{TABLE}) {
        $STATE{MEMBER}->{table} //= $table->{name};
    }

    push @{$relation->{tables} //= []} => \%params;

    return \%params;
}

sub references {
    my $ref_extra = {};

    my @args;
    for my $arg (@_) {
        if (ref($arg) eq 'HASH' && ($arg->{on_delete} || $arg->{precache})) {
            $ref_extra = $arg;
            next;
        }

        push @args => $arg;
    }

    if (my $member = $STATE{MEMBER}) {
        $member->{reference} = 1;
        $member->{on_delete} //= $ref_extra->{on_delete} if $ref_extra->{on_delete};
        $member->{precache}  //= $ref_extra->{precache}  if $ref_extra->{precache};
        member(@args) if @args;
        return;
    }

    if (my $table = $STATE{TABLE}) {
        if (my $col = $STATE{COLUMN}) {
            relation(
                {reference => 1, %$ref_extra},
                @args,
            );
            return;
        }

        if (@args && ref($args[0]) eq 'ARRAY') {
            my $cols = shift;
            relation(
                {columns => $cols, reference => 1, %$ref_extra},
                @args,
            );
            return;
        }

        croak "references() under a 'table' builder must either start with an arrayref of columns, or be inside a 'column' builder";
    }

    croak "references() must be used under either a 'table' builder or a 'member' builder";
}

sub accessor {
    my ($accessor) = @_;

    my $member = $STATE{MEMBER} or croak "accessor() can only be used inside a 'member', or a 'relation' builder used under a 'column' builder";

    croak "Member already has an accessor ('$member->{accessor}' vs '$accessor')" if $member->{accessor};

    $member->{accessor} = $accessor;
}

sub on_delete {
    my ($on_delete) = @_;

    my $member = $STATE{MEMBER} or croak "on_delete() can only be used inside a 'member', or a 'relation' builder used under a 'column' builder";

    croak "Member already has an on_delete ('$member->{on_delete}' vs '$on_delete')" if $member->{on_delete};

    $member->{on_delete} = $on_delete;
}

sub precache {
    my ($precache) = @_;

    my $member = $STATE{MEMBER} or croak "precache() can only be used inside a 'member', or a 'relation' builder used under a 'column' builder";

    $member->{precache} = $precache;
}

sub _member_table {
    my ($name, @extra) = @_;
    croak "Too many arguments for table under a member builder ($STATE{MEMBER}->{name}, $STATE{MEMBER}->{created})" if @extra;
    my $member = $STATE{MEMBER}->{table};
    $member->{table} = $name;
}

sub is_view {
    my $table = $STATE{TABLE} or croak "is_view() may only be used in a table builder";
    $table->{is_view} = 1;
}

sub is_temp {
    my $table = $STATE{TABLE} or croak "is_temp() may only be used in a table builder";
    $table->{is_temp} = 1;
}

sub columns {
    my @specs = @_;

    @specs = @{$specs[0]} if @specs == 1 && ref($specs[0]) eq 'ARRAY';

    my @caller = caller;
    my $created = "$caller[1] line $caller[2]";

    my $member = $STATE{MEMBER};

    my $table;
    if ($member) {
        if (my $schema = $STATE{SCHEMA}) {
            $table = $schema->{tables}->{$member->{table}} if $member->{table};
        }
    }
    else {
        $table = $STATE{TABLE} or croak "columns may only be used in a table or member builder";
    }

    my $sql_spec = pop(@specs) if $table && @specs && ref($specs[-1]) eq 'HASH';

    while (my $name = shift @specs) {
        my $spec = @specs && ref($specs[0]) ? shift(@specs) : undef;
        croak "Cannot specify column data or builder under a member builder" if $member && $spec;

        push @{$member->{columns} //= []} => $name if $member;

        if ($table) {
            if ($spec) {
                my $type = ref($spec);
                if ($type eq 'HASH') {
                    $table->{columns}->{$name}->{$_} = $spec->{$_} for keys %$spec;
                }
                elsif ($type eq 'CODE') {
                    local $STATE{COLUMN} = $table->{columns}->{$name} //= {created => $created, name => $name};
                    local $STATE{STACK}  = ['COLUMN', @{$STATE{STACK} // []}];
                    set_subname('column_callback', $spec) if subname($spec) ne '__ANON__';
                    eval { $spec->(%STATE); 1 } or croak "Failed to build column '$name': $@";
                }
            }
            else {
                $table->{columns}->{$name} //= {created => $created, name => $name};
            }

            $table->{columns}->{$name}->{name}  //= $name;
            $table->{columns}->{$name}->{order} //= $COL_ORDER++;

            %{$table->{columns}->{$name}->{sql_spec} //= {}} = (%{$table->{columns}->{$name}->{sql_spec} //= {}}, %$sql_spec)
                if $sql_spec;
        }
        elsif ($spec) {
            croak "Cannot specify column data outside of a table builder";
        }
    }
}

BEGIN {
    my @COL_ATTRS = (
        [unique      => set_subname(unique_col_val => sub { @{$_[0]} > 1 ? undef : 1 }), {index => 'unique'}],
        [primary_key => set_subname(unique_pk_val => sub { @{$_[0]} > 1 ? undef : 1 }),  {set => 'primary_key', index => 'unique'}],
        [serial      => 1,                                                               {set => 'serial'}],
        [not_null    => 0,                                                               {set => 'nullable'}],
        [nullable    => sub { $_[0] // 1 },                                              {set => 'nullable'}],
        [omit        => 1],
        [
            default => set_subname default_col_val => sub {
                my $sub = shift(@{$_[0]});
                croak "First argument to default() must be a coderef" unless ref($sub) eq 'CODE';
                return $sub;
            },
        ],
        [
            conflate => set_subname conflate_col_val => sub {
                my $class = shift(@{$_[0]});
                eval { require(mod2file($class)); 1 } or croak "Could not load class $class: $@";
                return $class;
            },
        ],
    );
    for my $col_attr (@COL_ATTRS) {
        my ($attr, $val, $params) = @$col_attr;

        my $code = sub {
            my @cols = @_;

            my $val = ref($val) ? $val->(\@cols) : $val;

            my $table = $STATE{TABLE} or croak "$attr can only be used inside a column or table builder";

            if (my $column = $STATE{COLUMN}) {
                croak "Cannot provide a list of columns inside a column builder ($column->{created})" if @cols;
                $column->{$attr} = $val;
                @cols = ($column->{name});
                $column->{order} //= $COL_ORDER++;
            }
            else {
                croak "Must provide a list of columns when used inside a table builder" unless @cols;

                my @caller  = caller;
                my $created = "$caller[1] line $caller[2]";

                for my $cname (@cols) {
                    my $col = $table->{columns}->{$cname} //= {created => $created, name => $cname};
                    $col->{$attr} = $val if defined $val;
                    $col->{order} //= $COL_ORDER++;
                }
            }

            my $ordered;

            if (my $key = $params->{set}) {
                $ordered //= [sort @cols];
                $table->{$key} = $ordered;
            }

            if (my $key = $params->{index}) {
                $ordered //= [sort @cols];
                my $index = join ', ' => @$ordered;
                $table->{$key}->{$index} = $ordered;
            }

            return @cols;
        };

        no strict 'refs';
        *{$attr} = set_subname $attr => $code;
    }
}

sub index {
    my $idx;

    my $table = $STATE{TABLE} or croak "Must be used under table builder";

    if (@_ == 0) {
        croak "Arguments are required";
    }
    elsif (@_ > 1) {
        my $name = shift;
        my $sql_spec = ref($_[0]) eq 'HASH' ? shift : undef;
        my @cols = @_;

        croak "A name is required as the first argument" unless $name;
        croak "A list of column names is required" unless @cols;

        $idx = {name => $name, columns => \@cols};
        $idx->{sql_spec} = $sql_spec if $sql_spec;
    }
    else {
        croak "1-argument form must be a hashref, got '$_[0]'" unless ref($_[0]) eq 'HASH';
        $idx = { %{$_[0]} };
    }

    my $name = $idx->{name};

    croak "Index '$name' is already defined on table" if $table->{indexes}->{$name};

    unless ($idx->{created}) {
        my @caller  = caller;
        $idx->{created} = "$caller[1] line $caller[2]";
    }

    $table->{indexes}->{$name} = $idx;
}

1;
