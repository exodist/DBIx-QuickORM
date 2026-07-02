use Test2::V0 '!meta', '!pass';
use DBI;
use File::Temp qw/tempdir/;

# Correctness fixes for the DSL:
#  I3: quick() rejects unknown credentials keys instead of silently ignoring them.
#  B13: columns(@names, sub {...}) applies the builder to each named column.

BEGIN {
    skip_all "DBD::SQLite is required for these tests"
        unless eval { require DBD::SQLite; 1 };
}

require DBIx::QuickORM;

subtest quick_rejects_unknown_credentials => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $dsn = "dbi:SQLite:dbname=$dir/x.sqlite";
    {
        my $dbh = DBI->connect($dsn, '', '', {RaiseError => 1, PrintError => 0});
        $dbh->do('CREATE TABLE t (id INTEGER PRIMARY KEY)');
        $dbh->disconnect;
    }

    like(
        dies { DBIx::QuickORM->quick(credentials => {dsn => $dsn, passsword => 'typo'}) },
        qr/Unknown credentials key\(s\): passsword/,
        "a misspelled credentials key croaks instead of connecting wrong",
    );

    ok(lives { DBIx::QuickORM->quick(credentials => {dsn => $dsn}) }, "valid credentials still connect");
};

subtest columns_with_trailing_builder => sub {
    {
        package My::Test::DSL::B13;
        use DBIx::QuickORM;

        schema b13 => sub {
            table t => sub {
                column id => sub { affinity 'numeric'; primary_key };
                columns(qw/a b/, sub { affinity 'string' });
            };
        };
    }

    my $cols = My::Test::DSL::B13->can('schema')->('b13')->{tables}->{t}->{columns};
    is($cols->{a}->{affinity}, 'string', "columns() applied the builder to column a");
    is($cols->{b}->{affinity}, 'string', "columns() applied the builder to column b");
};

subtest schema_link_requires_two_nodes => sub {
    like(
        dies {
            package My::Test::DSL::B10;
            use DBIx::QuickORM;
            schema b10 => sub {
                table a => sub { column id  => sub { primary_key; affinity 'numeric' } };
                table b => sub { column bid => sub { primary_key; affinity 'numeric' } };
                link {table => 'a', columns => ['id']};    # only one node
            };
        },
        qr/exactly two nodes/,
        "a schema-context link with only one node croaks instead of an undef-deref",
    );
};

done_testing;
