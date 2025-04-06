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

                column uuid => sub {
                    type 'UUID';
                    affinity 'binary' if $is_bin;
                };

                column data => sub {
                    type 'JSON';
                };
            };
        };
    };

    my $orm = orm('my_orm');
    my $con = $orm->connect;

    my $s = $con->source('example');

    my $a_uuid = DBIx::QuickORM::Type::UUID->new;
    my $uuid_bin = DBIx::QuickORM::Type::UUID::qorm_deflate($a_uuid, 'binary');

    my $x_row  = $s->insert({name => 'x', uuid => DBIx::QuickORM::Type::UUID->new, data => {name => 'x'}});

    my $a_row  = $s->insert({name => 'a', uuid => $a_uuid, data => {name => 'a'}});
    is(
        $a_row->stored_data,
        {
            id      => 2,
            name    => 'a',
            uuid => $is_bin ? $uuid_bin : $a_uuid,
            data => match qr/{"name":\s*"a"}/,
        },
        "Got stored data with correct (orm) field names, and in uninflated forms"
    );
    like(
        dies { $a_row->field('my_uuid') },
        qr/This row does not have a 'my_uuid' field/,
        "Cannot get field 'my_uuid', we have a 'uuid' field"
    );
    is($a_row->field('uuid'),      $a_uuid,       "Inflated UUID as string");
    is(ref($a_row->field('data')), 'HASH',        "Inflated JSON");
    is($a_row->field('data'),      {name => 'a'}, "deserialized json");

    $a_row->update({data => {name => 'a2'}});
    is($a_row->stored_data->{data}, match qr/{"name":\s*"a2"}/, "Updated in storage");
    is($a_row->field('data'),       {name => 'a2'},             "Updated json");

    $a_row->field(data => {name => 'a3'});
    is($a_row->pending_data->{data}, {name => "a3"}, "Updated in pending");
    is($a_row->stored_data->{data},  {name => 'a2'}, "Old data is still listed in stored");
    $a_row->save;
    is($a_row->stored_data->{data}, match qr/{"name":\s*"a3"}/, "Updated in storage");

    ref_is($s->one({uuid => $a_uuid}),   $a_row, "Found a by UUID string");
    ref_is($s->one({uuid => $uuid_bin}), $a_row, "Found a by UUID binary");

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
    my $b_row  = $s->insert({name => 'b', uuid => DBIx::QuickORM::Type::UUID->qorm_deflate($b_uuid, 'binary'), data => {name => 'b'}});
    is(
        $b_row->stored_data,
        {
            id      => 3,
            name    => 'b',
            uuid => $is_bin ? $uuid_bin : $b_uuid,
            data => match qr/{"name":\s*"b"}/,
        },
        "Got stored data with correct (orm) field names, and in uninflated forms"
    );
    is($b_row->field('uuid'), $b_uuid, "uuid conversion from binary occured");

    like(
        dies { $s->insert({name => 'x', uuid => "NOT A UUID", data => {name => 'bx'}}) },
        qr/'NOT A UUID' does not look like a uuid/,
        "Invalid UUID"
    );
};

done_testing;
