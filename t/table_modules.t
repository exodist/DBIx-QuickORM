use Test2::V0;
use lib 't/lib';
use DBIx::QuickORM::Tester qw/dbs_do all_dbs/;
use DBIx::QuickORM;

dbs_do db => sub {
    my ($dbname, $dbc, $st) = @_;

    my $orm = orm myorm => sub {
        db mydb => sub {
            db_class $dbname;
            db_name 'quickdb';
            db_connect sub { $dbc->connect };
        };

        schema myschema => sub {
            tables 'DBIx::QuickORM::Test::Tables';
        };
    };

    ok(lives { $orm->generate_and_load_schema() }, "Generate and load schema");

    is([sort $orm->connection->tables], bag { item 'aaa'; item 'bbb'; etc }, "Tables aaa and bbb were added");

    for my $set ([aaa => 'DBIx::QuickORM::Test::Tables::TestA'], [bbb => 'DBIx::QuickORM::Test::Tables::TestB']) {
        my ($tname, $class) = @$set;

        my $table = $orm->schema->table($tname);
        is($table,            $class->orm_table, "Got table data");
        is($table->row_class, $class,            "row class is set");

        my $row = $orm->source($tname)->insert(foo => 1);

        is($row->id, $row->column("${tname}_id"), "Added our own method to the row class");
        is($row->id, 1,                           "Got correct value");

        isa_ok($row, ['DBIx::QuickORM::Row', $class], "Got properly classed row");
    }
};

done_testing;
