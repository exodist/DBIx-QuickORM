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
    use DBIx::QuickORM::Test;
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
        my $row_a;
        $con->txn(sub {
            ok($row_a = $s->insert({name => 'a'}), "Inserted a row");
        });
        ok($row_a->is_valid, "Row is valid");
        ok($row_a->is_stored, "Row is in storage");

        my $row_b;
        $con->txn(sub {
            my $txn = shift;

            ok($row_b = $s->insert({name => 'b'}), "Inserted a row");

            ok($row_b->is_valid, "Row is valid");
            ok($row_b->is_stored, "Row is in storage");

            $txn->rollback;
        });

        ok(!$row_b->is_valid,  "Row is not valid anymore");
        ok(!$row_b->is_stored, "Row is not in storage anymore");

        like(
            dies { $row_b->field('name') },
            qr/This row is invalid \(Likely inserted during a transaction that was rolled back\)/,
            "Cannot use an invalid row"
        );

        $con->txn(sub {
            my $txn = shift;

            ok($row_b = $s->insert({name => 'b'}), "Inserted a row");

            ok($row_b->is_valid, "Row is valid");
            ok($row_b->is_stored, "Row is in storage");
        });

        ok($row_b->is_valid, "Row is valid");
        ok($row_b->is_stored, "Row is in storage");

        my $row_c;
        $con->txn(sub {
            $con->txn(sub {
                $con->txn(sub {
                    $con->txn(sub {
                        ok($row_c = $s->insert({name => 'c'}), "Inserted a row");

                        ok($row_c->is_valid,  "Row is valid");
                        ok($row_c->is_stored, "Row is in storage");
                    });

                    ok($row_c->is_valid,  "Row is valid");
                    ok($row_c->is_stored, "Row is in storage");
                });

                $con->txn(sub {
                    ok($row_c->is_valid,  "Row is valid");
                    ok($row_c->is_stored, "Row is in storage");
                    ok($row_c->row_data->{transaction} != $_[0], "It did not shift up to the new txn");
                });

                ok($row_c->row_data->{transaction} == $_[0], "It shifted down to this txn");

                ok($row_c->is_valid,  "Row is valid");
                ok($row_c->is_stored, "Row is in storage");

                $_[0]->rollback;
            });

            ok(!$row_c->is_valid,  "Row is not valid anymore");
            ok(!$row_c->is_stored, "Row is not in storage anymore");
        });

        ok(!$row_c->is_valid,  "Row is not valid anymore");
        ok(!$row_c->is_stored, "Row is not in storage anymore");

        like(
            dies { $row_c->field('name') },
            qr/This row is invalid \(Likely inserted during a transaction that was rolled back\)/,
            "Cannot use an invalid row"
        );
    };
};

done_testing;
