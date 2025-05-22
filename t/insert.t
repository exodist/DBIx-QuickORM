use Test2::V0 -target => 'DBIx::QuickORM', '!meta', '!pass';
use DBIx::QuickORM;
use Carp::Always;

use lib 't/lib';
use DBIx::QuickORM::Test;

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

    ok(my $orm = orm('my_orm')->connect, "Got a connection");
    my $h = $orm->handle('example');
    ok(my $row = $h->insert({name => 'a'}), "Inserted a row");
    is($row->field('id'), 1, "Got generated primary key");
    ok(!$row->stored_data->{xxx}, "Did not fetch 'xxx'");

    ok(my $row2 = $h->insert({name => 'b'}), "Inserted a row");
    is($row2->field('id'), 2, "Got generated primary key");
    ok(!$row2->stored_data->{xxx}, "Did not fetch 'xxx'");

    $h = $h->auto_refresh;

    my $row3 = $h->insert({name => 'c'});
    is($row3->field('id'), 3, "Got generated primary key");
    is($row3->stored_data->{xxx}, 'booger', "Fetched 'xxx' database set value");
};

done_testing;

