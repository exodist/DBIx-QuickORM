use Test2::V0 -target => 'DBIx::QuickORM', '!meta', '!pass';
use DBIx::QuickORM;
use Carp::Always;

use Scalar::Util qw/blessed/;
use Time::HiRes qw/sleep/;

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
    ok(my $row = $orm->source('example')->insert({name => 'a'}), "Inserted a row");

    my $async = $orm->async(example => (where => {name => 'a'}, fields => ['name', 'id', \'pg_sleep(1)']))->first;
    my $other_ref = $async;

    my $nasync = $orm->in_async;

    my $counter = 0;
    my $ready;
    until($ready = $async->ready) {
        $counter++;
        sleep 0.1 if $counter > 1;
    }

    ok($nasync, "We were in a sync query back when we stashed the value");
    ok(!$orm->in_async, "Async query is over");

    ok($counter > 1, "We waited at least once ($counter)");

    ok(blessed($ready), 'DBIx::QuickORM::Row', "Row was returned from ready()");
    ref_is($ready, $row, "same ref");

    is(blessed($async), 'DBIx::QuickORM::Row::Async', "Still async");
    my $copy = $async->row;
    is($async->field('name'), 'a', "Can get value");
    is(blessed($async), 'DBIx::QuickORM::Row', "Not async anymore!");
    ref_is($async, $row, "Same ref");
    ref_is($copy, $row, "Same ref");

    is(blessed($other_ref), 'DBIx::QuickORM::Row::Async', "Other ref is unchanged");
} qw/system_postgresql/;

done_testing;
