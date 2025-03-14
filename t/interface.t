use Test2::V0 -target => 'DBIx::QuickORM';
#use Carp::Always;

{
    package DBIx::QuickORM::ORM;
    $INC{'DBIx/QuickORM/ORM.pm'} = __FILE__;
    use DBIx::QuickORM::Util::HashBase;

    package DBIx::QuickORM::Schema;
    $INC{'DBIx/QuickORM/Schema.pm'} = __FILE__;
    use DBIx::QuickORM::Util::HashBase;

    package DBIx::QuickORM::Schema::Table;
    $INC{'DBIx/QuickORM/Schema/Table.pm'} = __FILE__;
    use DBIx::QuickORM::Util::HashBase;

    package DBIx::QuickORM::Schema::Table::Column;
    $INC{'DBIx/QuickORM/Schema/Table/Column.pm'} = __FILE__;
    use DBIx::QuickORM::Util::HashBase;

    package DBIx::QuickORM::DB;
    $INC{'DBIx/QuickORM/DB.pm'} = __FILE__;
    use DBIx::QuickORM::Util::HashBase;

    package DBIx::QuickORM::DB::Fake;
    $INC{'DBIx/QuickORM/DB/Fake.pm'} = __FILE__;
    our @ISA = ('DBIx::QuickORM::DB');
    use DBIx::QuickORM::Util::HashBase;

    package DBIx::QuickORM::Plugin;
    $INC{'DBIx/QuickORM/Plugin.pm'} = __FILE__;
    use DBIx::QuickORM::Util::HashBase;

    package DBIx::QuickORM::Plugin::My::Plugin;
    $INC{'DBIx/QuickORM/Plugin/My/Plugin.pm'} = __FILE__;
    our @ISA = ('DBIx::QuickORM::Plugin');
    use DBIx::QuickORM::Util::HashBase;
}

