use Test2::V0 -target => 'DBIx::QuickORM', '!meta', '!pass';
use DBIx::QuickORM;
use Carp::Always;
use Test2::Plugin::DieOnFail;

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
        autofill sub {
            autorow 'My::Test::Row';
            autoname link => sub {
                my %params = @_;
                return "get_$params{fetch_table}";
            };
        };
    };

    ok(my $orm = orm('my_orm')->connect, "Got a connection");

    my $foo_a = $orm->insert(foo => {name => 'a'});
    my $foo_b = $orm->insert(foo => {name => 'b'});
    my $foo_c = $orm->insert(foo => {name => 'c'});

    my $bar_a  = $orm->insert(bar => {name => 'a',  foo_id => $foo_a->foo_id});
    my $bar_a2 = $orm->insert(bar => {name => 'a2', foo_id => $foo_a->foo_id});
    my $bar_a3 = $orm->insert(bar => {name => 'a3', foo_id => $foo_a->foo_id});
    my $bar_b  = $orm->insert(bar => {name => 'b',  foo_id => $foo_b->foo_id});
    my $bar_c  = $orm->insert(bar => {name => 'c',  foo_id => $foo_c->foo_id});

    my $baz = $orm->insert(baz => {name => 'a', foo_id => $foo_a->foo_id, bar_id => $bar_a->bar_id});

    my $sel = $orm->select('foo')->join('bar')->join('get_baz')->data_only;
    debug($sel->all);
} qw/system_postgresql/;

done_testing;
