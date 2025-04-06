package My::ORM;
use lib 't/lib';
use Test2::V0 -target => 'DBIx::QuickORM', '!meta', '!pass';
use DBIx::QuickORM;
use DBIx::QuickORM::Test;
use Carp::Always;

do_for_all_dbs {
    my $db = shift;

    db mydb => sub {
        dialect curdialect();
        db_name 'quickdb';
        connect sub { $db->connect };
    };

    orm my_orm => sub {
        db 'mydb';
        autofill;
    };

    package main;
    use Test2::V0;
    My::ORM->import('qorm');

    my $con = qorm('my_orm');
    my $s = $con->source('example');

    subtest external_txns => sub {
        my $dbh = $con->dbh;
        ok(!$con->in_txn, "Not in a transaction");
        $dbh->begin_work;
        ok($con->in_txn, "In transaction");
        is($con->in_txn, 1, "Not a txn object");
        ok(!$con->current_txn, "No current transaction oject to fetch");
        $dbh->commit;
        ok(!$con->in_txn, "Not in a transaction");
    };

    subtest rows => sub {
        ok(my $row_a = $s->insert({name => 'a'}), "Inserted a row");
        ok(my $row_b = $s->insert({name => 'b'}), "Inserted a row");
        ok(my $row_c = $s->insert({name => 'c'}), "Inserted a row");


    };
} qw/system_postgresql/;


done_testing;
