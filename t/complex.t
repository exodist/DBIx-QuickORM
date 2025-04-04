use Test2::V0 -target => 'DBIx::QuickORM', '!meta', '!pass';
use DBIx::QuickORM;
use Carp::Always;

use lib 't/lib';
use DBIx::QuickORM::Test;

do_for_all_dbs {
    my $db = shift;

    my $is_bin = curdialect() =~ m/(percona|community)/i || curname() =~ m/system_mysql/;

    db my_db => sub {
        dialect curdialect();
        db_name 'quickdb';
        connect sub { $db->connect };
    };

    orm my_orm => sub {
        db 'my_db';

        schema my_schema => sub {
            table example => sub {
                column id => sub {
                    affinity 'numeric';
                    primary_key;
                    identity;
                };

                column name => sub {
                    affinity 'string';
                };

                column my_uuid => sub {
                    db_name 'uuid';
                    type 'UUID';
                    affinity 'binary' if $is_bin;
                };

                column my_data => sub {
                    db_name 'data';
                    type 'JSON';
                };
            };
        };
    };

    my $orm = orm('my_orm');
    my $con = $orm->connect;

    my $s = $orm->source('example');

    my $a_uuid = DBIx::QuickORM::Type::UUID->new;
    my $uuid_bin = DBIx::QuickORM::Type::UUID::qorm_deflate($a_uuid, 'binary');

    my $x_row  = $s->insert({name => 'x', my_uuid => DBIx::QuickORM::Type::UUID->new, my_data => {name => 'x'}});

    my $a_row  = $s->insert({name => 'a', my_uuid => $a_uuid, my_data => {name => 'a'}});
    is(
        $a_row->stored_data,
        {
            id      => 2,
            name    => 'a',
            my_uuid => $is_bin ? $uuid_bin : $a_uuid,
            my_data => match qr/{"name":\s*"a"}/,
        },
        "Got stored data with correct (orm) field names, and in uninflated forms"
    );
    like(
        dies { $a_row->field('uuid') },
        qr/This row does not have a 'uuid' field/,
        "Cannot get field 'uuid', we have a 'my_uuid' field"
    );
    is($a_row->field('my_uuid'),      $a_uuid,       "Inflated UUID as string");
    is(ref($a_row->field('my_data')), 'HASH',        "Inflated JSON");
    is($a_row->field('my_data'),      {name => 'a'}, "deserialized json");

    $a_row->update({my_data => {name => 'a2'}});
    is($a_row->stored_data->{my_data}, match qr/{"name":\s*"a2"}/, "Updated in storage");
    is($a_row->field('my_data'),       {name => 'a2'},             "Updated json");

    $a_row->field(my_data => {name => 'a3'});
    is($a_row->pending_data->{my_data}, {name => "a3"}, "Updated in pending");
    is($a_row->stored_data->{my_data},  {name => 'a2'}, "Old data is still listed in stored");
    $a_row->save;
    is($a_row->stored_data->{my_data}, match qr/{"name":\s*"a3"}/, "Updated in storage");

    ref_is($s->one({my_uuid => $a_uuid}),   $a_row, "Found a by UUID string");
    ref_is($s->one({my_uuid => $uuid_bin}), $a_row, "Found a by UUID binary");

    isnt($a_uuid, $uuid_bin, "Binary and string forms are not the same");

    $a_row->field(name => 'aa');
    $con->dbh->do("UPDATE example SET name = 'ax' WHERE id = 2");
    $a_row->refresh;
    like(
        $a_row,
        {
            stored  => {name => 'ax'},
            pending => {name => 'aa'},
            desync  => {name => 1},
        },
        "Row is desynced, pending changes were made before a refresh showed changes",
    );

    my $b_uuid = DBIx::QuickORM::Type::UUID->new;
    $uuid_bin = DBIx::QuickORM::Type::UUID::qorm_deflate($b_uuid, 'binary');
    my $b_row  = $s->insert({name => 'b', my_uuid => DBIx::QuickORM::Type::UUID->qorm_deflate($b_uuid, 'binary'), my_data => {name => 'b'}});
    is(
        $b_row->stored_data,
        {
            id      => 3,
            name    => 'b',
            my_uuid => $is_bin ? $uuid_bin : $b_uuid,
            my_data => match qr/{"name":\s*"b"}/,
        },
        "Got stored data with correct (orm) field names, and in uninflated forms"
    );
    is($b_row->field('my_uuid'), $b_uuid, "uuid conversion from binary occured");

    like(
        dies { $s->insert({name => 'x', my_uuid => "NOT A UUID", my_data => {name => 'bx'}}) },
        qr/'NOT A UUID' does not look like a uuid/,
        "Invalid UUID"
    );
};

done_testing;