{
    package Test::ORM;
    use Test2::V0 qw/!meta !pass/;

    use ok 'DBIx::QuickORM';

    imported_ok(qw{
        plugin
        plugins
        meta
        orm

        build_class

        server
         driver
         attributes
         host
         port
         socket
         user
         pass
         db
          connect
          dsn

        schema
         alt
         row_class
         table
          db_name
          column
           affinity
           conflate
           omit
           nullable
           identity
           type
           size
          columns
          primary_key
          unique
         link

        builder
        import
    });

    my $bld = __PACKAGE__->builder;
    isa_ok($bld, ['DBIx::QuickORM'], "Got an instance");
    ref_is(builder(), $bld, "Can be called as a method or a function");

    ref_is(
        $bld->top,
        $bld->{stack}->[-1],
        "Cann access top build"
    );

    ok(!$bld->top->{building}, "Top level is not building anything");

    like(dies { alt foo => sub { 1 } }, qr/alt\(\) cannot be used outside of a builder/, "Cannot use alt outside of a builder");

    like(
        dies { plugin(bless({}, 'FooBar')) },
        qr/is not an instance of 'DBIx::QuickORM::Plugin' or a subclass of it/,
        "Must be a valid plugin"
    );

    like(
        dies { plugin(bless({}, 'DBIx::QuickORM::Plugin'), "foo") },
        qr/Cannot pass in both a blessed plugin instance and constructor arguments/,
        "Cannot combine blessed instance and construction args"
    );

    like(
        dies { plugin('+DBIx::QuickORM') },
        qr/DBIx::QuickORM is not a subclass of DBIx::QuickORM::Plugin/,
        "Not a valid plugin, but real class"
    );

    like(
        dies { plugin('DBIx::QuickORM::Plugin::This::Is::A::Fake::Plugin') },
        qr{Could not load plugin 'DBIx::QuickORM::Plugin::This::Is::A::Fake::Plugin': Can't locate DBIx/QuickORM/Plugin/This/Is/A/Fake/Plugin\.pm in \@INC},
        "Not a valid plugin, but real class"
    );

    ok(lives { plugin(bless({}, 'DBIx::QuickORM::Plugin')) }, "Valid plugin is OK");
    is(@{$bld->top->{plugins}}, 1, "1 plugin present");

    my $plugin = plugin('My::Plugin');
    isa_ok($plugin, ['DBIx::QuickORM::Plugin::My::Plugin', 'DBIx::QuickORM::Plugin'], "Can add plugin by class");
    is(@{$bld->top->{plugins}}, 2, "2 plugins present");

    $plugin = plugin('+DBIx::QuickORM::Plugin::My::Plugin');
    isa_ok($plugin, ['DBIx::QuickORM::Plugin::My::Plugin', 'DBIx::QuickORM::Plugin'], "Can add plugin by fully qualified class prefixed by +");
    is(@{$bld->top->{plugins}}, 3, "3 plugins present");

    is(plugins(), $bld->top->{plugins}, "Got all the plugins");

    $bld->top->{plugins} = [];

    plugins
        '+DBIx::QuickORM::Plugin' => {foo => 1},
        'My::Plugin' => {bar => 1},
        'My::Plugin',
        '+DBIx::QuickORM::Plugin';

    is(
        plugins(),
        [
            bless({foo => 1}, 'DBIx::QuickORM::Plugin'),
            bless({bar => 1}, 'DBIx::QuickORM::Plugin::My::Plugin'),
            bless({}, 'DBIx::QuickORM::Plugin::My::Plugin'),
            bless({}, 'DBIx::QuickORM::Plugin'),
        ],
        "Can add a bunch of plugins with optional params"
    );

    $bld->top->{plugins} = [];

    like(
        dies { meta() },
        qr/Cannot access meta without a builder/,
        "Cannot use meta without a build",
    );

    like(
        dies { build_class('DBIx::QuickORM') },
        qr/Cannot set the build class without a builder/,
        "Cannot access without a builder"
    );

    like(
        dies { build_class() },
        qr/Not enough arguments/,
        "Must specify a class"
    );

    like(
        dies { build_class('') },
        qr/You must provide a class name/,
        "Must specify a class"
    );

    like(
        dies { build_class('Some::Fake::Class::That::Should::Not::Exist') },
        qr/Could not load class 'Some::Fake::Class::That::Should::Not::Exist': Can't locate Some/,
        "Must be a valid class"
    );

    my $db_inner;
    server somesql => sub {
        host 'foo';

        $db_inner = db somedb => sub {
            user 'bob';
        };
    };

    my $db = db('somesql.somedb');
    ref_is($db, $db_inner, "Same blessed ref");
    isa_ok($db, ['DBIx::QuickORM::DB'], "Got a db instance");
    like(
        $db,
        {
            user => 'bob',      # From db { ... }
            host => 'foo',      # From server { ... }
            name => 'somedb',
        },
        "Got expected db fields"
    );

    db otherdb => sub {
        host 'boo';
        user 'boouser';
        pass 'boopass';

        meta bah => 'humbug';
        is(meta()->{bah}, 'humbug', "Set the meta data directly");

        like(
            meta(),
            {
                host => 'boo',
                name => 'otherdb',
                user => 'boouser',
                pass => 'boopass',
                bah  => 'humbug',
            },
            "The fields were set"
        );
    };

    is(
        db('otherdb'),
        {
            host => 'boo',
            name => 'otherdb',
            user => 'boouser',
            pass => 'boopass',
            bah  => 'humbug',
        },
        "Created a db without a server"
    );

    db fake => sub {
        build_class 'DBIx::QuickORM::DB::Fake';
    };
    isa_ok(db('fake'), ['DBIx::QuickORM::DB::Fake'], "Got the alternate build class");

    db full => sub {
        db_name "full_db";
        driver 'Fake';

        connect sub { die "oops" };

        attributes {foo => 1};
        is(meta->{attributes}, {foo => 1}, "Can set attrs with a hashref");
        attributes foo => 2;
        is(meta->{attributes}, {foo => 2}, "Can set attrs with pairs");

        dsn "mydsn";
        host "myhost";
        port 1234;
        socket 'mysocket';
        user "me";
        pass "hunter1";

        like(dies { connect 'foo' }, qr/connect must be given a coderef as its only argument, got 'foo' instead/, "Only coderef");
        like(dies { attributes [] }, qr/attributes\(\) accepts either a hashref, or \(key => value\) pairs/, "Must be valid attributes");

    };

    isa_ok(db('full'), ['DBIx::QuickORM::DB::Fake'], "Got the driver class");
    is(
        db('full'),
        {
            name       => 'full_db',
            connect    => T(),
            attributes => {foo => 2},
            dsn        => "mydsn",
            host       => "myhost",
            port       => 1234,
            socket     => 'mysocket',
            user       => 'me',
            pass       => 'hunter1',
        },
        "All builders worked"
    );

    schema variable => sub {
        table foo => sub {
            alt alt_a => sub {
                column a => {affinity => 'string'};
            };

            alt alt_b => sub {
                column a => {affinity => 'numeric'};
            };

            column x => sub {
                affinity 'boolean';
                alt alt_a => sub {
                    affinity 'string';
                };
                alt alt_b => sub {
                    affinity 'numeric';
                };
            };
        };

        alt alt_a => sub {
            table a1 => sub {
                column a => sub { affinity 'string' }
            };
        };

        alt alt_b => sub {
            table a2 => sub { column a => sub { affinity 'numeric' } };
        };
    };


    is(
        schema('variable'),
        {
            name => 'variable',
            tables => {
                foo => {
                    name => 'foo',
                    columns => {
                        x => {
                            name => 'x',
                            affinity => 'boolean',
                        },
                    },
                },
            },
        },
        "Got a base variable schema",
    );

    is(
        schema('variable:alt_a'),
        {
            name => 'variable',
            tables => {
                foo => {
                    name => 'foo',
                    columns => {
                        a => {
                            name => 'a',
                            affinity => 'string',
                        },
                        x => {
                            name => 'x',
                            affinity => 'string',
                        },
                    },
                },
                a1 => {
                    name => 'a1',
                    columns => {
                        a => {
                            name => 'a',
                            affinity => 'string',
                        },
                    },
                },
            },
        },
        "Got the alt_a variant of the variable schema",
    );

    is(
        schema('variable:alt_b'),
        {
            name => 'variable',
            tables => {
                foo => {
                    name => 'foo',
                    columns => {
                        a => {
                            name => 'a',
                            affinity => 'numeric',
                        },
                        x => {
                            name => 'x',
                            affinity => 'numeric',
                        },
                    },
                },
                a2 => {
                    name => 'a2',
                    columns => {
                        a => {
                            name => 'a',
                            affinity => 'numeric',
                        },
                    },
                },
            },
        },
        "Got the alt_b variant of the variable schema",
    );

    server variable => sub {
        pass "foo";

        alt mysql => sub {
            host 'mysql';
            port 1234;
            user 'my_user';
        };

        alt postgresql => sub {
            host 'postgresql',
            port 2345;
            user 'pg_user';
        };

        db 'db_one';
        db 'db_two';
    };

    is(
        db('variable.db_one:mysql'),
        {
            host => 'mysql',
            name => 'db_one',
            pass => 'foo',
            port => 1234,
            user => 'my_user',
        },
        "Got 'db_one' from server 'variable', 'mysql' variant",
    );

    is(
        db('variable.db_one:postgresql'),
        {
            host => 'postgresql',
            name => 'db_one',
            pass => 'foo',
            port => 2345,
            user => 'pg_user',
        },
        "Got 'db_one' from server 'variable', 'postgresql' variant",
    );

    is(
        db('variable.db_two:mysql'),
        {
            host => 'mysql',
            name => 'db_two',
            pass => 'foo',
            port => 1234,
            user => 'my_user',
        },
        "Got 'db_two' from server 'variable', 'mysql' variant",
    );

    is(
        db('variable.db_two:postgresql'),
        {
            host => 'postgresql',
            name => 'db_two',
            pass => 'foo',
            port => 2345,
            user => 'pg_user',
        },
        "Got 'db_two' from server 'variable', 'postgresql' variant",
    );

    db 'from_creds' => sub {
        creds sub {
            return {
                host => 'hostname',
                user => 'username',
                pass => 'password',
                port => 1234,
                socket => 'socketname',
            }
        };
    };

    is(
        db('from_creds'),
        {
            name   => 'from_creds',
            host   => 'hostname',
            user   => 'username',
            pass   => 'password',
            port   => 1234,
            socket => 'socketname',
        },
        "Got credentials from subroutine",
    );
}

{
    package Test::Consumer;
    use Test2::V0;

    Test::ORM->import;
    imported_ok('qorm');

    Test::ORM->import('other_qorm');
    imported_ok('other_qorm');

    ref_is(qorm(), Test::ORM->builder, "shortcut to the 'DBIx::QuickORM' instance");

    isa_ok(qorm(db => 'somesql.somedb'), ['DBIx::QuickORM::DB'], "Got the db by name");
    isa_ok(qorm(db => 'variable.db_one:postgresql'), ['DBIx::QuickORM::DB'], "Got the db by name and variation");

    like(dies { qorm(1 .. 10) },         qr/Too many arguments/,                                             "Too many args");
    like(dies { qorm('fake') },          qr/'fake' is not a defined ORM/,                                    "Need to provide a valid orm name");
    like(dies { qorm('fake' => 'foo') }, qr/'fake' is not a valid item type to fetch from 'Test::Consumer'/, "We do not define any 'fake's here");
}

done_testing;


__END__

