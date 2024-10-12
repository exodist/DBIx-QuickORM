use Test2::V0 -target => 'DBIx::QuickORM::Conflator::UUID';

use ok $CLASS;

use lib 't/lib';
use DBIx::QuickORM::Tester qw/dbs_do all_dbs/;
use DBIx::QuickORM;

use DBIx::QuickORM::Conflator::UUID;

my $uuid = DBIx::QuickORM::Conflator::UUID->create;
my $str  = $uuid->as_string;
my $bin  = $uuid->as_binary;

dbs_do db => sub {
    my ($dbname, $dbc, $st) = @_;

    my $uuid_type = $dbname =~ m/^(MySQL|Percona)$/i ? 0 : 1;

    my $orm = orm myorm => sub {
        db mydb => sub {
            db_class $dbname;
            db_name 'quickdb';
            db_connect sub { $dbc->connect };
        };

        schema myschema => sub {
            table mytable => sub {
                column my_id => sub {
                    primary_key;
                    serial;
                    sql_spec(
                        mysql      => {type => 'INTEGER'},
                        postgresql => {type => 'SERIAL'},
                        sqlite     => {type => 'INTEGER'},

                        type => 'INTEGER',    # Fallback
                    );
                };

                column uuid_type => sub { conflate $CLASS };

                column char_type    => sub { conflate $CLASS; sql_spec(type => 'CHAR(36)') };
                column varchar_type => sub { conflate $CLASS; sql_spec(type => 'VARCHAR(36)') };

                if ($dbname =~ m/PostgreSQL/i) {
                    column bin_type => sub { conflate $CLASS; sql_spec(type => 'BYTEA') };
                }
                elsif ($dbname =~ m/percona/i) {
                    column bin_type => sub { conflate $CLASS; sql_spec(type => 'BINARY(16)') };
                }
                else {
                    # MariaDB (or DBD::MariaDB?) do not like inserting the uuid into binaries limited to 16, which is weird.
                    column bin_type => sub { conflate $CLASS; sql_spec(type => 'BINARY(16)') };
                }
            };
        };
    };

    note uc("== SQL for $dbname ==\n" . $orm->generate_schema_sql . "\n== END SQL for $dbname ==\n");

    ok(lives { $orm->generate_and_load_schema() }, "Generate and load schema");
    my @cols = qw/uuid_type char_type varchar_type bin_type/;

    my $s = $orm->source('mytable');

    my $row1 = $s->insert(map {($_ => $str)} @cols);
    my $row2 = $s->insert(map {($_ => $bin)} @cols);
    my $row3 = $s->insert(map {($_ => $uuid)} @cols);

    is($row1->from_db, { %{$row2->from_db}, my_id => T()}, "Rows 1 and 2 are identical");
    is($row1->from_db, { %{$row3->from_db}, my_id => T()}, "Rows 1 and 3 are identical");

    is($row1->from_db->{bin_type}, $bin, "Got binary data");
    is(uc($row1->from_db->{$_}), $str, "Got stringy data") for grep { $_ ne 'bin_type' && !($_ eq 'uuid_type' && !$uuid_type) } @cols;

    my $ref = "$row1";
    $row1 = undef;
    $s->connection->clear_cache;

    $row1 = $s->find(1);
    ok("$row1" ne $ref, "Got a clean row from the db, new ref");
    is($row1->column('bin_type')->as_string, $str, "Round trip bin_type");
};

done_testing;
