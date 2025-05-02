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
            autoname link => sub {
                my %params = @_;
                return "get_$params{fetch_table}";
            };
        };
    };

    ok(my $orm = orm('my_orm')->connect, "Got a connection");

    my $foo_a = $orm->insert('foo' => {name => 'a'});
    my $foo_b = $orm->insert('foo' => {name => 'b'});

    my $has_foo_a1 = $orm->insert('has_foo' => {foo_id => $foo_a->field('foo_id')});
    my $has_foo_a2 = $orm->insert('has_foo' => {foo_id => $foo_a->field('foo_id')});
    my $has_foo_b  = $orm->insert('has_foo' => {foo_id => $foo_b->field('foo_id')});

    my $sel = $foo_a->follow('get_has_foo');
    is([$sel->order_by('foo_id')->all], [$has_foo_a1, $has_foo_a2], "Got both has_foo rows");

    is($has_foo_a1->obtain('get_foo'), $foo_a, "Got foo_a");

    like(
        dies { $foo_a->obtain('get_has_foo') },
        qr/The specified link does not point to a unique row/,
        "Cannot obtain on a non unique link",
    );

    my $has_foo_a3 = $foo_a->insert_related('get_has_foo', {});
    my $has_foo_a4 = $foo_a->insert_related('get_has_foo', {});

    like(
        dies { $foo_a->insert_related('get_has_foo', {foo_id => undef}) },
        qr/field 'foo_id' already exists in provided row data/,
        "Cannot pre-populate the fields from the link",
    );

    is($has_foo_a4->siblings('get_foo')->count,      4, "Got all 4 siblings (including self)");
    is($has_foo_a4->siblings(['foo_id'])->count,     4, "Got all 4 siblings (including self)");
    is($has_foo_a4->siblings(['has_foo_id'])->count, 1, "Only self");

    my $link = bless({}, 'DBIx::QuickORM::Link');
    ref_is($foo_a->parse_link($link), $link, "If it is already a link just return it");

    $link = $foo_a->parse_link({table => 'has_foo', local_columns => ['foo_id'], other_columns => ['foo_id']});
    isa_ok($link, ['DBIx::QuickORM::Link'], "Created a link object");
    like(
        $link,
        {local_table => 'foo', other_table => 'has_foo', local_columns => ['foo_id'], other_columns => ['foo_id'], unique => F()},
        "Created link, and set unique"
    );

    $link = $has_foo_a1->parse_link({table => 'foo', local_columns => ['foo_id'], other_columns => ['foo_id']});
    isa_ok($link, ['DBIx::QuickORM::Link'], "Created a link object");
    like(
        $link,
        {local_table => 'has_foo', other_table => 'foo', local_columns => ['foo_id'], other_columns => ['foo_id'], unique => T()},
        "Created link, and set unique"
    );

    is(
        $foo_a->parse_link(\'has_foo'),
        $orm->schema->table('foo')->links_by_alias->{get_has_foo},
        "Got the only link to the specified table",
    );

    like(
        $foo_a->parse_link({has_foo => 'foo_id'}),
        {local_table => 'foo', other_table => 'has_foo', local_columns => ['foo_id'], other_columns => ['foo_id'], unique => F()},
        "Super simple search"
    );

    like(
        $foo_a->parse_link({has_foo => ['foo_id']}),
        {local_table => 'foo', other_table => 'has_foo', local_columns => ['foo_id'], other_columns => ['foo_id'], unique => F()},
        "Super simple search, multi-col"
    );

    like(
        $foo_a->parse_link({has_foo => {local => 'foo_id', other => 'foo_id'}}),
        {local_table => 'foo', other_table => 'has_foo', local_columns => ['foo_id'], other_columns => ['foo_id'], unique => F()},
        "Another form"
    );

    like(
        $foo_a->parse_link({local_table => 'foo', other_table => 'has_foo', fields => 'foo_id', has_foo => 'foo_id'}),
        {local_table => 'foo', other_table => 'has_foo', local_columns => ['foo_id'], other_columns => ['foo_id'], unique => F()},
        "Long form"
    );

    like(
        $foo_a->parse_link({local_table => 'foo', other_table => 'has_foo', local_fields => 'foo_id', has_foo => 'foo_id'}),
        {local_table => 'foo', other_table => 'has_foo', local_columns => ['foo_id'], other_columns => ['foo_id'], unique => F()},
        "Long form 2"
    );

    like(
        $foo_a->parse_link({table => 'has_foo', fields => ['foo_id']}),
        {local_table => 'foo', other_table => 'has_foo', local_columns => ['foo_id'], other_columns => ['foo_id'], unique => F()},
        "Long form 3"
    );
} qw/system_postgresql/;

done_testing;
